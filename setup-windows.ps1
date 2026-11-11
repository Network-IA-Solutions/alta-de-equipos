# setup-windows.ps1 - Alta de un equipo Windows en la red de Network Solutions.
#
# Que hace, en orden:
#   1. Instala los programas base con winget (incluye Claude Desktop y Docker Desktop).
#   2. Instala las herramientas de IA: Claude Code, Gentle AI y Gentle Shell.
#   3. Instala Tailscale y une el equipo a la tailnet.
#   4. Crea en el escritorio los accesos directos (Google, Proxmox, unidad compartida).
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
    '7zip.7zip',
    'OpenJS.NodeJS.LTS',      # Gentle Shell necesita Node >= 22.19
    'GoLang.Go',              # Gentle AI se instala desde el codigo en Windows (Go >= 1.25.10)
    'Anthropic.Claude',       # Claude Desktop
    'Docker.DockerDesktop'
)

# Instaladores oficiales de cada herramienta (se ejecutan en un proceso aparte).
$ClaudeCodeInstaller = 'https://claude.ai/install.ps1'
$GentleAiInstaller   = 'https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.ps1'
$GentleShellPackages = @('@earendil-works/pi-coding-agent', 'gentle-pi')
$MinNodeVersion      = [version]'22.19.0'
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

# winget no actualiza el PATH de esta sesion: se relee del registro.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Test-Command([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Ejecuta un instalador "irm | iex" en otro proceso: si hace "exit", no corta este script.
function Invoke-RemoteInstaller([string]$Name, [string]$Url) {
    Invoke-Action "instalador oficial de $Name ($Url)" {
        $ps = (Get-Process -Id $PID).Path
        & $ps -NoProfile -ExecutionPolicy Bypass -Command "irm '$Url' | iex"
        if ($LASTEXITCODE -ne 0) { throw "El instalador de $Name fallo (codigo $LASTEXITCODE)" }
    }
    Update-SessionPath
}

function Get-NodeVersion {
    if (-not (Test-Command node)) { return $null }
    $raw = (& node --version) -replace '^v', ''
    try { return [version]$raw } catch { return $null }
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
Update-SessionPath

Write-Step 'Herramientas de IA'
if (Test-Command claude) { Write-Skip 'Claude Code ya estaba instalado' }
else { Invoke-RemoteInstaller 'Claude Code' $ClaudeCodeInstaller; Write-Ok 'Claude Code instalado' }

if (Test-Command gentle-ai) { Write-Skip 'Gentle AI ya estaba instalado' }
else { Invoke-RemoteInstaller 'Gentle AI' $GentleAiInstaller; Write-Ok 'Gentle AI instalado' }

if (Test-Command gentle-shell) {
    Write-Skip 'Gentle Shell ya estaba instalado'
} else {
    $node = Get-NodeVersion
    if (-not $DryRun -and (-not $node -or $node -lt $MinNodeVersion)) {
        throw "Gentle Shell necesita Node $MinNodeVersion o superior (hay: $node). Cierra la terminal, abre otra y repite."
    }
    Invoke-Action "npm install -g $($GentleShellPackages -join ' ')" {
        & npm install -g @GentleShellPackages
        if ($LASTEXITCODE -ne 0) { throw "npm no pudo instalar Gentle Shell (codigo $LASTEXITCODE)" }
    }
    Write-Ok 'Gentle Shell instalado'
}

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
Write-Host ''
Write-Host '    Siguientes pasos, en una terminal NUEVA:'
Write-Host '      - Reinicia el equipo si Docker Desktop lo pide (activa WSL 2) y abrelo una vez.'
Write-Host '      - claude          -> inicia sesion en Claude Code'
Write-Host '      - gentle-ai       -> configura los agentes (memoria, skills, persona)'
Write-Host '      - gentle-shell    -> abre Gentle Shell'
