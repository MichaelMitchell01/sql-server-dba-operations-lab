#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateSet('SQLLAB1', 'SQLLAB2')]
    [string]$InstanceName = 'SQLLAB1',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CollectorName = 'SQLLAB1 Baseline',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = 'C:\SQLLab\PerfMon',

    [Parameter()]
    [ValidatePattern('^\d{2}:\d{2}:\d{2}$')]
    [string]$SampleInterval = '00:00:05',

    [Parameter()]
    [ValidatePattern('^\d{2}:\d{2}:\d{2}$')]
    [string]$RunDuration = '00:02:00',

    [Parameter()]
    [ValidateRange(10, 2048)]
    [int]$MaximumSizeMb = 250,

    [Parameter()]
    [switch]$Replace,

    [Parameter()]
    [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$sqlObjectPrefix = 'MSSQL${0}' -f $InstanceName
$counters = @(
    '\Processor(_Total)\% Processor Time',
    '\Memory\Available MBytes',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    ('\{0}:SQL Statistics\Batch Requests/sec' -f $sqlObjectPrefix),
    ('\{0}:Buffer Manager\Page life expectancy' -f $sqlObjectPrefix),
    ('\{0}:Buffer Manager\Buffer cache hit ratio' -f $sqlObjectPrefix),
    ('\{0}:General Statistics\User Connections' -f $sqlObjectPrefix),
    ('\{0}:Databases(_Total)\Log Bytes Flushed/sec' -f $sqlObjectPrefix),
    ('\{0}:Databases(_Total)\Transactions/sec' -f $sqlObjectPrefix)
)

$logman = Join-Path $env:SystemRoot 'System32\logman.exe'
$queryOutput = & $logman query $CollectorName 2>&1
$collectorExists = $LASTEXITCODE -eq 0

if ($collectorExists -and -not $Replace) {
    throw "Data Collector Set '$CollectorName' already exists. Use -Replace to recreate it."
}

if ($collectorExists -and $Replace) {
    if ($PSCmdlet.ShouldProcess($CollectorName, 'Stop and delete existing Data Collector Set')) {
        & $logman stop $CollectorName 2>$null | Out-Null
        & $logman delete $CollectorName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete existing collector '$CollectorName'."
        }
    }
}

$counterFile = New-TemporaryFile
try {
    Set-Content -LiteralPath $counterFile.FullName -Value $counters -Encoding Unicode
    $outputPath = Join-Path $OutputDirectory ($CollectorName -replace '[^A-Za-z0-9_.-]', '_')

    if ($PSCmdlet.ShouldProcess($CollectorName, 'Create Performance Monitor Data Collector Set')) {
        $logmanArguments = @(
            'create', 'counter', $CollectorName,
            '-cf', $counterFile.FullName,
            '-si', $SampleInterval,
            '-f', 'bincirc',
            '-max', $MaximumSizeMb,
            '-rf', $RunDuration,
            '-o', $outputPath
        )
        & $logman @logmanArguments | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "logman failed to create '$CollectorName'. Verify that the counter object names exist on this Windows installation."
        }
    }
}
finally {
    Remove-Item -LiteralPath $counterFile.FullName -Force -ErrorAction SilentlyContinue
}

if ($Start -and $PSCmdlet.ShouldProcess($CollectorName, 'Start Data Collector Set')) {
    & $logman start $CollectorName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "logman could not start '$CollectorName'."
    }
}

& $logman query $CollectorName
