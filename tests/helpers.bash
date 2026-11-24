# tests/helpers.bash — utilidades comunes de los tests (se cargan con `load helpers`).
# Todo ocurre dentro de $BATS_TEST_TMPDIR: los tests nunca tocan ficheros reales del sistema.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SCRIPTS="${REPO_ROOT}/scripts"

# setup_env — entorno aislado: sin colores y con un directorio de stubs al frente del PATH.
setup_env() {
  export NO_COLOR=1
  export STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  export PATH="${STUB_DIR}:${PATH}"
  unset HOMELAB_VALIDATOR HOMELAB_DOCKER_IMAGE
}

# make_stub <nombre> <cuerpo> — crea un ejecutable falso en el PATH del test.
make_stub() {
  local name="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"${STUB_DIR}/${name}"
  chmod +x "${STUB_DIR}/${name}"
}

# minimal_path — el PATH contiene solo utilidades básicas (enlaces) y los stubs: sirve para simular
# que faltan herramientas como dnsmasq, dig o wg. Borra los stubs ya creados: hay que recrear los necesarios.
minimal_path() {
  local tool target
  local core="bash env dirname readlink realpath find sort sed cat date mkdir cp cmp install grep paste chmod mktemp rm head"
  rm -f "${STUB_DIR}"/*
  mkdir -p "${BATS_TEST_TMPDIR}/core"
  for tool in $core; do
    target="$(command -v "$tool")"
    ln -sf "$target" "${BATS_TEST_TMPDIR}/core/${tool}"
  done
  export PATH="${STUB_DIR}:${BATS_TEST_TMPDIR}/core"
}

# copy_config — copia config/ del repositorio a un directorio temporal editable.
copy_config() {
  export CONF_DIR="${BATS_TEST_TMPDIR}/config"
  cp -r "${REPO_ROOT}/config" "$CONF_DIR"
}
