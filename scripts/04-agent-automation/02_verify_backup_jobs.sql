USE [msdb];
GO

SET NOCOUNT ON;

SELECT
    j.name AS job_name,
    j.enabled AS job_enabled,
    s.name AS schedule_name,
    s.enabled AS schedule_enabled,
    CASE s.freq_type
        WHEN 4 THEN N'DAILY'
        WHEN 8 THEN N'WEEKLY'
        ELSE CONCAT(N'TYPE_', s.freq_type)
    END AS frequency_type,
    CASE s.freq_subday_type
        WHEN 4 THEN CONCAT(N'Every ', s.freq_subday_interval, N' minute(s)')
        ELSE N'Once at scheduled time'
    END AS intraday_frequency
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobschedules AS js
  ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules AS s
  ON s.schedule_id = js.schedule_id
WHERE j.name IN
(
    N'DBA - OperationsLab - FULL Backup',
    N'DBA - OperationsLab - DIFF Backup',
    N'DBA - OperationsLab - LOG Backup',
    N'DBA - SQL Backup Retention'
)
ORDER BY j.name;

;WITH LatestOutcome AS
(
    SELECT
        j.name AS job_name,
        h.run_status,
        msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
        h.message,
        ROW_NUMBER() OVER
        (
            PARTITION BY j.job_id
            ORDER BY h.instance_id DESC
        ) AS rn
    FROM msdb.dbo.sysjobs AS j
    LEFT JOIN msdb.dbo.sysjobhistory AS h
      ON h.job_id = j.job_id
     AND h.step_id = 0
    WHERE j.name LIKE N'DBA - OperationsLab - % Backup'
       OR j.name = N'DBA - SQL Backup Retention'
)
SELECT
    job_name,
    CASE run_status
        WHEN 0 THEN N'FAILED'
        WHEN 1 THEN N'SUCCEEDED'
        WHEN 2 THEN N'RETRY'
        WHEN 3 THEN N'CANCELLED'
        WHEN 4 THEN N'IN PROGRESS'
        ELSE N'NO HISTORY'
    END AS latest_outcome,
    run_datetime,
    message
FROM LatestOutcome
WHERE rn = 1
ORDER BY job_name;

SELECT TOP (20)
    backup_run_id,
    database_name,
    backup_type,
    backup_file,
    started_at_utc,
    completed_at_utc,
    status,
    error_number,
    error_message
FROM DBA_Admin.dbo.BackupRunLog
ORDER BY backup_run_id DESC;
GO
