#Requires -Version 5.1

<#
.SYNOPSIS
Runs a topology-aware health check for the SQL Server DBA Operations Lab.

.DESCRIPTION
Uses Windows authentication and dbatools Invoke-DbaQuery to test both lab
instances. The script checks connectivity, instance configuration, SQL Server
Agent, database state, backup age, failed jobs, disk space, transaction-log
usage, and log-shipping freshness. It writes timestamped CSV and HTML reports.

Exit code 0 means that no CRITICAL result was detected.
Exit code 1 means that one or more CRITICAL results were detected, or the
health check itself could not run.

.EXAMPLE
.\Invoke-SqlLabHealthCheck.ps1

.EXAMPLE
.\Invoke-SqlLabHealthCheck.ps1 -OutputDirectory C:\SQLLab\Reports\Health
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$PrimaryInstance = 'localhost,14331',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SecondaryInstance = 'localhost,14332',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Database = 'OperationsLab',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = 'C:\SQLLab\Reports\Health',

    [Parameter()]
    [ValidateRange(1, 744)]
    [int]$FullBackupMaxAgeHours = 192,

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$LogBackupMaxAgeMinutes = 20,

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$LogShippingMaxLatencyMinutes = 15,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$LogUsedCriticalPercent = 80,

    [Parameter()]
    [ValidateRange(1, 8760)]
    [int]$FailedJobLookbackHours = 24,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$MinimumFreeSpacePercent = 10,

    [Parameter()]
    [ValidateRange(128, 2147483647)]
    [int]$ExpectedMaxMemoryMb = 16384,

    [Parameter()]
    [ValidateRange(0, 32767)]
    [int]$ExpectedMaxDop = 8,

    [Parameter()]
    [switch]$NoHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:results = [System.Collections.Generic.List[object]]::new()
$script:checkedAtUtc = [datetime]::UtcNow

function Add-HealthResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'INFO', 'WARNING', 'CRITICAL')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Instance,

        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Observed = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$Expected = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$Detail = ''
    )

    $script:results.Add([pscustomobject][ordered]@{
            CheckedAtUtc = $script:checkedAtUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Status       = $Status
            Instance     = $Instance
            Check        = $Check
            Observed     = $Observed
            Expected     = $Expected
            Detail       = $Detail
        }) | Out-Null
}

function Invoke-LabQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Instance,

        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter()]
        [string]$InitialCatalog = 'master',

        [Parameter()]
        [hashtable]$SqlParameter
    )

    $invokeParameters = @{
        SqlInstance     = $Instance
        Database        = $InitialCatalog
        Query           = $Query
        As              = 'PSObject'
        EnableException = $true
    }

    if ($null -ne $SqlParameter -and $SqlParameter.Count -gt 0) {
        $invokeParameters.SqlParameter = $SqlParameter
    }

    $queryResults = @(Invoke-DbaQuery @invokeParameters)
    return ,$queryResults
}

function Get-AgeInMinutes {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$DateValue
    )

    if ($null -eq $DateValue -or $DateValue -is [System.DBNull]) {
        return $null
    }

    [math]::Round(((Get-Date) - [datetime]$DateValue).TotalMinutes, 2)
}

function ConvertTo-DisplayText {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return '<NULL>'
    }

    [string]$Value
}

try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        throw 'The dbatools PowerShell module is not installed. Install it with: Install-Module dbatools -Scope CurrentUser'
    }

    Import-Module dbatools -ErrorAction Stop
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

$topology = @(
    [pscustomobject]@{
        Instance      = $PrimaryInstance
        Role          = 'PRIMARY'
        ExpectedState = 'ONLINE'
    },
    [pscustomobject]@{
        Instance      = $SecondaryInstance
        Role          = 'SECONDARY'
        ExpectedState = 'RESTORING'
    }
)

foreach ($node in $topology) {
    $instance = $node.Instance

    try {
        $connection = Invoke-LabQuery -Instance $instance -Query @'
SELECT
    CAST(@@SERVERNAME AS nvarchar(128)) AS server_name,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition;
'@

        if ($connection.Count -ne 1) {
            throw 'The connectivity query did not return exactly one row.'
        }

        Add-HealthResult -Status PASS -Instance $instance -Check 'SQL connectivity' `
            -Observed "$($connection[0].server_name) / $($connection[0].product_version)" `
            -Expected 'Connection succeeds with Windows authentication' `
            -Detail $connection[0].edition
    }
    catch {
        Add-HealthResult -Status CRITICAL -Instance $instance -Check 'SQL connectivity' `
            -Observed 'Connection failed' -Expected 'Connection succeeds with Windows authentication' `
            -Detail $_.Exception.Message
        continue
    }

    try {
        $configuration = Invoke-LabQuery -Instance $instance -Query @'
SELECT
    MAX(CASE WHEN name = N'min server memory (MB)' THEN CONVERT(bigint, value) END) AS min_memory_configured_mb,
    MAX(CASE WHEN name = N'min server memory (MB)' THEN CONVERT(bigint, value_in_use) END) AS min_memory_runtime_mb,
    MAX(CASE WHEN name = N'max server memory (MB)' THEN CONVERT(bigint, value_in_use) END) AS max_memory_mb,
    MAX(CASE WHEN name = N'max degree of parallelism' THEN CONVERT(bigint, value_in_use) END) AS maxdop
FROM sys.configurations
WHERE name IN
(
    N'min server memory (MB)',
    N'max server memory (MB)',
    N'max degree of parallelism'
);
'@

        $configuration = $configuration[0]

        $memoryStatus = if ([int64]$configuration.min_memory_configured_mb -eq 0 -and
            [int64]$configuration.max_memory_mb -eq $ExpectedMaxMemoryMb) { 'PASS' } else { 'WARNING' }

        Add-HealthResult -Status $memoryStatus -Instance $instance -Check 'Server memory configuration' `
            -Observed "min configured=$($configuration.min_memory_configured_mb) MB; min runtime=$($configuration.min_memory_runtime_mb) MB; max=$($configuration.max_memory_mb) MB" `
            -Expected "min configured=0 MB (runtime may report 16 MB on 64-bit SQL Server); max=$ExpectedMaxMemoryMb MB"

        $maxDopStatus = if ([int64]$configuration.maxdop -eq $ExpectedMaxDop) { 'PASS' } else { 'WARNING' }
        Add-HealthResult -Status $maxDopStatus -Instance $instance -Check 'MAXDOP configuration' `
            -Observed ([string]$configuration.maxdop) -Expected ([string]$ExpectedMaxDop)
    }
    catch {
        Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Instance configuration query' `
            -Observed 'Query failed' -Expected 'Configuration is readable' -Detail $_.Exception.Message
    }

    try {
        $agentRows = Invoke-LabQuery -Instance $instance -Query @'
SELECT servicename, status_desc, startup_type_desc, service_account
FROM sys.dm_server_services
WHERE servicename LIKE N'SQL Server Agent%';
'@

        if ($agentRows.Count -eq 0) {
            Add-HealthResult -Status CRITICAL -Instance $instance -Check 'SQL Server Agent service' `
                -Observed 'No Agent service row returned' -Expected 'Running / Automatic'
        }
        else {
            foreach ($agent in $agentRows) {
                $agentStatus = if ($agent.status_desc -eq 'Running') { 'PASS' } else { 'CRITICAL' }
                Add-HealthResult -Status $agentStatus -Instance $instance -Check 'SQL Server Agent service' `
                    -Observed "$($agent.status_desc) / $($agent.startup_type_desc)" `
                    -Expected 'Running' -Detail "$($agent.servicename); account=$($agent.service_account)"
            }
        }
    }
    catch {
        Add-HealthResult -Status CRITICAL -Instance $instance -Check 'SQL Server Agent service query' `
            -Observed 'Query failed' -Expected 'Agent status is readable' -Detail $_.Exception.Message
    }

    try {
        $databaseRows = Invoke-LabQuery -Instance $instance -SqlParameter @{ DatabaseName = $Database } -Query @'
SELECT
    name,
    state_desc,
    recovery_model_desc,
    user_access_desc,
    log_reuse_wait_desc
FROM sys.databases
WHERE name = @DatabaseName;
'@

        if ($databaseRows.Count -eq 0) {
            Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Database exists' `
                -Observed 'Database not found' -Expected "$Database exists"
        }
        else {
            $databaseRow = $databaseRows[0]
            $databaseStateStatus = if ($databaseRow.state_desc -eq $node.ExpectedState) { 'PASS' } else { 'CRITICAL' }

            Add-HealthResult -Status $databaseStateStatus -Instance $instance -Check 'Database state' `
                -Observed $databaseRow.state_desc -Expected $node.ExpectedState `
                -Detail "role=$($node.Role); access=$($databaseRow.user_access_desc); recovery=$($databaseRow.recovery_model_desc)"

            $recoveryStatus = if ($databaseRow.recovery_model_desc -eq 'FULL') { 'PASS' } else { 'CRITICAL' }
            Add-HealthResult -Status $recoveryStatus -Instance $instance -Check 'Recovery model' `
                -Observed $databaseRow.recovery_model_desc -Expected 'FULL' `
                -Detail "log_reuse_wait=$($databaseRow.log_reuse_wait_desc)"
        }
    }
    catch {
        Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Database state query' `
            -Observed 'Query failed' -Expected "$Database state is readable" -Detail $_.Exception.Message
    }

    try {
        $failedJobs = Invoke-LabQuery -Instance $instance -SqlParameter @{ LookbackHours = $FailedJobLookbackHours } -Query @'
DECLARE @Since datetime = DATEADD(HOUR, -@LookbackHours, GETDATE());

WITH JobOutcomes AS
(
    SELECT
        j.name AS job_name,
        msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
        h.message
    FROM msdb.dbo.sysjobhistory AS h
    INNER JOIN msdb.dbo.sysjobs AS j
        ON j.job_id = h.job_id
    WHERE h.step_id = 0
      AND h.run_status = 0
)
SELECT job_name, run_datetime, message
FROM JobOutcomes
WHERE run_datetime >= @Since
ORDER BY run_datetime DESC;
'@

        if ($failedJobs.Count -eq 0) {
            Add-HealthResult -Status PASS -Instance $instance -Check 'Failed SQL Agent jobs' `
                -Observed '0' -Expected "0 during the last $FailedJobLookbackHours hours"
        }
        else {
            $failedJobNames = ($failedJobs | ForEach-Object { "$($_.job_name) at $($_.run_datetime)" }) -join '; '
            Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Failed SQL Agent jobs' `
                -Observed ([string]$failedJobs.Count) -Expected "0 during the last $FailedJobLookbackHours hours" `
                -Detail $failedJobNames
        }
    }
    catch {
        Add-HealthResult -Status CRITICAL -Instance $instance -Check 'SQL Agent history query' `
            -Observed 'Query failed' -Expected 'Job history is readable' -Detail $_.Exception.Message
    }

    try {
        $volumes = Invoke-LabQuery -Instance $instance -Query @'
SELECT DISTINCT
    vs.volume_mount_point,
    CONVERT(decimal(19,2), vs.total_bytes / 1048576.0) AS total_mb,
    CONVERT(decimal(19,2), vs.available_bytes / 1048576.0) AS available_mb,
    CONVERT(decimal(9,2), 100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0)) AS free_percent
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY vs.volume_mount_point;
'@

        if ($volumes.Count -eq 0) {
            Add-HealthResult -Status WARNING -Instance $instance -Check 'Database volume free space' `
                -Observed 'No volume rows returned' -Expected "At least $MinimumFreeSpacePercent% free"
        }
        else {
            foreach ($volume in $volumes) {
                $spaceStatus = if ([decimal]$volume.free_percent -ge $MinimumFreeSpacePercent) { 'PASS' } else { 'CRITICAL' }
                Add-HealthResult -Status $spaceStatus -Instance $instance -Check 'Database volume free space' `
                    -Observed "$($volume.free_percent)% ($($volume.available_mb) MB free)" `
                    -Expected "At least $MinimumFreeSpacePercent% free" `
                    -Detail "$($volume.volume_mount_point); total=$($volume.total_mb) MB"
            }
        }
    }
    catch {
        Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Database volume query' `
            -Observed 'Query failed' -Expected 'Volume statistics are readable' -Detail $_.Exception.Message
    }

    if ($node.Role -eq 'PRIMARY') {
        try {
            $backupRows = Invoke-LabQuery -Instance $instance -SqlParameter @{ DatabaseName = $Database } -Query @'
SELECT
    MAX(CASE WHEN type = 'D' AND is_copy_only = 0 THEN backup_finish_date END) AS last_full_backup,
    MAX(CASE WHEN type = 'L' THEN backup_finish_date END) AS last_log_backup
FROM msdb.dbo.backupset
WHERE database_name = @DatabaseName;
'@

            $backupRow = $backupRows[0]
            $fullAgeMinutes = Get-AgeInMinutes -DateValue $backupRow.last_full_backup
            $logAgeMinutes = Get-AgeInMinutes -DateValue $backupRow.last_log_backup

            if ($null -eq $fullAgeMinutes) {
                Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Latest full backup age' `
                    -Observed 'No full backup found' -Expected "Not older than $FullBackupMaxAgeHours hours"
            }
            else {
                $fullAgeHours = [math]::Round($fullAgeMinutes / 60, 2)
                $fullStatus = if ($fullAgeHours -le $FullBackupMaxAgeHours) { 'PASS' } else { 'CRITICAL' }
                Add-HealthResult -Status $fullStatus -Instance $instance -Check 'Latest full backup age' `
                    -Observed "$fullAgeHours hours; $($backupRow.last_full_backup)" `
                    -Expected "Not older than $FullBackupMaxAgeHours hours"
            }

            if ($null -eq $logAgeMinutes) {
                Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Latest log backup age' `
                    -Observed 'No log backup found' -Expected "Not older than $LogBackupMaxAgeMinutes minutes"
            }
            else {
                $logStatus = if ($logAgeMinutes -le $LogBackupMaxAgeMinutes) { 'PASS' } else { 'CRITICAL' }
                Add-HealthResult -Status $logStatus -Instance $instance -Check 'Latest log backup age' `
                    -Observed "$logAgeMinutes minutes; $($backupRow.last_log_backup)" `
                    -Expected "Not older than $LogBackupMaxAgeMinutes minutes"
            }
        }
        catch {
            Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Backup history query' `
                -Observed 'Query failed' -Expected 'Backup history is readable' -Detail $_.Exception.Message
        }

        try {
            $logUsageRows = Invoke-LabQuery -Instance $instance -InitialCatalog $Database -Query @'
SELECT
    CONVERT(decimal(19,2), total_log_size_in_bytes / 1048576.0) AS total_log_mb,
    CONVERT(decimal(19,2), used_log_space_in_bytes / 1048576.0) AS used_log_mb,
    CONVERT(decimal(9,2), used_log_space_in_percent) AS used_log_percent
FROM sys.dm_db_log_space_usage;
'@

            $logUsage = $logUsageRows[0]
            $logUsageStatus = if ([decimal]$logUsage.used_log_percent -lt $LogUsedCriticalPercent) { 'PASS' } else { 'CRITICAL' }
            Add-HealthResult -Status $logUsageStatus -Instance $instance -Check 'Transaction-log utilization' `
                -Observed "$($logUsage.used_log_percent)% ($($logUsage.used_log_mb) of $($logUsage.total_log_mb) MB)" `
                -Expected "Less than $LogUsedCriticalPercent%"
        }
        catch {
            Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Transaction-log utilization query' `
                -Observed 'Query failed' -Expected 'Log utilization is readable' -Detail $_.Exception.Message
        }

        try {
            $primaryMonitorRows = Invoke-LabQuery -Instance $instance -SqlParameter @{ DatabaseName = $Database } -Query @'
SELECT
    primary_server,
    primary_database,
    last_backup_date,
    backup_threshold,
    threshold_alert_enabled
FROM msdb.dbo.log_shipping_monitor_primary
WHERE primary_database = @DatabaseName;
'@

            if ($primaryMonitorRows.Count -eq 0) {
                Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Log-shipping primary monitor' `
                    -Observed 'No monitor row found' -Expected "$Database is registered as the primary"
            }
            else {
                $primaryMonitor = $primaryMonitorRows[0]
                $primaryBackupAge = Get-AgeInMinutes -DateValue $primaryMonitor.last_backup_date
                $monitorStatus = if ($null -ne $primaryBackupAge -and
                    $primaryBackupAge -le $LogShippingMaxLatencyMinutes) { 'PASS' } else { 'CRITICAL' }

                Add-HealthResult -Status $monitorStatus -Instance $instance -Check 'Log-shipping primary backup freshness' `
                    -Observed "$(ConvertTo-DisplayText $primaryBackupAge) minutes; $($primaryMonitor.last_backup_date)" `
                    -Expected "Not older than $LogShippingMaxLatencyMinutes minutes" `
                    -Detail "primary=$($primaryMonitor.primary_server); configured threshold=$($primaryMonitor.backup_threshold) minutes"
            }
        }
        catch {
            Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Log-shipping primary monitor query' `
                -Observed 'Query failed' -Expected 'Primary monitor data is readable' -Detail $_.Exception.Message
        }
    }
    else {
        Add-HealthResult -Status INFO -Instance $instance -Check 'Transaction-log utilization' `
            -Observed 'Not queried while database is RESTORING' -Expected 'Check the writable primary'

        try {
            $secondaryMonitorRows = Invoke-LabQuery -Instance $instance -SqlParameter @{ DatabaseName = $Database } -Query @'
SELECT
    secondary_server,
    secondary_database,
    last_copied_date,
    last_restored_date,
    last_restored_latency,
    restore_threshold,
    threshold_alert_enabled
FROM msdb.dbo.log_shipping_monitor_secondary
WHERE secondary_database = @DatabaseName;
'@

            if ($secondaryMonitorRows.Count -eq 0) {
                Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Log-shipping secondary monitor' `
                    -Observed 'No monitor row found' -Expected "$Database is registered as the secondary"
            }
            else {
                $secondaryMonitor = $secondaryMonitorRows[0]
                $copyAge = Get-AgeInMinutes -DateValue $secondaryMonitor.last_copied_date
                $restoreAge = Get-AgeInMinutes -DateValue $secondaryMonitor.last_restored_date
                $reportedLatency = if ($secondaryMonitor.last_restored_latency -is [System.DBNull]) {
                    $null
                }
                else {
                    [decimal]$secondaryMonitor.last_restored_latency
                }

                $secondaryHealthy = $null -ne $copyAge -and
                    $null -ne $restoreAge -and
                    $copyAge -le $LogShippingMaxLatencyMinutes -and
                    $restoreAge -le $LogShippingMaxLatencyMinutes -and
                    ($null -eq $reportedLatency -or $reportedLatency -le $LogShippingMaxLatencyMinutes)

                $secondaryStatus = if ($secondaryHealthy) { 'PASS' } else { 'CRITICAL' }
                Add-HealthResult -Status $secondaryStatus -Instance $instance -Check 'Log-shipping secondary freshness' `
                    -Observed "copy age=$(ConvertTo-DisplayText $copyAge) min; restore age=$(ConvertTo-DisplayText $restoreAge) min; reported latency=$(ConvertTo-DisplayText $reportedLatency) min" `
                    -Expected "Each available value is at most $LogShippingMaxLatencyMinutes minutes" `
                    -Detail "last copied=$($secondaryMonitor.last_copied_date); last restored=$($secondaryMonitor.last_restored_date); configured threshold=$($secondaryMonitor.restore_threshold) minutes"
            }
        }
        catch {
            Add-HealthResult -Status CRITICAL -Instance $instance -Check 'Log-shipping secondary monitor query' `
                -Observed 'Query failed' -Expected 'Secondary monitor data is readable' -Detail $_.Exception.Message
        }
    }
}

$statusOrder = @{
    CRITICAL = 1
    WARNING  = 2
    INFO     = 3
    PASS     = 4
}

$orderedResults = @($script:results | Sort-Object @{ Expression = { $statusOrder[$_.Status] } }, Instance, Check)
$criticalCount = @($orderedResults | Where-Object Status -eq 'CRITICAL').Count
$warningCount = @($orderedResults | Where-Object Status -eq 'WARNING').Count
$passCount = @($orderedResults | Where-Object Status -eq 'PASS').Count
$overallStatus = if ($criticalCount -gt 0) { 'CRITICAL' } else { 'HEALTHY' }
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvPath = Join-Path $OutputDirectory "SqlLabHealth_$timestamp.csv"
$htmlPath = Join-Path $OutputDirectory "SqlLabHealth_$timestamp.html"

$orderedResults | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

if (-not $NoHtml) {
    $style = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2937; }
h1 { color: #0f3b5f; }
.summary { margin: 12px 0 20px 0; padding: 12px; background: #eef4f8; border-left: 5px solid #0f3b5f; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th { background: #0f3b5f; color: white; text-align: left; }
th, td { border: 1px solid #c7d2dc; padding: 7px; vertical-align: top; }
tr:nth-child(even) { background: #f7fafc; }
</style>
'@

    $preContent = @"
<h1>SQL Server DBA Operations Lab Health Check</h1>
<div class="summary">
<strong>Overall status:</strong> $overallStatus<br />
<strong>Checked at:</strong> $($script:checkedAtUtc.ToString('yyyy-MM-dd HH:mm:ss.fff')) UTC<br />
<strong>Primary:</strong> $PrimaryInstance &nbsp; <strong>Secondary:</strong> $SecondaryInstance<br />
<strong>PASS:</strong> $passCount &nbsp; <strong>WARNING:</strong> $warningCount &nbsp; <strong>CRITICAL:</strong> $criticalCount
</div>
"@

    $orderedResults |
        ConvertTo-Html -Title 'SQL Lab Health Check' -Head $style -PreContent $preContent |
        Set-Content -LiteralPath $htmlPath -Encoding UTF8
}

$orderedResults |
    Select-Object Status, Instance, Check, Observed, Expected |
    Format-Table -AutoSize -Wrap |
    Out-Host

[pscustomobject][ordered]@{
    OverallStatus = $overallStatus
    CriticalCount = $criticalCount
    WarningCount  = $warningCount
    PassCount     = $passCount
    CsvReport     = $csvPath
    HtmlReport    = if ($NoHtml) { $null } else { $htmlPath }
}

if ($criticalCount -gt 0) {
    exit 1
}

exit 0
