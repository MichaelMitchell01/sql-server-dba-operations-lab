/*
    Configures Query Store, executes a controlled workload, reports plans,
    and exposes guarded FORCE/UNFORCE actions.
*/
USE [master];
GO

ALTER DATABASE [OperationsLab] SET QUERY_STORE = ON
(
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,
    WAIT_STATS_CAPTURE_MODE = ON,
    MAX_STORAGE_SIZE_MB = 1024,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    SIZE_BASED_CLEANUP_MODE = AUTO
);
GO

USE [OperationsLab];
GO

SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM app.Orders)
    THROW 50000, N'Seed the synthetic workload before running this module.', 1;

CREATE TABLE #CustomerOrders
(
    order_id bigint,
    customer_id bigint,
    customer_code varchar(20),
    full_name nvarchar(150),
    order_date datetime2(3),
    order_status varchar(20),
    source_system varchar(20),
    total_amount decimal(14,2)
);

CREATE TABLE #StatusOrders
(
    order_id bigint,
    customer_id bigint,
    order_date datetime2(3),
    order_status varchar(20),
    source_system varchar(20),
    total_amount decimal(14,2)
);

CREATE TABLE #ProductSales
(
    product_id int,
    sku varchar(30),
    product_name nvarchar(200),
    category varchar(50),
    units_sold bigint,
    revenue decimal(38,2)
);

DECLARE @Iteration int = 1;

WHILE @Iteration <= 60
BEGIN
    TRUNCATE TABLE #CustomerOrders;
    INSERT #CustomerOrders
    EXEC app.usp_GetCustomerOrders
        @CustomerID = ((@Iteration * 137) % 10000) + 1,
        @StartDate = NULL,
        @EndDate = NULL;

    TRUNCATE TABLE #StatusOrders;
    INSERT #StatusOrders
    EXEC app.usp_GetOrdersByStatusSource
        @OrderStatus = CASE WHEN @Iteration % 2 = 0 THEN 'COMPLETED' ELSE 'PENDING' END,
        @SourceSystem = CASE WHEN @Iteration % 3 = 0 THEN 'MOBILE' ELSE 'WEB' END;

    TRUNCATE TABLE #ProductSales;
    INSERT #ProductSales
    EXEC app.usp_GetProductSales
        @Category = CASE @Iteration % 5
                        WHEN 0 THEN 'HARDWARE'
                        WHEN 1 THEN 'SOFTWARE'
                        WHEN 2 THEN 'NETWORK'
                        WHEN 3 THEN 'STORAGE'
                        ELSE 'ACCESSORY'
                    END,
        @StartDate = NULL,
        @EndDate = NULL;

    SET @Iteration += 1;
END;

EXEC sys.sp_query_store_flush_db;

;WITH RuntimeTotals AS
(
    SELECT
        rs.plan_id,
        SUM(CONVERT(bigint, rs.count_executions)) AS executions,
        SUM(CONVERT(decimal(38,4), rs.avg_duration) * rs.count_executions)
            / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,
        SUM(CONVERT(decimal(38,4), rs.avg_cpu_time) * rs.count_executions)
            / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_cpu_ms,
        SUM(CONVERT(decimal(38,4), rs.avg_logical_io_reads) * rs.count_executions)
            / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,
        MIN(rs.first_execution_time) AS first_execution_time,
        MAX(rs.last_execution_time) AS last_execution_time
    FROM sys.query_store_runtime_stats AS rs
    GROUP BY rs.plan_id
)
SELECT
    OBJECT_SCHEMA_NAME(q.object_id) AS schema_name,
    OBJECT_NAME(q.object_id) AS procedure_name,
    q.query_id,
    p.plan_id,
    p.is_forced_plan,
    p.plan_forcing_type_desc,
    p.force_failure_count,
    p.last_force_failure_reason_desc,
    r.executions,
    CONVERT(decimal(18,2), r.avg_duration_ms) AS avg_duration_ms,
    CONVERT(decimal(18,2), r.avg_cpu_ms) AS avg_cpu_ms,
    CONVERT(decimal(18,2), r.avg_logical_reads) AS avg_logical_reads,
    r.first_execution_time,
    r.last_execution_time,
    qt.query_sql_text
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt
  ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan AS p
  ON p.query_id = q.query_id
LEFT JOIN RuntimeTotals AS r
  ON r.plan_id = p.plan_id
WHERE q.object_id IN
(
    OBJECT_ID(N'app.usp_GetCustomerOrders'),
    OBJECT_ID(N'app.usp_GetOrdersByStatusSource'),
    OBJECT_ID(N'app.usp_GetProductSales')
)
ORDER BY procedure_name, q.query_id, p.plan_id;

/*
    Change @PlanAction to FORCE or UNFORCE only after reviewing the report.
    Use the matching query_id and plan_id from the same row set.
*/
DECLARE @PlanAction varchar(10) = 'REPORT';
DECLARE @QueryId bigint = 0;
DECLARE @PlanId bigint = 0;

IF @PlanAction = 'FORCE'
BEGIN
    IF @QueryId <= 0 OR @PlanId <= 0
        THROW 50001, N'Valid @QueryId and @PlanId values are required.', 1;

    EXEC sys.sp_query_store_force_plan
        @query_id = @QueryId,
        @plan_id = @PlanId;
END
ELSE IF @PlanAction = 'UNFORCE'
BEGIN
    IF @QueryId <= 0 OR @PlanId <= 0
        THROW 50002, N'Valid @QueryId and @PlanId values are required.', 1;

    EXEC sys.sp_query_store_unforce_plan
        @query_id = @QueryId,
        @plan_id = @PlanId;
END
ELSE IF @PlanAction <> 'REPORT'
    THROW 50003, N'@PlanAction must be REPORT, FORCE, or UNFORCE.', 1;

SELECT
    query_id,
    plan_id,
    is_forced_plan,
    plan_forcing_type_desc,
    force_failure_count,
    last_force_failure_reason_desc
FROM sys.query_store_plan
WHERE (@QueryId = 0 OR query_id = @QueryId)
ORDER BY query_id, plan_id;
GO

