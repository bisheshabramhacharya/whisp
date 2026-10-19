# Removes Whisp for Windows. Your dictionary, history and recordings in %APPDATA%\Whisp
# are kept unless you pass -RemoveData.
param([switch]$RemoveData)

$ErrorActionPreference = 'Continue'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Whisp'

Get-Process Whisp -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Whisp.lnk') -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Whisp -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Whisp' -Recurse -ErrorAction SilentlyContinue
# Speech model, private .NET SDK and build files.
Remove-Item (Join-Path $env:LOCALAPPDATA 'Whisp') -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveData) {
    Remove-Item (Join-Path $env:APPDATA 'Whisp') -Recurse -Force -ErrorAction SilentlyContinue
}
# Last: this script lives in the install folder.
Set-Location $env:TEMP
Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Whisp removed.'
