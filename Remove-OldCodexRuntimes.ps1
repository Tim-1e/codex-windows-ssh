[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex-Windows-SSH'))

# Both updater and explicit maintenance may call this after an isolated desktop
# page-load check. Live references and locked files are retained for next launch.
function Test-RemovableCodexRuntime {
    param([string]$Root, [string]$Path, [string]$CurrentId, [object[]]$Processes)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -ne $rootFull) { return $false }
    $id = [IO.Path]::GetFileName($full)
    if ($id -eq $CurrentId -or $id -notmatch '^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$') { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $full 'installed.json') -PathType Leaf)) { return $false }
    try {
        $metadata = Get-Content -LiteralPath (Join-Path $full 'installed.json') -Raw | ConvertFrom-Json
        if ($metadata.packageVersion -ne ($id -replace '-r\d+$', '') -or -not $metadata.automaticWindowsDetection) { return $false }
    } catch { return $false }
    foreach ($process in $Processes) {
        if (($process.ExecutablePath -and $process.ExecutablePath.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) -or
            ($process.CommandLine -and $process.CommandLine.IndexOf($full + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0)) { return $false }
    }
    $items = @(Get-Item -LiteralPath $rootFull, $full) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { return $false }
    return $true
}

function Remove-UnlockedCodexRuntime {
    param([string]$Root, [string]$Path, [string]$CurrentId, [object[]]$Processes)
    if (-not (Test-RemovableCodexRuntime $Root $Path $CurrentId $Processes)) {
        throw 'Refusing to clean a selected, active, unowned or unsafe runtime.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $metadataPath = Join-Path $full 'installed.json'
    $firstError = $null
    # Keep the ownership stamp until the final directory can be removed. A
    # locked hardlink must not prevent unrelated files from being reclaimed.
    foreach ($file in Get-ChildItem -LiteralPath $full -File -Recurse -Force) {
        if ($file.FullName -eq $metadataPath) { continue }
        try { Remove-Item -LiteralPath $file.FullName -Force }
        catch { if (-not $firstError) { $firstError = $_.Exception.Message } }
    }
    foreach ($directory in Get-ChildItem -LiteralPath $full -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending) {
        try {
            if (-not @(Get-ChildItem -LiteralPath $directory.FullName -Force).Count) {
                [IO.Directory]::Delete($directory.FullName, $false)
            }
        } catch { if (-not $firstError) { $firstError = $_.Exception.Message } }
    }
    $remaining = @(Get-ChildItem -LiteralPath $full -Force | Where-Object { $_.FullName -ne $metadataPath })
    if (-not $remaining.Count) {
        $metadataBytes = [IO.File]::ReadAllBytes($metadataPath)
        try {
            Remove-Item -LiteralPath $metadataPath -Force
            [IO.Directory]::Delete($full, $false)
            return [pscustomobject]@{ path=$full; removed=$true; remainingFiles=0; remainingBytes=0 }
        } catch {
            if (-not $firstError) { $firstError = $_.Exception.Message }
            # A directory handle can block only this final step. Restore our
            # exact ownership record so the next maintenance run can retry.
            if ((Test-Path -LiteralPath $full -PathType Container) -and -not (Test-Path -LiteralPath $metadataPath)) {
                [IO.File]::WriteAllBytes($metadataPath, $metadataBytes)
            }
        }
    }
    $files = @(Get-ChildItem -LiteralPath $full -File -Recurse -Force)
    [pscustomobject]@{
        path=$full; removed=$false; remainingFiles=$files.Count
        remainingBytes=($files | Measure-Object Length -Sum).Sum
        reason=if ($firstError) { $firstError } else { 'Files or directories are still in use; retry later.' }
    }
}

$currentId = (Get-Content -LiteralPath (Join-Path $installRoot 'current.version') -Raw).Trim()
if ($currentId -notmatch '^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$') { throw 'Invalid selected runtime ID; nothing was removed.' }
$selected = Join-Path $installRoot $currentId
$validation = Get-Content -LiteralPath (Join-Path $selected 'installed.json') -Raw | ConvertFrom-Json
if ($validation.validation.status -ne 'passed' -or -not (Test-Path -LiteralPath (Join-Path $selected 'app\ChatGPT.exe'))) {
    throw 'The selected runtime is not validated; nothing was removed.'
}
if (-not $validation.validation.PSObject.Properties['desktopStartup'] -or $validation.validation.desktopStartup.status -ne 'passed') {
    throw 'The selected desktop has no successful startup validation; nothing was removed.'
}
$removed = @()
$deferred = @()
foreach ($directory in Get-ChildItem -LiteralPath $installRoot -Directory) {
    # Re-read immediately before each deletion; never remove a running or newly
    # selected runtime, and never walk a junction out of this install root.
    $latestId = (Get-Content -LiteralPath (Join-Path $installRoot 'current.version') -Raw).Trim()
    if ($latestId -ne $currentId) { throw 'Selection changed during cleanup; stopped.' }
    $processes = @(Get-CimInstance Win32_Process)
    if (-not (Test-RemovableCodexRuntime -Root $installRoot -Path $directory.FullName -CurrentId $currentId -Processes $processes)) { continue }
    if ($PSCmdlet.ShouldProcess($directory.FullName, 'Permanently remove unused Codex runtime (no account data)')) {
        try {
            $result = Remove-UnlockedCodexRuntime $installRoot $directory.FullName $currentId $processes
            if ($result.removed) { $removed += $directory.FullName }
            else { $deferred += $result }
        } catch {
            # A DLL/PAK hardlinked with a live runtime may be locked even when
            # no process names this old directory. Retry before a later launch.
            $deferred += [pscustomobject]@{ path=$directory.FullName; reason=$_.Exception.Message }
        }
    }
}
[pscustomobject]@{ retained=$selected; removed=$removed; deferred=$deferred; userDataUntouched=$true; officialPackageUntouched=$true } | ConvertTo-Json -Depth 4
