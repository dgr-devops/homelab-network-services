#!/usr/bin/env bash
# check-dns.sh — comprueba que un servidor DNS resuelve los nombres esperados (estilo Nagios).
#
# Uso: check-dns.sh [-s SERVIDOR] [-p PUERTO] [-t SEGUNDOS] [-h] nombre[=ip]...
# Códigos de salida: 0 = todo correcto, 1 = respuesta distinta de la esperada,
#                    2 = sin respuesta, 3 = falta dig, 64 = uso incorrecto.

set -euo pipefail

# readlink -f: permite ejecutar el script a través de un enlace simbólico.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<'EOF'
Uso: check-dns.sh [-s SERVIDOR] [-p PUERTO] [-t SEGUNDOS] [-h] nombre[=ip]...

Pregunta con `dig` a un servidor DNS por cada nombre. Con `nombre=ip` exige esa respuesta
exacta; sin `=ip` basta con que el nombre resuelva a algo.

Opciones:
  -s SERVIDOR  Servidor a consultar (por defecto 127.0.0.1)
  -p PUERTO    Puerto UDP/TCP (por defecto 53)
  -t SEGUNDOS  Tiempo máximo por consulta (por defecto 2)
  -h           Muestra esta ayuda

Códigos de salida: 0 = todo correcto, 1 = respuesta distinta de la esperada,
2 = sin respuesta, 3 = falta dig, 64 = uso incorrecto.
EOF
}

main() {
  local server="127.0.0.1" port=53 timeout=2 opt
  while getopts ':s:p:t:h' opt; do
    case "$opt" in
      s) server="$OPTARG" ;;
      p) port="$OPTARG" ;;
      t) timeout="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  if (($# == 0)); then
    usage >&2
    exit "$EXIT_USAGE"
  fi
  if ! is_uint "$port" || ((port < 1 || port > 65535)); then
    die "Puerto no válido: '${port}'" "$EXIT_USAGE"
  fi
  if ! is_uint "$timeout" || ((timeout < 1)); then
    die "Tiempo máximo no válido: '${timeout}'" "$EXIT_USAGE"
  fi
  [[ "$server" != -* ]] || die "Servidor no válido: '${server}'" "$EXIT_USAGE"
  require_cmd dig

  local item name expected answer worst=$EXIT_OK
  for item in "$@"; do
    name="${item%%=*}"
    expected=""
    [[ "$item" == *=* ]] && expected="${item#*=}"
    [[ -n "$name" && "$name" != -* ]] || die "Nombre no válido: '${item}'" "$EXIT_USAGE"

    # +short imprime solo la respuesta; `|| true`: dig devuelve ≠0 si no hay servidor.
    answer="$(dig +short +time="$timeout" +tries=1 -p "$port" "@${server}" "$name" A 2>/dev/null || true)"
    # Con CNAME la primera línea es el alias: nos quedamos con las direcciones IPv4.
    answer="$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' <<<"$answer" | paste -sd, - || true)"

    if [[ -z "$answer" ]]; then
      printf '%-9s %s no resuelve en %s:%s\n' "CRITICAL" "$name" "$server" "$port"
      worst=$EXIT_CRITICAL
    elif [[ -n "$expected" && ",${answer}," != *",${expected},"* ]]; then
      printf '%-9s %s -> %s (se esperaba %s)\n' "WARNING" "$name" "$answer" "$expected"
      ((worst >= EXIT_WARNING)) || worst=$EXIT_WARNING
    else
      printf '%-9s %s -> %s\n' "OK" "$name" "$answer"
    fi
  done
  exit "$worst"
}

main "$@"
