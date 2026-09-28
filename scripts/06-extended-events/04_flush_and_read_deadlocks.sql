USE [master];
GO

SET NOCOUNT ON;

DECLARE @FlushByRestart bit = 1;
DECLARE @SessionName sysname = N'OperationsLab_Deadlocks';
DECLARE @TargetFile nvarchar(4000);

IF NOT EXISTS
(
    SELECT 1
    FROM sys.server_event_sessions
    WHERE name = @SessionName
)
    THROW 50000, N'The OperationsLab_Deadlocks session does not exist.', 1;

IF @FlushByRestart = 1
   AND EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = @SessionName)
BEGIN
    ALTER EVENT SESSION [OperationsLab_Deadlocks] ON SERVER STATE = STOP;
    ALTER EVENT SESSION [OperationsLab_Deadlocks] ON SERVER STATE = START;
END;

SELECT @TargetFile = CONVERT(nvarchar(4000), f.value)
FROM sys.server_event_sessions AS s
JOIN sys.server_event_session_fields AS f
  ON f.event_session_id = s.event_session_id
WHERE s.name = @SessionName
  AND f.name = N'filename';

IF @TargetFile IS NULL
    THROW 50001, N'No event_file target path was found.', 1;

DECLARE @Wildcard nvarchar(4000) =
    CASE
        WHEN RIGHT(@TargetFile, 4) = N'.xel'
            THEN LEFT(@TargetFile, LEN(@TargetFile) - 4) + N'*.xel'
        ELSE @TargetFile + N'*.xel'
    END;

;WITH EventData AS
(
    SELECT
        file_name,
        file_offset,
        CONVERT(xml, event_data) AS event_xml
    FROM sys.fn_xe_file_target_read_file(@Wildcard, NULL, NULL, NULL)
), Deadlocks AS
(
    SELECT
        file_name,
        file_offset,
        event_xml.value(N'(event/@timestamp)[1]', N'datetime2(7)') AS captured_at_utc,
        event_xml.query(N'(event/data/value/deadlock)[1]') AS deadlock_graph,
        event_xml
    FROM EventData
    WHERE event_xml.value(N'(event/@name)[1]', N'sysname') = N'xml_deadlock_report'
)
SELECT
    file_name,
    file_offset,
    captured_at_utc,
    deadlock_graph,
    event_xml
FROM Deadlocks
ORDER BY captured_at_utc DESC;
GO
