[CmdletBinding()]
param(
    [switch]$NoShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($PSVersionTable.PSEdition -ne 'Core') {
    $pwsh = Get-Command pwsh.exe -ErrorAction Stop
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath)
    if ($NoShortcut) { $arguments += '-NoShortcut' }
    & $pwsh.Source @arguments
    exit $LASTEXITCODE
}

function Assert-ExactChildPath {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )

    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escaped the intended root: $childFull"
    }
    return $childFull
}

function Invoke-NodePatcher {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $node = Get-Command node.exe -ErrorAction Stop
    $output = @(& $node.Source @Arguments)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "ASAR patcher failed with exit code $exitCode"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function New-RebasedRuntime {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$SourceAsar,
        [Parameter(Mandatory)][string]$PatchedAsar,
        [string]$ReuseRoot
    )

    $sourceFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $targetFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $reuseFull = if ([string]::IsNullOrWhiteSpace($ReuseRoot)) {
        $null
    } else {
        [IO.Path]::GetFullPath($ReuseRoot).TrimEnd('\')
    }
    $canHardlinkFromReuse = $reuseFull -and
        [IO.Path]::GetPathRoot($reuseFull).Equals(
            [IO.Path]::GetPathRoot($targetFull),
            [StringComparison]::OrdinalIgnoreCase
        )

    $reparsePoint = Get-ChildItem -LiteralPath $sourceFull -Recurse -Force |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($reparsePoint) {
        throw "The official runtime contains an unsupported reparse point: $($reparsePoint.FullName)"
    }

    New-Item -ItemType Directory -Path $targetFull | Out-Null
    foreach ($directory in Get-ChildItem -LiteralPath $sourceFull -Directory -Recurse -Force) {
        $relative = $directory.FullName.Substring($sourceFull.Length).TrimStart('\')
        New-Item -ItemType Directory -Path (Join-Path $targetFull $relative) | Out-Null
    }
    $hardlinkedFiles = 0
    $hardlinkFallbackFiles = 0
    $copiedFiles = 0
    [int64]$copiedBytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $sourceFull -File -Recurse -Force) {
        if ($file.FullName.Equals($SourceAsar, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $relative = $file.FullName.Substring($sourceFull.Length).TrimStart('\')
        $destination = Join-Path $targetFull $relative
        $reuseCandidate = if ($canHardlinkFromReuse) { Join-Path $reuseFull $relative } else { $null }
        $reuse = $false
        if ($reuseCandidate -and (Test-Path -LiteralPath $reuseCandidate -PathType Leaf)) {
            $candidate = Get-Item -LiteralPath $reuseCandidate
            if ($candidate.Length -eq $file.Length) {
                $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                $candidateHash = (Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash
                $reuse = $sourceHash -eq $candidateHash
            }
        }
        if ($reuse) {
            try {
                New-Item -ItemType HardLink -Path $destination -Target $reuseCandidate | Out-Null
                $hardlinkedFiles += 1
            }
            catch {
                if (Test-Path -LiteralPath $destination) {
                    Remove-Item -LiteralPath $destination -Force
                }
                Copy-Item -LiteralPath $file.FullName -Destination $destination
                $hardlinkFallbackFiles += 1
                $copiedFiles += 1
                $copiedBytes += $file.Length
            }
        } else {
            Copy-Item -LiteralPath $file.FullName -Destination $destination
            $copiedFiles += 1
            $copiedBytes += $file.Length
        }
    }
    Move-Item -LiteralPath $PatchedAsar -Destination (Join-Path $targetFull 'resources\app.asar')
    $copiedFiles += 1
    $copiedBytes += (Get-Item -LiteralPath (Join-Path $targetFull 'resources\app.asar')).Length
    return [pscustomobject]@{
        reuseRoot = $reuseFull
        hardlinkedFiles = $hardlinkedFiles
        hardlinkFallbackFiles = $hardlinkFallbackFiles
        copiedFiles = $copiedFiles
        copiedBytes = $copiedBytes
    }
}

$queryScript = Join-Path $PSScriptRoot 'Get-CodexPackage.ps1'
$patcher = Join-Path $PSScriptRoot 'patch-codex-asar.mjs'
$launcherTemplate = Join-Path $PSScriptRoot 'Start-Codex.vbs'
foreach ($required in @($queryScript, $patcher, $launcherTemplate, (Join-Path $PSScriptRoot 'codex-windows-controller.ps1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required repository file is missing: $required"
    }
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$queryArguments = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $queryScript
)
$packageJson = @(& $windowsPowerShell @queryArguments)
$queryExitCode = $LASTEXITCODE
if ($queryExitCode -ne 0) {
    throw "Codex package query failed with exit code $queryExitCode"
}
$package = ($packageJson -join [Environment]::NewLine) | ConvertFrom-Json

$sourceApp = Join-Path $package.installLocation 'app'
$sourceExe = Join-Path $sourceApp 'ChatGPT.exe'
$sourceAsar = Join-Path $sourceApp 'resources\app.asar'
foreach ($required in @($sourceExe, $sourceAsar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "The installed Codex package is incomplete: $required"
    }
}
$signature = Get-AuthenticodeSignature -LiteralPath $sourceExe
if ($signature.Status -ne 'Valid') {
    throw "The official Codex executable signature is not valid: $($signature.Status)"
}

$installRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'OpenAI') 'Codex-Windows-SSH'
$versionRoot = Join-Path $installRoot $package.version
$runtimeRoot = Join-Path $versionRoot 'app'
$runtimeAsar = Join-Path $runtimeRoot 'resources\app.asar'
$runtimeExe = Join-Path $runtimeRoot 'ChatGPT.exe'
$installedLauncher = Join-Path $versionRoot 'Start-Codex.vbs'
$metadataPath = Join-Path $versionRoot 'installed.json'

$freshInstall = -not (Test-Path -LiteralPath $runtimeRoot)
$runtimeStats = [pscustomobject]@{
    reuseRoot = $null
    hardlinkedFiles = $null
    hardlinkFallbackFiles = $null
    copiedFiles = $null
    copiedBytes = $null
}
$patchResult = $null
if ($freshInstall) {
    New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
    $buildId = [guid]::NewGuid().ToString('N')
    $patchedAsar = Join-Path $versionRoot "app.asar.patched-$buildId"
    $stagingRoot = Join-Path $versionRoot "app.staging-$buildId"
    Assert-ExactChildPath -Parent $versionRoot -Child $patchedAsar | Out-Null
    Assert-ExactChildPath -Parent $versionRoot -Child $stagingRoot | Out-Null
    try {
        $patchResult = Invoke-NodePatcher -Arguments @($patcher, $sourceAsar, $patchedAsar)
        Invoke-NodePatcher -Arguments @($patcher, '--verify', $patchedAsar) | Out-Null
        $reuseRoot = Get-ChildItem -LiteralPath $installRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'app' } |
            Where-Object {
                -not $_.Equals($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath (Join-Path $_ 'ChatGPT.exe') -PathType Leaf)
            } |
            Select-Object -First 1
        $runtimeStats = New-RebasedRuntime -SourceRoot $sourceApp -TargetRoot $stagingRoot -SourceAsar $sourceAsar -PatchedAsar $patchedAsar -ReuseRoot $reuseRoot
        if (Test-Path -LiteralPath $runtimeRoot) {
            throw "Runtime destination appeared during installation: $runtimeRoot"
        }
        Move-Item -LiteralPath $stagingRoot -Destination $runtimeRoot
    }
    catch {
        $installationError = $_
        foreach ($candidate in @($patchedAsar, $stagingRoot)) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            try {
                $resolved = [IO.Path]::GetFullPath((Get-Item -LiteralPath $candidate).FullName)
                Assert-ExactChildPath -Parent $versionRoot -Child $resolved | Out-Null
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
            catch {
                Write-Warning "Could not remove failed staging path '$candidate'. Exit Codex before removing it. $($_.Exception.Message)"
            }
        }
        throw $installationError
    }
} else {
    if (-not (Test-Path -LiteralPath $runtimeExe -PathType Leaf) -or -not (Test-Path -LiteralPath $runtimeAsar -PathType Leaf)) {
        throw "A partial runtime already exists: $runtimeRoot"
    }
    Invoke-NodePatcher -Arguments @($patcher, '--verify', $runtimeAsar) | Out-Null
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        $existingMetadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
        foreach ($property in $runtimeStats.PSObject.Properties) {
            $existingProperty = $existingMetadata.PSObject.Properties[$property.Name]
            if ($existingProperty) {
                $property.Value = $existingProperty.Value
            }
        }
    }
}

Copy-Item -LiteralPath $launcherTemplate -Destination $installedLauncher -Force
$metadata = [ordered]@{
    packageVersion = $package.version
    packageFullName = $package.packageFullName
    sourceAsarSha256 = (Get-FileHash -LiteralPath $sourceAsar -Algorithm SHA256).Hash
    patchedAsarSha256 = (Get-FileHash -LiteralPath $runtimeAsar -Algorithm SHA256).Hash
    reuseRoot = $runtimeStats.reuseRoot
    hardlinkedFiles = $runtimeStats.hardlinkedFiles
    hardlinkFallbackFiles = $runtimeStats.hardlinkFallbackFiles
    copiedFiles = $runtimeStats.copiedFiles
    copiedBytes = $runtimeStats.copiedBytes
    automaticWindowsDetection = $true
    installedAtUtc = [DateTime]::UtcNow.ToString('O')
}
[IO.File]::WriteAllText(
    $metadataPath,
    ($metadata | ConvertTo-Json -Depth 3),
    [Text.UTF8Encoding]::new($false)
)

$shortcutPaths = @()
if (-not $NoShortcut) {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $icon = Join-Path $runtimeRoot 'resources\icon-chatgpt.ico'
    $shortcutShell = New-Object -ComObject WScript.Shell
    foreach ($directory in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        $shortcutPath = Join-Path $directory 'Codex.lnk'
        if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
            $existing = $shortcutShell.CreateShortcut($shortcutPath)
            $owned = $existing.TargetPath.Equals($wscript, [StringComparison]::OrdinalIgnoreCase) -and
                $existing.Arguments.IndexOf($installRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
            if (-not $owned) {
                throw "Refusing to overwrite an unrelated shortcut: $shortcutPath"
            }
        }
        $shortcut = $shortcutShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $wscript
        $shortcut.Arguments = '//nologo "' + $installedLauncher + '"'
        $shortcut.WorkingDirectory = $versionRoot
        $shortcut.IconLocation = $icon + ',0'
        $shortcut.Description = 'Codex'
        $shortcut.Save()
        $shortcutPaths += $shortcutPath
    }
}

[pscustomobject]@{
    installed = $true
    version = $package.version
    runtime = $runtimeRoot
    freshInstall = $freshInstall
    hardlinkedFiles = $runtimeStats.hardlinkedFiles
    hardlinkFallbackFiles = $runtimeStats.hardlinkFallbackFiles
    copiedFiles = $runtimeStats.copiedFiles
    copiedBytes = $runtimeStats.copiedBytes
    shortcuts = $shortcutPaths
    instruction = 'Exit every Codex/ChatGPT desktop process, then open Codex from the new shortcut.'
} | ConvertTo-Json -Depth 3
