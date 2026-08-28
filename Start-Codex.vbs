Option Explicit

Dim fso, shell, basePath, appPath
Dim processService, processes, processItem, processPath, otherProcessPath

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

If shell.Environment("PROCESS")("CODEX_WINDOWS_SSH_LAUNCHER_VALIDATE") = "1" Then
    WScript.Echo "syntax-ok"
    WScript.Quit 0
End If

basePath = fso.GetParentFolderName(WScript.ScriptFullName)
appPath = fso.BuildPath(fso.BuildPath(basePath, "app"), "ChatGPT.exe")

If Not fso.FileExists(appPath) Then
    MsgBox "Codex runtime is incomplete:" & vbCrLf & basePath, vbCritical, "Codex"
    WScript.Quit 2
End If

otherProcessPath = ""
On Error Resume Next
Set processService = GetObject("winmgmts:\\.\root\cimv2")
If Err.Number = 0 Then
    Set processes = processService.ExecQuery("SELECT ExecutablePath FROM Win32_Process WHERE Name='ChatGPT.exe'")
    For Each processItem In processes
        processPath = ""
        Err.Clear
        processPath = CStr(processItem.ExecutablePath)
        If Err.Number = 0 And Len(processPath) > 0 Then
            If LCase(processPath) <> LCase(appPath) Then otherProcessPath = processPath
        End If
    Next
End If
Err.Clear
On Error GoTo 0

If Len(otherProcessPath) > 0 Then
    MsgBox "Another Codex/ChatGPT instance is still running." & vbCrLf & _
        "Exit it completely, then open Codex again." & vbCrLf & vbCrLf & otherProcessPath, _
        vbExclamation, "Codex"
    WScript.Quit 3
End If

shell.CurrentDirectory = basePath
shell.Run Chr(34) & appPath & Chr(34), 1, False
WScript.Quit 0
