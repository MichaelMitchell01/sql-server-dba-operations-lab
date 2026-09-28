/* Create the five-minute Agent job on SQLLAB1. */
USE [msdb];
GO

SET NOCOUNT ON;

IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
    THROW 50000, N'Run this script on SQLLAB1.', 1;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Server Health Snapshot')
BEGIN
    DECLARE @JobId uniqueidentifier;
    DECLARE @Owner sysname = SUSER_SNAME();

    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - Server Health Snapshot',
        @enabled = 1,
        @description = N'Captures SQL Server health counters in DBA_Admin every five minutes.',
        @owner_login_name = @Owner,
        @job_id = @JobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = N'Capture server health',
        @subsystem = N'TSQL',
        @database_name = N'DBA_Admin',
        @command = N'EXEC dbo.usp_CaptureServerHealth;',
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @JobId,
        @name = N'Every 5 Minutes - Server Health Snapshot',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 5,
        @active_start_time = 000000;

    EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId;
END
ELSE
    PRINT N'Health-snapshot job already exists; no changes made.';
GO

/* Report differences between the latest two successful collections. */
USE [DBA_Admin];
GO

DECLARE @CurrentId bigint;
DECLARE @PreviousId bigint;

;WITH Successful AS
(
    SELECT
        collection_id,
        ROW_NUMBER() OVER (ORDER BY collection_id DESC) AS rn
    FROM dbo.HealthCollection
    WHERE status = 'SUCCEEDED'
)
SELECT
    @CurrentId = MAX(CASE WHEN rn = 1 THEN collection_id END),
    @PreviousId = MAX(CASE WHEN rn = 2 THEN collection_id END)
FROM Successful
WHERE rn <= 2;

IF @PreviousId IS NULL
    THROW 50001, N'At least two successful collections are required.', 1;

SELECT
    p.collection_id AS previous_collection_id,
    p.captured_at_utc AS interval_start_utc,
    c.collection_id AS current_collection_id,
    c.captured_at_utc AS interval_end_utc,
    DATEDIFF(SECOND, p.captured_at_utc, c.captured_at_utc) AS interval_seconds
FROM dbo.HealthCollection AS p
CROSS JOIN dbo.HealthCollection AS c
WHERE p.collection_id = @PreviousId
  AND c.collection_id = @CurrentId;

;WITH WaitDeltas AS
(
    SELECT
        c.wait_type,
        c.waiting_tasks_count - p.waiting_tasks_count AS waiting_tasks_delta,
        c.wait_time_ms - p.wait_time_ms AS total_wait_ms_delta,
        (c.wait_time_ms - c.signal_wait_time_ms)
            - (p.wait_time_ms - p.signal_wait_time_ms) AS resource_wait_ms_delta,
        c.signal_wait_time_ms - p.signal_wait_time_ms AS signal_wait_ms_delta
    FROM dbo.WaitStatsSnapshot AS c
    JOIN dbo.WaitStatsSnapshot AS p
      ON p.wait_type = c.wait_type
     AND p.collection_id = @PreviousId
    WHERE c.collection_id = @CurrentId
), PositiveWaits AS
(
    SELECT *
    FROM WaitDeltas
    WHERE total_wait_ms_delta > 0
)
SELECT TOP (20)
    wait_type,
    waiting_tasks_delta,
    total_wait_ms_delta,
    resource_wait_ms_delta,
    signal_wait_ms_delta,
    CONVERT(decimal(6,2),
        100.0 * total_wait_ms_delta
        / NULLIF(SUM(total_wait_ms_delta) OVER (), 0)) AS percent_of_reported_wait
FROM PositiveWaits
ORDER BY total_wait_ms_delta DESC;

;WITH FileDeltas AS
(
    SELECT
        c.database_name,
        c.logical_file_name,
        c.file_type_desc,
        c.num_of_reads - p.num_of_reads AS reads_delta,
        c.num_of_writes - p.num_of_writes AS writes_delta,
        c.io_stall_read_ms - p.io_stall_read_ms AS read_stall_ms_delta,
        c.io_stall_write_ms - p.io_stall_write_ms AS write_stall_ms_delta
    FROM dbo.FileIOSnapshot AS c
    JOIN dbo.FileIOSnapshot AS p
      ON p.database_id = c.database_id
     AND p.file_id = c.file_id
     AND p.collection_id = @PreviousId
    WHERE c.collection_id = @CurrentId
)
SELECT
    database_name,
    logical_file_name,
    file_type_desc,
    reads_delta,
    writes_delta,
    CONVERT(decimal(18,2), read_stall_ms_delta * 1.0 / NULLIF(reads_delta, 0))
        AS interval_avg_read_latency_ms,
    CONVERT(decimal(18,2), write_stall_ms_delta * 1.0 / NULLIF(writes_delta, 0))
        AS interval_avg_write_latency_ms,
    CONVERT(decimal(18,2), (read_stall_ms_delta + write_stall_ms_delta) * 1.0
        / NULLIF(reads_delta + writes_delta, 0)) AS interval_avg_io_latency_ms
FROM FileDeltas
WHERE reads_delta > 0 OR writes_delta > 0
ORDER BY interval_avg_io_latency_ms DESC;
GO

