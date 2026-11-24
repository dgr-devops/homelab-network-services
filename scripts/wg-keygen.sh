#!/usr/bin/env bash
# wg-keygen.sh — genera pares de claves WireGuard (y una clave precompartida) fuera del repositorio.
#
# Uso: wg-keygen.sh [-d DIR] [-p] [-h] nombre...
# Códigos de salida: 0 = generadas, 2 = no se pudo generar, 3 = falta `wg`, 64 = uso incorrecto.

set -euo pipefail

# readlink -f: permite ejecutar el script a través de un enlace simbólico.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<'EOF'
Uso: wg-keygen.sh [-d DIR] [-p] [-h] nombre...

Genera, para cada nombre (p. ej. server, laptop), un par de claves con `wg genkey` y `wg pubkey`:

  DIR/nombre.key   clave privada (modo 600)
  DIR/nombre.pub   clave pública

Solo se imprime por pantalla la clave PÚBLICA. La privada nunca sale por stdout ni por logs.

Opciones:
  -d DIR  Directorio de salida (por defecto ./keys, ignorado por git; se crea con modo 700)
  -p      Genera además DIR/preshared.key (clave precompartida, modo 600)
  -h      Muestra esta ayuda

No sobrescribe claves existentes: si ya existe un fichero, aborta antes de escribir nada.

Códigos de salida: 0 = generadas, 2 = no se pudo generar, 3 = falta `wg`, 64 = uso incorrecto.
EOF
}

# valid_name <nombre> — letras, números, guion y guion bajo (evita rutas y opciones camufladas).
valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

main() {
  local dir="./keys" preshared=false opt name
  while getopts ':d:ph' opt; do
    case "$opt" in
      d) dir="$OPTARG" ;;
      p) preshared=true ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  if (($# == 0)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi
  for name in "$@"; do
    valid_name "$name" || die "Nombre no válido: '${name}' (solo letras, números, - y _)" "$EXIT_USAGE"
  done
  require_cmd wg

  # Comprobación previa: nada se escribe si algún destino ya existe.
  local -a targets=()
  for name in "$@"; do targets+=("${dir}/${name}.key" "${dir}/${name}.pub"); done
  [[ "$preshared" == true ]] && targets+=("${dir}/preshared.key")
  local target
  for target in "${targets[@]}"; do
    [[ ! -e "$target" ]] || die "Ya existe ${target}; no se sobrescribe" "$EXIT_CRITICAL"
  done

  # umask 077 antes de crear nada: ningún fichero sensible existe ni un instante con permisos amplios.
  umask 077
  mkdir -p -- "$dir"
  chmod 700 -- "$dir"

  local private public
  for name in "$@"; do
    private="$(wg genkey)"
    public="$(printf '%s' "$private" | wg pubkey)"
    printf '%s\n' "$private" >"${dir}/${name}.key"
    printf '%s\n' "$public" >"${dir}/${name}.pub"
    printf '%-12s clave pública: %s\n' "$name" "$public"
  done
  if [[ "$preshared" == true ]]; then
    wg genpsk >"${dir}/preshared.key"
    printf '%-12s %s\n' "preshared" "generada en ${dir}/preshared.key"
  fi
  log_info "Claves privadas en ${dir} (modo 600). No las subas a git."
}

main "$@"
