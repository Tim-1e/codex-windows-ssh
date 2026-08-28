Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    exit 87
}

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine('CODEX_WINDOWS_CONTROLLER_V1')
[Console]::Out.Flush()

function Resolve-NativeCodex {
    $direct = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($direct) {
        return $direct.Source
    }

    $wrapper = Get-Command codex.ps1 -ErrorAction Stop
    $binDirectory = Split-Path -Parent $wrapper.Path
    $stablePattern = Join-Path $binDirectory 'node_modules\@openai\codex\node_modules\@openai\codex-win32-*\vendor\*\bin\codex.exe'
    $candidate = Get-ChildItem -Path $stablePattern -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }

    $packageRoot = Join-Path $binDirectory 'node_modules\@openai'
    $candidate = Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        Select-Object -Last 1
    if (-not $candidate) {
        throw "Unable to locate the native Codex executable under $packageRoot"
    }
    return $candidate.FullName
}

$server = $null
$proxyListener = $null
$frontClient = $null
$backClient = $null
try {
    $nativeCodex = Resolve-NativeCodex
    $proxyListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $proxyListener.Start()
    $proxyPort = ([Net.IPEndPoint]$proxyListener.LocalEndpoint).Port

    $portPicker = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $portPicker.Start()
        $port = ([Net.IPEndPoint]$portPicker.LocalEndpoint).Port
    }
    finally {
        $portPicker.Stop()
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $nativeCodex
    $startInfo.Arguments = '-c features.code_mode_host=true app-server --analytics-default-enabled --listen ws://127.0.0.1:' + $port
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true

    $server = [Diagnostics.Process]::new()
    $server.StartInfo = $startInfo
    if (-not $server.Start()) {
        throw 'Failed to start Codex app-server'
    }
    $server.StandardInput.Close()

    $ready = $false
    for ($attempt = 0; $attempt -lt 100 -and -not $server.HasExited; $attempt += 1) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $pending = $client.ConnectAsync([Net.IPAddress]::Loopback, $port)
            if ($pending.Wait(100) -and $client.Connected) {
                $ready = $true
                break
            }
        }
        catch {
            # Listener is not ready yet.
        }
        finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 50
    }
    if (-not $ready) {
        throw 'Codex app-server did not become ready on its loopback port'
    }

    $endpoint = [pscustomobject]@{
        controllerPid = $PID
        pid = $server.Id
        port = $proxyPort
        backendPort = $port
    } | ConvertTo-Json -Compress
    [Console]::Out.WriteLine('CODEX_WINDOWS_ENDPOINT_V1 ' + $endpoint)
    [Console]::Out.Flush()

    $accept = $proxyListener.AcceptTcpClientAsync()
    if (-not $accept.Wait(30000)) {
        throw 'Timed out waiting for the SSH direct-tcpip connection'
    }
    $frontClient = $accept.Result
    $frontClient.NoDelay = $true
    $backClient = [Net.Sockets.TcpClient]::new()
    $backClient.NoDelay = $true
    $backClient.Connect([Net.IPAddress]::Loopback, $port)

    $frontStream = $frontClient.GetStream()
    $backStream = $backClient.GetStream()
    $frontToBack = $frontStream.CopyToAsync($backStream)
    $backToFront = $backStream.CopyToAsync($frontStream)
    [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($frontToBack, $backToFront)) | Out-Null
    $serverExitCode = 0
}
finally {
    if ($frontClient) {
        $frontClient.Dispose()
    }
    if ($backClient) {
        $backClient.Dispose()
    }
    if ($proxyListener) {
        $proxyListener.Stop()
    }
    if ($server -and -not $server.HasExited) {
        $server.Kill()
        $server.WaitForExit(5000) | Out-Null
    }
    if ($server) {
        $server.Dispose()
    }
}
exit $serverExitCode
