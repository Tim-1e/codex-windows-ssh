[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex-Windows-SSH'))

# Run after verifying the selected build opens successfully. This is explicit
# maintenance, not part of update publication: a build check alone cannot prove
# that a new desktop actually starts, so it must not delete the fallback.
function Test-RemovableCodexRuntime {
    param([string]$Root, [string]$Path, [string]$CurrentId, [object[]]$Processes)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -ne $rootFull) { return $false }
    $id = [IO.Path]::GetFileName($full)
    if ($id -eq $CurrentId -or $id -notmatch '^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$') { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $full 'installed.json') -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $full 'app\ChatGPT.exe') -PathType Leaf)) { return $false }
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

$currentId = (Get-Content -LiteralPath (Join-Path $installRoot 'current.version') -Raw).Trim()
if ($currentId -notmatch '^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$') { throw 'Invalid selected runtime ID; nothing was removed.' }
$selected = Join-Path $installRoot $currentId
$validation = Get-Content -LiteralPath (Join-Path $selected 'installed.json') -Raw | ConvertFrom-Json
if ($validation.validation.status -ne 'passed' -or -not (Test-Path -LiteralPath (Join-Path $selected 'app\ChatGPT.exe'))) {
    throw 'The selected runtime is not validated; nothing was removed.'
}
$removed = @()
foreach ($directory in Get-ChildItem -LiteralPath $installRoot -Directory) {
    # Re-read immediately before each deletion; never remove a running or newly
    # selected runtime, and never walk a junction out of this install root.
    $latestId = (Get-Content -LiteralPath (Join-Path $installRoot 'current.version') -Raw).Trim()
    if ($latestId -ne $currentId) { throw 'Selection changed during cleanup; stopped.' }
    $processes = @(Get-CimInstance Win32_Process)
    if (-not (Test-RemovableCodexRuntime -Root $installRoot -Path $directory.FullName -CurrentId $currentId -Processes $processes)) { continue }
    if ($PSCmdlet.ShouldProcess($directory.FullName, 'Permanently remove unused Codex runtime (no account data)')) {
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        $removed += $directory.FullName
    }
}
[pscustomobject]@{ retained=$selected; removed=$removed; userDataUntouched=$true; officialPackageUntouched=$true } | ConvertTo-Json
