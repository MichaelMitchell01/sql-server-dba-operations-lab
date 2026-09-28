/*
    Creates four SQL Server Agent jobs on SQLLAB1.
    Existing jobs with the same names are preserved and reported.
*/
USE [msdb];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF IS_SRVROLEMEMBER(N'sysadmin') <> 1
    THROW 50000, N'Sysadmin membership is required.', 1;

IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
    THROW 50001, N'Run this script only on SQLLAB1.', 1;

IF DB_ID(N'DBA_Admin') IS NULL
   OR OBJECT_ID(N'DBA_Admin.dbo.usp_BackupDatabase', N'P') IS NULL
    THROW 50002, N'Install the DBA_Admin backup framework first.', 1;

DECLARE @Owner sysname = SUSER_SNAME();
DECLARE @JobId uniqueidentifier;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - OperationsLab - FULL Backup')
BEGIN
    SET @JobId = NULL;
    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - OperationsLab - FULL Backup',
        @enabled = 1,
        @description = N'Weekly checksum/compressed full backup of OperationsLab.',
        @owner_login_name = @Owner,
        @job_id = @JobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = N'Back up OperationsLab FULL',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'EXEC DBA_Admin.dbo.usp_BackupDatabase @DatabaseName=N''OperationsLab'', @BackupType=''FULL'';',
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @JobId,
        @name = N'Weekly Sunday 0100 - OperationsLab FULL',
        @enabled = 1,
        @freq_type = 8,
        @freq_interval = 1,
        @freq_recurrence_factor = 1,
        @active_start_time = 010000;

    EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId;
END
ELSE
    PRINT N'FULL backup job already exists; no changes made.';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - OperationsLab - DIFF Backup')
BEGIN
    SET @JobId = NULL;
    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - OperationsLab - DIFF Backup',
        @enabled = 1,
        @description = N'Monday-through-Saturday checksum/compressed differential backup of OperationsLab.',
        @owner_login_name = @Owner,
        @job_id = @JobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = N'Back up OperationsLab DIFF',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'EXEC DBA_Admin.dbo.usp_BackupDatabase @DatabaseName=N''OperationsLab'', @BackupType=''DIFF'';',
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @JobId,
        @name = N'Daily Mon-Sat 0100 - OperationsLab DIFF',
        @enabled = 1,
        @freq_type = 8,
        @freq_interval = 126,
        @freq_recurrence_factor = 1,
        @active_start_time = 010000;

    EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId;
END
ELSE
    PRINT N'DIFF backup job already exists; no changes made.';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - OperationsLab - LOG Backup')
BEGIN
    SET @JobId = NULL;
    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - OperationsLab - LOG Backup',
        @enabled = 1,
        @description = N'15-minute checksum/compressed transaction-log backup of OperationsLab.',
        @owner_login_name = @Owner,
        @job_id = @JobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = N'Back up OperationsLab LOG',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'EXEC DBA_Admin.dbo.usp_BackupDatabase @DatabaseName=N''OperationsLab'', @BackupType=''LOG'';',
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @JobId,
        @name = N'Every 15 Minutes - OperationsLab LOG',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 15,
        @active_start_time = 000000;

    EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId;
END
ELSE
    PRINT N'LOG backup job already exists; no changes made.';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - SQL Backup Retention')
BEGIN
    SET @JobId = NULL;
    EXEC msdb.dbo.sp_add_job
        @job_name = N'DBA - SQL Backup Retention',
        @enabled = 1,
        @description = N'Deletes expired lab .bak and .trn files through the repository PowerShell script.',
        @owner_login_name = @Owner,
        @job_id = @JobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = N'Delete expired lab backups',
        @subsystem = N'CmdExec',
        @command = N'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\SQLLab\Scripts\Remove-ExpiredSqlBackups.ps1" -RootPath "C:\SQLLab\SQLLAB1\Backup" -RetentionDays 14',
        @on_success_action = 1,
        @on_fail_action = 2;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @JobId,
        @name = N'Daily 0230 - SQL Backup Retention',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @active_start_time = 023000;

    EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId;
END
ELSE
    PRINT N'Retention job already exists; no changes made.';
GO

