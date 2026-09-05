[CmdletBinding()]
param(
    [switch]$NoShortcut,
    [switch]$EnableAutoUpdate,
    [switch]$DisableAutoUpdate,
    [switch]$CheckForUpdate,
    [switch]$ShowProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = if ($ShowProgress) { 'Continue' } else { 'SilentlyContinue' }
$script:ValidationSchemaVersion = 3

if ($EnableAutoUpdate -and $DisableAutoUpdate) {
    throw 'EnableAutoUpdate and DisableAutoUpdate cannot be used together.'
}

if ($PSVersionTable.PSEdition -ne 'Core') {
    $pwsh = Get-Command pwsh.exe -ErrorAction Stop
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath)
    if ($NoShortcut) { $arguments += '-NoShortcut' }
    if ($EnableAutoUpdate) { $arguments += '-EnableAutoUpdate' }
    if ($DisableAutoUpdate) { $arguments += '-DisableAutoUpdate' }
    if ($CheckForUpdate) { $arguments += '-CheckForUpdate' }
    if ($ShowProgress) { $arguments += '-ShowProgress' }
    & $pwsh.Source @arguments
    exit $LASTEXITCODE
}

function Write-InstallProgress {
    param(
        [Parameter(Mandatory)][ValidateRange(0, 100)][int]$Percent,
        [Parameter(Mandatory)][string]$Status
    )

    if ($ShowProgress) {
        Write-Progress -Id 1 -Activity 'Updating Codex Windows SSH' -Status $Status -PercentComplete $Percent
    }
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

function Test-OwnedLauncherShortcut {
    param(
        [Parameter(Mandatory)]$Shell,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LauncherHost,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $shortcut = $Shell.CreateShortcut($Path)
    if ([string]::IsNullOrWhiteSpace($shortcut.TargetPath)) { return $false }

    $target = [Environment]::ExpandEnvironmentVariables($shortcut.TargetPath)
    try { $target = [IO.Path]::GetFullPath($target) } catch { return $false }
    $rootPrefix = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    $hostOwned = $target.Equals($LauncherHost, [StringComparison]::OrdinalIgnoreCase) -and
        $shortcut.Arguments.IndexOf($InstallRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    $runtimeOwned = $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    return $hostOwned -or $runtimeOwned
}

function New-CodexLauncherShortcut {
    param(
        [Parameter(Mandatory)]$Shell,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Icon
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.codex-shortcut-' + [guid]::NewGuid().ToString('N') + '.lnk')
    try {
        $shortcut = $Shell.CreateShortcut($temporary)
        $shortcut.TargetPath = $Target
        $shortcut.Arguments = ''
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.IconLocation = $Icon + ',0'
        $shortcut.Description = 'Codex'
        $shortcut.Save()

        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Publish-CodexLauncherHost {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $compiler = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) {
        throw 'The Windows .NET Framework C# compiler is unavailable.'
    }

    $directory = [IO.Path]::GetDirectoryName($Destination)
    $temporary = Join-Path $directory ('.codex-launcher-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        $compilerOutput = @(& $compiler @(
            '/nologo',
            '/target:winexe',
            '/optimize+',
            '/reference:System.dll',
            '/reference:System.Windows.Forms.dll',
            "/out:$temporary",
            $Source
        ) 2>&1)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            throw "Codex launcher compilation failed: $($compilerOutput -join [Environment]::NewLine)"
        }
        [IO.File]::Move($temporary, $Destination, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Publish-ElectronAsarIntegrityTool {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $compiler = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) {
        throw 'The Windows .NET Framework C# compiler is unavailable.'
    }

    $directory = [IO.Path]::GetDirectoryName($Destination)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.electron-asar-integrity-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        $compilerOutput = @(& $compiler @(
            '/nologo',
            '/target:exe',
            '/optimize+',
            '/reference:System.dll',
            '/reference:System.Web.Extensions.dll',
            "/out:$temporary",
            $Source
        ) 2>&1)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            throw "Electron ASAR integrity tool compilation failed: $($compilerOutput -join [Environment]::NewLine)"
        }
        $selfTestOutput = @(& $temporary --self-test 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Electron ASAR integrity tool self-test failed: $($selfTestOutput -join [Environment]::NewLine)"
        }
        [IO.File]::Move($temporary, $Destination, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-ElectronAsarIntegrity {
    param(
        [Parameter(Mandatory)][ValidateSet('sync', 'verify')][string]$Mode,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Asar
    )

    $output = @(& $Tool $Mode $Executable $Asar 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Electron ASAR integrity $Mode failed with exit code $exitCode`: $($output -join [Environment]::NewLine)"
    }
    try {
        return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
    } catch {
        throw "Electron ASAR integrity $Mode returned invalid output: $($output -join [Environment]::NewLine)"
    }
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

function Test-PatchedRuntime {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$Patcher,
        [Parameter(Mandatory)][string]$IntegrityTool
    )

    $runtimeExe = Join-Path $RuntimeRoot 'ChatGPT.exe'
    $runtimeAsar = Join-Path $RuntimeRoot 'resources\app.asar'
    $runtimeCli = Join-Path $RuntimeRoot 'resources\codex.exe'
    foreach ($required in @($runtimeExe, $runtimeAsar, $runtimeCli)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Runtime validation failed; missing file: $required"
        }
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $runtimeExe
    if ($signature.Status -notin @('Valid', 'NotSigned')) {
        throw "Runtime validation failed; executable signature state is $($signature.Status)"
    }
    $archive = Invoke-NodePatcher -Arguments @($Patcher, '--verify', $runtimeAsar)
    $embeddedIntegrity = Invoke-ElectronAsarIntegrity -Mode verify -Tool $IntegrityTool -Executable $runtimeExe -Asar $runtimeAsar
    $cliOutput = @(& $runtimeCli --version 2>&1)
    $cliExitCode = $LASTEXITCODE
    if ($cliExitCode -ne 0) {
        throw "Runtime validation failed; bundled Codex CLI exited with code $cliExitCode"
    }

    return [pscustomobject]@{
        schemaVersion = $script:ValidationSchemaVersion
        status = 'passed'
        validatedAtUtc = [DateTime]::UtcNow.ToString('O')
        executableSignature = $signature.Status.ToString()
        asarHeaderSha256 = $embeddedIntegrity.headerSha256
        embeddedAsarIntegrityLanguages = @($embeddedIntegrity.languages)
        mainBundleSha256 = $archive.mainSha256
        bundledCliVersion = ($cliOutput -join [Environment]::NewLine).Trim()
    }
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

    Write-InstallProgress -Percent 42 -Status 'Scanning official runtime files'
    $sourceItems = @(Get-ChildItem -LiteralPath $sourceFull -Recurse -Force)
    $reparsePoint = $sourceItems |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($reparsePoint) {
        throw "The official runtime contains an unsupported reparse point: $($reparsePoint.FullName)"
    }

    New-Item -ItemType Directory -Path $targetFull | Out-Null
    foreach ($directory in $sourceItems | Where-Object { $_.PSIsContainer }) {
        $relative = $directory.FullName.Substring($sourceFull.Length).TrimStart('\')
        New-Item -ItemType Directory -Path (Join-Path $targetFull $relative) | Out-Null
    }
    $hardlinkedFiles = 0
    $hardlinkFallbackFiles = 0
    $copiedFiles = 0
    [int64]$copiedBytes = 0
    $files = @($sourceItems | Where-Object { -not $_.PSIsContainer })
    $processedFiles = 0
    foreach ($file in $files) {
        $processedFiles += 1
        if (($processedFiles % 20) -eq 0 -or $processedFiles -eq $files.Count) {
            $copyPercent = 45 + [Math]::Floor(38 * $processedFiles / [Math]::Max(1, $files.Count))
            Write-InstallProgress -Percent $copyPercent -Status "Building runtime ($processedFiles/$($files.Count) files)"
        }
        if ($file.FullName.Equals($SourceAsar, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $relative = $file.FullName.Substring($sourceFull.Length).TrimStart('\')
        $destination = Join-Path $targetFull $relative
        $reuseCandidate = if ($canHardlinkFromReuse) { Join-Path $reuseFull $relative } else { $null }
        $reuse = $false
        if (
            -not $relative.Equals('ChatGPT.exe', [StringComparison]::OrdinalIgnoreCase) -and
            $reuseCandidate -and
            (Test-Path -LiteralPath $reuseCandidate -PathType Leaf)
        ) {
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
$launcherHostSource = Join-Path $PSScriptRoot 'CodexLauncher.cs'
$integrityToolSource = Join-Path $PSScriptRoot 'ElectronAsarIntegrity.cs'
$backgroundUpdater = Join-Path $PSScriptRoot 'Update-Codex-Windows-SSH.ps1'
foreach ($required in @($queryScript, $patcher, $launcherTemplate, $launcherHostSource, $integrityToolSource, $backgroundUpdater, (Join-Path $PSScriptRoot 'codex-windows-controller.ps1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required repository file is missing: $required"
    }
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Write-InstallProgress -Percent 2 -Status 'Reading the registered official package'
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

$installRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'OpenAI') 'Codex-Windows-SSH'
$currentVersionPath = Join-Path $installRoot 'current.version'
if (
    $CheckForUpdate -and
    -not $EnableAutoUpdate -and
    -not $DisableAutoUpdate -and
    (Test-Path -LiteralPath $currentVersionPath -PathType Leaf)
) {
    $currentRuntimeId = (Get-Content -Raw -LiteralPath $currentVersionPath).Trim()
    $currentVersionRoot = Join-Path $installRoot $currentRuntimeId
    $currentRuntime = Join-Path $currentVersionRoot 'app'
    $currentMetadata = Join-Path $currentVersionRoot 'installed.json'
    if (
        -not [string]::IsNullOrWhiteSpace($currentRuntimeId) -and
        (Test-Path -LiteralPath (Join-Path $currentRuntime 'ChatGPT.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $currentRuntime 'resources\app.asar') -PathType Leaf) -and
        (Test-ValidationStamp -MetadataPath $currentMetadata -Package $package)
    ) {
        Write-InstallProgress -Percent 100 -Status 'Already current and validated'
        if ($ShowProgress) { Write-Progress -Id 1 -Activity 'Updating Codex Windows SSH' -Completed }
        [pscustomobject]@{
            installed = $true
            updated = $false
            validated = $true
            version = $package.version
            runtimeId = $currentRuntimeId
            officialPackageVersion = $package.version
            runtime = $currentRuntime
            reason = 'already-current'
        } | ConvertTo-Json
        return
    }
}

$sourceApp = Join-Path $package.installLocation 'app'
$sourceExe = Join-Path $sourceApp 'ChatGPT.exe'
$sourceAsar = Join-Path $sourceApp 'resources\app.asar'
foreach ($required in @($sourceExe, $sourceAsar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "The installed Codex package is incomplete: $required"
    }
}
Write-InstallProgress -Percent 8 -Status "Checking official signature ($($package.version))"
$signature = Get-AuthenticodeSignature -LiteralPath $sourceExe
if ($signature.Status -ne 'Valid') {
    throw "The official Codex executable signature is not valid: $($signature.Status)"
}

$runtimeId = "$($package.version)-r$script:ValidationSchemaVersion"
$versionRoot = Join-Path $installRoot $runtimeId
$runtimeRoot = Join-Path $versionRoot 'app'
$runtimeAsar = Join-Path $runtimeRoot 'resources\app.asar'
$runtimeExe = Join-Path $runtimeRoot 'ChatGPT.exe'
$metadataPath = Join-Path $versionRoot 'installed.json'
$updaterRoot = Join-Path $installRoot 'updater'
$integrityTool = Join-Path $updaterRoot 'ElectronAsarIntegrity.exe'
Write-InstallProgress -Percent 12 -Status 'Building the Electron ASAR integrity validator'
Publish-ElectronAsarIntegrityTool -Source $integrityToolSource -Destination $integrityTool

$selectedRuntimeRoot = $null
if (Test-Path -LiteralPath $currentVersionPath -PathType Leaf) {
    $selectedRuntimeId = (Get-Content -Raw -LiteralPath $currentVersionPath).Trim()
    if ($selectedRuntimeId -match '^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$') {
        $candidateRoot = Join-Path (Join-Path $installRoot $selectedRuntimeId) 'app'
        if (
            -not $candidateRoot.Equals($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath (Join-Path $candidateRoot 'ChatGPT.exe') -PathType Leaf)
        ) {
            $selectedRuntimeRoot = $candidateRoot
        }
    }
}

$runtimeExists = Test-Path -LiteralPath $runtimeRoot -PathType Container
$freshInstall = -not $runtimeExists
$runtimeComplete = [bool](
    $runtimeExists -and
    (Test-Path -LiteralPath $runtimeExe -PathType Leaf) -and
    (Test-Path -LiteralPath $runtimeAsar -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $runtimeRoot 'resources\codex.exe') -PathType Leaf)
)
$runtimeRebuild = -not $runtimeComplete -or -not (Test-ValidationStamp -MetadataPath $metadataPath -Package $package)
$runtimeStats = [pscustomobject]@{
    reuseRoot = $null
    hardlinkedFiles = $null
    hardlinkFallbackFiles = $null
    copiedFiles = $null
    copiedBytes = $null
}
$patchResult = $null
$runtimeValidation = $null
if ($runtimeRebuild) {
    New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
    $buildId = [guid]::NewGuid().ToString('N')
    $patchedAsar = Join-Path $versionRoot "app.asar.patched-$buildId"
    $stagingRoot = Join-Path $versionRoot "app.staging-$buildId"
    Assert-ExactChildPath -Parent $versionRoot -Child $patchedAsar | Out-Null
    Assert-ExactChildPath -Parent $versionRoot -Child $stagingRoot | Out-Null
    try {
        Write-InstallProgress -Percent 15 -Status 'Checking upstream SSH transport compatibility'
        Invoke-NodePatcher -Arguments @($patcher, '--check', $sourceAsar) | Out-Null
        Write-InstallProgress -Percent 25 -Status 'Applying the Windows SSH patch'
        $patchResult = Invoke-NodePatcher -Arguments @($patcher, $sourceAsar, $patchedAsar)
        $reuseRoot = if ($runtimeComplete) {
            $runtimeRoot
        } elseif ($selectedRuntimeRoot) {
            $selectedRuntimeRoot
        } else {
            Get-ChildItem -LiteralPath $installRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'app' } |
                Where-Object {
                    -not $_.Equals($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath (Join-Path $_ 'ChatGPT.exe') -PathType Leaf)
                } |
                Select-Object -First 1
        }
        Write-InstallProgress -Percent 40 -Status 'Rebasing the official runtime'
        $runtimeStats = New-RebasedRuntime -SourceRoot $sourceApp -TargetRoot $stagingRoot -SourceAsar $sourceAsar -PatchedAsar $patchedAsar -ReuseRoot $reuseRoot
        Write-InstallProgress -Percent 84 -Status 'Synchronizing Electron ASAR integrity'
        Invoke-ElectronAsarIntegrity -Mode sync -Tool $integrityTool -Executable (Join-Path $stagingRoot 'ChatGPT.exe') -Asar (Join-Path $stagingRoot 'resources\app.asar') | Out-Null
        Write-InstallProgress -Percent 86 -Status 'Validating the staged runtime and bundled CLI'
        $runtimeValidation = Test-PatchedRuntime -RuntimeRoot $stagingRoot -Patcher $patcher -IntegrityTool $integrityTool
        Write-InstallProgress -Percent 90 -Status 'Publishing the validated runtime'
        if ($runtimeExists) {
            $previousRoot = Join-Path $versionRoot "app.previous-$buildId"
            Assert-ExactChildPath -Parent $versionRoot -Child $previousRoot | Out-Null
            Move-Item -LiteralPath $runtimeRoot -Destination $previousRoot
            try {
                Move-Item -LiteralPath $stagingRoot -Destination $runtimeRoot
            } catch {
                Move-Item -LiteralPath $previousRoot -Destination $runtimeRoot
                throw
            }
            Remove-Item -LiteralPath $previousRoot -Recurse -Force
        } else {
            if (Test-Path -LiteralPath $runtimeRoot) {
                throw "Runtime destination appeared during installation: $runtimeRoot"
            }
            Move-Item -LiteralPath $stagingRoot -Destination $runtimeRoot
        }
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
    Write-InstallProgress -Percent 20 -Status 'Checking upstream SSH transport compatibility'
    Invoke-NodePatcher -Arguments @($patcher, '--check', $sourceAsar) | Out-Null
    Write-InstallProgress -Percent 70 -Status 'Validating the existing runtime and bundled CLI'
    $runtimeValidation = Test-PatchedRuntime -RuntimeRoot $runtimeRoot -Patcher $patcher -IntegrityTool $integrityTool
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

$metadata = [ordered]@{
    runtimeId = $runtimeId
    packageVersion = $package.version
    packageFullName = $package.packageFullName
    sourceExecutableSha256 = (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash
    sourceExecutableSignature = $signature.Status.ToString()
    sourceAsarSha256 = (Get-FileHash -LiteralPath $sourceAsar -Algorithm SHA256).Hash
    patchedAsarSha256 = (Get-FileHash -LiteralPath $runtimeAsar -Algorithm SHA256).Hash
    reuseRoot = $runtimeStats.reuseRoot
    hardlinkedFiles = $runtimeStats.hardlinkedFiles
    hardlinkFallbackFiles = $runtimeStats.hardlinkFallbackFiles
    copiedFiles = $runtimeStats.copiedFiles
    copiedBytes = $runtimeStats.copiedBytes
    automaticWindowsDetection = $true
    patchCompatibility = 'structural'
    validation = $runtimeValidation
    installedAtUtc = [DateTime]::UtcNow.ToString('O')
}
[IO.File]::WriteAllText(
    $metadataPath,
    ($metadata | ConvertTo-Json -Depth 3),
    [Text.UTF8Encoding]::new($false)
)

Write-InstallProgress -Percent 94 -Status 'Installing the stable updater and launcher'
New-Item -ItemType Directory -Path $updaterRoot -Force | Out-Null
foreach ($name in @(
    'Install-Codex-Windows-SSH.ps1',
    'Update-Codex-Windows-SSH.ps1',
    'Get-CodexPackage.ps1',
    'patch-codex-asar.mjs',
    'codex-windows-controller.ps1',
    'Start-Codex.vbs',
    'CodexLauncher.cs',
    'ElectronAsarIntegrity.cs'
)) {
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $name))
    $destination = [IO.Path]::GetFullPath((Join-Path $updaterRoot $name))
    if (-not $source.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

$stableLauncher = Join-Path $installRoot 'Start-Codex.vbs'
Copy-Item -LiteralPath $launcherTemplate -Destination $stableLauncher -Force
foreach ($existingVersion in Get-ChildItem -LiteralPath $installRoot -Directory -ErrorAction SilentlyContinue) {
    if ($existingVersion.Name -notmatch '^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$') { continue }
    Copy-Item -LiteralPath $launcherTemplate -Destination (Join-Path $existingVersion.FullName 'Start-Codex.vbs') -Force
}
$runtimeIcon = Join-Path $runtimeRoot 'resources\icon-chatgpt.ico'
$stableIcon = Join-Path $installRoot 'Codex.ico'
if (Test-Path -LiteralPath $runtimeIcon -PathType Leaf) {
    Copy-Item -LiteralPath $runtimeIcon -Destination $stableIcon -Force
} elseif (-not (Test-Path -LiteralPath $stableIcon -PathType Leaf)) {
    throw "The runtime does not contain a shortcut icon: $runtimeIcon"
}
$stableLauncherHost = Join-Path $installRoot 'CodexLauncher.exe'
Write-InstallProgress -Percent 96 -Status 'Building the stable taskbar launcher'
Publish-CodexLauncherHost -Source $launcherHostSource -Destination $stableLauncherHost
$autoUpdateMarker = Join-Path $installRoot 'auto-update.enabled'
if ($EnableAutoUpdate) {
    [IO.File]::WriteAllText($autoUpdateMarker, "enabled`n", [Text.UTF8Encoding]::new($false))
} elseif ($DisableAutoUpdate -and (Test-Path -LiteralPath $autoUpdateMarker -PathType Leaf)) {
    Remove-Item -LiteralPath $autoUpdateMarker -Force
}
$autoUpdateEnabled = Test-Path -LiteralPath $autoUpdateMarker -PathType Leaf

$currentVersionTemporary = Join-Path $installRoot ('.current.version-' + [guid]::NewGuid().ToString('N'))
Assert-ExactChildPath -Parent $installRoot -Child $currentVersionTemporary | Out-Null
try {
    [IO.File]::WriteAllText(
        $currentVersionTemporary,
        $runtimeId,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::Move($currentVersionTemporary, $currentVersionPath, $true)
} finally {
    if (Test-Path -LiteralPath $currentVersionTemporary -PathType Leaf) {
        Remove-Item -LiteralPath $currentVersionTemporary -Force
    }
}

$shortcutPaths = @()
if (-not $NoShortcut) {
    Write-InstallProgress -Percent 98 -Status 'Updating Codex shortcuts'
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcutShell = New-Object -ComObject WScript.Shell
    foreach ($directory in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        $shortcutPath = Join-Path $directory 'Codex.lnk'
        if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
            if (-not (Test-OwnedLauncherShortcut -Shell $shortcutShell -Path $shortcutPath -LauncherHost $wscript -InstallRoot $installRoot)) {
                throw "Refusing to overwrite an unrelated shortcut: $shortcutPath"
            }
        }
        New-CodexLauncherShortcut -Shell $shortcutShell -Path $shortcutPath -Target $stableLauncherHost -InstallRoot $installRoot -Icon $stableIcon
        $shortcutPaths += $shortcutPath
    }

    $programsDirectory = [Environment]::GetFolderPath('Programs')
    if (-not [string]::IsNullOrWhiteSpace($programsDirectory)) {
        $legacyStartMenuShortcut = Join-Path $programsDirectory 'ChatGPT.lnk'
        if (Test-OwnedLauncherShortcut -Shell $shortcutShell -Path $legacyStartMenuShortcut -LauncherHost $wscript -InstallRoot $installRoot) {
            New-CodexLauncherShortcut -Shell $shortcutShell -Path $legacyStartMenuShortcut -Target $stableLauncherHost -InstallRoot $installRoot -Icon $stableIcon
            $shortcutPaths += $legacyStartMenuShortcut
        }
    }

    $taskbarDirectory = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (Test-Path -LiteralPath $taskbarDirectory -PathType Container) {
        foreach ($pinnedFile in Get-ChildItem -LiteralPath $taskbarDirectory -Filter '*.lnk' -File) {
            if (-not (Test-OwnedLauncherShortcut -Shell $shortcutShell -Path $pinnedFile.FullName -LauncherHost $wscript -InstallRoot $installRoot)) { continue }

            New-CodexLauncherShortcut -Shell $shortcutShell -Path $pinnedFile.FullName -Target $stableLauncherHost -InstallRoot $installRoot -Icon $stableIcon
            $shortcutPaths += $pinnedFile.FullName
        }
    }
}

Write-InstallProgress -Percent 100 -Status 'Update and validation complete'
if ($ShowProgress) { Write-Progress -Id 1 -Activity 'Updating Codex Windows SSH' -Completed }

[pscustomobject]@{
    installed = $true
    updated = $runtimeRebuild
    validated = $true
    version = $package.version
    runtimeId = $runtimeId
    officialPackageVersion = $package.version
    runtime = $runtimeRoot
    freshInstall = $freshInstall
    hardlinkedFiles = $runtimeStats.hardlinkedFiles
    hardlinkFallbackFiles = $runtimeStats.hardlinkFallbackFiles
    copiedFiles = $runtimeStats.copiedFiles
    copiedBytes = $runtimeStats.copiedBytes
    validation = $runtimeValidation
    autoUpdateEnabled = $autoUpdateEnabled
    shortcuts = $shortcutPaths
    instruction = 'Exit every Codex/ChatGPT desktop process, then open Start > Codex. Pin that stable Start entry once if desired; enabled updates are checked, shown, validated, and selected before launch.'
} | ConvertTo-Json -Depth 3
