# Log-Shipping Operations Runbook

## Scope

This runbook covers the `OperationsLab` log-shipping configuration between `LABHOST\SQLLAB1` and `LABHOST\SQLLAB2`. It is written for a controlled lab and must be reviewed before use elsewhere.

Normal roles:

- Primary: `LABHOST\SQLLAB1`, `OperationsLab` `ONLINE`.
- Secondary: `LABHOST\SQLLAB2`, `OperationsLab` `RESTORING`.
- Direction: SQLLAB1 backup job to the share, then SQLLAB2 copy and restore jobs.

## Operating rules

1. Identify the current writable primary from database state and application behavior; never infer it from a remembered job name alone.
2. Freeze application writes before a planned final-log backup.
3. Disable or stop relevant schedules before manually controlling the last backup/copy/restore sequence.
4. Preserve log-chain order. Never skip a required log backup.
5. Do not recover the destination until every intended log, including the tail log when available, has been restored.
6. After `WITH RECOVERY`, that database cannot accept additional log restores from the old chain.
7. Avoid leaving a database in `SINGLE_USER`. Use `MULTI_USER` for the normal `ONLINE` and `RESTORING` states.
8. Record UTC timestamps, filenames, marker IDs, job outcomes, database states, and any deviations.

## Preflight checks

Confirm all of the following before a planned transition:

- Current primary is `ONLINE` and writable.
- Current secondary is `RESTORING` or intentionally in `STANDBY`.
- No backup, copy, or restore job is currently running.
- SQL Server Agent is running on both instances.
- Relevant jobs and schedules have the expected enabled state.
- The backup share and local copy folder have adequate free space.
- Database Engine and Agent service accounts retain required share and NTFS permissions.
- The latest files form an unbroken log chain.
- A recent full backup exists and has been verified.
- Stakeholders know that writes will be paused.

## Read-only validation queries

Run this on each instance to confirm identity and database state:

```sql
SELECT
    CAST(SERVERPROPERTY('ServerName') AS sysname) AS connected_server,
    d.name AS database_name,
    d.state_desc,
    d.user_access_desc,
    d.recovery_model_desc
FROM sys.databases AS d
WHERE d.name = N'OperationsLab';
```

Inspect the current SQL Server Agent job state and most recent outcome in `msdb`:

```sql
SELECT
    j.name AS job_name,
    j.enabled AS job_enabled,
    ja.start_execution_date,
    ja.stop_execution_date,
    CASE
        WHEN ja.start_execution_date IS NOT NULL
         AND ja.stop_execution_date IS NULL THEN N'RUNNING'
        ELSE N'NOT RUNNING'
    END AS current_state
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobactivity AS ja
  ON ja.job_id = j.job_id
 AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
WHERE j.name LIKE N'LS%OperationsLab%'
ORDER BY j.name;
```

Run the following on the monitor/secondary instance. `last_copied_file` and `last_restored_file` belong to the monitor table, not `log_shipping_secondary`:

```sql
SELECT
    secondary_server,
    secondary_database,
    last_copied_file,
    last_copied_date,
    last_restored_file,
    last_restored_date,
    last_restored_latency
FROM msdb.dbo.log_shipping_monitor_secondary
WHERE secondary_database = N'OperationsLab';
```

Use **Management → Reports → Standard Reports → Transaction Log Shipping Status** on both instances as an additional check. A green `Good` result does not replace validation of the actual database state and latest restored file.

## Create a transition marker

Immediately before the final backup sequence, insert a unique marker on the writable primary and record the returned values. Adapt the column list to the repository's final table definition.

```sql
USE OperationsLab;
GO

DECLARE @marker uniqueidentifier = NEWID();

INSERT audit.ChangeLog (table_name, record_id, action_name, details)
VALUES
(
    N'OperationsLab',
    NULL,
    N'ROLE_MARKER',
    CONCAT(N'marker_id=', CONVERT(nvarchar(36), @marker))
);

SELECT
    @marker AS marker_id,
    SCOPE_IDENTITY() AS audit_id,
    SYSUTCDATETIME() AS recorded_at_utc;
```

Do not resume writes after this point until the role transition is complete or formally aborted.

## Planned failover: SQLLAB1 to SQLLAB2

1. Announce the write freeze and stop application writers, workload generators, Agent jobs, and maintenance tasks that can modify `OperationsLab`.
2. Verify there are no unexpected sessions or open transactions on SQLLAB1.
3. Disable the active log-shipping backup schedule on SQLLAB1 and the copy/restore schedules on SQLLAB2. Record the original states.
4. Insert and record a transition marker on SQLLAB1.
5. Take the final transaction-log backup. If the source is healthy and the transition is final, use a tail-log backup with `NORECOVERY`; this prevents further writes to the old primary.
6. Copy the final file to SQLLAB2 and confirm its size and filename.
7. Restore every outstanding log in sequence on SQLLAB2 using `NORECOVERY`, then restore the final/tail file using `RECOVERY`.
8. Confirm SQLLAB2 is `ONLINE`, `MULTI_USER`, writable, and contains the marker.
9. Point the test workload or application connection to `localhost,14332`.
10. Run smoke tests, row-count checks, constraint checks, and an application write/read test.
11. Keep SQLLAB1 non-writable until a reverse log-shipping configuration or reinitialization plan is complete.

### Stop conditions

Stop and investigate rather than forcing recovery if:

- a required file is missing or out of sequence;
- `RESTORE HEADERONLY` or restore output shows an unexpected database or log chain;
- the final backup cannot be read by the destination service account;
- an unexpected writer remains active;
- the destination marker does not match;
- the destination reports corruption or constraint failures.

## Reverse log shipping after failover

Once SQLLAB2 is the accepted primary:

1. Keep SQLLAB1 in `RESTORING` or reinitialize it from a fresh full backup of SQLLAB2.
2. Configure SQLLAB2 as the log-shipping primary and SQLLAB1 as the secondary.
3. Use a distinct backup/copy path so files from the two directions cannot be confused.
4. Grant the SQLLAB1 restore-side service account access to the reverse-direction files.
5. Enable the SQLLAB2 backup schedule and SQLLAB1 copy/restore schedules.
6. Manually run one backup, copy, and restore cycle in that order.
7. Confirm matching filenames and `Good` status before calling the reverse direction healthy.

## Planned failback: SQLLAB2 to SQLLAB1

1. Freeze all writes to SQLLAB2 and prove the workload is stopped.
2. Disable the reverse-direction backup, copy, and restore schedules. Wait for any executing job to finish.
3. Insert and record a new failback marker on SQLLAB2.
4. Run a final reverse backup/copy/restore cycle so SQLLAB1 receives the marker while remaining in `RESTORING`.
5. Take the SQLLAB2 tail-log backup with `NORECOVERY`. Record the exact filename and UTC time.
6. Copy the tail-log file to the SQLLAB1 restore location.
7. Restore it to SQLLAB1 using `WITH RECOVERY` only after confirming that all preceding files were restored.
8. Verify SQLLAB1 is `ONLINE`, `MULTI_USER`, writable, and contains the exact marker and audit ID.
9. Point the workload back to `localhost,14331` and perform smoke tests.
10. Reinitialize SQLLAB2 as the normal secondary if required, without overwriting the recovered SQLLAB1 database.
11. Re-enable only the original SQLLAB1 backup and SQLLAB2 copy/restore schedules.
12. Manually run one original-direction backup/copy/restore cycle. Confirm the same new filename appears at all three stages.
13. Wait for an unattended scheduled cycle and confirm the next filename also propagates successfully.

The controlled lab used failback marker `FA02E255-515B-4BE2-990C-991C81748635`, tail log `OperationsLab_20260928060131.trn`, and first unattended post-failback log `OperationsLab_20260928063200.trn`.

## Remove stale reverse-direction metadata

After the original direction is healthy, remove obsolete reverse-direction configuration so reports do not retain red `Alert` rows.

1. Script the existing configuration or take screenshots before changing metadata.
2. On the old reverse secondary, remove the reverse secondary-database configuration with the log-shipping UI or the supported `sp_delete_log_shipping_secondary_database` procedure.
3. If no reverse databases remain for that source, remove the reverse secondary-primary relationship.
4. On the old reverse primary, remove the primary-to-secondary mapping and then the obsolete reverse primary configuration.
5. Delete only orphaned reverse-direction jobs and schedules; preserve the active original-direction jobs.
6. Refresh both Transaction Log Shipping Status reports and confirm that only the active SQLLAB1-to-SQLLAB2 direction remains.

Do not delete `msdb` rows directly.

## Post-transition validation

Record each item in the runbook:

| Check | Required evidence |
|---|---|
| Active primary | Server name, database `ONLINE`, `MULTI_USER`, successful write/read |
| Active secondary | Server name and database `RESTORING` |
| Marker | Same GUID, audit ID, and timestamp on recovered primary |
| Jobs | Correct jobs and schedules enabled; obsolete direction disabled or removed |
| File continuity | Matching final filenames at backup, copy, and restore stages |
| Scheduled recovery | At least one unattended cycle succeeds |
| Log-shipping health | `Good` on both reports for the active direction |
| Database integrity | `DBCC CHECKDB` completes with zero errors |
| Data integrity | Expected row counts, totals, and constraints |

## RPO and RTO recording

- **RPO:** Compare the last committed marker/workload record on the source with the recovered destination. Record the number of known missing transactions. The controlled lab result was zero.
- **RTO:** Measure from the approved write-freeze or outage start to successful application validation on the recovered primary. If start and end times were not captured consistently, record RTO as not measured instead of estimating it.

## Abort and rollback

Before the final `WITH RECOVERY`, a planned transition can normally be paused while the destination remains in `RESTORING`. After the destination is recovered and accepts writes, do not attempt to resume the old direction as though nothing changed. Freeze writes, choose an authoritative copy, and establish a new restore chain. If authority is ambiguous, stop both writers and escalate rather than attempting to merge divergent databases.

