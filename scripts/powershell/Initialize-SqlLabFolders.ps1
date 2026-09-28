#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RootPath = 'C:\SQLLab',

    [Parameter()]
    [switch]$ApplyPermissions,

    [Parameter()]
    [switch]$CreateLogShippingShare,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ShareName = 'SQLLabLS$'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$relativeDirectories = @(
    'SQLLAB1\Data',
    'SQLLAB1\Log',
    'SQLLAB1\Backup\Full',
    'SQLLAB1\Backup\Diff',
    'SQLLAB1\Backup\Log',
    'SQLLAB1\XE',
    'SQLLAB1\Audit',
    'SQLLAB2\Data',
    'SQLLAB2\Log',
    'SQLLAB2\Backup\Full',
    'SQLLAB2\Backup\Diff',
    'SQLLAB2\Backup\Log',
    'SQLLAB2\XE',
    'SQLLAB2\Audit',
    'LogShipping\Backup',
    'LogShipping\Copy',
    'LogShipping\ReverseBackup',
    'LogShipping\ReverseCopy',
    'PerfMon',
    'Scripts'
)

$createdDirectories = foreach ($relativePath in $relativeDirectories) {
    $path = Join-Path -Path $RootPath -ChildPath $relativePath

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($path, 'Create SQL lab directory')) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $path -PathType Container) {
        Get-Item -LiteralPath $path
    }
}

if ($ApplyPermissions) {
    $instanceAccounts = @{
        SQLLAB1 = @('NT SERVICE\MSSQL$SQLLAB1', 'NT SERVICE\SQLAgent$SQLLAB1')
        SQLLAB2 = @('NT SERVICE\MSSQL$SQLLAB2', 'NT SERVICE\SQLAgent$SQLLAB2')
    }

    foreach ($instanceName in $instanceAccounts.Keys) {
        $instancePath = Join-Path -Path $RootPath -ChildPath $instanceName
        $acl = Get-Acl -LiteralPath $instancePath

        foreach ($account in $instanceAccounts[$instanceName]) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $account,
                [System.Security.AccessControl.FileSystemRights]::Modify,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.SetAccessRule($rule)
        }

        if ($PSCmdlet.ShouldProcess($instancePath, 'Grant instance service accounts Modify permission')) {
            Set-Acl -LiteralPath $instancePath -AclObject $acl
        }
    }

    $logShippingPath = Join-Path -Path $RootPath -ChildPath 'LogShipping'
    $logShippingAcl = Get-Acl -LiteralPath $logShippingPath
    $allServiceAccounts = $instanceAccounts.Values | ForEach-Object { $_ } | Sort-Object -Unique

    foreach ($account in $allServiceAccounts) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $account,
            [System.Security.AccessControl.FileSystemRights]::Modify,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $logShippingAcl.SetAccessRule($rule)
    }

    if ($PSCmdlet.ShouldProcess($logShippingPath, 'Grant log-shipping service-account permissions')) {
        Set-Acl -LiteralPath $logShippingPath -AclObject $logShippingAcl
    }
}

if ($CreateLogShippingShare) {
    $sharePath = Join-Path -Path $RootPath -ChildPath 'LogShipping\Backup'
    $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue

    if ($null -ne $existingShare) {
        if ($existingShare.Path -ne $sharePath) {
            throw "Share $ShareName already exists at '$($existingShare.Path)', not '$sharePath'."
        }
    }
    elseif ($PSCmdlet.ShouldProcess("$ShareName -> $sharePath", 'Create hidden SMB share')) {
        $shareParameters = @{
            Name         = $ShareName
            Path         = $sharePath
            FullAccess   = 'BUILTIN\Administrators'
            ChangeAccess = @(
                'NT SERVICE\MSSQL$SQLLAB1',
                'NT SERVICE\SQLAgent$SQLLAB1',
                'NT SERVICE\MSSQL$SQLLAB2',
                'NT SERVICE\SQLAgent$SQLLAB2'
            )
        }
        New-SmbShare @shareParameters | Out-Null
    }
}

$createdDirectories |
    Select-Object FullName, CreationTimeUtc, LastWriteTimeUtc |
    Sort-Object FullName
