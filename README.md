# Alta de equipos — Network Solutions

Un solo comando deja un equipo listo: programas instalados, dentro de la red por Tailscale y con
los accesos directos a Google, Proxmox y la unidad compartida en el escritorio.

> **Antes del primer uso**, el administrador de la tailnet ejecuta una vez, en Linux, macOS o
> Git Bash:
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/Network-IA-Solutions/alta-de-equipos/main/configurar-admin.sh | bash
> ```
>
> Pide un token de API de Tailscale, ajusta la política (con respaldo, validación y confirmación),
> crea la auth key para los equipos y, opcionalmente, invita a la persona a GitHub.

## El comando

**Windows** — PowerShell **como administrador**:

```powershell
irm https://raw.githubusercontent.com/Network-IA-Solutions/alta-de-equipos/main/setup-windows.ps1 | iex
```

**Linux y macOS** — terminal normal (pide `sudo` cuando lo necesita):

```bash
curl -fsSL https://raw.githubusercontent.com/Network-IA-Solutions/alta-de-equipos/main/setup-unix.sh | bash
```

El script pide la **auth key de Tailscale** que entrega el administrador. Se escribe a ciegas y no
queda en el historial.

## Qué hace

| Paso | Windows | Linux | macOS |
|---|---|---|---|
| Programas base | winget: Chrome, Git, VS Code, 7-Zip | apt / dnf / pacman: git, curl | Homebrew: git, Chrome, VS Code |
| Tailscale | winget + `tailscale up --unattended` | instalador oficial + `tailscale up` | Homebrew cask + `tailscale up` |
| Accesos directos | `.url` y `.lnk` en el escritorio | `.desktop` en el escritorio | `.webloc` en el escritorio |

Accesos directos creados:

| Nombre | Destino |
|---|---|
| Google | `https://www.google.com` |
| Proxmox - R630 | `https://100.99.232.33:8006` |
| Proxmox - T40 | `https://100.93.21.6:8006` |
| Proxmox - OptiPlex | `https://100.84.231.111:8006` |
| Unidad compartida | `\\100.75.16.110\Archivos` (`smb://` en Linux y macOS) |

Se puede ejecutar varias veces: lo que ya está instalado o conectado se salta.

**Lo que no hace:** invitar a la persona a la organización. Eso necesita permisos de
administrador y está en `ADMIN.md`, paso 4.

## Opciones

| Variable | Efecto |
|---|---|
| `DRY_RUN=1` | Muestra lo que haría sin cambiar nada |
| `TS_AUTHKEY=tskey-auth-...` | Usa esa clave sin preguntar (para automatizar; queda en el historial) |

```powershell
$env:DRY_RUN = '1'; irm https://raw.githubusercontent.com/Network-IA-Solutions/alta-de-equipos/main/setup-windows.ps1 | iex
```

```bash
curl -fsSL https://raw.githubusercontent.com/Network-IA-Solutions/alta-de-equipos/main/setup-unix.sh | DRY_RUN=1 bash
```

## Cambiar la lista de programas o accesos

Al principio de cada script hay un bloque `configuracion`. Se edita ahí y se vuelve a publicar.
Los IDs de Windows se buscan con `winget search <nombre>`.

## Avisos esperados

- **Proxmox** usa un certificado propio: el navegador avisa la primera vez.
- **macOS** pide una vez permitir la configuración VPN de Tailscale.
- La **unidad compartida** puede pedir usuario y contraseña de Samba al abrirla.

## Archivos

| Archivo | Para quién |
|---|---|
| `setup-windows.ps1` | el equipo nuevo (Windows) |
| `setup-unix.sh` | el equipo nuevo (Linux y macOS) |
| `configurar-admin.sh` | el administrador: política, auth key e invitación, en un comando |
| `ADMIN.md` | el administrador: los mismos pasos a mano (en la unidad compartida) |
| `tailscale-acl.hujson` | el administrador: política de Tailscale propuesta |
| `invitar-a-la-organizacion.sh` | el administrador: invitar a GitHub |
