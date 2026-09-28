/*
    Creates database roles immediately.
    Windows principals and file audit remain disabled until their flags are set.
*/
USE [master];
GO

SET NOCOUNT ON;

SELECT
    servicename,
    service_account,
    startup_type_desc,
    status_desc
FROM sys.dm_server_services
ORDER BY servicename;
GO

USE [OperationsLab];
GO

IF DATABASE_PRINCIPAL_ID(N'operations_reader') IS NULL
    CREATE ROLE operations_reader AUTHORIZATION dbo;

IF DATABASE_PRINCIPAL_ID(N'operations_writer') IS NULL
    CREATE ROLE operations_writer AUTHORIZATION dbo;

IF DATABASE_PRINCIPAL_ID(N'operations_executor') IS NULL
    CREATE ROLE operations_executor AUTHORIZATION dbo;

IF DATABASE_PRINCIPAL_ID(N'operations_auditor') IS NULL
    CREATE ROLE operations_auditor AUTHORIZATION dbo;

GRANT SELECT ON SCHEMA::app TO operations_reader;

GRANT SELECT, INSERT, UPDATE ON SCHEMA::app TO operations_writer;
DENY DELETE ON SCHEMA::app TO operations_writer;

GRANT EXECUTE ON SCHEMA::app TO operations_executor;

GRANT SELECT ON SCHEMA::audit TO operations_auditor;
DENY INSERT, UPDATE, DELETE ON SCHEMA::audit TO operations_auditor;
GO

USE [master];
GO

DECLARE @ApplyWindowsPrincipals bit = 0;
DECLARE @ReaderPrincipal sysname = N'LAB\SqlLabReaders';
DECLARE @WriterPrincipal sysname = N'LAB\SqlLabWriters';
DECLARE @ExecutorPrincipal sysname = N'LAB\SqlLabExecutors';
DECLARE @AuditorPrincipal sysname = N'LAB\SqlLabAuditors';

IF @ApplyWindowsPrincipals = 1
BEGIN
    DECLARE @Principal sysname;
    DECLARE @Role sysname;
    DECLARE @Sql nvarchar(max);

    DECLARE PrincipalCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT principal_name, role_name
        FROM
        (
            VALUES
                (@ReaderPrincipal, N'operations_reader'),
                (@WriterPrincipal, N'operations_writer'),
                (@ExecutorPrincipal, N'operations_executor'),
                (@AuditorPrincipal, N'operations_auditor')
        ) AS v(principal_name, role_name);

    OPEN PrincipalCursor;
    FETCH NEXT FROM PrincipalCursor INTO @Principal, @Role;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF SUSER_ID(@Principal) IS NULL
        BEGIN
            SET @Sql = N'CREATE LOGIN ' + QUOTENAME(@Principal) + N' FROM WINDOWS;';
            EXEC sys.sp_executesql @Sql;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM OperationsLab.sys.database_principals
            WHERE name = @Principal
        )
        BEGIN
            SET @Sql = N'USE [OperationsLab]; CREATE USER ' + QUOTENAME(@Principal)
                + N' FOR LOGIN ' + QUOTENAME(@Principal) + N';';
            EXEC sys.sp_executesql @Sql;
        END;

        SET @Sql = N'USE [OperationsLab]; ALTER ROLE ' + QUOTENAME(@Role)
            + N' ADD MEMBER ' + QUOTENAME(@Principal) + N';';
        EXEC sys.sp_executesql @Sql;

        FETCH NEXT FROM PrincipalCursor INTO @Principal, @Role;
    END;

    CLOSE PrincipalCursor;
    DEALLOCATE PrincipalCursor;
END
ELSE
    PRINT N'Windows principal creation skipped. Replace LAB group names and set @ApplyWindowsPrincipals = 1 to apply.';
GO

DECLARE @ApplyServerAudit bit = 0;

IF @ApplyServerAudit = 1
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'OperationsLab_File_Audit')
    BEGIN
        CREATE SERVER AUDIT [OperationsLab_File_Audit]
        TO FILE
        (
            FILEPATH = N'C:\SQLLab\SQLLAB1\Audit\',
            MAXSIZE = 100 MB,
            MAX_ROLLOVER_FILES = 5,
            RESERVE_DISK_SPACE = OFF
        )
        WITH
        (
            QUEUE_DELAY = 1000,
            ON_FAILURE = CONTINUE
        );
    END;

    ALTER SERVER AUDIT [OperationsLab_File_Audit] WITH (STATE = ON);

    IF NOT EXISTS
    (
        SELECT 1
        FROM OperationsLab.sys.database_audit_specifications
        WHERE name = N'OperationsLab_Database_Audit'
    )
    BEGIN
        EXEC(N'
            USE [OperationsLab];
            CREATE DATABASE AUDIT SPECIFICATION [OperationsLab_Database_Audit]
            FOR SERVER AUDIT [OperationsLab_File_Audit]
                ADD (SELECT ON SCHEMA::[app] BY [public]),
                ADD (INSERT ON SCHEMA::[app] BY [public]),
                ADD (UPDATE ON SCHEMA::[app] BY [public]),
                ADD (DELETE ON SCHEMA::[app] BY [public]),
                ADD (EXECUTE ON SCHEMA::[app] BY [public])
            WITH (STATE = ON);');
    END;
END
ELSE
    PRINT N'Server audit creation skipped. Verify the audit folder and set @ApplyServerAudit = 1 to apply.';
GO

USE [OperationsLab];
GO

SELECT
    r.name AS role_name,
    m.name AS member_name
FROM sys.database_role_members AS drm
JOIN sys.database_principals AS r
  ON r.principal_id = drm.role_principal_id
JOIN sys.database_principals AS m
  ON m.principal_id = drm.member_principal_id
WHERE r.name LIKE N'operations[_]%'
ORDER BY r.name, m.name;

SELECT
    pr.name AS principal_name,
    pe.state_desc,
    pe.permission_name,
    pe.class_desc,
    OBJECT_SCHEMA_NAME(pe.major_id) AS schema_name
FROM sys.database_permissions AS pe
JOIN sys.database_principals AS pr
  ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name LIKE N'operations[_]%'
ORDER BY pr.name, pe.permission_name;
GO
