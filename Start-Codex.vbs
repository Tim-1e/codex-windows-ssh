Option Explicit

Dim fso, shell, scriptDirectory, parentDirectory, canonicalRoot
Dim basePath, runtimeBase, appPath, validationMode
Dim currentVersionPath, currentVersion, currentFile
Dim cleanupPath, cleanupCommand, cleanupExitCode
Dim processService, processes, processItem, processPath, otherProcessPath
Dim sameProcessRunning, launchProbeAvailable, launchedProcessRunning
Dim launchExitCode, launchErrorNumber, launchErrorDescription

Sub WriteLaunchState(stage, detail)
    Dim logFile
    On Error Resume Next
    Set logFile = fso.CreateTextFile(fso.BuildPath(basePath, "last-launch.txt"), True, False)
    logFile.WriteLine "time=" & CStr(Now)
    logFile.WriteLine "stage=" & stage
    logFile.WriteLine "basePath=" & basePath
    logFile.WriteLine "runtimeBase=" & runtimeBase
    logFile.WriteLine "appPath=" & appPath
    logFile.WriteLine "detail=" & detail
    logFile.Close
    On Error GoTo 0
End Sub

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

validationMode = shell.Environment("PROCESS")("CODEX_WINDOWS_SSH_LAUNCHER_VALIDATE")
If validationMode = "1" Then
    WScript.Echo "syntax-ok"
    WScript.Quit 0
End If

scriptDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
parentDirectory = fso.GetParentFolderName(scriptDirectory)
canonicalRoot = fso.BuildPath(fso.BuildPath(shell.ExpandEnvironmentStrings("%LOCALAPPDATA%"), "OpenAI"), "Codex-Windows-SSH")
basePath = scriptDirectory
If Not fso.FileExists(fso.BuildPath(basePath, "current.version")) Then
    If fso.FileExists(fso.BuildPath(parentDirectory, "current.version")) Then
        basePath = parentDirectory
    ElseIf fso.FileExists(fso.BuildPath(canonicalRoot, "current.version")) Then
        basePath = canonicalRoot
    End If
End If
runtimeBase = basePath
currentVersionPath = fso.BuildPath(basePath, "current.version")
If fso.FileExists(currentVersionPath) Then
    Set currentFile = fso.OpenTextFile(currentVersionPath, 1, False)
    currentVersion = Trim(Replace(Replace(currentFile.ReadAll, vbCr, ""), vbLf, ""))
    currentFile.Close
    If Len(currentVersion) > 0 Then runtimeBase = fso.BuildPath(basePath, currentVersion)
End If
appPath = fso.BuildPath(fso.BuildPath(runtimeBase, "app"), "ChatGPT.exe")

If validationMode = "resolve" Then
    WScript.Echo "basePath=" & basePath
    WScript.Echo "runtimeBase=" & runtimeBase
    WScript.Echo "appPath=" & appPath
    If fso.FileExists(appPath) Then WScript.Quit 0
    WScript.Quit 2
End If

otherProcessPath = ""
sameProcessRunning = False
On Error Resume Next
Set processService = GetObject("winmgmts:\\.\root\cimv2")
If Err.Number = 0 Then
    Set processes = processService.ExecQuery("SELECT ExecutablePath FROM Win32_Process WHERE Name='ChatGPT.exe'")
    For Each processItem In processes
        processPath = ""
        Err.Clear
        processPath = CStr(processItem.ExecutablePath)
        If Err.Number = 0 And Len(processPath) > 0 Then
            If LCase(processPath) = LCase(appPath) Then
                sameProcessRunning = True
            Else
                otherProcessPath = processPath
            End If
        End If
    Next
End If
Err.Clear
On Error GoTo 0

If Len(otherProcessPath) > 0 Then
    WriteLaunchState "blocked-other-instance", otherProcessPath
    MsgBox "Another Codex/ChatGPT instance is still running." & vbCrLf & _
        "Exit it completely, then open Codex again." & vbCrLf & vbCrLf & otherProcessPath, _
        vbExclamation, "Codex"
    WScript.Quit 3
End If

' Retry only local cleanup before the new app locks shared DLL/PAK hardlinks.
' Online checks start inside the app so progress uses the official themed card.
cleanupPath = fso.BuildPath(fso.BuildPath(basePath, "updater"), "Remove-OldCodexRuntimes.ps1")
If Not sameProcessRunning And fso.FileExists(cleanupPath) Then
    cleanupCommand = "pwsh.exe -NoLogo -NoProfile -NonInteractive -File " & Chr(34) & cleanupPath & Chr(34)
    cleanupExitCode = shell.Run(cleanupCommand, 0, True)
    If cleanupExitCode <> 0 Then WriteLaunchState "cleanup-deferred", "exitCode=" & CStr(cleanupExitCode)
End If

If Not fso.FileExists(appPath) Then
    WriteLaunchState "runtime-incomplete", appPath
    MsgBox "Codex runtime is incomplete:" & vbCrLf & appPath, vbCritical, "Codex"
    WScript.Quit 2
End If

shell.CurrentDirectory = runtimeBase
On Error Resume Next
launchExitCode = shell.Run(Chr(34) & appPath & Chr(34), 1, False)
launchErrorNumber = Err.Number
launchErrorDescription = Err.Description
Err.Clear
On Error GoTo 0
If launchErrorNumber <> 0 Then
    WriteLaunchState "launch-failed", "error=" & CStr(launchErrorNumber) & "; " & launchErrorDescription
    MsgBox "Codex could not be started:" & vbCrLf & launchErrorDescription, vbCritical, "Codex"
    WScript.Quit 4
End If
WScript.Sleep 1200
launchProbeAvailable = False
launchedProcessRunning = False
On Error Resume Next
If IsObject(processService) Then
    Err.Clear
    Set processes = processService.ExecQuery("SELECT ExecutablePath FROM Win32_Process WHERE Name='ChatGPT.exe'")
    If Err.Number = 0 Then
        launchProbeAvailable = True
        For Each processItem In processes
            processPath = ""
            Err.Clear
            processPath = CStr(processItem.ExecutablePath)
            If Err.Number = 0 And LCase(processPath) = LCase(appPath) Then
                launchedProcessRunning = True
                Exit For
            End If
        Next
    End If
End If
Err.Clear
On Error GoTo 0

If launchedProcessRunning Then
    WriteLaunchState "running", "shellRun=" & CStr(launchExitCode) & "; processAlive=true"
    WScript.Quit 0
End If
If launchProbeAvailable Then
    WriteLaunchState "exited-early", "shellRun=" & CStr(launchExitCode) & "; processAlive=false"
    MsgBox "Codex exited immediately after launch." & vbCrLf & _
        "Details: " & fso.BuildPath(basePath, "last-launch.txt"), vbCritical, "Codex"
    WScript.Quit 5
End If

WriteLaunchState "dispatched-unverified", "shellRun=" & CStr(launchExitCode) & "; processProbe=unavailable"
WScript.Quit 0
