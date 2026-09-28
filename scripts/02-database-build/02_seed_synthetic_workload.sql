USE [OperationsLab];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF CONVERT(sysname, SERVERPROPERTY(N'InstanceName')) <> N'SQLLAB1'
    THROW 50000, N'Run this script only on the SQLLAB1 source instance.', 1;

IF DB_NAME() <> N'OperationsLab'
    THROW 50001, N'Run this script only in the OperationsLab database.', 1;

IF EXISTS (SELECT 1 FROM app.Customers)
   OR EXISTS (SELECT 1 FROM app.Products)
   OR EXISTS (SELECT 1 FROM app.Orders)
   OR EXISTS (SELECT 1 FROM app.OrderItems)
   OR EXISTS (SELECT 1 FROM app.Payments)
    THROW 50002, N'Seed stopped because one or more application tables already contain rows.', 1;

DECLARE @StartingAuditRows bigint =
    (SELECT COUNT_BIG(*) FROM audit.ChangeLog);

DROP TABLE IF EXISTS #Numbers;

;WITH Numbers AS
(
    SELECT TOP (100000)
        CONVERT(int, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) AS n
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
SELECT n
INTO #Numbers
FROM Numbers;

CREATE UNIQUE CLUSTERED INDEX CX_Numbers
    ON #Numbers (n);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT app.Customers
    (
        customer_code,
        full_name,
        email_address,
        region_code
    )
    SELECT
        CONCAT('CUST-', RIGHT(REPLICATE('0', 10) + CONVERT(varchar(10), n), 10)),
        CONCAT(N'Customer ', CONVERT(nvarchar(10), n)),
        CONCAT('customer', CONVERT(varchar(10), n), '@example.test'),
        CASE
            WHEN n % 10 BETWEEN 0 AND 4 THEN 'NY'
            WHEN n % 10 IN (5, 6) THEN 'NJ'
            WHEN n % 10 = 7 THEN 'CT'
            WHEN n % 10 = 8 THEN 'PA'
            ELSE 'MA'
        END
    FROM #Numbers
    WHERE n <= 10000;

    INSERT app.Products
    (
        sku,
        product_name,
        category,
        unit_price,
        stock_quantity
    )
    SELECT
        CONCAT('SKU-', RIGHT(REPLICATE('0', 6) + CONVERT(varchar(6), n), 6)),
        CONCAT(N'Product ', CONVERT(nvarchar(10), n)),
        CASE n % 5
            WHEN 0 THEN 'HARDWARE'
            WHEN 1 THEN 'SOFTWARE'
            WHEN 2 THEN 'NETWORK'
            WHEN 3 THEN 'STORAGE'
            ELSE 'ACCESSORY'
        END,
        CONVERT(decimal(12,2), 5.00 + ((n * 37) % 25000) / 100.0),
        50 + ((n * 17) % 951)
    FROM #Numbers
    WHERE n <= 500;

    DROP TABLE IF EXISTS #CustomerMap;

    SELECT
        ROW_NUMBER() OVER (ORDER BY customer_id) AS rn,
        customer_id
    INTO #CustomerMap
    FROM app.Customers;

    CREATE UNIQUE CLUSTERED INDEX CX_CustomerMap
        ON #CustomerMap (rn);

    INSERT app.Orders
    (
        customer_id,
        order_date,
        order_status,
        source_system
    )
    SELECT
        c.customer_id,
        DATEADD(MINUTE, -(n.n * 10), SYSUTCDATETIME()),
        CASE
            WHEN n.n % 100 < 60 THEN 'COMPLETED'
            WHEN n.n % 100 < 75 THEN 'SHIPPED'
            WHEN n.n % 100 < 85 THEN 'PROCESSING'
            WHEN n.n % 100 < 95 THEN 'PENDING'
            ELSE 'CANCELLED'
        END,
        CASE
            WHEN n.n % 100 < 55 THEN 'WEB'
            WHEN n.n % 100 < 80 THEN 'MOBILE'
            WHEN n.n % 100 < 95 THEN 'CALL_CENTER'
            ELSE 'BATCH'
        END
    FROM #Numbers AS n
    JOIN #CustomerMap AS c
      ON c.rn = ((n.n - 1) % 10000) + 1
    WHERE n.n <= 100000;

    DROP TABLE IF EXISTS #OrderMap;

    SELECT
        ROW_NUMBER() OVER (ORDER BY order_id) AS rn,
        order_id
    INTO #OrderMap
    FROM app.Orders;

    CREATE UNIQUE CLUSTERED INDEX CX_OrderMap
        ON #OrderMap (rn);

    DROP TABLE IF EXISTS #ProductMap;

    SELECT
        ROW_NUMBER() OVER (ORDER BY product_id) AS rn,
        product_id,
        unit_price
    INTO #ProductMap
    FROM app.Products;

    CREATE UNIQUE CLUSTERED INDEX CX_ProductMap
        ON #ProductMap (rn);

    INSERT app.OrderItems
    (
        order_id,
        product_id,
        quantity,
        unit_price
    )
    SELECT
        o.order_id,
        p.product_id,
        CONVERT(smallint, ((o.rn + v.item_number) % 5) + 1),
        p.unit_price
    FROM #OrderMap AS o
    CROSS JOIN (VALUES (1), (2), (3)) AS v(item_number)
    JOIN #ProductMap AS p
      ON p.rn = ((o.rn + (v.item_number * 137) - 2) % 500) + 1;

    ;WITH OrderTotals AS
    (
        SELECT
            order_id,
            SUM(line_total) AS total_amount
        FROM app.OrderItems
        GROUP BY order_id
    )
    UPDATE o
       SET o.total_amount = t.total_amount,
           o.last_modified_at = SYSUTCDATETIME()
    FROM app.Orders AS o
    JOIN OrderTotals AS t
      ON t.order_id = o.order_id;

    INSERT app.Payments
    (
        order_id,
        payment_date,
        amount,
        payment_method,
        payment_status,
        transaction_reference
    )
    SELECT
        o.order_id,
        DATEADD(MINUTE, 5, o.order_date),
        o.total_amount,
        CASE
            WHEN m.rn % 100 < 60 THEN 'CARD'
            WHEN m.rn % 100 < 80 THEN 'ACH'
            WHEN m.rn % 100 < 95 THEN 'PAYPAL'
            ELSE 'GIFT_CARD'
        END,
        CASE
            WHEN m.rn % 100 < 85 THEN 'SETTLED'
            WHEN m.rn % 100 < 92 THEN 'PENDING'
            WHEN m.rn % 100 < 97 THEN 'FAILED'
            ELSE 'REFUNDED'
        END,
        CONCAT('TXN-', CONVERT(varchar(20), o.order_id))
    FROM #OrderMap AS m
    JOIN app.Orders AS o
      ON o.order_id = m.order_id
    WHERE m.rn <= 90000;

    INSERT audit.ChangeLog
    (
        event_time,
        table_name,
        record_id,
        action_name,
        details
    )
    SELECT
        DATEADD(SECOND, -n.n, SYSUTCDATETIME()),
        N'app.Orders',
        o.order_id,
        CASE WHEN n.n % 5 = 0 THEN 'UPDATE' ELSE 'INSERT' END,
        CONCAT(N'Synthetic workload event ', CONVERT(nvarchar(10), n.n))
    FROM #Numbers AS n
    JOIN #OrderMap AS o
      ON o.rn = n.n
    WHERE n.n <= 20000;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

SELECT
    v.table_name,
    v.expected_rows,
    v.actual_rows,
    CASE WHEN v.expected_rows = v.actual_rows THEN N'PASS' ELSE N'FAIL' END AS result
FROM
(
    SELECT N'app.Customers' AS table_name,
           CONVERT(bigint, 10000) AS expected_rows,
           (SELECT COUNT_BIG(*) FROM app.Customers) AS actual_rows
    UNION ALL
    SELECT N'app.Products', 500,
           (SELECT COUNT_BIG(*) FROM app.Products)
    UNION ALL
    SELECT N'app.Orders', 100000,
           (SELECT COUNT_BIG(*) FROM app.Orders)
    UNION ALL
    SELECT N'app.OrderItems', 300000,
           (SELECT COUNT_BIG(*) FROM app.OrderItems)
    UNION ALL
    SELECT N'app.Payments', 90000,
           (SELECT COUNT_BIG(*) FROM app.Payments)
    UNION ALL
    SELECT N'audit.ChangeLog', @StartingAuditRows + 20000,
           (SELECT COUNT_BIG(*) FROM audit.ChangeLog)
) AS v
ORDER BY v.table_name;

;WITH CalculatedTotals AS
(
    SELECT
        order_id,
        SUM(line_total) AS calculated_total
    FROM app.OrderItems
    GROUP BY order_id
)
SELECT
    COUNT_BIG(*) AS mismatched_order_totals
FROM app.Orders AS o
JOIN CalculatedTotals AS c
  ON c.order_id = o.order_id
WHERE o.total_amount <> c.calculated_total;

DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;
GO
