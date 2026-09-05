[CmdletBinding()]
param(
    [switch]$Interactive,
    [switch]$Status,
    [switch]$Menu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = if ($Interactive) { 'Continue' } else { 'SilentlyContinue' }
$script:ValidationSchemaVersion = 4

$installer = Join-Path $PSScriptRoot 'Install-Codex-Windows-SSH.ps1'
$queryScript = Join-Path $PSScriptRoot 'Get-CodexPackage.ps1'
$installRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'OpenAI') 'Codex-Windows-SSH'
$logPath = Join-Path $installRoot 'last-update.json'

$modeCount = @(@($Interactive, $Status, $Menu) | Where-Object { $_.IsPresent }).Count
if ($modeCount -gt 1) {
    throw 'Interactive, Status, and Menu modes cannot be combined.'
}

function Show-MenuMessage {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Detail,
        [switch]$ErrorIcon
    )

    Add-Type -AssemblyName System.Windows.Forms
    $text = if ([string]::IsNullOrWhiteSpace($Detail)) {
        $Message
    } else {
        $Message + [Environment]::NewLine + [Environment]::NewLine + $Detail
    }
    $icon = if ($ErrorIcon) {
        [Windows.Forms.MessageBoxIcon]::Error
    } else {
        [Windows.Forms.MessageBoxIcon]::Information
    }
    [void][Windows.Forms.MessageBox]::Show(
        $text,
        'Codex Windows SSH',
        [Windows.Forms.MessageBoxButtons]::OK,
        $icon
    )
}

function Get-OfficialPackage {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $queryScript
    )
    $output = @(& $windowsPowerShell @arguments)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Codex package query failed with exit code $exitCode"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Test-ValidationStamp {
    param(
        [Parameter(Mandatory)][string]$MetadataPath,
        [Parameter(Mandatory)][pscustomobject]$Package
    )

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) { return $false }
    try {
        $metadata = Get-Content -Raw -LiteralPath $MetadataPath | ConvertFrom-Json
        $validationProperty = $metadata.PSObject.Properties['validation']
        if (-not $validationProperty) { return $false }
        $validation = $validationProperty.Value
        return (
            $metadata.packageVersion -eq $Package.version -and
            $metadata.packageFullName -eq $Package.packageFullName -and
            $validation.schemaVersion -eq $script:ValidationSchemaVersion -and
            $validation.status -eq 'passed'
        )
    } catch {
        return $false
    }
}

function Get-UpdateState {
    $package = Get-OfficialPackage
    $currentVersionPath = Join-Path $installRoot 'current.version'
    $currentRuntimeId = if (Test-Path -LiteralPath $currentVersionPath -PathType Leaf) {
        (Get-Content -Raw -LiteralPath $currentVersionPath).Trim()
    } else {
        $null
    }
    $versionRoot = if ([string]::IsNullOrWhiteSpace($currentRuntimeId)) {
        $null
    } else {
        Join-Path $installRoot $currentRuntimeId
    }
    $runtimeRoot = if ($versionRoot) { Join-Path $versionRoot 'app' } else { $null }
    $metadataPath = if ($versionRoot) { Join-Path $versionRoot 'installed.json' } else { $null }
    $metadata = if ($metadataPath -and (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        try { Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json } catch { $null }
    } else {
        $null
    }
    $metadataPackageVersion = if ($metadata -and $metadata.PSObject.Properties['packageVersion']) {
        $metadata.packageVersion
    } else {
        $null
    }
    $runtimeComplete = [bool](
        $runtimeRoot -and
        (Test-Path -LiteralPath (Join-Path $runtimeRoot 'ChatGPT.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $runtimeRoot 'resources\app.asar') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $runtimeRoot 'resources\codex.exe') -PathType Leaf)
    )
    $validated = [bool](
        $runtimeComplete -and
        (Test-ValidationStamp -MetadataPath $metadataPath -Package $package)
    )

    $reason = if ([string]::IsNullOrWhiteSpace($currentRuntimeId)) {
        'not-installed'
    } elseif (-not $runtimeComplete) {
        'runtime-incomplete'
    } elseif ($metadataPackageVersion -ne $package.version) {
        'official-package-changed'
    } elseif (-not $validated) {
        'validation-required'
    } else {
        'already-current'
    }

    return [pscustomobject]@{
        checkedAtUtc = [DateTime]::UtcNow.ToString('O')
        officialPackageVersion = $package.version
        officialPackageFullName = $package.packageFullName
        officialPackageSource = 'Microsoft Store registration'
        selectedPatchedVersion = $metadataPackageVersion
        selectedRuntimeId = $currentRuntimeId
        runtime = $runtimeRoot
        validated = $validated
        updateRequired = $reason -ne 'already-current'
        reason = $reason
    }
}

function Write-UpdateRecord {
    param([Parameter(Mandatory)][object]$Record)

    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    $temporary = Join-Path $installRoot ('.last-update-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Record | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::Move($temporary, $logPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-VisibleUpdate {
    $pwsh = Get-Command pwsh.exe -ErrorAction Stop
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh.Source
    $startInfo.UseShellExecute = $true
    $startInfo.WorkingDirectory = $PSScriptRoot
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-Interactive')) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $process) { throw 'Could not start the visible Codex updater.' }
    $process.WaitForExit()
    return $process.ExitCode
}

if ($Menu) {
    $menuExitCode = 1
    try {
        $state = Get-UpdateState
        if (-not $state.updateRequired) {
            Write-UpdateRecord -Record ([ordered]@{
                checkedAtUtc = [DateTime]::UtcNow.ToString('O')
                succeeded = $true
                result = $state
                source = 'app-menu'
            })
            Show-MenuMessage -Message 'Codex Windows SSH is current and validated.' -Detail (
                "Official package: $($state.officialPackageVersion)" + [Environment]::NewLine +
                "Patched runtime: $($state.selectedPatchedVersion)"
            )
            exit 0
        }

        $menuExitCode = Invoke-VisibleUpdate
        if ($menuExitCode -eq 0) {
            $updatedState = Get-UpdateState
            Show-MenuMessage -Message 'Update and validation completed.' -Detail (
                "Selected runtime: $($updatedState.selectedPatchedVersion)" + [Environment]::NewLine +
                'Restart Codex if the selected runtime changed.'
            )
        } else {
            Show-MenuMessage -Message 'Update or validation failed.' -Detail "Details: $logPath" -ErrorIcon
        }
    } catch {
        $menuExitCode = 1
        Write-UpdateRecord -Record ([ordered]@{
            checkedAtUtc = [DateTime]::UtcNow.ToString('O')
            succeeded = $false
            error = $_.Exception.Message
            source = 'app-menu'
        })
        Show-MenuMessage -Message 'The update check failed.' -Detail (
            $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine +
            "Details: $logPath"
        ) -ErrorIcon
    }
    exit $menuExitCode
}

if ($Status) {
    Get-UpdateState | ConvertTo-Json -Depth 5
    return
}

if (-not $Interactive) {
    try {
        $state = Get-UpdateState
        if (-not $state.updateRequired) {
            Write-UpdateRecord -Record ([ordered]@{
                checkedAtUtc = [DateTime]::UtcNow.ToString('O')
                succeeded = $true
                result = $state
            })
            exit 0
        }
        exit (Invoke-VisibleUpdate)
    } catch {
        Write-UpdateRecord -Record ([ordered]@{
            checkedAtUtc = [DateTime]::UtcNow.ToString('O')
            succeeded = $false
            error = $_.Exception.Message
        })
        exit 1
    }
}

$mutex = [Threading.Mutex]::new($false, 'Local\CodexWindowsSSHUpdater')
$acquired = $false
$exitCode = 0
try {
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(15))
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) { throw 'Timed out waiting for another Codex update to finish.' }

    $state = Get-UpdateState
    if (-not $state.updateRequired) {
        Write-UpdateRecord -Record ([ordered]@{
            checkedAtUtc = [DateTime]::UtcNow.ToString('O')
            succeeded = $true
            result = $state
        })
        Write-Host "Codex Windows SSH is current and validated: $($state.selectedPatchedVersion)"
    } else {
        try { $Host.UI.RawUI.WindowTitle = 'Codex update and validation' } catch { }
        Write-Host "Official package: $($state.officialPackageVersion)"
        Write-Host "Patched runtime:  $($state.selectedPatchedVersion)"
        Write-Host "Action:           $($state.reason)"
        Write-Host ''

        $output = @(& $installer -NoShortcut -CheckForUpdate -ShowProgress)
        $result = (($output -join [Environment]::NewLine) | ConvertFrom-Json)
        Write-UpdateRecord -Record ([ordered]@{
            checkedAtUtc = [DateTime]::UtcNow.ToString('O')
            succeeded = $true
            stateBefore = $state
            result = $result
        })
        Write-Host "Updated and validated: $($result.version) ($($result.validation.bundledCliVersion))"
    }
} catch {
    $exitCode = 1
    Write-UpdateRecord -Record ([ordered]@{
        checkedAtUtc = [DateTime]::UtcNow.ToString('O')
        succeeded = $false
        error = $_.Exception.Message
    })
    Write-Error $_
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

exit $exitCode
