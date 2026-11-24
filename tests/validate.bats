#!/usr/bin/env bats
# Tests de scripts/validate.sh con herramientas falsas (stubs) para controlar cada resultado.

load helpers

setup() {
  setup_env
  copy_config
  # Todas las herramientas «existen» y aceptan la configuración. `unshare -rn CMD...` ejecuta CMD.
  make_stub nft 'exit "${NFT_RC:-0}"'
  make_stub dnsmasq 'if [ "${DNSMASQ_RC:-0}" -ne 0 ]; then echo "dnsmasq: línea 3: opción mala" >&2; fi; exit "${DNSMASQ_RC:-0}"'
  make_stub unbound-checkconf 'exit "${UNBOUND_RC:-0}"'
  make_stub wg-quick 'exit 0'
  make_stub wg 'exit 0'
  make_stub ip 'exit 0'
  make_stub unshare 'shift; exec "$@"'
}

@test "muestra la ayuda con -h y sale con 0" {
  run "${SCRIPTS}/validate.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: validate.sh"* ]]
}

@test "componente desconocido devuelve 64" {
  run "${SCRIPTS}/validate.sh" -c "$CONF_DIR" bind9
  [ "$status" -eq 64 ]
}

@test "directorio de configuración inexistente devuelve 64" {
  run "${SCRIPTS}/validate.sh" -c "${BATS_TEST_TMPDIR}/nada"
  [ "$status" -eq 64 ]
}

@test "todo válido devuelve 0 y muestra un OK por componente" {
  run "${SCRIPTS}/validate.sh" -c "$CONF_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"nftables"* ]]
  [[ "$output" == *"OK"*"dnsmasq"* ]]
  [[ "$output" == *"OK"*"unbound"* ]]
  [[ "$output" == *"OK"*"wg0-server.conf.example"* ]]
  [[ "$output" == *"OK"*"wg0-client.conf.example"* ]]
}

@test "una configuración inválida devuelve 2 y muestra el error de la herramienta" {
  DNSMASQ_RC=1 run "${SCRIPTS}/validate.sh" -c "$CONF_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"*"dnsmasq"* ]]
  [[ "$output" == *"opción mala"* ]]
}

@test "un fallo no impide validar el resto de componentes" {
  NFT_RC=1 run "${SCRIPTS}/validate.sh" -c "$CONF_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"*"nftables"* ]]
  [[ "$output" == *"OK"*"dnsmasq"* ]]
}

@test "se puede validar solo un componente" {
  run "${SCRIPTS}/validate.sh" -c "$CONF_DIR" dnsmasq
  [ "$status" -eq 0 ]
  [[ "$output" == *"dnsmasq"* ]]
  [[ "$output" != *"nftables"* ]]
}

@test "si falta una herramienta el componente se omite y sale con 1" {
  minimal_path
  make_stub nft 'exit 0'
  make_stub unshare 'shift; exec "$@"'
  run bash "${SCRIPTS}/validate.sh" -c "$CONF_DIR" dnsmasq nftables
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"*"dnsmasq"* ]]
  [[ "$output" == *"OK"*"nftables"* ]]
}

@test "falta el fichero de configuración de un componente: FAIL y 2" {
  rm "${CONF_DIR}/dnsmasq/homelab.conf"
  run "${SCRIPTS}/validate.sh" -c "$CONF_DIR" dnsmasq
  [ "$status" -eq 2 ]
  [[ "$output" == *"no existe"* ]]
}

@test "sin ficheros de WireGuard devuelve FAIL y 2" {
  rm "${CONF_DIR}"/wireguard/*
  run "${SCRIPTS}/validate.sh" -c "$CONF_DIR" wireguard
  [ "$status" -eq 2 ]
  [[ "$output" == *"sin ficheros .conf"* ]]
}

@test "sin unbound-checkconf y sin -d se omite unbound" {
  minimal_path
  run bash "${SCRIPTS}/validate.sh" -c "$CONF_DIR" unbound
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"*"unbound"*"usa -d"* ]]
}

@test "con -d usa Docker para unbound cuando falta la herramienta" {
  minimal_path
  make_stub docker 'echo "docker $*" >>"${BATS_TEST_TMPDIR}/docker.calls"; exit 0'
  run bash "${SCRIPTS}/validate.sh" -d -c "$CONF_DIR" unbound
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"unbound"*"Docker"* ]]
  grep -q 'alpine' "${BATS_TEST_TMPDIR}/docker.calls"
}

@test "con -d usa Docker para WireGuard con NET_ADMIN cuando falta wg-quick" {
  minimal_path
  make_stub docker 'echo "docker $*" >>"${BATS_TEST_TMPDIR}/docker.calls"; exit 0'
  run bash "${SCRIPTS}/validate.sh" -d -c "$CONF_DIR" wireguard
  [ "$status" -eq 0 ]
  grep -q -- '--cap-add NET_ADMIN' "${BATS_TEST_TMPDIR}/docker.calls"
}

@test "HOMELAB_DOCKER_IMAGE cambia la imagen usada" {
  minimal_path
  make_stub docker 'echo "docker $*" >>"${BATS_TEST_TMPDIR}/docker.calls"; exit 0'
  HOMELAB_DOCKER_IMAGE=alpine:3.19 run bash "${SCRIPTS}/validate.sh" -d -c "$CONF_DIR" unbound
  [ "$status" -eq 0 ]
  grep -q 'alpine:3.19' "${BATS_TEST_TMPDIR}/docker.calls"
}
