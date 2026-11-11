Option Explicit

Dim fso, shell, scriptDir, projectRoot, previewRoot
Dim previewFolder, candidate, latestFolder, latestDate
Dim executable, manifest

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
projectRoot = fso.GetParentFolderName(scriptDir)
previewRoot = fso.BuildPath(projectRoot, "releases\preview")

If Not fso.FolderExists(previewRoot) Then
    MsgBox "Yixue preview directory was not found.", 16, "Yixue"
    WScript.Quit 1
End If

Set previewFolder = fso.GetFolder(previewRoot)
Set latestFolder = Nothing
latestDate = CDate("2000-01-01")

For Each candidate In previewFolder.SubFolders
    executable = fso.BuildPath(candidate.Path, "yixue_app.exe")
    manifest = fso.BuildPath(candidate.Path, "preview-manifest.json")
    If LCase(Left(candidate.Name, 1)) = "v" _
        And InStr(1, LCase(candidate.Name), "-preview.", vbTextCompare) > 0 _
        And fso.FileExists(executable) _
        And fso.FileExists(manifest) Then
        If candidate.DateLastModified > latestDate Then
            Set latestFolder = candidate
            latestDate = candidate.DateLastModified
        End If
    End If
Next

If latestFolder Is Nothing Then
    MsgBox "No complete Yixue preview release was found.", 16, "Yixue"
    WScript.Quit 1
End If

executable = fso.BuildPath(latestFolder.Path, "yixue_app.exe")
If WScript.Arguments.Named.Exists("print") Then
    WScript.Echo executable
    WScript.Quit 0
End If

shell.Environment("PROCESS")("YIXUE_DATA_DIR") = fso.BuildPath(projectRoot, "user-data")
shell.CurrentDirectory = latestFolder.Path
shell.Run Chr(34) & executable & Chr(34), 1, False
