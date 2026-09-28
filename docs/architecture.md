# Architecture

## Purpose

This lab models the daily work of a SQL Server database administrator in a compact, repeatable environment. It emphasizes operational correctness: configuration, backups, recovery, observability, troubleshooting, security, and documented role transitions.

The design deliberately uses two named instances on one Windows host. That keeps the lab affordable and makes both sides easy to inspect, but it is not a production high-availability design.

## Components

| Component | Public lab name | Role |
|---|---|---|
| Windows host | `LABHOST` | Runs both SQL Server instances and local lab storage |
| SQL instance 1 | `LABHOST\SQLLAB1` | Normal primary; TCP `14331` |
| SQL instance 2 | `LABHOST\SQLLAB2` | Normal log-shipping secondary; TCP `14332` |
| Primary database | `SQLLAB1.OperationsLab` | Writable application database |
| Secondary database | `SQLLAB2.OperationsLab` | Continuously restored with `NORECOVERY` |
| Administration database | `DBA_Admin` | Job logging and health-collection tables/procedures |
| Backup share | `\\LABHOST\SQLLabLS$` | Makes transaction-log backups available to the copy job |
| Local copy area | `C:\SQLLab\LogShipping\Copy` | Stores files copied for the secondary restore job |
| Management client | SSMS 22.10.1 | Administration, testing, and evidence capture |

## Normal data flow

```mermaid
flowchart LR
    A["Application writes"] --> P["SQLLAB1 OperationsLab"]
    P -->|"BACKUP LOG"| B["SQLLabLS$ share"]
    B -->|"copy"| C["SQLLAB2 copy area"]
    C -->|"RESTORE LOG"| S["SQLLAB2 RESTORING"]
```

The SQLLAB1 backup job creates log backups on a fixed schedule. The SQLLAB2 copy job transfers available files to its local copy folder, and the restore job applies them in log sequence number order. The secondary remains unavailable for normal access while it is in `RESTORING`.

## Instance configuration

Both instances were configured consistently to make comparisons useful.

| Setting | SQLLAB1 | SQLLAB2 |
|---|---:|---:|
| Minimum server memory | 0 MB | 0 MB |
| Maximum server memory | 16,384 MB | 16,384 MB |
| Maximum degree of parallelism | 8 | 8 |
| Database Engine service startup | Automatic | Automatic |
| SQL Server Agent | Enabled for scheduled operations | Enabled for scheduled operations |

The setup wizard created eight equal-size `tempdb` data files. Fixed-megabyte autogrowth was used instead of percentage growth. Production sizing would require measurements from the actual workload and storage subsystem.

## OperationsLab configuration

| Property | Value |
|---|---|
| Compatibility level | 170 |
| Recovery model | `FULL` |
| Page verification | `CHECKSUM` |
| Auto close | Off |
| Auto shrink | Off |
| Query Store state | `READ_WRITE` |
| Query Store capture | `AUTO` |
| Query Store wait statistics | On |
| Query Store maximum size | 1,024 MB |

The primary database files were explicitly sized and configured with fixed autogrowth increments. File sizes were only increased when the requested size exceeded the existing size.

## Logical data model

| Schema | Object | Notes |
|---|---|---|
| `app` | `Customers` | Identity key, unique customer code, region, status, creation timestamp |
| `app` | `Products` | Identity key, SKU, category, price, inventory, modified timestamp |
| `app` | `Orders` | Identity key, customer relationship, status, source, total, row version |
| `app` | `OrderItems` | Order/product relationships, quantity, price, computed line total |
| `app` | `Payments` | Order relationship, amount, method, status, transaction reference |
| `audit` | `ChangeLog` | Audit identity, event time, table, record, action, login, details |

Foreign keys and check constraints protect the workload tables. A validation query compares stored order totals with the sum of order lines, and `DBCC CHECKCONSTRAINTS` verifies declared constraints.

## Workload and performance design

The synthetic workload exercises customer lookups, status/source filtering, product aggregation, inserts, updates, auditing, and concurrent transactions. Three stored procedures provide stable Query Store subjects:

- `app.usp_GetCustomerOrders`
- `app.usp_GetOrdersByStatusSource`
- `app.usp_GetProductSales`

Query Store was used to compare multiple plans for the same query, force a selected plan, verify the forcing state and failure count, and return the query to normal optimization.

An Extended Events session captured `xml_deadlock_report` events to an event file. The reproducible deadlock used two sessions that acquired `U`/`X` key locks on `app.Orders` in opposite order. The saved `.xdl` graph identified the victim, survivor, resources, owners, and waiters.

## Automation

The lab contains two categories of SQL Server Agent automation:

| Category | Jobs |
|---|---|
| Native backup operations | Full backup, differential backup, transaction-log backup, retention cleanup |
| Log shipping | Primary backup, secondary copy, secondary restore, alert monitoring |
| Monitoring | Periodic server-health snapshot |

Native backup procedures write execution status to `DBA_Admin`. Log-shipping history remains in `msdb`. Job names generated by the log-shipping wizard can include the source server name; public screenshots and scripts should replace it with `LABHOST`.

## Monitoring architecture

The health collector records:

- collection start, completion, status, errors, CPU count, scheduler count, and memory;
- cumulative wait statistics;
- file I/O counters and calculated read/write latency;
- active requests, waits, blocking relationships, and query text when present.

Interval reports compare consecutive successful snapshots rather than interpreting cumulative counters as activity during a single interval.

Windows Performance Monitor supplies an independent operating-system and SQL Server counter baseline. The collector was run under an elevated identity and its two-minute report was reviewed separately from SQL Server data.

## Security boundaries

- Windows authentication is the default administrative path.
- SQL Server Database Engine and Agent virtual service accounts receive only the folder/share permissions required for their jobs.
- Interactive user access to a UNC path is not used as proof that a service account can access that path, or vice versa.
- Database users and roles are scoped to job functions rather than granting broad server-level privileges.
- Secrets and machine-specific identities are excluded from the repository.

## Recovery characteristics

Log shipping provides warm-standby recovery through scheduled log backup, copy, and restore operations. It does not provide automatic failover. A planned transition requires a write freeze, final-log capture, application reconnection, and explicit recovery of the destination database.

During the controlled failback exercise, the final audit marker appeared on the recovered primary with the same GUID and audit ID, demonstrating an RPO of zero for that test. RTO was not precisely instrumented.

## Limitations and production changes

For production, place the instances on separate hosts and fault domains, use appropriately protected storage and network paths, encrypt connections with trusted certificates, protect backup files, centralize alerting, measure recovery time, test failure scenarios regularly, and document application connection changes. Capacity, backup frequency, retention, latency thresholds, and security policy must be derived from business requirements rather than copied from this lab.
