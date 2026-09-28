USE [DBA_Admin];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.HealthCollection', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HealthCollection
    (
        collection_id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_HealthCollection PRIMARY KEY,
        captured_at_utc datetime2(3) NOT NULL,
        completed_at_utc datetime2(3) NULL,
        collector_server sysname NOT NULL,
        status varchar(20) NOT NULL,
        error_number int NULL,
        error_message nvarchar(2048) NULL,
        cpu_count int NULL,
        scheduler_count int NULL,
        total_physical_memory_mb bigint NULL,
        available_physical_memory_mb bigint NULL,
        CONSTRAINT CK_HealthCollection_Status
            CHECK (status IN ('STARTED','SUCCEEDED','FAILED'))
    );
END;

IF OBJECT_ID(N'dbo.WaitStatsSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.WaitStatsSnapshot
    (
        collection_id bigint NOT NULL,
        wait_type nvarchar(120) NOT NULL,
        waiting_tasks_count bigint NOT NULL,
        wait_time_ms bigint NOT NULL,
        max_wait_time_ms bigint NOT NULL,
        signal_wait_time_ms bigint NOT NULL,
        CONSTRAINT PK_WaitStatsSnapshot PRIMARY KEY (collection_id, wait_type),
        CONSTRAINT FK_WaitStatsSnapshot_Collection
            FOREIGN KEY (collection_id) REFERENCES dbo.HealthCollection (collection_id)
    );
END;

IF OBJECT_ID(N'dbo.FileIOSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.FileIOSnapshot
    (
        collection_id bigint NOT NULL,
        database_id int NOT NULL,
        file_id int NOT NULL,
        database_name sysname NOT NULL,
        logical_file_name sysname NOT NULL,
        file_type_desc nvarchar(60) NOT NULL,
        num_of_reads bigint NOT NULL,
        num_of_writes bigint NOT NULL,
        io_stall_read_ms bigint NOT NULL,
        io_stall_write_ms bigint NOT NULL,
        num_of_bytes_read bigint NOT NULL,
        num_of_bytes_written bigint NOT NULL,
        size_on_disk_bytes bigint NOT NULL,
        CONSTRAINT PK_FileIOSnapshot PRIMARY KEY (collection_id, database_id, file_id),
        CONSTRAINT FK_FileIOSnapshot_Collection
            FOREIGN KEY (collection_id) REFERENCES dbo.HealthCollection (collection_id)
    );
END;

IF OBJECT_ID(N'dbo.ActiveRequestSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ActiveRequestSnapshot
    (
        collection_id bigint NOT NULL,
        captured_at_utc datetime2(3) NOT NULL,
        session_id smallint NOT NULL,
        request_id int NOT NULL,
        blocking_session_id smallint NULL,
        database_name sysname NULL,
        login_name nvarchar(128) NULL,
        host_name nvarchar(128) NULL,
        program_name nvarchar(128) NULL,
        request_status nvarchar(30) NULL,
        command nvarchar(32) NULL,
        wait_type nvarchar(120) NULL,
        wait_time_ms int NULL,
        cpu_time_ms int NULL,
        total_elapsed_time_ms int NULL,
        logical_reads bigint NULL,
        writes bigint NULL,
        query_text nvarchar(max) NULL,
        CONSTRAINT PK_ActiveRequestSnapshot
            PRIMARY KEY (collection_id, session_id, request_id),
        CONSTRAINT FK_ActiveRequestSnapshot_Collection
            FOREIGN KEY (collection_id) REFERENCES dbo.HealthCollection (collection_id)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CaptureServerHealth
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CollectionId bigint;
    DECLARE @CapturedAt datetime2(3) = SYSUTCDATETIME();
    DECLARE @CpuCount int;
    DECLARE @SchedulerCount int;
    DECLARE @TotalMemoryMb bigint;
    DECLARE @AvailableMemoryMb bigint;

    SELECT
        @CpuCount = cpu_count,
        @SchedulerCount = scheduler_count
    FROM sys.dm_os_sys_info;

    SELECT
        @TotalMemoryMb = total_physical_memory_kb / 1024,
        @AvailableMemoryMb = available_physical_memory_kb / 1024
    FROM sys.dm_os_sys_memory;

    INSERT dbo.HealthCollection
    (
        captured_at_utc,
        collector_server,
        status,
        cpu_count,
        scheduler_count,
        total_physical_memory_mb,
        available_physical_memory_mb
    )
    VALUES
    (
        @CapturedAt,
        CONVERT(sysname, SERVERPROPERTY(N'ServerName')),
        'STARTED',
        @CpuCount,
        @SchedulerCount,
        @TotalMemoryMb,
        @AvailableMemoryMb
    );

    SET @CollectionId = SCOPE_IDENTITY();

    BEGIN TRY
        INSERT dbo.WaitStatsSnapshot
        (
            collection_id,
            wait_type,
            waiting_tasks_count,
            wait_time_ms,
            max_wait_time_ms,
            signal_wait_time_ms
        )
        SELECT
            @CollectionId,
            wait_type,
            waiting_tasks_count,
            wait_time_ms,
            max_wait_time_ms,
            signal_wait_time_ms
        FROM sys.dm_os_wait_stats;

        INSERT dbo.FileIOSnapshot
        (
            collection_id,
            database_id,
            file_id,
            database_name,
            logical_file_name,
            file_type_desc,
            num_of_reads,
            num_of_writes,
            io_stall_read_ms,
            io_stall_write_ms,
            num_of_bytes_read,
            num_of_bytes_written,
            size_on_disk_bytes
        )
        SELECT
            @CollectionId,
            mf.database_id,
            mf.file_id,
            DB_NAME(mf.database_id),
            mf.name,
            mf.type_desc,
            vfs.num_of_reads,
            vfs.num_of_writes,
            vfs.io_stall_read_ms,
            vfs.io_stall_write_ms,
            vfs.num_of_bytes_read,
            vfs.num_of_bytes_written,
            vfs.size_on_disk_bytes
        FROM sys.master_files AS mf
        CROSS APPLY sys.dm_io_virtual_file_stats(mf.database_id, mf.file_id) AS vfs;

        INSERT dbo.ActiveRequestSnapshot
        (
            collection_id,
            captured_at_utc,
            session_id,
            request_id,
            blocking_session_id,
            database_name,
            login_name,
            host_name,
            program_name,
            request_status,
            command,
            wait_type,
            wait_time_ms,
            cpu_time_ms,
            total_elapsed_time_ms,
            logical_reads,
            writes,
            query_text
        )
        SELECT
            @CollectionId,
            @CapturedAt,
            r.session_id,
            r.request_id,
            NULLIF(r.blocking_session_id, 0),
            DB_NAME(r.database_id),
            s.login_name,
            s.host_name,
            s.program_name,
            r.status,
            r.command,
            r.wait_type,
            r.wait_time,
            r.cpu_time,
            r.total_elapsed_time,
            r.logical_reads,
            r.writes,
            txt.text
        FROM sys.dm_exec_requests AS r
        JOIN sys.dm_exec_sessions AS s
          ON s.session_id = r.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt
        WHERE s.is_user_process = 1
          AND r.session_id <> @@SPID;

        UPDATE dbo.HealthCollection
           SET completed_at_utc = SYSUTCDATETIME(),
               status = 'SUCCEEDED'
         WHERE collection_id = @CollectionId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.HealthCollection
           SET completed_at_utc = SYSUTCDATETIME(),
               status = 'FAILED',
               error_number = ERROR_NUMBER(),
               error_message = ERROR_MESSAGE()
         WHERE collection_id = @CollectionId;

        THROW;
    END CATCH;

    SELECT *
    FROM dbo.HealthCollection
    WHERE collection_id = @CollectionId;
END;
GO

EXEC dbo.usp_CaptureServerHealth;
GO

