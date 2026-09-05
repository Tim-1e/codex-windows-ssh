[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'OpenAI') 'Codex-Windows-SSH'
$expectedRoot = [IO.Path]::GetFullPath($installRoot).TrimEnd('\')

function Test-OwnedShortcut {
    param([Parameter(Mandatory)]$Shortcut)

    if ($Shortcut.Arguments.IndexOf($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($Shortcut.TargetPath)) { return $false }
    try {
        $target = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Shortcut.TargetPath))
        return $target.StartsWith($expectedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

$running = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and
    [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($expectedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
})
if ($running.Count -gt 0) {
    throw 'Exit the patched Codex runtime completely before uninstalling it.'
}

$shortcutShell = New-Object -ComObject WScript.Shell
foreach ($directory in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
    if ([string]::IsNullOrWhiteSpace($directory)) { continue }
    foreach ($name in @('Codex.lnk', 'ChatGPT.lnk', 'win_fix_codex.lnk', 'Codex_Fix.lnk')) {
        $shortcutPath = Join-Path $directory $name
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { continue }
        $shortcut = $shortcutShell.CreateShortcut($shortcutPath)
        if (Test-OwnedShortcut -Shortcut $shortcut) {
            Remove-Item -LiteralPath $shortcutPath -Force
        }
    }
}

$taskbarDirectory = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
if (Test-Path -LiteralPath $taskbarDirectory -PathType Container) {
    foreach ($shortcutPath in Get-ChildItem -LiteralPath $taskbarDirectory -Filter '*.lnk' -File) {
        $shortcut = $shortcutShell.CreateShortcut($shortcutPath.FullName)
        if (Test-OwnedShortcut -Shortcut $shortcut) {
            Remove-Item -LiteralPath $shortcutPath.FullName -Force
        }
    }
}

if (Test-Path -LiteralPath $expectedRoot) {
    $resolvedRoot = [IO.Path]::GetFullPath((Get-Item -LiteralPath $expectedRoot).FullName).TrimEnd('\')
    if (-not $resolvedRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected path: $resolvedRoot"
    }
    if (-not $resolvedRoot.EndsWith('\OpenAI\Codex-Windows-SSH', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing broad removal target: $resolvedRoot"
    }
    $reparsePoint = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($reparsePoint) {
        throw "Refusing recursive removal because the runtime contains a reparse point: $($reparsePoint.FullName)"
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}

[pscustomobject]@{
    uninstalled = $true
    officialPackageUntouched = $true
    userDataUntouched = $true
} | ConvertTo-Json
