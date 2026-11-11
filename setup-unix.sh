#!/usr/bin/env bash
# setup-unix.sh - Alta de un equipo Linux o macOS en la red de Network Solutions.
#
# Que hace, en orden:
#   1. Instala los programas base (apt/dnf/pacman en Linux, Homebrew en macOS).
#   2. Instala Tailscale y une el equipo a la tailnet.
#   3. Crea en el escritorio los accesos directos (Google, Proxmox, unidad compartida).
#
# Uso (como usuario normal; pide sudo cuando lo necesita):
#   curl -fsSL <URL>/setup-unix.sh | bash
#
# La clave de Tailscale (auth key) se pide por pantalla y no queda en el historial.
# Para automatizar sin preguntas: curl -fsSL <URL>/setup-unix.sh | TS_AUTHKEY=tskey-auth-... bash
# Para ver que haria sin cambiar nada: ... | DRY_RUN=1 bash
#
# Este script NO contiene secretos: se puede publicar.
set -euo pipefail

# ---------------------------------------------------------------- configuracion
LINUX_PACKAGES=(git curl)
MAC_FORMULAE=(git)
MAC_CASKS=(google-chrome visual-studio-code)

SHARE_URL="smb://100.75.16.110/Archivos"
SHORTCUT_NAMES=("Google" "Proxmox - R630" "Proxmox - T40" "Proxmox - OptiPlex")
SHORTCUT_URLS=("https://www.google.com" "https://100.99.232.33:8006" "https://100.93.21.6:8006" "https://100.84.231.111:8006")
# ------------------------------------------------------------------------------

DRY_RUN="${DRY_RUN:-0}"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$1"; }
skip() { printf '    \033[90m--  %s\033[0m\n' "$1"; }
die()  { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    \033[33m[dry-run]\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi

OS="$(uname -s)"
case "$OS" in
  Linux)  PLATFORM=linux ;;
  Darwin) PLATFORM=mac ;;
  *) die "Sistema no soportado: $OS. En Windows usa setup-windows.ps1." ;;
esac

# ------------------------------------------------------------------ programas
install_linux_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    run $SUDO apt-get update -y
    run $SUDO apt-get install -y "${LINUX_PACKAGES[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    run $SUDO dnf install -y "${LINUX_PACKAGES[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    run $SUDO pacman -Sy --needed --noconfirm "${LINUX_PACKAGES[@]}"
  else
    die "No se encontro apt, dnf ni pacman. Instala a mano: ${LINUX_PACKAGES[*]}"
  fi
  ok "paquetes: ${LINUX_PACKAGES[*]}"
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then skip "Homebrew ya estaba instalado"; return; fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then eval "$("$candidate" shellenv)"; skip "Homebrew ya estaba instalado"; return; fi
  done
  run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ "$DRY_RUN" != "1" ]]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [[ -x "$candidate" ]]; then eval "$("$candidate" shellenv)"; fi
    done
  fi
  ok "Homebrew instalado"
}

install_mac_packages() {
  ensure_homebrew
  for f in "${MAC_FORMULAE[@]}"; do
    if [[ "$DRY_RUN" != "1" ]] && brew list --formula "$f" >/dev/null 2>&1; then skip "$f ya estaba instalado"; continue; fi
    run brew install "$f"; ok "$f"
  done
  for c in "${MAC_CASKS[@]}"; do
    if [[ "$DRY_RUN" != "1" ]] && brew list --cask "$c" >/dev/null 2>&1; then skip "$c ya estaba instalado"; continue; fi
    run brew install --cask "$c"; ok "$c"
  done
}

# ------------------------------------------------------------------ tailscale
tailscale_cli() {
  if [[ "$PLATFORM" == "mac" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  elif command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
  fi
}

install_tailscale() {
  if [[ -n "$(tailscale_cli)" ]]; then skip "Tailscale ya estaba instalado"; return; fi
  if [[ "$PLATFORM" == "linux" ]]; then
    run sh -c "curl -fsSL https://tailscale.com/install.sh | sh"
  else
    run brew install --cask tailscale
    run open -a Tailscale
  fi
  ok "Tailscale instalado"
}

read_auth_key() {
  if [[ -n "${TS_AUTHKEY:-}" ]]; then printf '%s' "$TS_AUTHKEY"; return; fi
  # stdin es el propio script cuando se usa "curl | bash": se lee de la terminal.
  if [[ -r /dev/tty ]]; then
    printf '    Pega la auth key de Tailscale (Enter vacio = iniciar sesion en el navegador): ' > /dev/tty
    local key=""
    IFS= read -rs key < /dev/tty || true
    printf '\n' > /dev/tty
    printf '%s' "$key"
  fi
}

join_tailnet() {
  local ts; ts="$(tailscale_cli)"
  if [[ -z "$ts" && "$DRY_RUN" != "1" ]]; then die "No se encuentra el comando tailscale tras instalarlo."; fi
  ts="${ts:-tailscale}"

  if [[ "$DRY_RUN" != "1" ]] && "$ts" status >/dev/null 2>&1; then
    skip "el equipo ya esta conectado a la tailnet"; return
  fi

  local host; host="$(hostname -s 2>/dev/null || hostname)"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  local key=""
  if [[ "$DRY_RUN" != "1" ]]; then key="$(read_auth_key)"; fi

  local ts_sudo="$SUDO"
  if [[ "$PLATFORM" == "mac" ]]; then ts_sudo=""; fi

  if [[ "$DRY_RUN" == "1" ]]; then
    run "$ts" up --hostname="$host"
  elif [[ -n "$key" ]]; then
    $ts_sudo "$ts" up --authkey="$key" --hostname="$host"
  else
    $ts_sudo "$ts" up --hostname="$host"
  fi
  key=""
  ok "conectado como $host"
}

# ---------------------------------------------------------- accesos directos
desktop_dir() {
  local d=""
  if [[ "$PLATFORM" == "linux" ]] && command -v xdg-user-dir >/dev/null 2>&1; then d="$(xdg-user-dir DESKTOP)"; fi
  if [[ -z "$d" || "$d" == "$HOME" ]]; then d="$HOME/Desktop"; fi
  printf '%s' "$d"
}

write_shortcut() {
  local dir="$1" name="$2" url="$3"
  if [[ "$DRY_RUN" == "1" ]]; then run "acceso directo $name -> $url"; return; fi
  if [[ "$PLATFORM" == "mac" ]]; then
    cat > "$dir/$name.webloc" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>URL</key><string>$url</string></dict></plist>
EOF
  else
    local file="$dir/$name.desktop"
    cat > "$file" <<EOF
[Desktop Entry]
Type=Link
Name=$name
URL=$url
Icon=folder-remote
EOF
    chmod +x "$file"
    if command -v gio >/dev/null 2>&1; then gio set "$file" metadata::trusted true 2>/dev/null || true; fi
  fi
  ok "$name"
}

create_shortcuts() {
  local dir; dir="$(desktop_dir)"
  run mkdir -p "$dir"
  local i
  for i in "${!SHORTCUT_NAMES[@]}"; do
    write_shortcut "$dir" "${SHORTCUT_NAMES[$i]}" "${SHORTCUT_URLS[$i]}"
  done
  write_shortcut "$dir" "Unidad compartida" "$SHARE_URL"
}

# ----------------------------------------------------------------------- main
if [[ "$DRY_RUN" == "1" ]]; then printf '\033[33mModo DRY_RUN: no se cambia nada.\033[0m\n'; fi

step "Programas base ($PLATFORM)"
if [[ "$PLATFORM" == "linux" ]]; then install_linux_packages; else install_mac_packages; fi

step "Tailscale"
install_tailscale
if [[ "$PLATFORM" == "mac" ]]; then
  printf '    macOS pedira permitir la configuracion VPN de Tailscale una vez: aceptala.\n'
fi
join_tailnet

step "Accesos directos en el escritorio"
create_shortcuts

step "Listo"
printf '    Proxmox usa un certificado propio: el navegador avisara la primera vez, es esperado.\n'
printf '    La invitacion a la organizacion la hace un administrador (ver ADMIN.md).\n'
