#!/usr/bin/env bash
# configurar-admin.sh - Deja la tailnet y la organizacion listas para el alta de equipos.
#
# Lo ejecuta el ADMINISTRADOR de la tailnet, una vez:
#   curl -fsSL https://raw.githubusercontent.com/Network-IA-Solutions/alta-de-equipos/main/configurar-admin.sh | bash
#
# Que hace:
#   1. Lee la politica de Tailscale actual y guarda un respaldo en tu carpeta personal.
#   2. Le agrega la etiqueta tag:equipo: los equipos nuevos solo llegan a la unidad
#      compartida (445) y al panel de Proxmox (8006). Las personas siguen como hoy.
#   3. Valida la politica con Tailscale, te muestra los cambios y solo guarda si escribes "si".
#   4. Crea una auth key reutilizable con tag:equipo y te la muestra una vez.
#   5. Opcional: invita a una persona a la organizacion de GitHub (necesita gh y ser admin).
#
# Necesita: curl, python 3 y un token de API de Tailscale
#   (https://login.tailscale.com/admin/settings/keys -> Generate access token).
#
# Variables opcionales:
#   DRY_RUN=1         valida y muestra los cambios, pero no guarda nada ni crea la clave
#   KEY_DAYS=30       dias de vigencia de la auth key (1-90)
#   GITHUB_ORG=...    organizacion de GitHub (por defecto Network-IA-Solutions)
#
# Prueba local de la mezcla, sin red:  configurar-admin.sh --solo-mezclar politica.json
set -euo pipefail

API="https://api.tailscale.com/api/v2/tailnet/-"
DRY_RUN="${DRY_RUN:-0}"
KEY_DAYS="${KEY_DAYS:-30}"
GITHUB_ORG="${GITHUB_ORG:-Network-IA-Solutions}"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$1"; }
warn() { printf '    \033[33m!!\033[0m  %s\n' "$1"; }
die()  { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

ask() {   # ask <variable> <texto> [secreto]
  local __var="$1" __prompt="$2" __secret="${3:-}" __value=""
  [[ -r /dev/tty ]] || die "No hay terminal para preguntar. Ejecutalo desde una terminal interactiva."
  printf '    %s' "$__prompt" > /dev/tty
  if [[ -n "$__secret" ]]; then IFS= read -rs __value < /dev/tty || true; printf '\n' > /dev/tty
  else IFS= read -r __value < /dev/tty || true; fi
  printf -v "$__var" '%s' "$__value"
}

find_python() {
  local c
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' >/dev/null 2>&1; then
      echo "$c"; return
    fi
  done
}

# En Git Bash de Windows, python no entiende rutas /tmp/...: se convierten.
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

PY="$(find_python)"
[[ -n "$PY" ]] || die "Falta Python 3."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------- mezcla (python)
cat > "$WORK/merge.py" <<'PYEOF'
import difflib, json, sys

TAG = "tag:equipo"
HOSTS = {
    "nas-archivos": "100.75.16.110",
    "proxmox-r630": "100.99.232.33",
    "proxmox-t40": "100.93.21.6",
    "proxmox-optiplex": "100.84.231.111",
}
PROXMOX = ["proxmox-r630", "proxmox-t40", "proxmox-optiplex"]
ACL_RULES = [
    {"action": "accept", "src": [TAG], "dst": ["nas-archivos:445"]},
    {"action": "accept", "src": [TAG], "dst": [h + ":8006" for h in PROXMOX]},
]
GRANT_RULES = [
    {"src": [TAG], "dst": ["nas-archivos"], "ip": ["tcp:445"]},
    {"src": [TAG], "dst": PROXMOX, "ip": ["tcp:8006"]},
]

def merge(policy):
    changes = []
    p = json.loads(json.dumps(policy))

    owners = p.setdefault("tagOwners", {})
    if TAG not in owners:
        owners[TAG] = ["autogroup:admin"]
        changes.append("tagOwners: se crea %s (dueno: autogroup:admin)" % TAG)

    hosts = p.setdefault("hosts", {})
    for name, ip in HOSTS.items():
        if name in hosts and hosts[name] != ip:
            raise SystemExit("El host '%s' ya existe con otra IP (%s). Revisa la politica a mano." % (name, hosts[name]))
        if name not in hosts:
            hosts[name] = ip
            changes.append("hosts: %s = %s" % (name, ip))

    has_acls, has_grants = "acls" in p, "grants" in p
    if not has_acls and not has_grants:
        raise SystemExit("La politica no tiene 'acls' ni 'grants'. Revisala a mano antes de seguir.")

    for section in ("acls", "grants"):
        for i, rule in enumerate(p.get(section, [])):
            src = rule.get("src", [])
            if "*" in src:
                rule["src"] = ["autogroup:member" if s == "*" else s for s in src]
                changes.append('%s[%d]: src "*" pasa a "autogroup:member" (las personas siguen igual; los equipos etiquetados ya no)' % (section, i))

    section, rules = ("acls", ACL_RULES) if has_acls else ("grants", GRANT_RULES)
    for rule in rules:
        if rule not in p[section]:
            p[section].append(rule)
            changes.append("%s: nueva regla %s -> %s" % (section, TAG, ", ".join(rule["dst"])))

    for i, rule in enumerate(p.get("ssh", [])):
        if "*" in rule.get("src", []):
            print('AVISO: ssh[%d] usa src "*". Revisa si los equipos nuevos deben tener SSH.' % i, file=sys.stderr)

    return p, changes

def main():
    src, out, summary, diff = sys.argv[1:5]
    with open(src, encoding="utf-8") as f:
        policy = json.load(f)
    new, changes = merge(policy)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(new, f, indent=2, ensure_ascii=False)
    with open(summary, "w", encoding="utf-8") as f:
        f.write("\n".join(changes) + ("\n" if changes else ""))
    a = json.dumps(policy, indent=2, ensure_ascii=False, sort_keys=True).splitlines()
    b = json.dumps(new, indent=2, ensure_ascii=False, sort_keys=True).splitlines()
    with open(diff, "w", encoding="utf-8") as f:
        f.write("\n".join(difflib.unified_diff(a, b, "politica actual", "politica nueva", lineterm="")) + "\n")

main()
PYEOF

run_merge() {   # run_merge <entrada.json>  -> $WORK/new.json, summary.txt, diff.txt
  "$PY" "$(native_path "$WORK/merge.py")" "$(native_path "$1")" \
    "$(native_path "$WORK/new.json")" "$(native_path "$WORK/summary.txt")" "$(native_path "$WORK/diff.txt")"
}

if [[ "${1:-}" == "--solo-mezclar" ]]; then
  [[ -f "${2:-}" ]] || die "Uso: $0 --solo-mezclar politica.json"
  run_merge "$2"
  cat "$WORK/summary.txt"; echo "---"; cat "$WORK/new.json"; echo
  exit 0
fi

# ---------------------------------------------------------------- api helpers
TS_TOKEN=""
ts_api() {   # ts_api <metodo> <ruta> <salida> [cuerpo] [cabecera-extra]  -> imprime codigo HTTP
  local method="$1" path="$2" out="$3" body="${4:-}" extra="${5:-}"
  local args=(-sS -X "$method" -o "$out" -D "$WORK/headers" -w '%{http_code}' "$API$path")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data-binary "@$body")
  [[ -n "$extra" ]] && args+=(-H "$extra")
  # El token va por la configuracion de curl (stdin), no por la linea de comandos.
  printf 'header = "Authorization: Bearer %s"\n' "$TS_TOKEN" | curl -K - "${args[@]}"
}

# ----------------------------------------------------------------------- main
command -v curl >/dev/null 2>&1 || die "Falta curl."
[[ "$KEY_DAYS" =~ ^[0-9]+$ ]] && (( KEY_DAYS >= 1 && KEY_DAYS <= 90 )) || die "KEY_DAYS debe estar entre 1 y 90."
[[ "$DRY_RUN" == "1" ]] && printf '\033[33mModo DRY_RUN: no se guarda nada ni se crea la clave.\033[0m\n'

step "Token de API de Tailscale"
printf '    Se crea en https://login.tailscale.com/admin/settings/keys -> Generate access token\n'
ask TS_TOKEN "Pega el token (no se ve al escribir): " secret
[[ "$TS_TOKEN" == tskey-api-* ]] || die "Eso no parece un token de API (empieza por tskey-api-)."

step "Politica actual"
code="$(ts_api GET /acl "$WORK/current.json" "" "Accept: application/json")"
[[ "$code" == "200" ]] || die "Tailscale respondio $code al leer la politica: $(cat "$WORK/current.json")"
etag="$(grep -i '^etag:' "$WORK/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')"
[[ -n "$etag" ]] || die "Tailscale no devolvio ETag; no se puede guardar sin riesgo de pisar otro cambio."

backup="$HOME/tailscale-politica-respaldo-$(date +%Y%m%d-%H%M%S).hujson"
code="$(ts_api GET /acl "$backup" "" "Accept: application/hujson")"
[[ "$code" == "200" ]] || die "No se pudo guardar el respaldo (HTTP $code)."
ok "respaldo con comentarios: $backup"

step "Cambios propuestos"
run_merge "$WORK/current.json"
if [[ ! -s "$WORK/summary.txt" ]]; then
  ok "la politica ya tenia todo: no hay nada que cambiar"
  policy_changed=0
else
  policy_changed=1
  sed 's/^/    - /' "$WORK/summary.txt"
  warn "La politica se guarda como JSON: los comentarios actuales se pierden (siguen en el respaldo)."
  printf '\n    Diferencias completas:\n'
  sed 's/^/      /' "$WORK/diff.txt"
fi

if (( policy_changed )); then
  step "Validacion con Tailscale"
  code="$(ts_api POST /acl/validate "$WORK/validate.json" "$WORK/new.json")"
  [[ "$code" == "200" ]] || die "La validacion fallo (HTTP $code): $(cat "$WORK/validate.json")"
  msg="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("message", ""))' "$(native_path "$WORK/validate.json")" 2>/dev/null || true)"
  [[ -z "$msg" ]] || die "Tailscale rechaza la politica: $msg"
  ok "Tailscale acepta la politica nueva"

  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY_RUN: no se guarda la politica"
  else
    ask answer 'Escribe "si" para guardar la politica nueva: '
    [[ "$answer" == "si" || "$answer" == "sí" ]] || die "Cancelado. No se cambio nada."
    code="$(ts_api POST /acl "$WORK/saved.json" "$WORK/new.json" "If-Match: $etag")"
    [[ "$code" == "200" ]] || die "No se pudo guardar (HTTP $code): $(cat "$WORK/saved.json"). Si fue 412, alguien cambio la politica mientras tanto: vuelve a ejecutar."
    ok "politica guardada"
  fi
fi

step "Auth key para los equipos nuevos"
if [[ "$DRY_RUN" == "1" ]]; then
  warn "DRY_RUN: no se crea la clave"
elif (( policy_changed )) || grep -q '"tag:equipo"' "$WORK/current.json"; then
  cat > "$WORK/key-request.json" <<EOF
{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":false,"preauthorized":true,"tags":["tag:equipo"]}}},"expirySeconds":$(( KEY_DAYS * 86400 )),"description":"alta-de-equipos"}
EOF
  code="$(ts_api POST /keys "$WORK/key.json" "$WORK/key-request.json")"
  [[ "$code" == "200" ]] || die "No se pudo crear la clave (HTTP $code): $(cat "$WORK/key.json")"
  key="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["key"])' "$(native_path "$WORK/key.json")")"
  ok "clave creada (vence en $KEY_DAYS dias, reutilizable, con tag:equipo)"
  printf '\n    \033[1m%s\033[0m\n\n' "$key"
  warn "Guardala en el gestor de contrasenas y compartela por ahi. Esta es la unica vez que se muestra."
  key=""
fi

step "Invitacion a la organizacion de GitHub ($GITHUB_ORG)"
if ! command -v gh >/dev/null 2>&1; then
  warn "gh no esta instalado: se salta. Se puede invitar desde https://github.com/orgs/$GITHUB_ORG/people"
else
  ask email "Correo de la persona a invitar (Enter para saltar): "
  if [[ -z "$email" ]]; then
    ok "sin invitacion"
  elif [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY_RUN: no se envia la invitacion a $email"
  else
    me="$(gh api user --jq .login)"
    role="$(gh api "orgs/$GITHUB_ORG/memberships/$me" --jq .role 2>/dev/null || true)"
    if [[ "$role" != "admin" ]]; then
      warn "$me no es admin de $GITHUB_ORG: no puede invitar. Lo hace un admin desde https://github.com/orgs/$GITHUB_ORG/people"
    else
      gh api --method POST "orgs/$GITHUB_ORG/invitations" -f email="$email" -f role=direct_member --jq '"    ok  invitacion enviada a \(.email)"'
    fi
  fi
fi

TS_TOKEN=""
step "Listo"
printf '    En cada equipo nuevo se ejecuta el comando del README y se pega la auth key.\n'
printf '    El token de API ya no hace falta: se puede revocar en la misma pagina de claves.\n'
