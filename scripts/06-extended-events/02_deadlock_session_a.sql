/*
    Window A: run this batch, then immediately run 03_deadlock_session_b.sql
    in a second SSMS window connected to OperationsLab on SQLLAB1.
*/
USE [OperationsLab];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET DEADLOCK_PRIORITY LOW;

IF (SELECT COUNT_BIG(*) FROM app.Orders WHERE order_id IN (1, 2)) <> 2
    THROW 50000, N'Orders 1 and 2 are required for the deadlock exercise.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE app.Orders
       SET last_modified_at = SYSUTCDATETIME()
     WHERE order_id = 1;

    WAITFOR DELAY '00:00:08';

    UPDATE app.Orders
       SET last_modified_at = SYSUTCDATETIME()
     WHERE order_id = 2;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    SELECT
        ERROR_NUMBER() AS error_number,
        ERROR_MESSAGE() AS error_message;
END CATCH;
GO
