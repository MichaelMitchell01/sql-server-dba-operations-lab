/*
    Run once on SQLLAB1 and once on SQLLAB2 as a sysadmin.
    This script changes instance memory and MAXDOP, then reports configuration.
*/
USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF IS_SRVROLEMEMBER(N'sysadmin') <> 1
    THROW 50000, N'Sysadmin membership is required.', 1;

DECLARE @MajorVersion int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
DECLARE @InstanceName sysname = CONVERT(sysname, SERVERPROPERTY(N'InstanceName'));

IF @MajorVersion IS NULL OR @MajorVersion < 17
    THROW 50001, N'This lab targets SQL Server 2025 (17.x) or later.', 1;

IF @InstanceName NOT IN (N'SQLLAB1', N'SQLLAB2')
    THROW 50002, N'Connect to the SQLLAB1 or SQLLAB2 named instance.', 1;

EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE;

EXEC sys.sp_configure N'min server memory (MB)', 0;
EXEC sys.sp_configure N'max server memory (MB)', 16384;
EXEC sys.sp_configure N'max degree of parallelism', 8;
RECONFIGURE;

SELECT
    CONVERT(sysname, SERVERPROPERTY(N'ServerName')) AS connected_server,
    CONVERT(nvarchar(128), SERVERPROPERTY(N'ProductVersion')) AS product_version,
    CONVERT(nvarchar(128), SERVERPROPERTY(N'Edition')) AS edition,
    cpu_count,
    scheduler_count,
    physical_memory_kb / 1024 AS physical_memory_mb
FROM sys.dm_os_sys_info;

SELECT
    name,
    value_in_use,
    value AS configured_value
FROM sys.configurations
WHERE name IN
(
    N'min server memory (MB)',
    N'max server memory (MB)',
    N'max degree of parallelism'
)
ORDER BY name;

SELECT
    servicename,
    service_account,
    startup_type_desc,
    status_desc,
    last_startup_time
FROM sys.dm_server_services
ORDER BY servicename;

SELECT
    file_id,
    name AS logical_file_name,
    type_desc,
    size / 128.0 AS size_mb,
    CASE WHEN is_percent_growth = 1 THEN NULL ELSE growth / 128.0 END AS growth_mb,
    is_percent_growth,
    physical_name
FROM tempdb.sys.database_files
ORDER BY type_desc, file_id;
GO

