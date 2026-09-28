/*
    SQL Server 2025 log-shipping template.

    Run each labeled section in a separate SSMS window connected to the named
    instance shown in the section heading. Every changing section is disabled
    by default. Replace LABHOST and review paths before setting a flag to 1.

    This script assumes SQLLAB1 is the primary and SQLLAB2 is the secondary.
*/

/* ========================================================================== */
/* SECTION A -- SQLLAB1: optional initialization backups                       */
/* ========================================================================== */
USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CreateInitializationBackups bit = 0;
DECLARE @InitialFullFile nvarchar(500) =
    N'C:\SQLLab\LogShipping\Backup\OperationsLab_INITIAL_FULL.bak';
DECLARE @InitialLogFile nvarchar(500) =
    N'C:\SQLLab\LogShipping\Backup\OperationsLab_INITIAL_LOG.trn';

IF @CreateInitializationBackups = 1
BEGIN
    IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
        THROW 50000, N'Section A must run on SQLLAB1.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name = N'OperationsLab'
          AND state_desc = N'ONLINE'
          AND recovery_model_desc = N'FULL'
    )
        THROW 50001, N'OperationsLab must be ONLINE in FULL recovery.', 1;

    BACKUP DATABASE [OperationsLab]
    TO DISK = @InitialFullFile
    WITH INIT, CHECKSUM, COMPRESSION, STATS = 5;

    BACKUP LOG [OperationsLab]
    TO DISK = @InitialLogFile
    WITH INIT, CHECKSUM, COMPRESSION, STATS = 5;

    RESTORE VERIFYONLY FROM DISK = @InitialFullFile WITH CHECKSUM;
    RESTORE VERIFYONLY FROM DISK = @InitialLogFile WITH CHECKSUM;
END
ELSE
    PRINT N'Section A skipped. Set @CreateInitializationBackups = 1 to create the initial full and log files.';
GO

/* ========================================================================== */
/* SECTION B -- SQLLAB2: initialize OperationsLab WITH NORECOVERY              */
/* Copy the initialization files into the SQLLAB2 copy folder first.           */
/* ========================================================================== */
USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RestoreInitializationBackups bit = 0;
DECLARE @InitialFullFile nvarchar(500) =
    N'C:\SQLLab\LogShipping\Copy\OperationsLab_INITIAL_FULL.bak';
DECLARE @InitialLogFile nvarchar(500) =
    N'C:\SQLLab\LogShipping\Copy\OperationsLab_INITIAL_LOG.trn';

IF @RestoreInitializationBackups = 1
BEGIN
    IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB2'
        THROW 50010, N'Section B must run on SQLLAB2.', 1;

    IF DB_ID(N'OperationsLab') IS NOT NULL
        THROW 50011, N'OperationsLab already exists on SQLLAB2. Review its role before replacing it.', 1;

    RESTORE DATABASE [OperationsLab]
    FROM DISK = @InitialFullFile
    WITH
        MOVE N'OperationsLab' TO N'C:\SQLLab\SQLLAB2\Data\OperationsLab.mdf',
        MOVE N'OperationsLab_log' TO N'C:\SQLLab\SQLLAB2\Log\OperationsLab_log.ldf',
        NORECOVERY,
        CHECKSUM,
        STATS = 5;

    RESTORE LOG [OperationsLab]
    FROM DISK = @InitialLogFile
    WITH NORECOVERY, CHECKSUM, STATS = 5;
END
ELSE
    PRINT N'Section B skipped. Set @RestoreInitializationBackups = 1 only after reviewing the files and destination.';
GO

/* ========================================================================== */
/* SECTION C -- SQLLAB1: create and schedule the log-backup job                */
/* ========================================================================== */
USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ConfigurePrimary bit = 0;
DECLARE @PrimaryDatabase sysname = N'OperationsLab';
DECLARE @BackupDirectory nvarchar(500) = N'C:\SQLLab\LogShipping\Backup';
DECLARE @BackupShare nvarchar(500) = N'\\LABHOST\SQLLabLS$';
DECLARE @MonitorServer sysname = CONVERT(sysname, SERVERPROPERTY(N'ServerName'));
DECLARE @BackupJobId uniqueidentifier;
DECLARE @PrimaryId uniqueidentifier;

IF @ConfigurePrimary = 1
BEGIN
    IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
        THROW 50020, N'Section C must run on SQLLAB1.', 1;

    IF @BackupShare LIKE N'%LABHOST%'
        THROW 50022, N'Replace LABHOST in @BackupShare before execution.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM msdb.dbo.log_shipping_primary_databases
        WHERE primary_database = @PrimaryDatabase
    )
        THROW 50021, N'Primary log-shipping metadata already exists for OperationsLab.', 1;

    EXEC master.dbo.sp_add_log_shipping_primary_database
        @database = @PrimaryDatabase,
        @backup_directory = @BackupDirectory,
        @backup_share = @BackupShare,
        @backup_job_name = N'LSBackup_OperationsLab',
        @backup_retention_period = 4320,
        @monitor_server = @MonitorServer,
        @monitor_server_security_mode = 1,
        @backup_threshold = 15,
        @threshold_alert = 14420,
        @threshold_alert_enabled = 1,
        @history_retention_period = 5760,
        @backup_job_id = @BackupJobId OUTPUT,
        @primary_id = @PrimaryId OUTPUT,
        @backup_compression = 1,
        @primary_connection_options = N'Encrypt=Mandatory;TrustServerCertificate=True;',
        @monitor_connection_options = N'Encrypt=Mandatory;TrustServerCertificate=True;';

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @BackupJobId,
        @name = N'Every 5 Minutes - LS Backup OperationsLab',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 5,
        @active_start_time = 000000;

    EXEC msdb.dbo.sp_update_job
        @job_id = @BackupJobId,
        @enabled = 1;

    SELECT @BackupJobId AS backup_job_id, @PrimaryId AS primary_id;
END
ELSE
    PRINT N'Section C skipped. Replace LABHOST, review settings, and set @ConfigurePrimary = 1.';
GO

/* ========================================================================== */
/* SECTION D -- SQLLAB2: create copy/restore jobs and secondary metadata       */
/* ========================================================================== */
USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ConfigureSecondary bit = 0;
DECLARE @PrimaryServer sysname = N'LABHOST\SQLLAB1';
DECLARE @PrimaryDatabase sysname = N'OperationsLab';
DECLARE @SecondaryDatabase sysname = N'OperationsLab';
DECLARE @BackupShare nvarchar(500) = N'\\LABHOST\SQLLabLS$';
DECLARE @CopyDirectory nvarchar(500) = N'C:\SQLLab\LogShipping\Copy';
DECLARE @MonitorServer sysname = N'LABHOST\SQLLAB1';
DECLARE @CopyJobId uniqueidentifier;
DECLARE @RestoreJobId uniqueidentifier;
DECLARE @SecondaryId uniqueidentifier;

IF @ConfigureSecondary = 1
BEGIN
    IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB2'
        THROW 50030, N'Section D must run on SQLLAB2.', 1;

    IF @PrimaryServer LIKE N'LABHOST%'
       OR @BackupShare LIKE N'%LABHOST%'
       OR @MonitorServer LIKE N'LABHOST%'
        THROW 50033, N'Replace all LABHOST sample values before execution.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.databases
        WHERE name = @SecondaryDatabase
          AND state_desc = N'RESTORING'
    )
        THROW 50031, N'OperationsLab must be initialized and RESTORING on SQLLAB2.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM msdb.dbo.log_shipping_secondary
        WHERE primary_server = @PrimaryServer
          AND primary_database = @PrimaryDatabase
    )
        THROW 50032, N'Secondary log-shipping metadata already exists.', 1;

    EXEC master.dbo.sp_add_log_shipping_secondary_primary
        @primary_server = @PrimaryServer,
        @primary_database = @PrimaryDatabase,
        @backup_source_directory = @BackupShare,
        @backup_destination_directory = @CopyDirectory,
        @copy_job_name = N'LSCopy_LABHOST_SQLLAB1_OperationsLab',
        @restore_job_name = N'LSRestore_LABHOST_SQLLAB1_OperationsLab',
        @file_retention_period = 4320,
        @monitor_server = @MonitorServer,
        @monitor_server_security_mode = 1,
        @copy_job_id = @CopyJobId OUTPUT,
        @restore_job_id = @RestoreJobId OUTPUT,
        @secondary_id = @SecondaryId OUTPUT,
        @secondary_connection_options = N'Encrypt=Mandatory;TrustServerCertificate=True;',
        @monitor_connection_options = N'Encrypt=Mandatory;TrustServerCertificate=True;';

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @CopyJobId,
        @name = N'Every 5 Minutes - LS Copy OperationsLab',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 5,
        @active_start_time = 000100;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @RestoreJobId,
        @name = N'Every 5 Minutes - LS Restore OperationsLab',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 5,
        @active_start_time = 000300;

    EXEC master.dbo.sp_add_log_shipping_secondary_database
        @secondary_database = @SecondaryDatabase,
        @primary_server = @PrimaryServer,
        @primary_database = @PrimaryDatabase,
        @restore_delay = 0,
        @restore_mode = 0,
        @disconnect_users = 0,
        @restore_threshold = 15,
        @threshold_alert_enabled = 1,
        @history_retention_period = 5760;

    EXEC msdb.dbo.sp_update_job @job_id = @CopyJobId, @enabled = 1;
    EXEC msdb.dbo.sp_update_job @job_id = @RestoreJobId, @enabled = 1;

    SELECT
        @CopyJobId AS copy_job_id,
        @RestoreJobId AS restore_job_id,
        @SecondaryId AS secondary_id;
END
ELSE
    PRINT N'Section D skipped. Replace LABHOST, review settings, and set @ConfigureSecondary = 1.';
GO

/* ========================================================================== */
/* SECTION E -- SQLLAB1: register SQLLAB2 with the primary                     */
/* ========================================================================== */
USE [master];
GO

SET NOCOUNT ON;

DECLARE @RegisterSecondaryOnPrimary bit = 0;
DECLARE @SecondaryServer sysname = N'LABHOST\SQLLAB2';

IF @RegisterSecondaryOnPrimary = 1
BEGIN
    IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
        THROW 50040, N'Section E must run on SQLLAB1.', 1;

    IF @SecondaryServer LIKE N'LABHOST%'
        THROW 50041, N'Replace LABHOST in @SecondaryServer before execution.', 1;

    EXEC master.dbo.sp_add_log_shipping_primary_secondary
        @primary_database = N'OperationsLab',
        @secondary_server = @SecondaryServer,
        @secondary_database = N'OperationsLab';
END
ELSE
    PRINT N'Section E skipped. Replace LABHOST and set @RegisterSecondaryOnPrimary = 1.';
GO
