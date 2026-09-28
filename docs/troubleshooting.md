# Troubleshooting Notes

This document records issues encountered while building the lab. Server names and account names are anonymized.

## Quick diagnostic sequence

Before changing configuration:

1. Confirm the SSMS status bar shows the intended server and database.
2. Run `SELECT @@SERVERNAME, DB_NAME();`.
3. Check `sys.databases` for the current database state and access mode.
4. Check whether a relevant Agent job is already running.
5. Read the complete error message and Agent job-step output.
6. Verify which Windows identity actually accesses a local folder or UNC path.
7. Preserve filenames, timestamps, and job history before retrying.

## Encountered issues

| Symptom | Cause | Resolution | Verification |
|---|---|---|---|
| `Msg 5039: MODIFY FILE failed. Specified size is less than or equal to current size.` | The deployment script requested an initial file size that was not larger than the existing file. SQL Server will not use `MODIFY FILE (SIZE=...)` to shrink a file. | Treat it as a nonfatal idempotency issue. Query current sizes and only issue the change when the target is larger. Do not shrink merely to silence the message. | Query `sys.database_files`; confirm size and fixed autogrowth values meet or exceed the baseline. |
| Backup `VERIFYONLY` or restore returned operating-system error 5, Access is denied | The SQL Server service identity, not the interactive administrator, performs SQL Server file I/O. It lacked NTFS or share permission. | Grant the correct Database Engine virtual account access to the backup folder and, for a UNC location, both share and NTFS permissions. Grant Agent access where job steps require it. | Run a small backup through SQL Server, then `RESTORE VERIFYONLY`; do not rely only on an interactive `Test-Path`. |
| `Invalid object name 'app.Orders'` | The query window was connected to `master` or another database. | Select `OperationsLab` in the database dropdown or begin the batch with `USE OperationsLab; GO`. | Run `SELECT DB_NAME();` and then query `app.Orders`. |
| PowerShell `Test-Path` on `\\LABHOST\SQLLabLS$` returned Access is denied | The interactive PowerShell account did not have access, even though a SQL Server virtual service account might have the required rights. | Test the correct security principal and inspect both share and NTFS ACLs. Do not broaden permissions to `Everyone` merely to make the test pass. | Execute the actual SQL Agent backup/copy operation and confirm the file is created or copied. |
| Health-snapshot schedule existed but no new successful row appeared | SQL Server Agent was stopped, the job/schedule association was disabled, the start date/time was in the future, or the job was already executing. | Verify Agent state, job and schedule enabled flags, job-to-schedule attachment, active start date, next run time, and job activity. Start once manually to isolate scheduling from procedure failures. | Confirm new `SUCCEEDED` rows at successive scheduled intervals and review job history. |
| `logman query 'SQLLAB1 Baseline'` reported Data Collector Set not found | The collector was created in a different user/elevation context or the queried name differed. | Open Performance Monitor and PowerShell with the same elevated identity, copy the exact collector name, and query that name. | The Performance Monitor report displays the intended two-minute time range and counters. |
| `Invalid column name 'last_copied_file'` | The query targeted `msdb.dbo.log_shipping_secondary`, which stores configuration rather than monitor progress. | Query `msdb.dbo.log_shipping_monitor_secondary`, or inspect the installed schema before selecting version-specific columns. | The query returns the last copied and last restored filenames and timestamps. |
| Restore job reported that exclusive access could not be obtained and terminated abnormally | A session was connected to the secondary, or a previous step changed access state in an unsafe order. | Close SSMS windows using that database, identify and end only confirmed lab sessions, and retry the restore. Keep the secondary in `RESTORING`; do not attempt `ALTER DATABASE` while it is restoring. | Restore history advances and the database remains `RESTORING` until the planned recovery step. |
| `ALTER DATABASE is not permitted while a database is in the Restoring state` | `ALTER DATABASE ... SET SINGLE_USER/MULTI_USER` was attempted against a restoring database. | Remove that statement. Access-mode changes are unnecessary for a normal `NORECOVERY` log restore. Recover the database only as part of the approved transition. | The next valid log restores without the access-mode statement. |
| A restore left the database in `RESTORING` | The restore intentionally used `NORECOVERY`, or the final `RECOVERY` step had not run. | If more logs remain, leave it restoring. If every required log has been applied and this server is becoming primary, issue the reviewed final recovery step. | `sys.databases.state_desc` is correct for the intended role: `RESTORING` for secondary or `ONLINE` for primary. |
| Transaction Log Shipping Status showed stale red reverse-direction rows after failback | Reverse-direction metadata and monitor relationships still existed in `msdb`. | Remove the obsolete reverse secondary configuration, mapping, primary configuration, and orphaned jobs using the log-shipping UI or supported stored procedures. Preserve the active original direction. | Refresh reports on both instances; only SQLLAB1-to-SQLLAB2 remains and reports `Good`. |
| `Invalid column name 'primary_database'` while querying `log_shipping_primary_secondaries` | The query assumed columns that belong to the primary database table were repeated in the mapping table. | Inspect the table schema and join `log_shipping_primary_secondaries` to `log_shipping_primary_databases` through `primary_id`. Avoid hard-coded assumptions across metadata tables. | The corrected query returns the intended primary/secondary relationship without errors. |
| Extended Events file read returned no deadlock event | The event had not flushed to the file, the wrong rollover file was read, or the session/filter differed from the test. | Confirm the session is started, reproduce the deadlock, stop the session to force a flush if appropriate, and read the full event-file wildcard path. | `sys.fn_xe_file_target_read_file` returns `xml_deadlock_report`, and the XML opens as an `.xdl` graph. |
| SSMS Error List displayed invalid-object warnings although the batch succeeded | IntelliSense used stale metadata or a different database context; the Error List was not the runtime Messages output. | Refresh IntelliSense cache, set the correct database context, and judge execution from the Messages pane and result sets. | The batch executes successfully and the object resolves in a new query window. |

## Safer file-size logic

Use a guard when a repeatable setup script establishes a minimum size:

```sql
USE OperationsLab;
GO

DECLARE @target_size_mb int = 512;

IF EXISTS
(
    SELECT 1
    FROM sys.database_files
    WHERE name = N'OperationsLab'
      AND size / 128.0 < @target_size_mb
)
BEGIN
    ALTER DATABASE OperationsLab
        MODIFY FILE (NAME = N'OperationsLab', SIZE = 512MB);
END;
GO
```

Apply the same pattern independently to each logical data or log file. File shrink is a separate, exceptional maintenance decision.

## Confirm the executing service identities

Run on the relevant instance:

```sql
SELECT
    servicename,
    service_account,
    startup_type_desc,
    status_desc
FROM sys.dm_server_services
ORDER BY servicename;
```

For named instances using default virtual accounts, expected patterns are:

- Database Engine: `NT Service\MSSQL$SQLLAB1` or `NT Service\MSSQL$SQLLAB2`
- SQL Server Agent: `NT Service\SQLAgent$SQLLAB1` or `NT Service\SQLAgent$SQLLAB2`

Use the returned values as the authority; do not assume the service identity from the person currently signed in.

## Correct log-shipping metadata relationship

When a query needs the primary database name and the secondary mapping, join on `primary_id` rather than assuming the mapping table contains every descriptive column:

```sql
SELECT
    p.primary_server,
    p.primary_database,
    s.secondary_server,
    s.secondary_database
FROM msdb.dbo.log_shipping_primary_databases AS p
JOIN msdb.dbo.log_shipping_primary_secondaries AS s
  ON s.primary_id = p.primary_id
WHERE p.primary_database = N'OperationsLab';
```

Before using any `msdb` query on a different SQL Server release, inspect available columns with `sys.columns` or `sp_help`.

## Prevention checklist

- Put `USE [database]; GO` at the top of database-specific scripts.
- Print `@@SERVERNAME`, `DB_NAME()`, and UTC time at the start of destructive or recovery scripts.
- Make setup scripts idempotent where practical.
- Separate configuration queries from monitor/history queries.
- Use fixed, documented folders for full, differential, log, log-shipping, Extended Events, and PerfMon files.
- Grant permissions to the actual service identities and validate with the actual job.
- Capture Agent job output in addition to the green/red UI status.
- Record exact filenames at backup, copy, and restore stages.
- Never run backup and reverse-backup schedules concurrently for the same planned transition.
- Keep one authoritative writable primary.
- Do not delete log-shipping metadata rows manually.
- Take screenshots only after hiding personal names, local usernames, and unrelated objects.

## Backup chain not detected after log-shipping role reversal

**Symptom:** `Test-DbaLastBackup` returned no result rows.

**Cause:** The log-shipping failover and failback created multiple recovery
forks. The existing full backup did not provide a valid base for the current
recovery fork.

**Resolution:** A new regular full backup was taken on SQLLAB1. dbatools then
identified the current backup chain and completed the restore and DBCC CHECKDB
validation successfully.

## PowerShell StrictMode array handling

**Symptom:** The restore completed, but the wrapper reported that the `Count`
property could not be found.

**Cause:** An empty array produced inside an `if` expression was unrolled to
`$null` under `Set-StrictMode`.

**Resolution:** The failure collection was initialized separately as `@()`
before conditionally assigning query results.