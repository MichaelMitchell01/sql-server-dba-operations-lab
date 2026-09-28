USE [OperationsLab];
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'OperationsLab'
    THROW 50000, N'Run in OperationsLab.', 1;

SELECT
    CONVERT(sysname, SERVERPROPERTY(N'ServerName')) AS connected_server,
    d.name AS database_name,
    d.state_desc,
    d.user_access_desc,
    d.compatibility_level,
    d.recovery_model_desc,
    d.page_verify_option_desc,
    d.is_auto_close_on,
    d.is_auto_shrink_on
FROM sys.databases AS d
WHERE d.name = DB_NAME();

SELECT
    actual_state_desc,
    desired_state_desc,
    query_capture_mode_desc,
    wait_stats_capture_mode_desc,
    max_storage_size_mb,
    current_storage_size_mb
FROM sys.database_query_store_options;

SELECT
    CONCAT(QUOTENAME(s.name), N'.', QUOTENAME(t.name)) AS table_name,
    SUM(p.rows) AS row_count
FROM sys.tables AS t
JOIN sys.schemas AS s
  ON s.schema_id = t.schema_id
JOIN sys.partitions AS p
  ON p.object_id = t.object_id
 AND p.index_id IN (0, 1)
WHERE s.name IN (N'app', N'audit')
GROUP BY s.name, t.name
ORDER BY s.name, t.name;

;WITH CalculatedTotals AS
(
    SELECT
        order_id,
        SUM(line_total) AS calculated_total
    FROM app.OrderItems
    GROUP BY order_id
)
SELECT COUNT_BIG(*) AS mismatched_order_totals
FROM app.Orders AS o
JOIN CalculatedTotals AS c
  ON c.order_id = o.order_id
WHERE o.total_amount <> c.calculated_total;

DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;
DBCC CHECKDB (N'OperationsLab') WITH NO_INFOMSGS;
GO
