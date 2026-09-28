/* Run immediately after Window A begins waiting. */
USE [OperationsLab];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET DEADLOCK_PRIORITY NORMAL;

IF (SELECT COUNT_BIG(*) FROM app.Orders WHERE order_id IN (1, 2)) <> 2
    THROW 50000, N'Orders 1 and 2 are required for the deadlock exercise.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE app.Orders
       SET last_modified_at = SYSUTCDATETIME()
     WHERE order_id = 2;

    WAITFOR DELAY '00:00:08';

    UPDATE app.Orders
       SET last_modified_at = SYSUTCDATETIME()
     WHERE order_id = 1;

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
