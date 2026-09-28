#Requires -Version 5.1

<#
.SYNOPSIS
Performs an actual restore validation of the latest OperationsLab backup chain.

.DESCRIPTION
Uses dbatools Test-DbaLastBackup with Windows authentication. By default, the
latest valid backup chain for OperationsLab on SQLLAB1 is restored under a
temporary name on SQLLAB2, DBCC CHECKDB is executed, and the temporary database
is dropped. Timestamped CSV and HTML reports record the outcome.

Exit code 0 means that the restore and DBCC CHECKDB succeeded.
Exit code 1 means that validation failed or the script could not run.

.EXAMPLE
.\Test-SqlLabRestore.ps1 -CopyFile

.EXAMPLE
.\Test-SqlLabRestore.ps1 -CopyFile -CopyPath C:\SQLLab\RestoreValidation

.EXAMPLE
.\Test-SqlLabRestore.ps1 -VerifyOnly
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SqlInstance = 'localhost\SQLLAB1,14331',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Database = 'OperationsLab',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Destination = 'localhost\SQLLAB2,14332',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DataDirectory = 'C:\SQLLab\SQLLAB2\Data',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = 'C:\SQLLab\SQLLAB2\Log',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Prefix = 'RestoreCheck-',

    [Parameter()]
    [switch]$CopyFile,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CopyPath = 'C:\SQLLab\RestoreValidation',

    [Parameter()]
    [switch]$VerifyOnly,

    [Parameter()]
    [switch]$RetainRestoredDatabase,

    [Parameter()]
    [ValidateRange(0, 32767)]
    [int]$MaxDop = 4,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = 'C:\SQLLab\Reports\RestoreValidation'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-RestoreReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Summary,

        [Parameter()]
        [AllowNull()]
        [object[]]$Detail,

        [Parameter(Mandatory)]
        [string]$ReportDirectory,

        [Parameter(Mandatory)]
        [string]$Timestamp
    )

    New-Item -Path $ReportDirectory -ItemType Directory -Force | Out-Null

    $summaryCsvPath = Join-Path $ReportDirectory "SqlLabRestoreValidation_Summary_$Timestamp.csv"
    $detailCsvPath = Join-Path $ReportDirectory "SqlLabRestoreValidation_Detail_$Timestamp.csv"
    $htmlPath = Join-Path $ReportDirectory "SqlLabRestoreValidation_$Timestamp.html"

    $Summary | Export-Csv -LiteralPath $summaryCsvPath -NoTypeInformation -Encoding UTF8

    if ($null -ne $Detail -and $Detail.Count -gt 0) {
        $Detail |
            Select-Object SourceServer, TestServer, Database, FileExists, Size, RestoreResult, DbccResult,
            RestoreStart, RestoreEnd, RestoreElapsed, DbccMaxDop, DbccStart, DbccEnd, DbccElapsed,
            @{ Name = 'BackupDates'; Expression = { $_.BackupDates -join '; ' } },
            @{ Name = 'BackupFiles'; Expression = { $_.BackupFiles -join '; ' } },
            @{ Name = 'DbccOutput'; Expression = { $_.DbccOutput -join ' | ' } } |
            Export-Csv -LiteralPath $detailCsvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'No detail rows were returned.' | Set-Content -LiteralPath $detailCsvPath -Encoding UTF8
    }

    $style = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2937; }
h1, h2 { color: #0f3b5f; }
table { border-collapse: collapse; width: 100%; margin-bottom: 20px; font-size: 13px; }
th { background: #0f3b5f; color: white; text-align: left; }
th, td { border: 1px solid #c7d2dc; padding: 7px; vertical-align: top; }
tr:nth-child(even) { background: #f7fafc; }
</style>
'@

    $summaryFragment = $Summary | ConvertTo-Html -Fragment -PreContent '<h2>Summary</h2>'
    if ($null -ne $Detail -and $Detail.Count -gt 0) {
        $detailFragment = $Detail |
            Select-Object SourceServer, TestServer, Database, FileExists, Size, RestoreResult, DbccResult,
            RestoreStart, RestoreEnd, RestoreElapsed, DbccMaxDop, DbccStart, DbccEnd, DbccElapsed |
            ConvertTo-Html -Fragment -PreContent '<h2>dbatools result</h2>'
    }
    else {
        $detailFragment = '<h2>dbatools result</h2><p>No detail rows were returned.</p>'
    }

    ConvertTo-Html -Title 'SQL Lab Restore Validation' -Head $style `
        -Body "<h1>SQL Server DBA Operations Lab Restore Validation</h1>$summaryFragment$detailFragment" |
        Set-Content -LiteralPath $htmlPath -Encoding UTF8

    [pscustomobject][ordered]@{
        SummaryCsv = $summaryCsvPath
        DetailCsv  = $detailCsvPath
        HtmlReport = $htmlPath
    }
}

$startedAtUtc = [datetime]::UtcNow
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$testResults = @()
$status = 'FAILED'
$failureMessage = $null

try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        throw 'The dbatools PowerShell module is not installed. Install it with: Install-Module dbatools -Scope CurrentUser'
    }

    Import-Module dbatools -ErrorAction Stop
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null

        $sourceServer = Connect-DbaInstance `
        -SqlInstance $SqlInstance `
        -NetworkProtocol TcpIp `
        -TrustServerCertificate `
        -ErrorAction Stop

    $destinationServer = Connect-DbaInstance `
        -SqlInstance $Destination `
        -NetworkProtocol TcpIp `
        -TrustServerCertificate `
        -ErrorAction Stop

    $sourceCheck = @(Invoke-DbaQuery `
        -SqlInstance $sourceServer `
        -Database master `
        -Query @'
SELECT
    CAST(@@SERVERNAME AS nvarchar(128)) AS server_name,
    d.name,
    d.state_desc,
    d.recovery_model_desc
FROM sys.databases AS d
WHERE d.name = @DatabaseName;
'@ `
        -SqlParameter @{ DatabaseName = $Database } `
        -As PSObject `
        -EnableException)

    if ($sourceCheck.Count -ne 1) {
        throw "Database [$Database] was not found on source instance [$SqlInstance]."
    }

    if ($sourceCheck[0].state_desc -ne 'ONLINE') {
        throw "Source database [$Database] is [$($sourceCheck[0].state_desc)], not ONLINE."
    }

    $sourceDatabases = @(
        Get-DbaDatabase `
            -SqlInstance $sourceServer `
            -Database $Database `
            -ErrorAction Stop
    )

    if ($sourceDatabases.Count -ne 1) {
        throw "Get-DbaDatabase did not return exactly one [$Database] database."
    }

    $sourceDatabase = $sourceDatabases[0]

    $destinationCheck = @(Invoke-DbaQuery `
        -SqlInstance $destinationServer `
        -Database master `
        -Query @'
SELECT CAST(@@SERVERNAME AS nvarchar(128)) AS server_name;
'@ `
        -As PSObject `
        -EnableException)

    if ($destinationCheck.Count -ne 1) {
        throw "The destination connectivity query for [$Destination] did not return exactly one row."
    }

    $backupHistory = @(
        Get-DbaDbBackupHistory `
            -SqlInstance $sourceServer `
            -Database $Database `
            -Last `
            -EnableException
    )

    $fullBackups = @(
        $backupHistory |
            Where-Object Type -eq 'Full'
    )

    if ($backupHistory.Count -eq 0 -or $fullBackups.Count -eq 0) {
        throw "No usable backup chain containing a full backup was found for [$Database] on [$SqlInstance]."
    }

    $validationDatabaseName = "$Prefix$Database"

    $existingValidationDatabase = @(
        Get-DbaDatabase `
            -SqlInstance $destinationServer `
            -Database $validationDatabaseName `
            -ErrorAction Stop
    )

    if ($existingValidationDatabase.Count -gt 0) {
        throw "Temporary database [$validationDatabaseName] already exists on [$Destination]."
    }

    if ($CopyFile) {
        New-Item -Path $CopyPath -ItemType Directory -Force | Out-Null
    }

    $testParameters = @{
        Destination     = $destinationServer
        DataDirectory   = $DataDirectory
        LogDirectory    = $LogDirectory
        Prefix          = $Prefix
        Checksum        = $true
        MaxDop          = $MaxDop
        EnableException = $true
        Confirm         = $false
    }

    if ($CopyFile) {
        $testParameters.CopyFile = $true
        $testParameters.CopyPath = $CopyPath
    }

    if ($VerifyOnly) {
        $testParameters.VerifyOnly = $true
    }

    if ($RetainRestoredDatabase) {
        $testParameters.NoDrop = $true
    }

    if ($PSCmdlet.ShouldProcess(
            "Source=$SqlInstance; Database=$Database; Destination=$Destination",
            'Validate the latest backup chain with Test-DbaLastBackup')) {

        $testResults = @(
            $sourceDatabase |
                Test-DbaLastBackup @testParameters
        )
    }

    if ($WhatIfPreference) {
        $status = 'WHATIF'
    }
    elseif ($testResults.Count -eq 0) {
        throw 'Test-DbaLastBackup returned no result rows.'
    }
    else {
        $restoreFailures = @($testResults | Where-Object { $_.RestoreResult -ne 'Success' })
        $dbccFailures = @()

if (-not $VerifyOnly) {
    $dbccFailures = @(
        $testResults |
            Where-Object { $_.DbccResult -ne 'Success' }
    )
}
        $missingFiles = @($testResults | Where-Object { $_.FileExists -eq $false })

        if ($restoreFailures.Count -gt 0 -or $dbccFailures.Count -gt 0 -or $missingFiles.Count -gt 0) {
            $problems = [System.Collections.Generic.List[string]]::new()

            foreach ($row in $restoreFailures) {
                $problems.Add("$($row.Database): RestoreResult=$($row.RestoreResult)") | Out-Null
            }
            foreach ($row in $dbccFailures) {
                $problems.Add("$($row.Database): DbccResult=$($row.DbccResult)") | Out-Null
            }
            foreach ($row in $missingFiles) {
                $problems.Add("$($row.Database): one or more backup files were not found") | Out-Null
            }

            throw ($problems -join '; ')
        }

        $status = 'SUCCEEDED'
    }
}
catch {
    $status = 'FAILED'
    $failureMessage = $_.Exception.Message
}

$completedAtUtc = [datetime]::UtcNow
$durationSeconds = [math]::Round(($completedAtUtc - $startedAtUtc).TotalSeconds, 2)
$summary = [pscustomobject][ordered]@{
    StartedAtUtc           = $startedAtUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    CompletedAtUtc         = $completedAtUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    DurationSeconds        = $durationSeconds
    Status                 = $status
    SourceInstance         = $SqlInstance
    SourceDatabase         = $Database
    DestinationInstance    = $Destination
    TestDatabasePrefix     = $Prefix
    VerifyOnly             = [bool]$VerifyOnly
    CopyFile               = [bool]$CopyFile
    CopyPath               = if ($CopyFile) { $CopyPath } else { $null }
    RetainRestoredDatabase = [bool]$RetainRestoredDatabase
    ResultRows             = $testResults.Count
    ErrorMessage           = $failureMessage
}

$reportPaths = Write-RestoreReport -Summary $summary -Detail $testResults `
    -ReportDirectory $OutputDirectory -Timestamp $timestamp

$summary | Format-List | Out-Host
$reportPaths | Format-List | Out-Host

if ($status -eq 'FAILED') {
    Write-Error "Restore validation failed: $failureMessage" -ErrorAction Continue
    exit 1
}

exit 0
