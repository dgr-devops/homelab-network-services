#!/usr/bin/env bash
# deploy.sh — instala las configuraciones del homelab en un sistema (o en un directorio de pruebas).
#
# Uso: deploy.sh [-n] [-d] [-r RAIZ] [-c DIR] [-h] [componente...]
# Códigos de salida: 0 = desplegado, 1 = algún componente omitido, 2 = validación fallida o
#                    claves de ejemplo, 3 = desconocido, 64 = uso incorrecto.

set -euo pipefail

# readlink -f: permite ejecutar el script a través de un enlace simbólico.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly COMPONENTS=(dnsmasq unbound nftables wireguard)
# Validador sustituible (los tests usan un falso).
readonly VALIDATOR="${HOMELAB_VALIDATOR:-${SCRIPT_DIR}/validate.sh}"
# Texto base64 con el que empiezan TODAS las claves de ejemplo del repositorio («EXAMPLE-»).
readonly EXAMPLE_KEY_MARKER='RVhBTVBMRS1'

usage() {
  cat <<'EOF'
Uso: deploy.sh [-n] [-d] [-r RAIZ] [-c DIR] [-h] [componente...]

Instala las configuraciones en RAIZ (por defecto /) después de validarlas:

  dnsmasq    config/dnsmasq/homelab.conf    -> RAIZ/etc/dnsmasq.d/homelab.conf
  unbound    config/unbound/homelab.conf    -> RAIZ/etc/unbound/unbound.conf.d/homelab.conf
  nftables   config/nftables/homelab.nft    -> RAIZ/etc/nftables.d/homelab.nft
  wireguard  config/wireguard/wg0.conf      -> RAIZ/etc/wireguard/wg0.conf   (modo 600)

Sin componentes se despliegan los cuatro. Es seguro por diseño:
  - Valida antes de copiar y aborta si alguna configuración es inválida.
  - Hace copia de seguridad (fichero.bak-FECHA) de lo que vaya a sustituir.
  - No toca ficheros idénticos y NO reinicia servicios: al final indica qué ejecutar.
  - wireguard solo instala config/wireguard/wg0.conf (la real, ignorada por git) y se niega
    a instalar claves de ejemplo.

Opciones:
  -n, --dry-run  Muestra lo que haría sin cambiar nada
  -d             Usa Docker para validar lo que falte en el equipo (véase validate.sh -d)
  -r RAIZ        Instala bajo RAIZ en vez de / (para ensayar sin root: -r /tmp/prueba)
  -c DIR         Directorio de configuración (por defecto: config/ del repositorio)
  -h             Muestra esta ayuda

Códigos de salida: 0 = desplegado, 1 = algún componente omitido, 2 = validación fallida o
claves de ejemplo, 3 = desconocido, 64 = uso incorrecto.
EOF
}

DRY_RUN=false
VALIDATE_FLAGS=()
ROOT="/"
CONFIG_DIR="${SCRIPT_DIR}/../config"
SKIPPED=0
CHANGED=()

# install_file <origen> <destino> <modo> — copia con copia de seguridad; respeta --dry-run.
install_file() {
  local src="$1" dest="$2" mode="$3" stamp backup
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    printf '%-10s %s (sin cambios)\n' "IGUAL" "$dest"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '%-10s %s -> %s (modo %s)\n' "SIMULADO" "${src##*/}" "$dest" "$mode"
    CHANGED+=("$dest")
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    stamp="$(date '+%Y%m%d%H%M%S')"
    backup="${dest}.bak-${stamp}"
    cp -p -- "$dest" "$backup"
    printf '%-10s %s\n' "COPIA" "$backup"
  fi
  install -m "$mode" -- "$src" "$dest"
  printf '%-10s %s (modo %s)\n' "INSTALADO" "$dest" "$mode"
  CHANGED+=("$dest")
}

deploy_dnsmasq() {
  install_file "${CONFIG_DIR}/dnsmasq/homelab.conf" "${ROOT}/etc/dnsmasq.d/homelab.conf" 644
}

deploy_unbound() {
  install_file "${CONFIG_DIR}/unbound/homelab.conf" "${ROOT}/etc/unbound/unbound.conf.d/homelab.conf" 644
}

deploy_nftables() {
  install_file "${CONFIG_DIR}/nftables/homelab.nft" "${ROOT}/etc/nftables.d/homelab.nft" 644
}

deploy_wireguard() {
  local src="${CONFIG_DIR}/wireguard/wg0.conf"
  if [[ ! -f "$src" ]]; then
    log_warn "wireguard omitido: no existe wg0.conf en el directorio de configuración (genera claves con wg-keygen.sh y crea ese fichero a partir del .example)"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if grep -q "$EXAMPLE_KEY_MARKER" "$src"; then
    log_error "wireguard: wg0.conf contiene claves de EJEMPLO; no se instala"
    exit "$EXIT_CRITICAL"
  fi
  install_file "$src" "${ROOT}/etc/wireguard/wg0.conf" 600
}

# validate_selected <componente...> — aborta si la validación falla; avisa si no se pudo ejecutar.
# El validador revisa todos los *.conf* de wireguard, así que un wg0.conf real también se comprueba.
validate_selected() {
  local rc=0
  "$VALIDATOR" "${VALIDATE_FLAGS[@]}" -c "$CONFIG_DIR" "$@" >&2 || rc=$?
  case "$rc" in
    0) ;;
    1) log_warn "Validación incompleta (falta alguna herramienta): se continúa bajo tu responsabilidad" ;;
    *) die "La validación ha fallado: no se despliega nada" "$EXIT_CRITICAL" ;;
  esac
}

main() {
  local opt item known component
  local -a args=()
  for item in "$@"; do
    [[ "$item" == "--dry-run" ]] && item="-n"
    args+=("$item")
  done
  set -- "${args[@]}"

  while getopts ':ndr:c:h' opt; do
    case "$opt" in
      n) DRY_RUN=true ;;
      d) VALIDATE_FLAGS+=(-d) ;;
      r) ROOT="$OPTARG" ;;
      c) CONFIG_DIR="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -d "$CONFIG_DIR" ]] || die "No existe el directorio de configuración: ${CONFIG_DIR}" "$EXIT_USAGE"
  ROOT="${ROOT%/}"

  local -a selected=("$@")
  ((${#selected[@]} > 0)) || selected=("${COMPONENTS[@]}")
  for item in "${selected[@]}"; do
    known=false
    for component in "${COMPONENTS[@]}"; do
      [[ "$item" == "$component" ]] && known=true
    done
    if [[ "$known" == false ]]; then
      log_error "Componente desconocido: ${item} (válidos: ${COMPONENTS[*]})"
      exit "$EXIT_USAGE"
    fi
  done

  validate_selected "${selected[@]}"

  for item in "${selected[@]}"; do
    case "$item" in
      dnsmasq) deploy_dnsmasq ;;
      unbound) deploy_unbound ;;
      nftables) deploy_nftables ;;
      wireguard) deploy_wireguard ;;
    esac
  done

  if [[ "$DRY_RUN" == true ]]; then
    log_info "Simulación: no se ha cambiado nada"
  elif ((${#CHANGED[@]} > 0)); then
    log_info "Siguiente paso (no se ha reiniciado nada): systemctl restart dnsmasq unbound; nft -f ${ROOT}/etc/nftables.d/homelab.nft; systemctl restart wg-quick@wg0"
  fi
  ((SKIPPED == 0)) || exit "$EXIT_WARNING"
  exit "$EXIT_OK"
}

main "$@"
