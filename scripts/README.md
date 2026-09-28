# Script Execution Guide

These scripts rebuild the public version of the SQL Server DBA Operations Lab. They use anonymized server names and synthetic data.

## Required edits

Before execution, replace public sample values where they appear:

| Sample value | Replace with |
|---|---|
| `LABHOST\SQLLAB1` | Actual primary instance name |
| `LABHOST\SQLLAB2` | Actual secondary instance name |
| `\\LABHOST\SQLLabLS$` | Actual log-shipping share |
| `C:\SQLLab\...` | Existing local lab paths |
| `LAB\SqlLabReaders` and similar | Existing Windows users or groups |

Never add passwords, production connection strings, or private backup files to this repository.

## Run order

| Order | Location | Run on | Purpose |
|---:|---|---|---|
| 1 | `powershell/Initialize-SqlLabFolders.ps1` | Elevated PowerShell | Create directories; optionally create the share and apply service-account ACLs |
| 2 | `01-instance-configuration/01_configure_and_verify_instance.sql` | SQLLAB1 and SQLLAB2 | Configure memory/MAXDOP and verify services/tempdb |
| 3 | `02-database-build/01_create_operationslab.sql` | SQLLAB1 | Create `DBA_Admin`, `OperationsLab`, schemas, tables, indexes, and procedures |
| 4 | `02-database-build/02_seed_synthetic_workload.sql` | SQLLAB1 | Insert deterministic synthetic workload data |
| 5 | `02-database-build/03_validate_operationslab.sql` | SQLLAB1 | Validate configuration, counts, totals, constraints, and integrity |
| 6 | `03-backup-recovery/01_install_backup_framework.sql` | SQLLAB1 | Install logged backup procedures in `DBA_Admin` |
| 7 | Copy `powershell/Remove-ExpiredSqlBackups.ps1` to `C:\SQLLab\Scripts\` | Windows | Put the retention script at the path used by its Agent job |
| 8 | `04-agent-automation/01_create_backup_jobs.sql` | SQLLAB1 | Create full, differential, log, and retention jobs |
| 9 | Remaining performance, monitoring, and security modules | As documented in each file | Execute the focused lab exercises |
| 10 | `09-log-shipping/01_configure_log_shipping_template.sql` | Both instances in labeled sections | Configure log shipping after initializing the secondary |
| 11 | `09-log-shipping/02_operate_and_validate_log_shipping.sql` | Current primary/secondary as labeled | Validate, mark, transition, and clean up topology |

## Safety controls

- Scripts that restore, recover, remove metadata, create a share, or alter ACLs use explicit switches or execution flags.
- Leave each flag at `0` or omit the PowerShell switch to report or prepare without performing the protected action.
- Read the complete script and set the intended SSMS connection before changing a flag.
- Check the SSMS status bar and the script's server/database output before every recovery operation.
- Keep only one writable `OperationsLab` database during a role transition.

## Validation order

After each module, run its report section before continuing. At final closeout, capture:

1. Database state on both instances.
2. Log-shipping status and latest matching filename.
3. SQL Server Agent job history.
4. Marker ID and audit ID on the recovered primary.
5. `DBCC CHECKDB` output with zero allocation and consistency errors.

## Microsoft references

- [Configure log shipping](https://learn.microsoft.com/sql/database-engine/log-shipping/configure-log-shipping-sql-server?view=sql-server-ver17)
- [Log-shipping stored procedures](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/log-shipping-stored-procedures-transact-sql?view=sql-server-ver17)
- [Monitor performance with Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)
- [SQL Server deadlocks guide](https://learn.microsoft.com/sql/relational-databases/sql-server-deadlocks-guide?view=sql-server-ver17)
