# Makefile — lint, tests, validación de configuraciones y laboratorio de red.
#
#   make lint | make test | make validate | make lab | make check
#   make deploy-dry            # simula el despliegue en ./build/root (no toca el sistema)

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(sort $(wildcard $(ROOT)/scripts/*.sh))

.DEFAULT_GOAL := help
.PHONY: help lint test validate lab deploy-dry check

help: ## Muestra esta ayuda
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-11s %s\n", $$1, $$2}'

lint: ## Pasa shellcheck a scripts, librería y laboratorio
	shellcheck $(SCRIPTS) $(ROOT)/lib/common.sh $(ROOT)/tests/integration/netns-lab.sh

test: ## Ejecuta los tests con bats (incluye el laboratorio netns si el sistema lo permite)
	bats $(ROOT)/tests/

validate: ## Valida las configuraciones con nft, dnsmasq, unbound y wg (usa Docker si falta algo)
	$(ROOT)/scripts/validate.sh -d

lab: ## Ejecuta solo el laboratorio de red en netns (cortafuegos, NAT, DNS y DHCP reales)
	unshare -rn $(ROOT)/tests/integration/netns-lab.sh

deploy-dry: ## Simula el despliegue sobre ./build/root
	$(ROOT)/scripts/deploy.sh --dry-run -d -r $(ROOT)/build/root

check: lint test ## lint + test
