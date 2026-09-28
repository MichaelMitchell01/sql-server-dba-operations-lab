[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RootPath = 'C:\SQLLab',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogShippingShare = '\\LABHOST\SQLLabLS$'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$paths = @(
    (Join-Path $RootPath 'SQLLAB1\Data'),
    (Join-Path $RootPath 'SQLLAB1\Log'),
    (Join-Path $RootPath 'SQLLAB1\Backup\Full'),
    (Join-Path $RootPath 'SQLLAB1\Backup\Diff'),
    (Join-Path $RootPath 'SQLLAB1\Backup\Log'),
    (Join-Path $RootPath 'SQLLAB1\XE'),
    (Join-Path $RootPath 'SQLLAB1\Audit'),
    (Join-Path $RootPath 'SQLLAB2\Data'),
    (Join-Path $RootPath 'SQLLAB2\Log'),
    (Join-Path $RootPath 'LogShipping\Backup'),
    (Join-Path $RootPath 'LogShipping\Copy'),
    $LogShippingShare
)

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

foreach ($path in $paths) {
    $accessible = $false
    $errorMessage = $null

    try {
        $accessible = Test-Path -LiteralPath $path -PathType Container -ErrorAction Stop
    }
    catch {
        $errorMessage = $_.Exception.Message
    }

    [pscustomobject]@{
        TestedAs     = $identity
        Path         = $path
        Accessible   = $accessible
        ErrorMessage = $errorMessage
    }
}

Write-Warning 'These results test the interactive Windows identity only. Validate SQL Server service access by running the actual backup, copy, or restore job.'

