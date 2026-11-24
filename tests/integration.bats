#!/usr/bin/env bats
# Prueba de integración: monta redes aisladas (netns) y comprueba cortafuegos, NAT, DNS y DHCP reales.
# Se omite sola si el sistema no permite espacios de nombres de usuario o faltan herramientas.

load helpers

setup() {
  local tool
  for tool in unshare nsenter nft dnsmasq dig python3 ip ping; do
    command -v "$tool" >/dev/null 2>&1 || skip "falta ${tool}"
  done
  unshare -rn true 2>/dev/null || skip "el sistema no permite unshare -rn (espacios de nombres de usuario)"
}

@test "laboratorio netns: todas las comprobaciones de red pasan" {
  run timeout 120 unshare -rn "${REPO_ROOT}/tests/integration/netns-lab.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 fallidas"* ]]
}
