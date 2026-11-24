#!/usr/bin/env bash
# validate.sh — valida las configuraciones del homelab con las herramientas reales, sin aplicarlas.
#
# Uso: validate.sh [-d] [-c DIR] [-h] [componente...]
# Códigos de salida: 0 = todo válido, 1 = hay componentes sin validar (falta la herramienta),
#                    2 = alguna configuración es inválida, 64 = uso incorrecto.

set -euo pipefail

# readlink -f: permite ejecutar el script a través de un enlace simbólico.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly COMPONENTS=(nftables dnsmasq unbound wireguard)
readonly DOCKER_IMAGE="${HOMELAB_DOCKER_IMAGE:-alpine:3.20}"

usage() {
  cat <<'EOF'
Uso: validate.sh [-d] [-c DIR] [-h] [componente...]

Comprueba la sintaxis de las configuraciones con la herramienta de cada servicio,
sin aplicar nada ni tocar el sistema:

  nftables   nft -c -f            (sin root, dentro de un espacio de nombres de usuario/red)
  dnsmasq    dnsmasq --test -C
  unbound    unbound-checkconf
  wireguard  wg-quick strip + wg setconf en un netns desechable (comprueba claves y rangos)

Sin componentes se validan los cuatro.

Opciones:
  -d      Si falta una herramienta en el equipo, usa un contenedor Docker (imagen alpine,
          variable HOMELAB_DOCKER_IMAGE) para unbound y wireguard. Necesita red la primera vez.
  -c DIR  Directorio de configuración (por defecto: config/ del repositorio)
  -h      Muestra esta ayuda

Códigos de salida: 0 = todo válido, 1 = hay componentes sin validar (falta la herramienta),
2 = alguna configuración es inválida, 64 = uso incorrecto.
EOF
}

USE_DOCKER=false
CONFIG_DIR="${SCRIPT_DIR}/../config"
FAILED=0
SKIPPED=0
LAST_OUTPUT=""

# report <componente> <OK|FAIL|SKIP> <detalle> — una línea por resultado.
report() {
  printf '%-5s %-10s %s\n' "$2" "$1" "$3"
  case "$2" in
    FAIL)
      FAILED=$((FAILED + 1))
      if [[ -n "$LAST_OUTPUT" ]]; then
        printf '%s\n' "$LAST_OUTPUT" | sed 's/^/        /'
      fi
      ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
  esac
  return 0
}

# run_check <componente> <detalle> <comando...> — ejecuta y traduce el resultado.
run_check() {
  local component="$1" detail="$2"
  shift 2
  if LAST_OUTPUT="$("$@" 2>&1)"; then
    LAST_OUTPUT=""
    report "$component" OK "$detail"
  else
    report "$component" FAIL "$detail"
  fi
}

# rel <ruta> — ruta relativa al directorio de configuración (salida sin rutas personales).
rel() {
  printf '%s' "${1#"${CONFIG_DIR}"/}"
}

# docker_ready — verdadero si se puede usar Docker como alternativa.
docker_ready() {
  [[ "$USE_DOCKER" == true ]] && have_cmd docker
}

validate_nftables() {
  local file="${CONFIG_DIR}/nftables/homelab.nft"
  [[ -r "$file" ]] || { report nftables FAIL "no existe ${file}"; return 0; }
  if ! have_cmd nft; then
    report nftables SKIP "falta nft (paquete nftables)"
    return 0
  fi
  if ((EUID == 0)); then
    run_check nftables "$(rel "$file")" nft -c -f "$file"
  elif have_cmd unshare; then
    # Sin root: un netns de usuario permite a `nft -c` hablar con el kernel sin tocar el cortafuegos real.
    run_check nftables "$(rel "$file") (netns de usuario)" unshare -rn nft -c -f "$file"
  else
    report nftables SKIP "sin root y sin unshare"
  fi
}

validate_dnsmasq() {
  local file="${CONFIG_DIR}/dnsmasq/homelab.conf"
  [[ -r "$file" ]] || { report dnsmasq FAIL "no existe ${file}"; return 0; }
  if ! have_cmd dnsmasq; then
    report dnsmasq SKIP "falta dnsmasq"
    return 0
  fi
  run_check dnsmasq "$(rel "$file")" dnsmasq --test -C "$file"
}

validate_unbound() {
  local dir="${CONFIG_DIR}/unbound" file="${CONFIG_DIR}/unbound/homelab.conf"
  [[ -r "$file" ]] || { report unbound FAIL "no existe ${file}"; return 0; }
  if have_cmd unbound-checkconf; then
    run_check unbound "$(rel "$file")" unbound-checkconf "$file"
  elif docker_ready; then
    run_check unbound "$(rel "$file") (Docker ${DOCKER_IMAGE})" docker run --rm -v "$(realpath "$dir"):/c:ro" \
      "$DOCKER_IMAGE" sh -c 'apk add -q --no-cache unbound >/dev/null && unbound-checkconf /c/homelab.conf'
  else
    report unbound SKIP "falta unbound-checkconf (usa -d para Docker)"
  fi
}

# SC2016: las comillas simples son intencionadas; el fragmento se expande en el `sh` hijo.
# shellcheck disable=SC2016
# Fragmento que se ejecuta con sh: copia el fichero con nombre de interfaz válido, lo despoja de
# las opciones de wg-quick y lo carga en una interfaz WireGuard recién creada en un netns desechable.
readonly WG_SNIPPET='
tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
cp "$1" "$tmp/wgchk.conf"; chmod 600 "$tmp/wgchk.conf"
wg-quick strip "$tmp/wgchk.conf" >"$tmp/stripped.conf"
ip link add wgchk type wireguard
wg setconf wgchk "$tmp/stripped.conf"'

validate_wireguard() {
  local dir="${CONFIG_DIR}/wireguard" file mode=""
  local -a files=()
  while IFS= read -r file; do files+=("$file"); done < <(find "$dir" -maxdepth 1 -type f -name '*.conf*' | sort)
  if ((${#files[@]} == 0)); then
    report wireguard FAIL "sin ficheros .conf en ${dir}"
    return 0
  fi

  # Como root basta un netns (-n); sin root hace falta además un espacio de nombres de usuario (-r).
  local unshare_flags=-rn
  ((EUID != 0)) || unshare_flags=-n
  if have_cmd wg-quick && have_cmd wg && have_cmd ip && have_cmd unshare; then
    mode=native
  elif docker_ready; then
    mode=docker
  fi
  for file in "${files[@]}"; do
    case "$mode" in
      native) run_check wireguard "${file##*/}" unshare "$unshare_flags" sh -c "$WG_SNIPPET" sh "$file" ;;
      docker)
        run_check wireguard "${file##*/} (Docker ${DOCKER_IMAGE})" docker run --rm --cap-add NET_ADMIN \
          -v "$(realpath "$dir"):/c:ro" "$DOCKER_IMAGE" \
          sh -c "apk add -q --no-cache wireguard-tools >/dev/null; $WG_SNIPPET" sh "/c/${file##*/}"
        ;;
      *) report wireguard SKIP "${file##*/}: falta wg-quick (usa -d para Docker)" ;;
    esac
  done
}

main() {
  local opt item component known
  while getopts ':dc:h' opt; do
    case "$opt" in
      d) USE_DOCKER=true ;;
      c) CONFIG_DIR="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -d "$CONFIG_DIR" ]] || die "No existe el directorio de configuración: ${CONFIG_DIR}" "$EXIT_USAGE"
  CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"

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

  for item in "${selected[@]}"; do
    case "$item" in
      nftables) validate_nftables ;;
      dnsmasq) validate_dnsmasq ;;
      unbound) validate_unbound ;;
      wireguard) validate_wireguard ;;
    esac
  done

  if ((FAILED > 0)); then
    log_error "${FAILED} comprobación(es) fallida(s)"
    exit "$EXIT_CRITICAL"
  fi
  if ((SKIPPED > 0)); then
    log_warn "${SKIPPED} comprobación(es) sin ejecutar por falta de herramientas"
    exit "$EXIT_WARNING"
  fi
  exit "$EXIT_OK"
}

main "$@"
