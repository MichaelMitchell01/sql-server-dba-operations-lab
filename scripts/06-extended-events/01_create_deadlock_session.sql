/* Prerequisite: C:\SQLLab\SQLLAB1\XE exists and is writable by the Engine service. */
USE [master];
GO

SET NOCOUNT ON;

IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
    THROW 50000, N'Run this script on SQLLAB1.', 1;

IF EXISTS
(
    SELECT 1
    FROM sys.dm_xe_sessions
    WHERE name = N'OperationsLab_Deadlocks'
)
    ALTER EVENT SESSION [OperationsLab_Deadlocks] ON SERVER STATE = STOP;

IF EXISTS
(
    SELECT 1
    FROM sys.server_event_sessions
    WHERE name = N'OperationsLab_Deadlocks'
)
    DROP EVENT SESSION [OperationsLab_Deadlocks] ON SERVER;

DECLARE @Sql nvarchar(max) = N'
CREATE EVENT SESSION [OperationsLab_Deadlocks] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_id,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
)
ADD TARGET package0.event_file
(
    SET filename = N''C:\SQLLab\SQLLAB1\XE\OperationsLab_Deadlocks.xel'',
        max_file_size = (25),
        max_rollover_files = (4)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);';

EXEC sys.sp_executesql @Sql;

ALTER EVENT SESSION [OperationsLab_Deadlocks] ON SERVER STATE = START;

SELECT
    s.name,
    CASE WHEN dxs.name IS NULL THEN 0 ELSE 1 END AS is_running,
    f.name AS field_name,
    f.value AS field_value
FROM sys.server_event_sessions AS s
LEFT JOIN sys.dm_xe_sessions AS dxs
  ON dxs.name = s.name
LEFT JOIN sys.server_event_session_fields AS f
  ON f.event_session_id = s.event_session_id
WHERE s.name = N'OperationsLab_Deadlocks';
GO

