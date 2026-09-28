/*
    Creates the lab databases and schema on SQLLAB1.
    Prerequisite: C:\SQLLab\SQLLAB1\Data and C:\SQLLab\SQLLAB1\Log exist
    and are writable by NT SERVICE\MSSQL$SQLLAB1.
*/
USE [master];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF IS_SRVROLEMEMBER(N'sysadmin') <> 1
    THROW 50000, N'Sysadmin membership is required.', 1;

IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
    THROW 50001, N'Run this database-build script only on SQLLAB1.', 1;

IF DB_ID(N'DBA_Admin') IS NULL
BEGIN
    CREATE DATABASE [DBA_Admin]
    ON PRIMARY
    (
        NAME = N'DBA_Admin',
        FILENAME = N'C:\SQLLab\SQLLAB1\Data\DBA_Admin.mdf',
        SIZE = 256MB,
        FILEGROWTH = 64MB
    )
    LOG ON
    (
        NAME = N'DBA_Admin_log',
        FILENAME = N'C:\SQLLab\SQLLAB1\Log\DBA_Admin_log.ldf',
        SIZE = 128MB,
        FILEGROWTH = 64MB
    );
END;

IF DB_ID(N'OperationsLab') IS NULL
BEGIN
    CREATE DATABASE [OperationsLab]
    ON PRIMARY
    (
        NAME = N'OperationsLab',
        FILENAME = N'C:\SQLLab\SQLLAB1\Data\OperationsLab.mdf',
        SIZE = 512MB,
        FILEGROWTH = 128MB
    )
    LOG ON
    (
        NAME = N'OperationsLab_log',
        FILENAME = N'C:\SQLLab\SQLLAB1\Log\OperationsLab_log.ldf',
        SIZE = 256MB,
        FILEGROWTH = 128MB
    );
END;
GO

ALTER DATABASE [DBA_Admin] SET RECOVERY SIMPLE;
ALTER DATABASE [DBA_Admin] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [DBA_Admin] SET AUTO_CLOSE OFF;
ALTER DATABASE [DBA_Admin] SET AUTO_SHRINK OFF;

ALTER DATABASE [OperationsLab] SET COMPATIBILITY_LEVEL = 170;
ALTER DATABASE [OperationsLab] SET RECOVERY FULL;
ALTER DATABASE [OperationsLab] SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE [OperationsLab] SET AUTO_CLOSE OFF;
ALTER DATABASE [OperationsLab] SET AUTO_SHRINK OFF;
ALTER DATABASE [OperationsLab] SET QUERY_STORE = ON
(
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,
    WAIT_STATS_CAPTURE_MODE = ON,
    MAX_STORAGE_SIZE_MB = 1024,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    SIZE_BASED_CLEANUP_MODE = AUTO
);
GO

USE [OperationsLab];
GO

IF SCHEMA_ID(N'app') IS NULL
    EXEC(N'CREATE SCHEMA app AUTHORIZATION dbo;');

IF SCHEMA_ID(N'audit') IS NULL
    EXEC(N'CREATE SCHEMA audit AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'app.Customers', N'U') IS NULL
BEGIN
    CREATE TABLE app.Customers
    (
        customer_id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
        customer_code varchar(20) NOT NULL,
        full_name nvarchar(150) NOT NULL,
        email_address varchar(255) NOT NULL,
        region_code char(2) NOT NULL,
        created_at datetime2(3) NOT NULL
            CONSTRAINT DF_Customers_CreatedAt DEFAULT (SYSUTCDATETIME()),
        is_active bit NOT NULL
            CONSTRAINT DF_Customers_IsActive DEFAULT ((1)),
        CONSTRAINT UQ_Customers_CustomerCode UNIQUE (customer_code),
        CONSTRAINT UQ_Customers_EmailAddress UNIQUE (email_address)
    );

    CREATE INDEX IX_Customers_Region_Active
        ON app.Customers (region_code, is_active)
        INCLUDE (customer_code, full_name, email_address);
END;
GO

IF OBJECT_ID(N'app.Products', N'U') IS NULL
BEGIN
    CREATE TABLE app.Products
    (
        product_id int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Products PRIMARY KEY CLUSTERED,
        sku varchar(30) NOT NULL,
        product_name nvarchar(200) NOT NULL,
        category varchar(50) NOT NULL,
        unit_price decimal(12,2) NOT NULL,
        stock_quantity int NOT NULL,
        modified_at datetime2(3) NOT NULL
            CONSTRAINT DF_Products_ModifiedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT UQ_Products_SKU UNIQUE (sku),
        CONSTRAINT CK_Products_UnitPrice CHECK (unit_price >= 0),
        CONSTRAINT CK_Products_StockQuantity CHECK (stock_quantity >= 0)
    );

    CREATE INDEX IX_Products_Category
        ON app.Products (category, product_id)
        INCLUDE (sku, product_name, unit_price, stock_quantity);
END;
GO

IF OBJECT_ID(N'app.Orders', N'U') IS NULL
BEGIN
    CREATE TABLE app.Orders
    (
        order_id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
        customer_id bigint NOT NULL,
        order_date datetime2(3) NOT NULL,
        order_status varchar(20) NOT NULL,
        source_system varchar(20) NOT NULL,
        total_amount decimal(14,2) NOT NULL
            CONSTRAINT DF_Orders_TotalAmount DEFAULT ((0)),
        last_modified_at datetime2(3) NOT NULL
            CONSTRAINT DF_Orders_LastModifiedAt DEFAULT (SYSUTCDATETIME()),
        row_version rowversion NOT NULL,
        CONSTRAINT FK_Orders_Customers
            FOREIGN KEY (customer_id) REFERENCES app.Customers (customer_id),
        CONSTRAINT CK_Orders_Status
            CHECK (order_status IN ('PENDING','PROCESSING','SHIPPED','COMPLETED','CANCELLED')),
        CONSTRAINT CK_Orders_Source
            CHECK (source_system IN ('WEB','MOBILE','CALL_CENTER','BATCH')),
        CONSTRAINT CK_Orders_TotalAmount CHECK (total_amount >= 0)
    );

    CREATE INDEX IX_Orders_Customer_Date
        ON app.Orders (customer_id, order_date DESC)
        INCLUDE (order_status, source_system, total_amount);

    CREATE INDEX IX_Orders_Status_Source_Date
        ON app.Orders (order_status, source_system, order_date DESC)
        INCLUDE (customer_id, total_amount);
END;
GO

IF OBJECT_ID(N'app.OrderItems', N'U') IS NULL
BEGIN
    CREATE TABLE app.OrderItems
    (
        order_item_id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_OrderItems PRIMARY KEY CLUSTERED,
        order_id bigint NOT NULL,
        product_id int NOT NULL,
        quantity smallint NOT NULL,
        unit_price decimal(12,2) NOT NULL,
        line_total AS CONVERT(decimal(14,2), quantity * unit_price),
        CONSTRAINT FK_OrderItems_Orders
            FOREIGN KEY (order_id) REFERENCES app.Orders (order_id),
        CONSTRAINT FK_OrderItems_Products
            FOREIGN KEY (product_id) REFERENCES app.Products (product_id),
        CONSTRAINT UQ_OrderItems_Order_Product UNIQUE (order_id, product_id),
        CONSTRAINT CK_OrderItems_Quantity CHECK (quantity > 0),
        CONSTRAINT CK_OrderItems_UnitPrice CHECK (unit_price >= 0)
    );

    CREATE INDEX IX_OrderItems_Product
        ON app.OrderItems (product_id, order_id)
        INCLUDE (quantity, unit_price);
END;
GO

IF OBJECT_ID(N'app.Payments', N'U') IS NULL
BEGIN
    CREATE TABLE app.Payments
    (
        payment_id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_Payments PRIMARY KEY CLUSTERED,
        order_id bigint NOT NULL,
        payment_date datetime2(3) NOT NULL,
        amount decimal(14,2) NOT NULL,
        payment_method varchar(20) NOT NULL,
        payment_status varchar(20) NOT NULL,
        transaction_reference varchar(50) NULL,
        CONSTRAINT FK_Payments_Orders
            FOREIGN KEY (order_id) REFERENCES app.Orders (order_id),
        CONSTRAINT CK_Payments_Amount CHECK (amount >= 0),
        CONSTRAINT CK_Payments_Method
            CHECK (payment_method IN ('CARD','ACH','PAYPAL','GIFT_CARD')),
        CONSTRAINT CK_Payments_Status
            CHECK (payment_status IN ('PENDING','SETTLED','FAILED','REFUNDED'))
    );

    CREATE UNIQUE INDEX UX_Payments_TransactionReference
        ON app.Payments (transaction_reference)
        WHERE transaction_reference IS NOT NULL;

    CREATE INDEX IX_Payments_Order_Date
        ON app.Payments (order_id, payment_date DESC)
        INCLUDE (amount, payment_method, payment_status);
END;
GO

IF OBJECT_ID(N'audit.ChangeLog', N'U') IS NULL
BEGIN
    CREATE TABLE audit.ChangeLog
    (
        audit_id bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ChangeLog PRIMARY KEY CLUSTERED,
        event_time datetime2(3) NOT NULL
            CONSTRAINT DF_ChangeLog_EventTime DEFAULT (SYSUTCDATETIME()),
        table_name sysname NOT NULL,
        record_id bigint NULL,
        action_name varchar(20) NOT NULL,
        login_name sysname NOT NULL
            CONSTRAINT DF_ChangeLog_LoginName DEFAULT (ORIGINAL_LOGIN()),
        details nvarchar(2000) NULL
    );

    CREATE INDEX IX_ChangeLog_EventTime
        ON audit.ChangeLog (event_time DESC, audit_id DESC)
        INCLUDE (table_name, record_id, action_name, login_name);
END;
GO

CREATE OR ALTER PROCEDURE app.usp_GetCustomerOrders
    @CustomerID bigint,
    @StartDate datetime2(3) = NULL,
    @EndDate datetime2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        o.order_id,
        o.customer_id,
        c.customer_code,
        c.full_name,
        o.order_date,
        o.order_status,
        o.source_system,
        o.total_amount
    FROM app.Orders AS o
    JOIN app.Customers AS c
      ON c.customer_id = o.customer_id
    WHERE o.customer_id = @CustomerID
      AND (@StartDate IS NULL OR o.order_date >= @StartDate)
      AND (@EndDate IS NULL OR o.order_date < @EndDate)
    ORDER BY o.order_date DESC, o.order_id DESC;
END;
GO

CREATE OR ALTER PROCEDURE app.usp_GetOrdersByStatusSource
    @OrderStatus varchar(20),
    @SourceSystem varchar(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        o.order_id,
        o.customer_id,
        o.order_date,
        o.order_status,
        o.source_system,
        o.total_amount
    FROM app.Orders AS o
    WHERE o.order_status = @OrderStatus
      AND o.source_system = @SourceSystem
    ORDER BY o.order_date DESC, o.order_id DESC;
END;
GO

CREATE OR ALTER PROCEDURE app.usp_GetProductSales
    @Category varchar(50),
    @StartDate datetime2(3) = NULL,
    @EndDate datetime2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.product_id,
        p.sku,
        p.product_name,
        p.category,
        SUM(CONVERT(bigint, oi.quantity)) AS units_sold,
        SUM(oi.line_total) AS revenue
    FROM app.Products AS p
    JOIN app.OrderItems AS oi
      ON oi.product_id = p.product_id
    JOIN app.Orders AS o
      ON o.order_id = oi.order_id
    WHERE p.category = @Category
      AND o.order_status <> 'CANCELLED'
      AND (@StartDate IS NULL OR o.order_date >= @StartDate)
      AND (@EndDate IS NULL OR o.order_date < @EndDate)
    GROUP BY
        p.product_id,
        p.sku,
        p.product_name,
        p.category
    ORDER BY revenue DESC, p.product_id;
END;
GO

SELECT
    CONVERT(sysname, SERVERPROPERTY(N'ServerName')) AS connected_server,
    d.name,
    d.compatibility_level,
    d.recovery_model_desc,
    d.page_verify_option_desc,
    d.is_auto_close_on,
    d.is_auto_shrink_on
FROM sys.databases AS d
WHERE d.name IN (N'DBA_Admin', N'OperationsLab')
ORDER BY d.name;
GO

