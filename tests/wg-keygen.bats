#!/usr/bin/env bats
# Tests de scripts/wg-keygen.sh con un `wg` falso (stub en el PATH).

load helpers

setup() {
  setup_env
  # genkey -> clave privada falsa; pubkey -> "PUB(<stdin>)"; genpsk -> clave precompartida falsa.
  make_stub wg 'case "$1" in
  genkey) echo "FAKE-PRIVATE-$RANDOM$RANDOM" ;;
  pubkey) echo "PUB($(cat))" ;;
  genpsk) echo "FAKE-PSK" ;;
  *) exit 1 ;;
esac'
  OUT="${BATS_TEST_TMPDIR}/keys"
}

@test "muestra la ayuda con -h y sale con 0" {
  run "${SCRIPTS}/wg-keygen.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: wg-keygen.sh"* ]]
}

@test "sin nombres devuelve 64" {
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT"
  [ "$status" -eq 64 ]
}

@test "nombres peligrosos devuelven 64 y no crean nada" {
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT" "../escape"
  [ "$status" -eq 64 ]
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT" -- "-opcion"
  [ "$status" -eq 64 ]
  [ ! -e "$OUT" ]
}

@test "genera .key y .pub por nombre con permisos restrictivos" {
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT" server laptop
  [ "$status" -eq 0 ]
  [ -s "${OUT}/server.key" ] && [ -s "${OUT}/server.pub" ]
  [ -s "${OUT}/laptop.key" ] && [ -s "${OUT}/laptop.pub" ]
  [ "$(stat -c %a "${OUT}/server.key")" = "600" ]
  [ "$(stat -c %a "${OUT}/server.pub")" = "600" ]
  [ "$(stat -c %a "$OUT")" = "700" ]
}

@test "la clave pública corresponde a la privada" {
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT" server
  [ "$status" -eq 0 ]
  [ "$(cat "${OUT}/server.pub")" = "PUB($(cat "${OUT}/server.key"))" ]
}

@test "solo se imprime la clave pública, nunca la privada" {
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT" server
  [ "$status" -eq 0 ]
  [[ "$output" == *"clave pública: PUB("* ]]
  private="$(cat "${OUT}/server.key")"
  [[ "$output" != *"FAKE-PRIVATE"* ]] || [[ "$output" == *"PUB(${private})"* ]]
  # La privada nunca aparece sola: solo dentro de la pública simulada por el stub.
  [[ "${output//PUB(${private})/}" != *"${private}"* ]]
}

@test "-p genera además la clave precompartida" {
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT" -p server
  [ "$status" -eq 0 ]
  [ "$(cat "${OUT}/preshared.key")" = "FAKE-PSK" ]
  [ "$(stat -c %a "${OUT}/preshared.key")" = "600" ]
}

@test "no sobrescribe claves existentes y no escribe nada" {
  mkdir -p "$OUT"
  echo viejo >"${OUT}/laptop.key"
  run "${SCRIPTS}/wg-keygen.sh" -d "$OUT" server laptop
  [ "$status" -eq 2 ]
  [[ "$output" == *"no se sobrescribe"* ]]
  [ "$(cat "${OUT}/laptop.key")" = "viejo" ]
  [ ! -e "${OUT}/server.key" ]
}

@test "sin wg devuelve 3" {
  minimal_path
  run bash "${SCRIPTS}/wg-keygen.sh" -d "$OUT" server
  [ "$status" -eq 3 ]
  [ ! -e "$OUT" ]
}
