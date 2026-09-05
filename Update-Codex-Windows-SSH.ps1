[CmdletBinding()]
param([switch]$Interactive, [switch]$Status, [switch]$Menu, [switch]$JsonProgress, [switch]$Launch,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$')][string]$RunningRuntimeId)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:ValidationSchemaVersion = 10
$installRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex-Windows-SSH'
$feedUrl = 'https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json'
$publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$updateEventsPath = $null

function Write-UpdateEvent {
    param([string]$Phase, [string]$Message, [object]$Percent = $null, [object]$Data = $null)
    $event = [ordered]@{ type='progress'; time=[DateTime]::UtcNow.ToString('O'); phase=$Phase; message=$Message; percent=$Percent; data=$Data }
    $line = $event | ConvertTo-Json -Depth 8 -Compress
    if ($updateEventsPath) { try { [IO.File]::AppendAllText($updateEventsPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) } catch {} }
    if ($JsonProgress) { try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch {} }
    else { Write-Host $Message }
}

function Assert-OfficialUrl {
    param([string]$Url)
    $uri = [uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'persistent.oaistatic.com' -or
        $uri.Port -ne 443 -or $uri.UserInfo -or -not $uri.AbsolutePath.StartsWith('/codex-app-prod/')) {
        throw "Refusing non-official update URL: $Url"
    }
    return $uri
}

function Assert-UpdateManifest {
    param($Manifest)
    if ($Manifest.schemaVersion -ne 1 -or $Manifest.packageIdentity -ne 'OpenAI.Codex' -or
        $Manifest.storeProductId -ne '9PLM9XGG6VKS' -or $Manifest.buildVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw 'Unrecognized official update manifest; current runtime is unchanged.'
    }
}

function Get-SelectedRuntime {
    $pointer = Join-Path $installRoot 'current.version'
    if (-not (Test-Path -LiteralPath $pointer)) { return $null }
    $id = (Get-Content -LiteralPath $pointer -Raw).Trim()
    if ($id -notmatch '^\d+\.\d+\.\d+\.\d+(?:-r\d+)?$') { throw 'Invalid current.version; refusing update.' }
    $versionRoot = Join-Path $installRoot $id
    try { $metadata = Get-Content -LiteralPath (Join-Path $versionRoot 'installed.json') -Raw | ConvertFrom-Json }
    catch { $metadata = [pscustomobject]@{ packageVersion=($id -replace '-r\d+$',''); validation=[pscustomobject]@{schemaVersion=0;status='missing'} } }
    return [pscustomobject]@{ id=$id; root=$versionRoot; metadata=$metadata }
}

function Get-OfficialRelease {
    $manifest = Invoke-RestMethod -Uri $feedUrl -TimeoutSec 20 -MaximumRedirection 0
    Assert-UpdateManifest $manifest
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($architecture -notin @('x64', 'arm64')) { throw "Unsupported architecture: $architecture" }
    $url = "https://persistent.oaistatic.com/codex-app-prod/releases/$($manifest.buildVersion)/ChatGPT-$architecture.msix"
    $version = $manifest.buildVersion
    try { $head = Invoke-WebRequest -Method Head -Uri $url -TimeoutSec 20 -MaximumRedirection 0 }
    catch {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        # Official Store rollout can precede the downloadable MSIX. Never call
        # this older package "latest", and never silently downgrade the user.
        $url = "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-$architecture.msix"
        $head = Invoke-WebRequest -Method Head -Uri $url -TimeoutSec 20 -MaximumRedirection 0
        $version = @($head.Headers['x-ms-meta-package_version'])[0]
        if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Official download has no valid package version.' }
    }
    Assert-OfficialUrl $url | Out-Null
    return [pscustomobject]@{ version=$version; latestVersion=$manifest.buildVersion; architecture=$architecture; url=$url;
        length=[long]@($head.Headers['Content-Length'])[0]; etag=@($head.Headers['ETag'])[0]; manifestUrl=$feedUrl }
}

function Save-OfficialPackage {
    param($Release, [string]$Destination)
    Assert-OfficialUrl $Release.url | Out-Null
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(20)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Release.url)
    if ($Release.etag) { [void]$request.Headers.TryAddWithoutValidation('If-Match', $Release.etag) }
    $response = $null; $inputStream = $null; $outputStream = $null
    $downloadDeadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(20))
    try {
        $response = $client.Send($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        [void]$response.EnsureSuccessStatusCode()
        $inputStream = $response.Content.ReadAsStream()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
        $buffer = [byte[]]::new(1048576)
        [long]$received = 0; $lastPercent = -1
        Write-UpdateEvent downloading "正在下载官方原包 $($Release.version)…" 0
        while ($true) {
            $readDeadline = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($downloadDeadline.Token)
            try {
                $readDeadline.CancelAfter([TimeSpan]::FromSeconds(45))
                $count = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $readDeadline.Token).GetAwaiter().GetResult()
            } finally { $readDeadline.Dispose() }
            if ($count -eq 0) { break }
            $outputStream.Write($buffer, 0, $count); $received += $count
            $percent = if ($Release.length -gt 0) { [Math]::Min(100, [int][Math]::Floor(100 * $received / $Release.length)) } else { 0 }
            if ($percent -ne $lastPercent) {
                Write-UpdateEvent downloading ("下载 {0}% · {1:N1} / {2:N1} MB" -f $percent, ($received/1MB), ($Release.length/1MB)) $percent
                $lastPercent = $percent
            }
        }
        if ($Release.length -le 0 -or $received -ne $Release.length) { throw 'Official package download length mismatch.' }
        $outputStream.Flush($true)
    } finally {
        if ($outputStream) { $outputStream.Dispose() }; if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }; $request.Dispose(); $client.Dispose(); $handler.Dispose(); $downloadDeadline.Dispose()
    }
}

function Expand-VerifiedPackage {
    param([string]$Path, [string]$Destination, $Release)
    Write-UpdateEvent verifying '正在验证官方 MSIX 数字签名和文件哈希…' 0
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { throw "Official MSIX signature verification failed: $($signature.Status)" }
    $sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $manifestEntry = $archive.GetEntry('AppxManifest.xml')
        if (-not $manifestEntry -or $manifestEntry.Length -gt 1MB) { throw 'Missing or oversized MSIX manifest.' }
        $reader = [IO.StreamReader]::new($manifestEntry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $identity = $manifest.Package.Identity
        if ($identity.Name -ne 'OpenAI.Codex' -or $identity.Publisher -ne $publisher -or
            $identity.Version -ne $Release.version -or $identity.ProcessorArchitecture -ne $Release.architecture) {
            throw 'Signed package identity/version/architecture does not match the official update.'
        }
        $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        New-Item -ItemType Directory -Path $Destination | Out-Null
        $entries = @($archive.Entries | Where-Object { $_.FullName.StartsWith('app/') -or $_.FullName -eq 'AppxManifest.xml' })
        [long]$total = ($entries | Measure-Object Length -Sum).Sum
        if ($total -gt 12GB -or $entries.Count -gt 60000) { throw 'Package exceeds supported extraction limits.' }
        [long]$done = 0; $lastPercent = -1
        foreach ($entry in $entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':')) { throw 'Unsafe path in MSIX.' }
            if ($entry.FullName.EndsWith('/')) { continue }
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            $done += $entry.Length
            $percent = [int](100 * $done / [Math]::Max(1, $total))
            if ($percent -ne $lastPercent) { Write-UpdateEvent extracting "正在展开已验证原包 $percent%" $percent; $lastPercent = $percent }
        }
        return [pscustomobject]@{ sha256=$sha256; signature=$signature.Status.ToString(); signer=$signature.SignerCertificate.Subject }
    } finally { $archive.Dispose() }
}

function Remove-UpdateWorkspace {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($full) -ne [IO.Path]::GetFullPath($installRoot) -or
        [IO.Path]::GetFileName($full) -notmatch '^\.update-[a-f0-9]{32}$') { throw 'Unsafe update workspace cleanup target.' }
    $items = @(Get-Item -LiteralPath $full) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Refusing update workspace containing reparse points.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}


# Dot sourcing exposes the real shared functions for small, dependency-free tests.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($Status) {
    $selected = Get-SelectedRuntime
    [pscustomobject]@{ selected=$selected; lastUpdate=if (Test-Path -LiteralPath (Join-Path $installRoot 'last-update.json')) {
        Get-Content -LiteralPath (Join-Path $installRoot 'last-update.json') -Raw | ConvertFrom-Json
    } else { $null }; statusIsLocalOnly=$true } | ConvertTo-Json -Depth 10
    return
}
# Legacy flags remain accepted for older launchers; UI lives only in the app.

$mutex = [Threading.Mutex]::new($false, 'Local\CodexWindowsSSHUpdater')
$acquired = $false; $workspace = $null; $exitCode = 1
$result = [ordered]@{ type='result'; checkedAtUtc=[DateTime]::UtcNow.ToString('O'); succeeded=$false; restartRequired=$false; message='更新失败'; source='official-online' }
try {
    try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
    if (-not $acquired) { throw '另一项更新正在进行，请等待它完成。' }
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    $updateEventsPath = Join-Path $installRoot 'last-update.log'
    [IO.File]::WriteAllText($updateEventsPath, '', [Text.UTF8Encoding]::new($false))
    Write-UpdateEvent checking '正在检查官方新版…'
    $selected = Get-SelectedRuntime
    $release = Get-OfficialRelease
    $result.release = $release
    $result.previousRuntimeId = if ($selected) { $selected.id } else { $null }
    $currentValid = $selected -and $selected.metadata.validation.schemaVersion -eq $script:ValidationSchemaVersion -and
        $selected.metadata.validation.status -eq 'passed'
    if ($currentValid) {
        foreach ($required in @('app\ChatGPT.exe', 'app\resources\app.asar', 'app\resources\codex.exe', 'app\resources\desktop-updater.cjs')) {
            if (-not (Test-Path -LiteralPath (Join-Path $selected.root $required) -PathType Leaf)) { $currentValid=$false; break }
        }
    }
    $behindFeed = [version]$release.version -lt [version]$release.latestVersion
    if ($behindFeed) { Write-UpdateEvent checking "官方清单 $($release.latestVersion) 的原包尚未同步；当前可下载 $($release.version)。" }
    if ($selected -and [version]$selected.metadata.packageVersion -gt [version]$release.version) {
        throw "官方可下载版本较旧，保留当前 $($selected.metadata.packageVersion)，不降级。"
    }
    if ($currentValid -and $selected.metadata.packageVersion -eq $release.version) {
        $result.restartRequired = [bool]($RunningRuntimeId -and $RunningRuntimeId -ne $selected.id)
        $result.message = if ($behindFeed) { '当前已是可下载的最新版本；官方更高版本原包尚未发布，请稍后重试。' } else { "已是官方最新版本 $($release.version)，兼容校验已通过。" }
        $result.result = if ($behindFeed) { 'upstream-package-pending' } else { 'already-current' }
        if ($result.restartRequired) { $result.message += " 已准备好 $($selected.id)，请重启 Codex_Fix 生效。" }
    } else {
        $workspace = Join-Path $installRoot ('.update-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workspace | Out-Null
        $msix = Join-Path $workspace 'official.msix'
        $extracted = Join-Path $workspace 'package'
        Save-OfficialPackage $release $msix
        $result.officialPackage = Expand-VerifiedPackage $msix $extracted $release
        Write-UpdateEvent building '正在识别官方结构并应用兼容补丁…' 0
        $buildOutput = @(& (Join-Path $PSScriptRoot 'Install-Codex-Windows-SSH.ps1') -NoShortcut -PackageRoot $extracted -ProgressCallback {
            param($percent, $message)
            $phase = if ($percent -ge 94) { 'switching' } elseif ($percent -ge 86) { 'validating' } else { 'building' }
            Write-UpdateEvent $phase $message $percent
        })
        $result.build = ($buildOutput -join [Environment]::NewLine) | ConvertFrom-Json
        $result.restartRequired = $true
        $result.result = 'updated'
        $result.message = "更新成功：$($release.version)。启动验证通过；当前会话保持运行，下次从 Codex_Fix 启动生效。"
    }
    # Also retry deferred hardlink cleanup on already-current pre-launch checks.
    # Never stop a user's running app to make a shared file deletable.
    Write-UpdateEvent cleanup '正在清理不用的修复副本（运行中的版本会保留）…'
    try { $result.cleanup = (& (Join-Path $PSScriptRoot 'Remove-OldCodexRuntimes.ps1') | ConvertFrom-Json) }
    catch { Write-UpdateEvent cleanup "旧版本暂未清理：$($_.Exception.Message)" }
    $result.succeeded = $true; $exitCode = 0
} catch {
    $result.error = $_.Exception.Message
    $result.message = "更新失败，保留当前可用版本：$($_.Exception.Message)"
    Write-UpdateEvent failed $result.message
} finally {
    if ($workspace) {
        Write-UpdateEvent cleanup '正在清理临时原包和构建目录；不会保留多份安装包…'
        try { Remove-UpdateWorkspace $workspace } catch { $result.cleanupWarning=$_.Exception.Message }
    }
    if ($acquired) {
        try {
            $temporary = Join-Path $installRoot '.last-update.json.tmp'
            [IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporary, (Join-Path $installRoot 'last-update.json'), $true)
        } catch { $result.logWarning=$_.Exception.Message }
        finally { $mutex.ReleaseMutex() }
    }
    $mutex.Dispose()
    $line = $result | ConvertTo-Json -Depth 12 -Compress
    if ($updateEventsPath) { try { [IO.File]::AppendAllText($updateEventsPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) } catch {} }
    if ($JsonProgress) { try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch {} } else { Write-Host $result.message }
}
exit $exitCode
