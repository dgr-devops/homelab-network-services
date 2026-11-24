# homelab-network-services

[![CI](https://github.com/dgr-devops/homelab-network-services/actions/workflows/ci.yml/badge.svg)](https://github.com/dgr-devops/homelab-network-services/actions/workflows/ci.yml)
![Licencia: MIT](https://img.shields.io/badge/licencia-MIT-green)

Configuración **reproducible** de los servicios de red de un homelab: **DNS** (dnsmasq + Unbound),
**DHCP**, **VPN WireGuard** y **cortafuegos nftables**, con scripts para validar y desplegar y un
**laboratorio de red aislado** que prueba tráfico real sin root ni tocar la red del equipo.
Incluye 60 tests con bats y todo pasa `shellcheck`.

> Es un proyecto de portfolio: la red (`192.168.50.0/24`, `10.8.0.0/24`) y las claves son **de ejemplo**.
> Las claves de WireGuard del repositorio no protegen nada, y `deploy.sh` se niega a instalarlas.

## Qué incluye

| Ruta | Contenido |
|---|---|
| `config/dnsmasq/homelab.conf` | DNS local (`home.arpa`, alias), DHCP con rango y reservas por MAC, reenvío a Unbound |
| `config/unbound/homelab.conf` | Resolutor recursivo solo en `127.0.0.1:5335`, con endurecimiento básico |
| `config/nftables/homelab.nft` | Cortafuegos con política `drop`, NAT, reenvío LAN/VPN/Internet |
| `config/wireguard/*.example` | Servidor y cliente WireGuard con claves de EJEMPLO |
| `scripts/validate.sh` | Valida cada configuración con su herramienta real, sin aplicarla |
| `scripts/deploy.sh` | Instala validando antes, con copia de seguridad y `--dry-run` |
| `scripts/wg-keygen.sh` | Genera claves WireGuard fuera del repositorio |
| `scripts/check-dns.sh` | Comprueba que un DNS resuelve lo esperado (códigos Nagios) |
| `tests/` | Tests bats con stubs + laboratorio de red en netns |
| `systemd/` | Servicio y temporizador de ejemplo para vigilar el DNS |
| `docs/decisiones.md` | Por qué todo es como es, y qué **no** se ha verificado |

## Requisitos

Linux con Bash 4.4+, `nftables`, `dnsmasq`, `iproute2` y `util-linux` (`unshare`, `nsenter`).
Opcionales: `unbound` y `wireguard-tools` (o Docker, que los sustituye en `validate.sh -d`).
Para desarrollar: [`shellcheck`](https://www.shellcheck.net/), [`bats`](https://github.com/bats-core/bats-core),
`dig` (`bind`/`dnsutils`) y `python3`.

## Uso rápido

```bash
git clone https://github.com/dgr-devops/homelab-network-services.git
cd homelab-network-services
make help          # lista los objetivos
make validate      # valida las 4 configuraciones (usa Docker si falta alguna herramienta)
make lab           # laboratorio de red: cortafuegos, NAT, DNS y DHCP reales
make check         # shellcheck + tests
make deploy-dry    # simula el despliegue sobre ./build/root
```

Para usarlo en un servidor propio: edita las líneas `define` de `homelab.nft` y las direcciones de
`dnsmasq`, genera tus claves con `scripts/wg-keygen.sh`, crea `config/wireguard/wg0.conf` a partir del
`.example` y ejecuta `sudo scripts/deploy.sh`. El script no reinicia nada: te dice qué ejecutar.

## Salida real

Todo lo que sigue se ha ejecutado en la máquina de desarrollo (nftables 1.1.7, dnsmasq 2.93, sin root real).

### Validación de las configuraciones

```console
$ scripts/validate.sh -d
OK    nftables   nftables/homelab.nft (netns de usuario)
OK    dnsmasq    dnsmasq/homelab.conf
OK    unbound    unbound/homelab.conf (Docker alpine:3.20)
OK    wireguard  wg0-client.conf.example (Docker alpine:3.20)
OK    wireguard  wg0-server.conf.example (Docker alpine:3.20)
```

Y con errores deliberados (una palabra mal escrita en nftables y un rango DHCP absurdo), el código de
salida es `2` y se ve el error de la herramienta (recortado):

```console
$ scripts/validate.sh -c /tmp/config-rota nftables dnsmasq
FAIL  nftables   nftables/homelab.nft (netns de usuario)
        nftables/homelab.nft:46:58-61: Error: syntax error, unexpected string
        expected any of: checksum, seq, reserved, flags, sport, dport, ackseq, doff, window, urgptr, option
            iifname { $LAN_IF, $WG_IF } ip saddr @admin_nets tcp dprt 22 ct state new limit rate 6/minute accept
                                                                 ^^^^
        [...]
FAIL  dnsmasq    dnsmasq/homelab.conf
        dnsmasq: opción dhcp-range (rango DHCP) errónea at line 36 of dnsmasq/homelab.conf
[ERROR] 2 comprobación(es) fallida(s)
```

### Laboratorio de red en netns

`make lab` monta tres redes aisladas (pasarela, LAN, «Internet»), arranca el dnsmasq real con la
configuración real, carga `homelab.nft` real y comprueba el tráfico:

```console
$ unshare -rn tests/integration/netns-lab.sh
== DNS y DHCP (dnsmasq real) ==
PASS  LAN resuelve nas.home.arpa -> 192.168.50.10
PASS  LAN resuelve el alias files.home.arpa
PASS  LAN resuelve gateway.home.arpa -> 192.168.50.1
PASS  nombre inexistente en home.arpa no resuelve
PASS  DHCP: la MAC reservada del NAS recibe 192.168.50.10
PASS  DHCP: una MAC desconocida recibe una IP del rango .100-.199
== Cortafuegos (homelab.nft real) ==
PASS  LAN: ping a la pasarela permitido
PASS  LAN: SSH (22/tcp) permitido
PASS  LAN: 8080/tcp descartado (escucha, pero no está permitido)
PASS  Internet: SSH hacia la pasarela descartado
PASS  Internet: DNS hacia la pasarela descartado
== Reenvío y NAT ==
PASS  LAN -> Internet permitido (forward)
PASS  NAT: Internet ve la IP pública de la pasarela, no la de la LAN
PASS  Internet -> LAN descartado (forward)

14 correctas, 0 fallidas
```

Para comprobar que estos tests **pueden fallar**, se cambió `policy drop` por `policy accept` en la
cadena `input`: el laboratorio dio `10 correctas, 2 fallidas` (el puerto 8080 y SSH desde Internet
dejaron de descartarse).

### Despliegue en seco

```console
$ scripts/deploy.sh --dry-run -d -r build/root
OK    dnsmasq    dnsmasq/homelab.conf
OK    unbound    unbound/homelab.conf (Docker alpine:3.20)
OK    nftables   nftables/homelab.nft (netns de usuario)
OK    wireguard  wg0-client.conf.example (Docker alpine:3.20)
OK    wireguard  wg0-server.conf.example (Docker alpine:3.20)
SIMULADO   homelab.conf -> build/root/etc/dnsmasq.d/homelab.conf (modo 644)
SIMULADO   homelab.conf -> build/root/etc/unbound/unbound.conf.d/homelab.conf (modo 644)
SIMULADO   homelab.nft -> build/root/etc/nftables.d/homelab.nft (modo 644)
[WARN] wireguard omitido: no existe wg0.conf en el directorio de configuración (genera claves con wg-keygen.sh y crea ese fichero a partir del .example)
[INFO] Simulación: no se ha cambiado nada
```

Sale con `1` porque WireGuard se omitió: nunca instala las claves de ejemplo.

### Generación de claves

Ejecutado en un contenedor `alpine` con `wireguard-tools` (el equipo de desarrollo no lo tiene
instalado). Las claves públicas se han sustituido por `<44 caracteres base64>`; el resto es literal:

```console
$ scripts/wg-keygen.sh -d /tmp/keys -p server laptop
server       clave pública: <44 caracteres base64>
laptop       clave pública: <44 caracteres base64>
preshared    generada en /tmp/keys/preshared.key
[INFO] Claves privadas en /tmp/keys (modo 600). No las subas a git.
$ ls -l /tmp/keys
-rw-------  1 root root  45 laptop.key
-rw-------  1 root root  45 laptop.pub
-rw-------  1 root root  45 preshared.key
-rw-------  1 root root  45 server.key
-rw-------  1 root root  45 server.pub
$ stat -c "%a" /tmp/keys
700
```

### Tests y análisis estático

```console
$ make lint        # shellcheck sin avisos
$ bats tests/
1..60
...
ok 60 sin wg devuelve 3
$ docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12   # sin salida: workflow válido
```

## Códigos de salida

`validate.sh`, `deploy.sh`, `wg-keygen.sh` y `check-dns.sh` usan los de Nagios: `0` OK, `1` aviso,
`2` crítico, `3` desconocido (falta una herramienta), `64` uso incorrecto. Los detalles de cada uno
están en `-h`.

## Qué NO está verificado

Resumen (detalle en [`docs/decisiones.md`](docs/decisiones.md)): no se ha desplegado en un servidor real;
no se ha arrancado Unbound ni establecido ningún túnel WireGuard (la configuración se valida con el
kernel, pero sin pares reales); en DHCP solo se prueba DISCOVER → OFFER; no se ha probado IPv6 ni el
arranque con systemd; y el CI de GitHub aún no se ha ejecutado (el workflow solo está validado con `actionlint`).

## Licencia

MIT. Véase [`LICENSE`](LICENSE).
