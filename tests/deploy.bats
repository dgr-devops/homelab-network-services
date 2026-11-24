#!/usr/bin/env bats
# Tests de scripts/deploy.sh con un validador falso y una raíz de instalación temporal.

load helpers

setup() {
  setup_env
  copy_config
  ROOT="${BATS_TEST_TMPDIR}/root"
  # Validador falso: registra los argumentos y devuelve $VALIDATOR_RC (0 por defecto).
  cat >"${STUB_DIR}/fake-validate" <<'EOF'
#!/usr/bin/env bash
echo "$*" >"${BATS_TEST_TMPDIR}/validate.args"
exit "${VALIDATOR_RC:-0}"
EOF
  chmod +x "${STUB_DIR}/fake-validate"
  export HOMELAB_VALIDATOR="${STUB_DIR}/fake-validate"
}

deploy() {
  run "${SCRIPTS}/deploy.sh" -r "$ROOT" -c "$CONF_DIR" "$@"
}

@test "muestra la ayuda con -h y sale con 0" {
  run "${SCRIPTS}/deploy.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: deploy.sh"* ]]
}

@test "componente desconocido devuelve 64" {
  deploy apache
  [ "$status" -eq 64 ]
  [[ "$output" == *"Componente desconocido: apache"* ]]
}

@test "directorio de configuración inexistente devuelve 64" {
  run "${SCRIPTS}/deploy.sh" -r "$ROOT" -c "${BATS_TEST_TMPDIR}/nada" dnsmasq
  [ "$status" -eq 64 ]
}

@test "instala dnsmasq, unbound y nftables en su ruta con modo 644" {
  deploy dnsmasq unbound nftables
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "${ROOT}/etc/dnsmasq.d/homelab.conf")" = "644" ]
  cmp "${CONF_DIR}/dnsmasq/homelab.conf" "${ROOT}/etc/dnsmasq.d/homelab.conf"
  cmp "${CONF_DIR}/unbound/homelab.conf" "${ROOT}/etc/unbound/unbound.conf.d/homelab.conf"
  cmp "${CONF_DIR}/nftables/homelab.nft" "${ROOT}/etc/nftables.d/homelab.nft"
  [[ "$output" == *"No se ha reiniciado nada"* || "$output" == *"no se ha reiniciado nada"* ]]
}

@test "--dry-run no crea ningún fichero" {
  run "${SCRIPTS}/deploy.sh" --dry-run -r "$ROOT" -c "$CONF_DIR" dnsmasq nftables
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIMULADO"*"dnsmasq.d/homelab.conf"* ]]
  [ ! -e "$ROOT" ]
}

@test "-n equivale a --dry-run" {
  deploy -n dnsmasq
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
}

@test "una segunda ejecución no cambia nada ni crea copias" {
  deploy dnsmasq
  deploy dnsmasq
  [ "$status" -eq 0 ]
  [[ "$output" == *"IGUAL"* ]]
  run find "$ROOT" -name '*.bak-*'
  [ -z "$output" ]
}

@test "si el destino difiere hace copia de seguridad antes de sustituir" {
  mkdir -p "${ROOT}/etc/dnsmasq.d"
  echo "configuración vieja" >"${ROOT}/etc/dnsmasq.d/homelab.conf"
  deploy dnsmasq
  [ "$status" -eq 0 ]
  cmp "${CONF_DIR}/dnsmasq/homelab.conf" "${ROOT}/etc/dnsmasq.d/homelab.conf"
  backup="$(find "${ROOT}/etc/dnsmasq.d" -name 'homelab.conf.bak-*')"
  [ -n "$backup" ]
  [ "$(cat "$backup")" = "configuración vieja" ]
}

@test "si la validación falla no se instala nada y sale con 2" {
  VALIDATOR_RC=2 deploy dnsmasq nftables
  [ "$status" -eq 2 ]
  [[ "$output" == *"La validación ha fallado"* ]]
  [ ! -e "$ROOT" ]
}

@test "si la validación es incompleta (1) avisa pero continúa" {
  VALIDATOR_RC=1 deploy dnsmasq
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validación incompleta"* ]]
  [ -f "${ROOT}/etc/dnsmasq.d/homelab.conf" ]
}

@test "pasa -d y el directorio de configuración al validador" {
  deploy -d dnsmasq
  [ "$status" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/validate.args")" = "-d -c ${CONF_DIR} dnsmasq" ]
}

@test "wireguard sin wg0.conf se omite y devuelve 1" {
  deploy wireguard
  [ "$status" -eq 1 ]
  [[ "$output" == *"wireguard omitido"* ]]
  [ ! -e "${ROOT}/etc/wireguard" ]
}

@test "wireguard se niega a instalar claves de ejemplo" {
  cp "${CONF_DIR}/wireguard/wg0-server.conf.example" "${CONF_DIR}/wireguard/wg0.conf"
  deploy wireguard
  [ "$status" -eq 2 ]
  [[ "$output" == *"claves de EJEMPLO"* ]]
  [ ! -e "${ROOT}/etc/wireguard/wg0.conf" ]
}

@test "wireguard instala una configuración con claves propias con modo 600" {
  sed 's/RVhBTVBMRS1[A-Za-z0-9+\/=]*/dGVzdC1wcnVlYmEtbm8tZXMtdW5hLWNsYXZlLXJlYWw=/' \
    "${CONF_DIR}/wireguard/wg0-server.conf.example" >"${CONF_DIR}/wireguard/wg0.conf"
  deploy wireguard
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "${ROOT}/etc/wireguard/wg0.conf")" = "600" ]
}
