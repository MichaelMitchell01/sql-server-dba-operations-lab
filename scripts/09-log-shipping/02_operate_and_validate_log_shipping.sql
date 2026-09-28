/*
    Run the read-only sections freely. Run each changing section only on the
    instance named in its heading and only during an approved lab transition.
*/

/* READ-ONLY -- run on either instance. */
USE [master];
GO

SET NOCOUNT ON;

SELECT
    CONVERT(sysname, SERVERPROPERTY(N'ServerName')) AS connected_server,
    d.name AS database_name,
    d.state_desc,
    d.user_access_desc,
    d.recovery_model_desc
FROM sys.databases AS d
WHERE d.name = N'OperationsLab';

SELECT
    j.name AS job_name,
    j.enabled AS job_enabled,
    s.name AS schedule_name,
    s.enabled AS schedule_enabled,
    CASE
        WHEN ja.start_execution_date IS NOT NULL
         AND ja.stop_execution_date IS NULL THEN N'RUNNING'
        ELSE N'NOT RUNNING'
    END AS current_state
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobschedules AS js
  ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules AS s
  ON s.schedule_id = js.schedule_id
LEFT JOIN msdb.dbo.sysjobactivity AS ja
  ON ja.job_id = j.job_id
 AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
WHERE j.name LIKE N'LS%OperationsLab%'
ORDER BY j.name;

SELECT
    primary_server,
    primary_database,
    last_backup_file,
    last_backup_date,
    backup_threshold,
    threshold_alert_enabled
FROM msdb.dbo.log_shipping_monitor_primary
WHERE primary_database = N'OperationsLab';

SELECT
    secondary_server,
    secondary_database,
    primary_server,
    primary_database,
    last_copied_file,
    last_copied_date,
    last_restored_file,
    last_restored_date,
    last_restored_latency
FROM msdb.dbo.log_shipping_monitor_secondary
WHERE secondary_database = N'OperationsLab';
GO

/* CURRENT PRIMARY: create a unique transition marker. */
USE [OperationsLab];
GO

DECLARE @InsertTransitionMarker bit = 0;

IF @InsertTransitionMarker = 1
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name = DB_NAME()
          AND state_desc <> N'ONLINE'
    )
        THROW 50000, N'The current database is not ONLINE.', 1;

    DECLARE @Marker uniqueidentifier = NEWID();

    INSERT audit.ChangeLog
    (
        table_name,
        record_id,
        action_name,
        details
    )
    VALUES
    (
        N'OperationsLab',
        NULL,
        N'ROLE_MARKER',
        CONCAT(N'marker_id=', CONVERT(nvarchar(36), @Marker))
    );

    SELECT
        @Marker AS marker_id,
        CONVERT(bigint, SCOPE_IDENTITY()) AS audit_id,
        SYSUTCDATETIME() AS created_at_utc;
END
ELSE
    PRINT N'Marker insertion skipped. Set @InsertTransitionMarker = 1 on the current writable primary.';
GO

/* CURRENT PRIMARY: final tail-log backup. Stops further writes by using NORECOVERY. */
USE [master];
GO

DECLARE @ExecuteTailLogBackup bit = 0;
DECLARE @TailLogFile nvarchar(500) =
    N'C:\SQLLab\LogShipping\Backup\OperationsLab_TAIL_REPLACE_TIMESTAMP.trn';

IF @ExecuteTailLogBackup = 1
BEGIN
    IF @TailLogFile LIKE N'%REPLACE_TIMESTAMP%'
        THROW 50011, N'Replace the sample tail-log filename before execution.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name = N'OperationsLab'
          AND state_desc = N'ONLINE'
          AND recovery_model_desc = N'FULL'
    )
        THROW 50010, N'OperationsLab must be ONLINE in FULL recovery.', 1;

    BACKUP LOG [OperationsLab]
    TO DISK = @TailLogFile
    WITH NORECOVERY, INIT, CHECKSUM, COMPRESSION, STATS = 5;

    SELECT @TailLogFile AS tail_log_file;
END
ELSE
    PRINT N'Tail-log backup skipped. Freeze writes, set a real filename, and set @ExecuteTailLogBackup = 1.';
GO

/* DESTINATION: restore the reviewed final/tail log and recover the new primary. */
USE [master];
GO

DECLARE @RecoverDestination bit = 0;
DECLARE @TailLogFile nvarchar(500) =
    N'C:\SQLLab\LogShipping\Copy\OperationsLab_TAIL_REPLACE_TIMESTAMP.trn';

IF @RecoverDestination = 1
BEGIN
    IF @TailLogFile LIKE N'%REPLACE_TIMESTAMP%'
        THROW 50021, N'Replace the sample tail-log filename before execution.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name = N'OperationsLab'
          AND state_desc = N'RESTORING'
    )
        THROW 50020, N'The destination OperationsLab database is not RESTORING.', 1;

    RESTORE LOG [OperationsLab]
    FROM DISK = @TailLogFile
    WITH RECOVERY, CHECKSUM, STATS = 5;

    SELECT
        name,
        state_desc,
        user_access_desc,
        recovery_model_desc
    FROM sys.databases
    WHERE name = N'OperationsLab';
END
ELSE
    PRINT N'Destination recovery skipped. Verify all prior logs and set @RecoverDestination = 1.';
GO

/* RECOVERED PRIMARY: locate a marker and run final integrity checks. */
USE [OperationsLab];
GO

DECLARE @MarkerId uniqueidentifier = NULL; -- paste the recorded GUID

SELECT TOP (20)
    audit_id,
    event_time,
    table_name,
    action_name,
    login_name,
    details
FROM audit.ChangeLog
WHERE action_name = 'ROLE_MARKER'
  AND
  (
      @MarkerId IS NULL
      OR details LIKE N'%' + CONVERT(nvarchar(36), @MarkerId) + N'%'
  )
ORDER BY audit_id DESC;

DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;
DBCC CHECKDB (N'OperationsLab') WITH NO_INFOMSGS;
GO

/*
    OBSOLETE REVERSE SECONDARY: remove reverse secondary metadata first.
    Replace server values. This removes the reverse copy/restore jobs.
*/
USE [master];
GO

DECLARE @RemoveReverseSecondaryMetadata bit = 0;
DECLARE @ReversePrimaryServer sysname = N'LABHOST\SQLLAB2';

IF @RemoveReverseSecondaryMetadata = 1
BEGIN
    IF @ReversePrimaryServer LIKE N'LABHOST%'
        THROW 50030, N'Replace LABHOST before removing metadata.', 1;

    EXEC master.dbo.sp_delete_log_shipping_secondary_database
        @secondary_database = N'OperationsLab';

    EXEC master.dbo.sp_delete_log_shipping_secondary_primary
        @primary_server = @ReversePrimaryServer,
        @primary_database = N'OperationsLab';
END
ELSE
    PRINT N'Reverse secondary cleanup skipped.';
GO

/* OBSOLETE REVERSE PRIMARY: remove its mapping, then its primary metadata. */
USE [master];
GO

DECLARE @RemoveReversePrimaryMetadata bit = 0;
DECLARE @ReverseSecondaryServer sysname = N'LABHOST\SQLLAB1';

IF @RemoveReversePrimaryMetadata = 1
BEGIN
    IF @ReverseSecondaryServer LIKE N'LABHOST%'
        THROW 50031, N'Replace LABHOST before removing metadata.', 1;

    EXEC master.dbo.sp_delete_log_shipping_primary_secondary
        @primary_database = N'OperationsLab',
        @secondary_server = @ReverseSecondaryServer,
        @secondary_database = N'OperationsLab';

    EXEC master.dbo.sp_delete_log_shipping_primary_database
        @database = N'OperationsLab';
END
ELSE
    PRINT N'Reverse primary cleanup skipped.';
GO
