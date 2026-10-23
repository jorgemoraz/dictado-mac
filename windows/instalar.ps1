# Instala o actualiza Dictado para Windows desde GitHub y lo deja arrancando con Windows.
# En PowerShell (no hace falta ser administrador):
#   irm https://raw.githubusercontent.com/jorgemoraz/dictado-mac/main/windows/instalar.ps1 | iex
# Desinstalar (conserva ajustes, diccionario y modelo de voz):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jorgemoraz/dictado-mac/main/windows/instalar.ps1))) desinstalar
param([string]$Accion = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'jorgemoraz/dictado-mac'
$root = Join-Path $env:LOCALAPPDATA 'Programs\Dictado'
$app = Join-Path $root 'app'
$exe = Join-Path $app 'DictadoWindows.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Dictado.lnk'

Get-Process DictadoWindows -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

if ($Accion -eq 'desinstalar') {
    Remove-ItemProperty $runKey -Name 'Dictado' -ErrorAction SilentlyContinue
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Dictado desinstalado. Ajustes, diccionario y modelo de voz se conservan en AppData.'
    return
}

Write-Host 'Buscando la última versión de Dictado para Windows…'
$releases = Invoke-RestMethod "https://api.github.com/repos/$repo/releases?per_page=20" -Headers @{ 'User-Agent' = 'Dictado-Windows' }
$release = $releases | Where-Object { $_.tag_name -like 'windows-v*' -and -not $_.draft -and -not $_.prerelease } | Select-Object -First 1
if (-not $release) { throw 'Todavía no hay ninguna versión publicada para Windows.' }
$asset = $release.assets | Where-Object { $_.name -eq 'DictadoWindows.zip' } | Select-Object -First 1
if (-not $asset) { throw "La versión $($release.tag_name) no incluye DictadoWindows.zip." }

$zip = Join-Path $env:TEMP 'DictadoWindows.zip'
Write-Host "Descargando $($release.tag_name) (unos 70 MB)…"
Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing

New-Item -ItemType Directory -Force $root | Out-Null
$staging = Join-Path $root 'app-new'
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Instalando…'
Expand-Archive $zip -DestinationPath $staging -Force
Remove-Item $zip -Force
Get-ChildItem $staging -Recurse -File | Unblock-File
Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue
Rename-Item $staging 'app'

Set-ItemProperty $runKey -Name 'Dictado' -Value "`"$exe`" --autostart"
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $app
$link.Description = 'Dictado por voz con Whisper'
$link.Save()

Start-Process $exe
Write-Host ''
Write-Host "Listo: Dictado $($release.tag_name.Substring(9)) instalado. Arranca con Windows y se actualiza solo desde GitHub."
Write-Host 'La primera vez descarga el modelo de voz (574 MB). Después: mantén Ctrl + Win, habla y suelta.'
