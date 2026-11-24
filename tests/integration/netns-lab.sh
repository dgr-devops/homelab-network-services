#!/usr/bin/env bash
# netns-lab.sh — laboratorio de red desechable para probar de verdad el cortafuegos y el DNS.
#
# Debe ejecutarse DENTRO de un espacio de nombres de usuario y de red:
#     unshare -rn tests/integration/netns-lab.sh
# Sin root real y sin tocar la red del equipo, monta tres redes aisladas:
#
#   LAN (netns B)  192.168.50.20 ──eth1┐
#                                       ├── pasarela (este netns): dnsmasq + homelab.nft real
#   «Internet» (C) 203.0.113.2    ──eth0┘
#
# y comprueba qué tráfico acepta y cuál descarta la pasarela. Sale con 0 si todo es correcto.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly LAN_GW=192.168.50.1 LAN_CLIENT=192.168.50.20 WAN_GW=203.0.113.1 WAN_PEER=203.0.113.2
PASSED=0
FAILED=0
PIDS=()
WORK="$(mktemp -d)"

cleanup() {
  [[ -n "${KEEP_LOGS:-}" ]] && cp "${WORK}/dnsmasq.err" "$KEEP_LOGS" 2>/dev/null || true
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# check <nombre> <comando...> — registra PASS/FAIL según el código de salida.
check() {
  local name="$1"
  shift
  if "$@" >"${WORK}/out" 2>&1; then
    printf 'PASS  %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL  %s\n' "$name"
    sed 's/^/        /' "${WORK}/out"
    FAILED=$((FAILED + 1))
  fi
}

# check_not <nombre> <comando...> — el comando DEBE fallar (tráfico descartado).
check_not() {
  local name="$1"
  shift
  if "$@" >"${WORK}/out" 2>&1; then
    printf 'FAIL  %s (debería haberse descartado)\n' "$name"
    FAILED=$((FAILED + 1))
  else
    printf 'PASS  %s\n' "$name"
    PASSED=$((PASSED + 1))
  fi
}

# in_ns <pid> <comando...> — ejecuta dentro del netns de otro proceso.
in_ns() {
  local pid="$1"
  shift
  nsenter -t "$pid" -n "$@"
}

# dhcp_offer <MAC> <regex> — envía un DHCPDISCOVER desde la LAN y comprueba la IP ofrecida.
dhcp_offer() {
  local offered
  offered="$(in_ns "$LAN_PID" python3 "${REPO_ROOT}/tests/integration/dhcp_discover.py" lan0 "$1")" || return 1
  echo "ofrecida: ${offered}"
  [[ "$offered" =~ $2 ]]
}

# listen_tcp <puerto> <fichero_origen> — acepta una conexión y guarda la IP de origen.
listen_tcp() {
  python3 - "$1" "$2" <<'EOF' &
import socket, sys
port, out = int(sys.argv[1]), sys.argv[2]
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))
s.listen(5)
while True:
    conn, addr = s.accept()
    open(out, "a").write(addr[0] + "\n")
    conn.close()
EOF
  PIDS+=("$!")
}

setup_topology() {
  ip link set lo up
  # B (LAN) y C («Internet»): procesos dormidos que sostienen sus netns.
  unshare -n sleep 600 &
  LAN_PID=$!
  unshare -n sleep 600 &
  WAN_PID=$!
  PIDS+=("$LAN_PID" "$WAN_PID")
  sleep 0.3

  ip link add eth1 type veth peer name lan0
  ip link add eth0 type veth peer name wan0
  ip link set lan0 netns "$LAN_PID"
  ip link set wan0 netns "$WAN_PID"
  ip addr add "${LAN_GW}/24" dev eth1
  ip addr add "${WAN_GW}/24" dev eth0
  ip link set eth1 up
  ip link set eth0 up
  sysctl -q -w net.ipv4.ip_forward=1

  in_ns "$LAN_PID" ip link set lo up
  in_ns "$LAN_PID" ip addr add "${LAN_CLIENT}/24" dev lan0
  in_ns "$LAN_PID" ip link set lan0 up
  in_ns "$LAN_PID" ip route add default via "$LAN_GW"
  in_ns "$WAN_PID" ip link set lo up
  in_ns "$WAN_PID" ip addr add "${WAN_PEER}/24" dev wan0
  in_ns "$WAN_PID" ip link set wan0 up
  in_ns "$WAN_PID" ip route add 192.168.50.0/24 via "$WAN_GW"
}

start_services() {
  # Se usa la configuración REAL del repositorio; solo se redirigen log y concesiones a un directorio
  # temporal (el fichero gana a la línea de órdenes, así que se reescriben esas dos líneas en una copia).
  sed -e "s#^log-facility=.*#log-facility=${WORK}/dnsmasq.log#" \
    -e "s#^dhcp-leasefile=.*#dhcp-leasefile=${WORK}/leases#" \
    "${REPO_ROOT}/config/dnsmasq/homelab.conf" >"${WORK}/dnsmasq.conf"
  dnsmasq --no-daemon --conf-file="${WORK}/dnsmasq.conf" --pid-file="${WORK}/dnsmasq.pid" 2>"${WORK}/dnsmasq.err" &
  PIDS+=("$!")
  listen_tcp 22 "${WORK}/ssh-peers"
  listen_tcp 8080 "${WORK}/other-peers"
  # Servidor «de Internet» para probar reenvío y NAT: escucha en el netns C.
  in_ns "$WAN_PID" python3 - "${WORK}/wan-peers" <<'EOF' &
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 9000))
s.listen(5)
while True:
    conn, addr = s.accept()
    open(sys.argv[1], "a").write(addr[0] + "\n")
    conn.close()
EOF
  PIDS+=("$!")
  # Servidor en la LAN para comprobar que «Internet» NO puede entrar.
  in_ns "$LAN_PID" python3 -c '
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 9001)); s.listen(5)
while True:
    s.accept()[0].close()' &
  PIDS+=("$!")
  sleep 1
  nft -f "${REPO_ROOT}/config/nftables/homelab.nft"
}

main() {
  setup_topology
  start_services

  echo "== DNS y DHCP (dnsmasq real) =="
  check "LAN resuelve nas.home.arpa -> 192.168.50.10" \
    in_ns "$LAN_PID" "${REPO_ROOT}/scripts/check-dns.sh" -s "$LAN_GW" nas.home.arpa=192.168.50.10
  check "LAN resuelve el alias files.home.arpa" \
    in_ns "$LAN_PID" "${REPO_ROOT}/scripts/check-dns.sh" -s "$LAN_GW" files.home.arpa=192.168.50.10
  check "LAN resuelve gateway.home.arpa -> 192.168.50.1" \
    in_ns "$LAN_PID" "${REPO_ROOT}/scripts/check-dns.sh" -s "$LAN_GW" gateway.home.arpa=192.168.50.1
  check_not "nombre inexistente en home.arpa no resuelve" \
    in_ns "$LAN_PID" "${REPO_ROOT}/scripts/check-dns.sh" -s "$LAN_GW" nope.home.arpa
  check "DHCP: la MAC reservada del NAS recibe 192.168.50.10" dhcp_offer 00:00:5e:00:53:10 '^192\.168\.50\.10$'
  check "DHCP: una MAC desconocida recibe una IP del rango .100-.199" \
    dhcp_offer 02:00:00:aa:bb:cc '^192\.168\.50\.(1[0-9][0-9])$'

  echo "== Cortafuegos (homelab.nft real) =="
  check "LAN: ping a la pasarela permitido" in_ns "$LAN_PID" ping -c1 -W2 "$LAN_GW"
  check "LAN: SSH (22/tcp) permitido" in_ns "$LAN_PID" python3 -c \
    "import socket; s=socket.socket(); s.settimeout(2); s.connect(('${LAN_GW}',22))"
  check_not "LAN: 8080/tcp descartado (escucha, pero no está permitido)" in_ns "$LAN_PID" python3 -c \
    "import socket; s=socket.socket(); s.settimeout(2); s.connect(('${LAN_GW}',8080))"
  check_not "Internet: SSH hacia la pasarela descartado" in_ns "$WAN_PID" python3 -c \
    "import socket; s=socket.socket(); s.settimeout(2); s.connect(('${WAN_GW}',22))"
  check_not "Internet: DNS hacia la pasarela descartado" \
    in_ns "$WAN_PID" "${REPO_ROOT}/scripts/check-dns.sh" -s "$WAN_GW" nas.home.arpa

  echo "== Reenvío y NAT =="
  check "LAN -> Internet permitido (forward)" in_ns "$LAN_PID" python3 -c \
    "import socket; s=socket.socket(); s.settimeout(2); s.connect(('${WAN_PEER}',9000))"
  check "NAT: Internet ve la IP pública de la pasarela, no la de la LAN" \
    grep -qx "$WAN_GW" "${WORK}/wan-peers"
  check_not "Internet -> LAN descartado (forward)" in_ns "$WAN_PID" python3 -c \
    "import socket; s=socket.socket(); s.settimeout(2); s.connect(('${LAN_CLIENT}',9001))"

  printf '\n%d correctas, %d fallidas\n' "$PASSED" "$FAILED"
  ((FAILED == 0))
}

main "$@"
