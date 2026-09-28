[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RootPath = 'C:\SQLLab\SQLLAB1\Backup',

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$RetentionDays = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    throw "Backup root does not exist: $RootPath"
}

$cutoffUtc = [DateTime]::UtcNow.AddDays(-$RetentionDays)
$candidateFiles = Get-ChildItem -LiteralPath $RootPath -File -Recurse |
    Where-Object {
        $_.Extension -in @('.bak', '.trn') -and
        $_.LastWriteTimeUtc -lt $cutoffUtc
    } |
    Sort-Object LastWriteTimeUtc, FullName

$results = foreach ($file in $candidateFiles) {
    $backupType = switch -Regex ($file.FullName) {
        '[\\/]Full[\\/]' { 'FULL'; break }
        '[\\/]Diff[\\/]' { 'DIFF'; break }
        '[\\/]Log[\\/]'  { 'LOG'; break }
        default            { 'SQL'; break }
    }

    $deleted = $false
    if ($PSCmdlet.ShouldProcess($file.FullName, "Delete expired $backupType backup")) {
        Remove-Item -LiteralPath $file.FullName -Force
        $deleted = $true
    }

    [pscustomobject]@{
        BackupType      = $backupType
        File            = $file.FullName
        LastWriteUtc    = $file.LastWriteTimeUtc
        CutoffUtc       = $cutoffUtc
        Deleted         = $deleted
    }
}

$results
