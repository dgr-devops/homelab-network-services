#!/usr/bin/env bats
# Tests de lib/common.sh.

load helpers

setup() {
  setup_env
}

# Ejecuta código bash con la librería ya cargada.
run_lib() {
  run bash -c "set -euo pipefail; source '${REPO_ROOT}/lib/common.sh'; $1"
}

@test "is_uint acepta enteros no negativos" {
  run_lib 'is_uint 0 && is_uint 42'
  [ "$status" -eq 0 ]
}

@test "is_uint rechaza vacío, negativos y texto" {
  run_lib '! is_uint "" && ! is_uint -1 && ! is_uint abc && ! is_uint 1.5'
  [ "$status" -eq 0 ]
}

@test "have_cmd distingue comandos existentes e inexistentes" {
  run_lib 'have_cmd bash && ! have_cmd no-existe-este-comando'
  [ "$status" -eq 0 ]
}

@test "require_cmd sale con 3 si falta un comando" {
  run_lib 'require_cmd no-existe-este-comando'
  [ "$status" -eq 3 ]
  [[ "$output" == *"Falta el comando requerido: no-existe-este-comando"* ]]
}

@test "die usa el código indicado y 1 por defecto" {
  run_lib 'die "fallo" 7'
  [ "$status" -eq 7 ]
  [[ "$output" == *"fallo"* ]]
  run_lib 'die "fallo"'
  [ "$status" -eq 1 ]
}

@test "las constantes de salida siguen la convención Nagios" {
  run_lib 'echo "$EXIT_OK $EXIT_WARNING $EXIT_CRITICAL $EXIT_UNKNOWN $EXIT_USAGE"'
  [ "$output" = "0 1 2 3 64" ]
}
