# Test Results

## Test record

| Field | Value |
|---|---|
| Completion date | 2026-09-28 |
| SQL Server version | SQL Server 2025 Developer Edition |
| SSMS version | 22.10.1 |
| Primary instance at closeout | `LABHOST\SQLLAB1` / `localhost,14331` |
| Secondary instance at closeout | `LABHOST\SQLLAB2` / `localhost,14332` |
| Database | `OperationsLab` |
| Data classification | Synthetic lab data only |

## Acceptance results

| Area | Validation | Result |
|---|---|---|
| Instance configuration | Both instances report minimum memory 0 MB, maximum memory 16,384 MB, and MAXDOP 8 | Pass |
| Database configuration | Compatibility 170, `FULL` recovery, `CHECKSUM`, auto-close off, auto-shrink off | Pass |
| Query Store | `READ_WRITE`, `AUTO` capture, wait statistics on, 1,024 MB maximum storage | Pass |
| Schema deployment | Five `app` tables and one `audit` table present | Pass |
| Structural validation | Identity, defaults, computed column, row version, data types, keys, and constraints present | Pass |
| Data validation | Stored order totals matched line totals; `DBCC CHECKCONSTRAINTS` reported no violations | Pass |
| Backup automation | Full, differential, and log jobs completed; procedure log recorded `SUCCEEDED` | Pass |
| Restore validation | Backup files verified and `OperationsLab` restored successfully to SQLLAB2 | Pass |
| Retention cleanup | Dry run identified the intended expired test file; live job and schedules enabled | Pass |
| Query Store analysis | Baseline and alternate plans recorded for target procedures | Pass |
| Query Store forcing | A plan was forced, verified, and later unforced without force failures | Pass |
| Deadlock capture | `xml_deadlock_report` captured and opened as an `.xdl` graph | Pass |
| Health collection | Snapshot procedure captured server, wait, file-I/O, and request data | Pass |
| Scheduled health job | Agent job and five-minute schedule validated | Pass |
| Interval analysis | Consecutive snapshots produced wait and file-latency deltas | Pass |
| Performance Monitor | Data Collector Set produced a readable two-minute report | Pass |
| Security and access | Service-account identities and required folder/share permissions validated | Pass |
| Log shipping | Backup, copy, and restore operations completed in sequence | Pass |
| Planned role reversal | SQLLAB2 operated as the primary and SQLLAB1 as the secondary | Pass |
| Planned failback | SQLLAB1 returned to primary without loss of the recorded marker | Pass |
| Cleanup | Obsolete reverse-direction metadata removed; stale alert rows cleared | Pass |
| Final integrity | `DBCC CHECKDB` reported zero allocation and zero consistency errors | Pass |

## Query Store observations

The target workload procedures appeared in Query Store with 60 recorded executions each during the measurement runs. Two of the controlled regressions produced materially different plans for the same query IDs. One observed example changed average duration from approximately 194.97 ms to 25.43 ms and average logical reads from approximately 1,395 to 655. Another changed average duration from approximately 15.80 ms to 1.90 ms and average logical reads from approximately 722 to 34.9.

These values describe a synthetic lab workload and should not be generalized as production performance claims.

## Deadlock test

The Extended Events session captured a two-session key-lock deadlock on `OperationsLab.app.Orders` and the `PK_Orders` index. The graph showed each session owning an exclusive lock and requesting an update lock held by the other. The designated lower-priority session was selected as the deadlock victim. The event was exported and reviewed in SSMS as an `.xdl` file.

## Health snapshot test

Successful snapshots recorded:

- server and scheduler information;
- total and available physical memory;
- cumulative wait counters;
- database file reads, writes, and calculated latency;
- active request and blocking information when present.

A consecutive-snapshot report correctly converted cumulative counters into interval deltas. The sample interval was five seconds. Because the environment was idle and synthetic, the captured wait mix is evidence that the collector works, not a production tuning recommendation.

## Recovery and failback evidence

| Recovery datum | Verified value |
|---|---|
| Failback marker ID | `FA02E255-515B-4BE2-990C-991C81748635` |
| Marker audit ID | `20005` |
| Marker creation time | `2026-09-28 05:53:19.718` UTC |
| Tail-log filename | `OperationsLab_20260928060131.trn` |
| First unattended post-failback file | `OperationsLab_20260928063200.trn` |
| Marker on recovered SQLLAB1 | Present and matching |
| Known lost transactions | 0 |
| Controlled-test RPO | 0 transactions |
| Measured RTO | Not available; no duration is claimed |

The same automatic log filename was observed at the backup source, secondary copy folder, and restore stage after the failback. This demonstrated that the original SQLLAB1-to-SQLLAB2 pipeline resumed unattended operation.

## Final state

| Instance | Database state | Access | Log-shipping role | Expected Agent work |
|---|---|---|---|---|
| `LABHOST\SQLLAB1` | `ONLINE` | `MULTI_USER` | Primary | Backup job enabled and succeeding |
| `LABHOST\SQLLAB2` | `RESTORING` | `MULTI_USER` metadata state | Secondary | Copy and restore jobs enabled and succeeding |

Both Transaction Log Shipping Status reports showed `Good` for the active SQLLAB1-to-SQLLAB2 relationship. Reverse-direction rows were removed after failback.

## Integrity result

The final `DBCC CHECKDB (N'OperationsLab') WITH NO_INFOMSGS` run completed without reported allocation or consistency errors.

## Evidence files

The publication set uses these sanitized screenshot names:

1. `evidence/01_SQLLAB1_LogShipping_Good.png`
2. `evidence/02_SQLLAB2_LogShipping_Good.png`
3. `evidence/03_SQLLAB1_Final_Database_State.png`
4. `evidence/04_SQLLAB2_Final_Database_State.png`
5. `evidence/05a_SQLLAB1_Backup_Job_History.png`
6. `evidence/05b_SQLLAB2_Copy_Restore_Job_History.png`
7. `evidence/06_DBCC_CHECKDB_Result.png`

Before publication, crop or redact Windows usernames, actual computer names, file paths containing personal names, connection history, and unrelated Object Explorer entries.

## Conclusion

The lab met its technical acceptance criteria. It demonstrated a complete operational cycle from database construction and workload generation through backup automation, performance diagnostics, monitoring, log-shipping role changes, controlled failback, cleanup, and final integrity validation. The architecture remains a same-host learning environment and is not represented as production high availability.

## Automated restore validation

- Date: 2026-09-28
- Source: `LABHOST\SQLLAB1`
- Destination: `LABHOST\SQLLAB2`
- Database: `OperationsLab`
- Status: `SUCCEEDED`
- Result rows: `1`
- Backup files accessible: Yes
- Restore completed: Yes
- DBCC CHECKDB completed without errors: Yes
- Temporary validation database removed: Yes

The validation restored the latest usable backup chain to a temporary database
on SQLLAB2, executed DBCC CHECKDB, recorded CSV and HTML reports, and removed
the temporary database after completion.

