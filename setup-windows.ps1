# setup-windows.ps1 - Alta de un equipo Windows en la red de Network Solutions.
#
# Que hace, en orden:
#   1. Instala los programas base con winget.
#   2. Instala Tailscale y une el equipo a la tailnet.
#   3. Crea en el escritorio los accesos directos (Google, Proxmox, unidad compartida).
#
# Uso (PowerShell abierto como administrador):
#   irm <URL>/setup-windows.ps1 | iex
#
# La clave de Tailscale (auth key) se pide por pantalla y no queda en el historial.
# Para automatizar sin preguntas: $env:TS_AUTHKEY = 'tskey-auth-...' antes de ejecutar.
# Para ver que haria sin cambiar nada: $env:DRY_RUN = '1' antes de ejecutar.
#
# Este script NO contiene secretos: se puede publicar.

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- configuracion
$Apps = @(
    'Google.Chrome',
    'Git.Git',
    'Microsoft.VisualStudioCode',
    '7zip.7zip'
)
$TailscaleId = 'Tailscale.Tailscale'

$SharePath = '\\100.75.16.110\Archivos'
$Shortcuts = [ordered]@{
    'Google'            = 'https://www.google.com'
    'Proxmox - R630'    = 'https://100.99.232.33:8006'
    'Proxmox - T40'     = 'https://100.93.21.6:8006'
    'Proxmox - OptiPlex' = 'https://100.84.231.111:8006'
}
# ------------------------------------------------------------------------------

$DryRun = $env:DRY_RUN -eq '1'

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    ok  $Text" -ForegroundColor Green }
function Write-Skip([string]$Text) { Write-Host "    --  $Text" -ForegroundColor DarkGray }

function Invoke-Action([string]$Description, [scriptblock]$Action) {
    if ($DryRun) { Write-Host "    [dry-run] $Description" -ForegroundColor Yellow; return }
    & $Action
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WingetInstalled([string]$Id) {
    winget list --id $Id --exact --accept-source-agreements *> $null
    return $LASTEXITCODE -eq 0
}

function Install-WingetApp([string]$Id) {
    if (Test-WingetInstalled $Id) { Write-Skip "$Id ya estaba instalado"; return }
    Invoke-Action "winget install $Id" {
        winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget no pudo instalar $Id (codigo $LASTEXITCODE)" }
    }
    Write-Ok "$Id instalado"
}

function Get-TailscaleExe {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-AuthKey {
    if ($env:TS_AUTHKEY) { return $env:TS_AUTHKEY }
    Write-Host '    Pega la auth key de Tailscale (Enter vacio = iniciar sesion en el navegador):'
    $secure = Read-Host -AsSecureString '    Auth key'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-UrlShortcut([string]$Folder, [string]$Name, [string]$Url) {
    $path = Join-Path $Folder "$Name.url"
    Invoke-Action "acceso directo $Name -> $Url" {
        Set-Content -LiteralPath $path -Encoding Ascii -Value @('[InternetShortcut]', "URL=$Url")
    }
    Write-Ok "$Name"
}

function New-FolderShortcut([string]$Folder, [string]$Name, [string]$Target) {
    $path = Join-Path $Folder "$Name.lnk"
    Invoke-Action "acceso directo $Name -> $Target" {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
        $lnk.TargetPath = $Target
        $lnk.Save()
    }
    Write-Ok "$Name"
}

# ------------------------------------------------------------------------ main
if (-not $DryRun -and -not (Test-Admin)) {
    throw 'Abre PowerShell como administrador y vuelve a ejecutar el comando.'
}
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'No se encontro winget. Instala "App Installer" desde Microsoft Store y vuelve a ejecutar.'
}
if ($DryRun) { Write-Host 'Modo DRY_RUN: no se cambia nada.' -ForegroundColor Yellow }

Write-Step 'Programas base'
foreach ($app in $Apps) { Install-WingetApp $app }

Write-Step 'Tailscale'
Install-WingetApp $TailscaleId
$ts = Get-TailscaleExe
if (-not $ts -and -not $DryRun) { throw 'Tailscale se instalo pero no se encuentra tailscale.exe. Reinicia la terminal y repite.' }

$alreadyUp = $false
if ($ts) {
    & $ts status *> $null
    $alreadyUp = $LASTEXITCODE -eq 0
}
if ($alreadyUp) {
    Write-Skip 'el equipo ya esta conectado a la tailnet'
} else {
    $hostname = $env:COMPUTERNAME.ToLower()
    $key = if ($DryRun) { '' } else { Get-AuthKey }
    Invoke-Action "tailscale up --hostname=$hostname --unattended" {
        if ($key) {
            & $ts up --authkey=$key --hostname=$hostname --unattended
        } else {
            & $ts up --hostname=$hostname --unattended
        }
        if ($LASTEXITCODE -ne 0) { throw "tailscale up fallo (codigo $LASTEXITCODE)" }
    }
    $key = $null
    Write-Ok "conectado como $hostname"
}

Write-Step 'Accesos directos en el escritorio'
$desktop = [Environment]::GetFolderPath('Desktop')
foreach ($name in $Shortcuts.Keys) { New-UrlShortcut $desktop $name $Shortcuts[$name] }
New-FolderShortcut $desktop 'Unidad compartida' $SharePath

Write-Step 'Listo'
Write-Host '    Proxmox usa un certificado propio: el navegador avisara la primera vez, es esperado.'
Write-Host '    La invitacion a la organizacion la hace un administrador (ver ADMIN.md).'
