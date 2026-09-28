/*
    Installs a logged backup procedure in DBA_Admin.
    The Full, Diff, and Log subdirectories must already exist.
*/
USE [DBA_Admin];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.BackupRunLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.BackupRunLog
    (
        backup_run_id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_BackupRunLog PRIMARY KEY,
        database_name sysname NOT NULL,
        backup_type varchar(4) NOT NULL,
        backup_file nvarchar(500) NOT NULL,
        started_at_utc datetime2(3) NOT NULL,
        completed_at_utc datetime2(3) NULL,
        status varchar(20) NOT NULL,
        error_number int NULL,
        error_message nvarchar(2048) NULL,
        CONSTRAINT CK_BackupRunLog_Type CHECK (backup_type IN ('FULL','DIFF','LOG')),
        CONSTRAINT CK_BackupRunLog_Status CHECK (status IN ('STARTED','SUCCEEDED','FAILED'))
    );

    CREATE INDEX IX_BackupRunLog_Database_Started
        ON dbo.BackupRunLog (database_name, started_at_utc DESC)
        INCLUDE (backup_type, status, backup_file, completed_at_utc);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_BackupDatabase
    @DatabaseName sysname,
    @BackupType varchar(4),
    @BackupRoot nvarchar(260) = N'C:\SQLLab\SQLLAB1\Backup'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BackupType = UPPER(@BackupType);

    IF @BackupType NOT IN ('FULL','DIFF','LOG')
        THROW 50000, N'@BackupType must be FULL, DIFF, or LOG.', 1;

    IF DB_ID(@DatabaseName) IS NULL
        THROW 50001, N'The requested database does not exist.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name = @DatabaseName
          AND state_desc <> N'ONLINE'
    )
        THROW 50002, N'The requested database is not ONLINE.', 1;

    IF @BackupType = 'LOG'
       AND EXISTS
       (
           SELECT 1
           FROM sys.databases
           WHERE name = @DatabaseName
             AND recovery_model_desc = N'SIMPLE'
       )
        THROW 50003, N'Log backups require FULL or BULK_LOGGED recovery.', 1;

    DECLARE @UtcNow datetime2(0) = SYSUTCDATETIME();
    DECLARE @Stamp char(15) =
        CONVERT(char(8), @UtcNow, 112) + N'_' +
        REPLACE(CONVERT(char(8), @UtcNow, 108), N':', N'');
    DECLARE @Subdirectory nvarchar(10) =
        CASE @BackupType WHEN 'FULL' THEN N'Full' WHEN 'DIFF' THEN N'Diff' ELSE N'Log' END;
    DECLARE @Extension nvarchar(4) = CASE WHEN @BackupType = 'LOG' THEN N'.trn' ELSE N'.bak' END;
    DECLARE @BackupFile nvarchar(500) =
        CONCAT(@BackupRoot, N'\', @Subdirectory, N'\', @DatabaseName, N'_', @BackupType, N'_', @Stamp, @Extension);
    DECLARE @RunId bigint;
    DECLARE @Sql nvarchar(max);

    INSERT dbo.BackupRunLog
    (
        database_name,
        backup_type,
        backup_file,
        started_at_utc,
        status
    )
    VALUES
    (
        @DatabaseName,
        @BackupType,
        @BackupFile,
        SYSUTCDATETIME(),
        'STARTED'
    );

    SET @RunId = SCOPE_IDENTITY();

    BEGIN TRY
        SET @Sql =
            CASE @BackupType
                WHEN 'FULL' THEN N'BACKUP DATABASE ' + QUOTENAME(@DatabaseName)
                    + N' TO DISK = N''' + REPLACE(@BackupFile, N'''', N'''''')
                    + N''' WITH INIT, CHECKSUM, COMPRESSION, STATS = 5;'
                WHEN 'DIFF' THEN N'BACKUP DATABASE ' + QUOTENAME(@DatabaseName)
                    + N' TO DISK = N''' + REPLACE(@BackupFile, N'''', N'''''')
                    + N''' WITH DIFFERENTIAL, INIT, CHECKSUM, COMPRESSION, STATS = 5;'
                ELSE N'BACKUP LOG ' + QUOTENAME(@DatabaseName)
                    + N' TO DISK = N''' + REPLACE(@BackupFile, N'''', N'''''')
                    + N''' WITH INIT, CHECKSUM, COMPRESSION, STATS = 5;'
            END;

        EXEC sys.sp_executesql @Sql;

        UPDATE dbo.BackupRunLog
           SET completed_at_utc = SYSUTCDATETIME(),
               status = 'SUCCEEDED'
         WHERE backup_run_id = @RunId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.BackupRunLog
           SET completed_at_utc = SYSUTCDATETIME(),
               status = 'FAILED',
               error_number = ERROR_NUMBER(),
               error_message = ERROR_MESSAGE()
         WHERE backup_run_id = @RunId;

        THROW;
    END CATCH;

    SELECT *
    FROM dbo.BackupRunLog
    WHERE backup_run_id = @RunId;
END;
GO

SELECT
    SCHEMA_NAME(schema_id) AS schema_name,
    name AS procedure_name,
    create_date,
    modify_date
FROM sys.procedures
WHERE name = N'usp_BackupDatabase';
GO

