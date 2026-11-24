#!/usr/bin/env bash
# lib/common.sh — funciones compartidas por los scripts de homelab-network-services.
# Se carga con: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# No se ejecuta directamente.

# Librería: las constantes se usan desde los scripts que la cargan.
# shellcheck disable=SC2034

# Códigos de salida estándar (compatibles con los plugins de Nagios).
readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_UNKNOWN=3
readonly EXIT_USAGE=64

# Colores solo si la salida es una terminal y NO_COLOR no está definido.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly C_RED=$'\033[31m' C_YELLOW=$'\033[33m' C_RESET=$'\033[0m'
else
  readonly C_RED="" C_YELLOW="" C_RESET=""
fi

# log <nivel> <mensaje...> — escribe en stderr con marca de hora.
log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

log_info() { log INFO "$*"; }
log_warn() { log "${C_YELLOW}WARN${C_RESET}" "$*"; }
log_error() { log "${C_RED}ERROR${C_RESET}" "$*"; }

# die <mensaje> [código] — error fatal: muestra el mensaje y sale.
die() {
  log_error "$1"
  exit "${2:-1}"
}

# have_cmd <comando> — verdadero si el comando existe.
have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# require_cmd <comando...> — aborta con EXIT_UNKNOWN si falta alguna dependencia.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    have_cmd "$cmd" || die "Falta el comando requerido: $cmd" "$EXIT_UNKNOWN"
  done
}

# is_uint <valor> — verdadero si es un entero no negativo.
is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}
