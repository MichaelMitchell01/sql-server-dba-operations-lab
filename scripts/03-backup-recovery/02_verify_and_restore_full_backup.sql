/*
    Run on SQLLAB2.
    VERIFYONLY runs by default. Set @ExecuteRestore = 1 only when the selected
    full backup and destination paths have been reviewed.
*/
USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @FullBackupFile nvarchar(500) = NULL;
DECLARE @LogBackupFile nvarchar(500) = NULL;
DECLARE @ValidationDatabase sysname = N'OperationsLab_Validation';
DECLARE @ExecuteRestore bit = 0;
DECLARE @DropExistingValidationDatabase bit = 0;

IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB2'
    THROW 50000, N'Run this validation-restore script on SQLLAB2.', 1;

IF @FullBackupFile IS NULL
BEGIN
    SELECT TOP (1)
        @FullBackupFile = bmf.physical_device_name
    FROM msdb.dbo.backupset AS bs
    JOIN msdb.dbo.backupmediafamily AS bmf
      ON bmf.media_set_id = bs.media_set_id
    WHERE bs.database_name = N'OperationsLab'
      AND bs.type = 'D'
      AND bs.is_copy_only = 0
    ORDER BY bs.backup_finish_date DESC;
END;

IF @LogBackupFile IS NULL
BEGIN
    SELECT TOP (1)
        @LogBackupFile = bmf.physical_device_name
    FROM msdb.dbo.backupset AS bs
    JOIN msdb.dbo.backupmediafamily AS bmf
      ON bmf.media_set_id = bs.media_set_id
    WHERE bs.database_name = N'OperationsLab'
      AND bs.type = 'L'
    ORDER BY bs.backup_finish_date DESC;
END;

IF @FullBackupFile IS NULL
    THROW 50001, N'No full backup file was supplied or found in local msdb history.', 1;

SELECT
    @FullBackupFile AS full_backup_file,
    @LogBackupFile AS log_backup_file,
    @ExecuteRestore AS execute_restore;

RESTORE VERIFYONLY
FROM DISK = @FullBackupFile
WITH CHECKSUM;

RESTORE FILELISTONLY
FROM DISK = @FullBackupFile;

IF @LogBackupFile IS NOT NULL
BEGIN
    RESTORE VERIFYONLY
    FROM DISK = @LogBackupFile
    WITH CHECKSUM;
END;

IF @ExecuteRestore = 0
BEGIN
    PRINT N'Backup verification completed. Restore was not requested.';
    RETURN;
END;

IF DB_ID(@ValidationDatabase) IS NOT NULL
BEGIN
    IF @DropExistingValidationDatabase = 0
        THROW 50002, N'The validation database already exists. Review it or set the explicit drop flag.', 1;

    DECLARE @DropSql nvarchar(max) =
        N'ALTER DATABASE ' + QUOTENAME(@ValidationDatabase)
        + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE '
        + QUOTENAME(@ValidationDatabase) + N';';
    EXEC sys.sp_executesql @DropSql;
END;

DECLARE @RestoreSql nvarchar(max) =
    N'RESTORE DATABASE ' + QUOTENAME(@ValidationDatabase)
    + N' FROM DISK = N''' + REPLACE(@FullBackupFile, N'''', N'''''') + N''' '
    + N'WITH MOVE N''OperationsLab'' TO N''C:\SQLLab\SQLLAB2\Data\OperationsLab_Validation.mdf'', '
    + N'MOVE N''OperationsLab_log'' TO N''C:\SQLLab\SQLLAB2\Log\OperationsLab_Validation_log.ldf'', '
    + N'RECOVERY, REPLACE, CHECKSUM, STATS = 5;';

EXEC sys.sp_executesql @RestoreSql;

DECLARE @CheckSql nvarchar(max) =
    N'DBCC CHECKDB (' + QUOTENAME(@ValidationDatabase, N'''') + N') WITH NO_INFOMSGS;';
EXEC sys.sp_executesql @CheckSql;

SELECT
    name,
    state_desc,
    user_access_desc,
    recovery_model_desc
FROM sys.databases
WHERE name = @ValidationDatabase;
GO

