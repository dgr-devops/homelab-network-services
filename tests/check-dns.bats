#!/usr/bin/env bats
# Tests de scripts/check-dns.sh con un `dig` falso (stub en el PATH).

load helpers

setup() {
  setup_env
  # El nombre consultado es el penúltimo argumento (el último es el tipo, A).
  make_stub dig 'name="${@: -2:1}"
case "$name" in
  nas.home.arpa) echo 192.168.50.10 ;;
  files.home.arpa) echo nas.home.arpa.; echo 192.168.50.10 ;;
  multi.home.arpa) echo 192.168.50.20; echo 192.168.50.21 ;;
  moved.home.arpa) echo 192.168.50.99 ;;
esac
exit 0'
}

@test "muestra la ayuda con -h y sale con 0" {
  run "${SCRIPTS}/check-dns.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: check-dns.sh"* ]]
}

@test "sin nombres devuelve 64" {
  run "${SCRIPTS}/check-dns.sh"
  [ "$status" -eq 64 ]
}

@test "opción desconocida devuelve 64" {
  run "${SCRIPTS}/check-dns.sh" -z nas.home.arpa
  [ "$status" -eq 64 ]
}

@test "puerto no válido devuelve 64" {
  run "${SCRIPTS}/check-dns.sh" -p 70000 nas.home.arpa
  [ "$status" -eq 64 ]
  [[ "$output" == *"Puerto no válido"* ]]
}

@test "tiempo máximo no válido devuelve 64" {
  run "${SCRIPTS}/check-dns.sh" -t 0 nas.home.arpa
  [ "$status" -eq 64 ]
}

@test "un servidor que parece una opción se rechaza con 64" {
  run "${SCRIPTS}/check-dns.sh" -s -evil nas.home.arpa
  [ "$status" -eq 64 ]
}

@test "un nombre que parece una opción se rechaza con 64" {
  run "${SCRIPTS}/check-dns.sh" -- -x.home.arpa
  [ "$status" -eq 64 ]
}

@test "nombre que resuelve a lo esperado devuelve 0" {
  run "${SCRIPTS}/check-dns.sh" nas.home.arpa=192.168.50.10
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"nas.home.arpa -> 192.168.50.10"* ]]
}

@test "sin IP esperada basta con que resuelva" {
  run "${SCRIPTS}/check-dns.sh" nas.home.arpa
  [ "$status" -eq 0 ]
}

@test "un alias (CNAME) se evalúa por sus direcciones" {
  run "${SCRIPTS}/check-dns.sh" files.home.arpa=192.168.50.10
  [ "$status" -eq 0 ]
  [[ "$output" != *"nas.home.arpa."* ]]
}

@test "con varias direcciones basta con que una sea la esperada" {
  run "${SCRIPTS}/check-dns.sh" multi.home.arpa=192.168.50.21
  [ "$status" -eq 0 ]
}

@test "respuesta distinta de la esperada devuelve 1" {
  run "${SCRIPTS}/check-dns.sh" moved.home.arpa=192.168.50.10
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING"*"se esperaba 192.168.50.10"* ]]
}

@test "nombre sin respuesta devuelve 2" {
  run "${SCRIPTS}/check-dns.sh" nope.home.arpa
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"nope.home.arpa no resuelve"* ]]
}

@test "con varios nombres gana el resultado más grave" {
  run "${SCRIPTS}/check-dns.sh" nas.home.arpa moved.home.arpa=192.168.50.10 nope.home.arpa
  [ "$status" -eq 2 ]
}

@test "pasa servidor y puerto a dig" {
  make_stub dig 'echo "$*" >"${BATS_TEST_TMPDIR}/dig.args"; echo 192.168.50.10'
  run "${SCRIPTS}/check-dns.sh" -s 192.168.50.1 -p 5353 nas.home.arpa
  [ "$status" -eq 0 ]
  grep -q -- '-p 5353 @192.168.50.1 nas.home.arpa A' "${BATS_TEST_TMPDIR}/dig.args"
}

@test "sin dig devuelve 3" {
  minimal_path
  run bash "${SCRIPTS}/check-dns.sh" nas.home.arpa
  [ "$status" -eq 3 ]
  [[ "$output" == *"Falta el comando requerido: dig"* ]]
}
