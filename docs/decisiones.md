# Decisiones de diseño

Por qué la configuración es como es y qué se ha verificado de verdad. Los ejemplos usan la red
`192.168.50.0/24` (LAN), `10.8.0.0/24` (VPN) y `203.0.113.0/24` (rango de documentación, RFC 5737).

## 1. dnsmasq para DNS y DHCP, Unbound solo como resolutor recursivo

dnsmasq es un único proceso pequeño que da DHCP, DNS local (nombres y alias) y caché. En un homelab
es lo mínimo que hace falta. Pero no resuelve de forma recursiva ni valida DNSSEC con comodidad,
así que delega en **Unbound**, que escucha **solo en `127.0.0.1:5335`**:

- La LAN solo habla con dnsmasq (puerto 53); Unbound nunca queda expuesto.
- Unbound resuelve desde los servidores raíz (sin depender del DNS del operador). La validación DNSSEC no está activada en el ejemplo: necesita el ancla de confianza (`auto-trust-anchor-file`), cuya ruta cambia según la distribución.
- Cada pieza hace una cosa: si Unbound cae, el DHCP y los nombres locales siguen funcionando.

El coste son dos procesos en vez de uno. Se acepta a cambio de la separación de responsabilidades.

## 2. Dominio `home.arpa`

RFC 8375 reserva `home.arpa` para redes domésticas. Evita `.local` (reservado para mDNS, rompe la
resolución en equipos con Avahi) y `.lan`/`.home` (no reservados: un día pueden existir en Internet).
`local=/home.arpa/` asegura que esas consultas **nunca salen a Internet**: o las responde dnsmasq o
dan NXDOMAIN (hay un test que lo comprueba).

## 3. nftables con política `drop` en `input` y `forward`

- **Denegar por defecto**: lo que no está escrito no entra. `output` queda en `accept` porque es la propia pasarela.
- **`ct state established,related` primero** (rápido) y `invalid` descartado.
- **ICMPv6 siempre permitido**: sin él no funciona el descubrimiento de vecinos y se rompe IPv6. El ping IPv4 se limita en tasa.
- **DHCP se filtra por interfaz y puerto, no por IP de origen**: un cliente que aún no tiene IP envía desde `0.0.0.0`.
- **DNS y SSH solo desde LAN y VPN** (conjunto `admin_nets`); SSH con límite de intentos nuevos por minuto.
- **WireGuard** (51820/udp) es lo único accesible desde Internet.
- **`forward`**: la LAN sale a Internet, la VPN llega a la LAN y a Internet, y nada entra desde Internet. NAT (`masquerade`) solo en la salida WAN.
- Los descartes se registran con límite (`limit rate`) para que un escaneo no llene el disco.

Las interfaces y redes están en `define` al principio del fichero: se cambian en un solo sitio.

## 4. WireGuard: claves de ejemplo que no pueden desplegarse por error

Los `.example` llevan claves que son **32 bytes de texto legible** («EXAMPLE-…») en base64: son válidas
sintácticamente (se pueden validar con `wg setconf`) pero no protegen nada. Tres defensas contra
subir o instalar claves reales o de ejemplo por error:

1. `wg-keygen.sh` escribe en `./keys/` (ignorado por git), con `umask 077`, y solo imprime claves públicas.
2. `.gitignore` excluye `config/wireguard/wg0.conf`, `*.key` y `keys/`.
3. `deploy.sh` rechaza instalar un `wg0.conf` que contenga el prefijo de las claves de ejemplo.

El cliente usa **túnel dividido** (`AllowedIPs` = VPN + LAN): solo el tráfico del homelab viaja por el túnel.
Se usa además clave precompartida (`PresharedKey`) como capa extra.

## 5. Validar sin root y sin aplicar nada

Todo lo que se puede comprobar se comprueba **antes** de tocar el sistema, y sin sudo:

| Servicio | Cómo se valida | Qué demuestra |
|---|---|---|
| nftables | `nft -c -f` dentro de `unshare -rn` | El kernel acepta el ruleset (sintaxis y semántica), sin cargarlo |
| dnsmasq | `dnsmasq --test -C` | Sintaxis de la configuración |
| Unbound | `unbound-checkconf` (local o en Docker) | Sintaxis y valores |
| WireGuard | `wg setconf` + `wg setconf` en un netns desechable | Claves, rangos y claves precompartidas bien formados |

`unshare -rn` crea un espacio de nombres de usuario y de red donde somos «root» solo ahí: se puede usar
`nft` y crear interfaces sin privilegios y sin afectar a la red real. Si falta una herramienta
(`unbound-checkconf`, `wg`), `validate.sh -d` usa un contenedor `alpine`. Sin Docker, el componente se
marca `SKIP` y el código de salida es `1` (no un falso «todo bien»).

## 6. Un laboratorio de red de verdad (`tests/integration/netns-lab.sh`)

Comprobar la sintaxis no demuestra que el cortafuegos haga lo que se espera. El laboratorio monta tres
redes aisladas (pasarela, LAN y «Internet») con pares `veth`, arranca el **dnsmasq real con la
configuración real** y carga el **`homelab.nft` real**, y comprueba tráfico de verdad:
resolución de nombres y alias, ofertas DHCP, SSH permitido desde la LAN, puerto cerrado descartado,
SSH y DNS desde Internet descartados, reenvío LAN → Internet, NAT (el «Internet» ve la IP pública de la
pasarela) y Internet → LAN descartado.

Para saber que los tests **pueden fallar**, se hizo una prueba de mutación: con la política de `input`
cambiada a `accept`, el laboratorio da 2 fallos (puerto 8080 y SSH desde Internet).

Detalles que se descubrieron al construirlo, y por qué el código es como es:

- **dnsmasq se arranca con `--no-daemon`**: en un espacio de nombres de usuario falla `setgroups` al
  intentar bajar privilegios; el modo de depuración no los baja.
- **El fichero de configuración gana a la línea de órdenes**, así que log y concesiones se redirigen
  reescribiendo dos líneas en una copia temporal del fichero real, no con opciones extra.
- **dnsmasq comprueba con `ping` una IP dinámica** antes de ofrecerla (~3 s): el cliente DHCP de prueba espera 8 s.

## 7. `deploy.sh`: seguro por diseño

- **Valida antes de copiar**; un fallo (código `2`) aborta sin tocar nada.
- **Copia de seguridad** (`fichero.bak-FECHA`) de lo que sustituye; un fichero idéntico no se toca.
- **`--dry-run`** y **`-r RAÍZ`** para ensayar sobre un directorio (`make deploy-dry`).
- **No reinicia servicios**: indica los comandos. Aplicar un cortafuegos por SSH sin querer puede dejarte fuera.
- Los ficheros se instalan con `install -m` (modos explícitos: `600` para WireGuard).

## 8. Bash, códigos de salida y tests

Misma convención que el resto del portfolio: `set -euo pipefail`, `lib/common.sh`, códigos Nagios
(`0` OK, `1` aviso, `2` crítico, `3` desconocido, `64` uso incorrecto), argumentos validados y que no
pueden pasar por opciones (`--`, nombres que empiezan por `-`). Los tests con bats usan **stubs en el
`PATH`** (`dig`, `wg`, `nft`, `docker`...) para controlar cada resultado, y un `PATH` mínimo para simular
herramientas ausentes.

## Qué NO se ha verificado

Honestidad sobre los límites de lo probado:

- **No se ha desplegado en un servidor real** ni como root sobre `/`: `deploy.sh` se probó con `-r` sobre un directorio temporal y con tests.
- **Unbound** solo se ha validado con `unbound-checkconf`; no se ha arrancado ni se ha probado la cadena dnsmasq → Unbound ni DNSSEC (no hay red real en las pruebas).
- **WireGuard** se valida con el kernel (`wg setconf`), pero **no se ha establecido ningún túnel** (sin pares reales, sin handshake, sin tráfico por `wg0`). Las reglas de `wg0` en `forward` no se han ejercitado.
- **DHCP**: se prueban DISCOVER → OFFER (reserva por MAC y rango dinámico); no se prueba el ciclo completo (REQUEST/ACK), la renovación ni los clientes reales.
- **IPv6**: solo ICMPv6 está permitido; no se ha probado tráfico IPv6.
- **Persistencia**: no se ha comprobado la carga de nftables ni de dnsmasq al arrancar el sistema, ni las unidades de systemd (solo `systemd-analyze verify`, que sólo se queja de que `/opt/...` no existe en la máquina de pruebas).
- **CI en GitHub**: el workflow se ha validado con `actionlint`, pero se ha escrito antes de publicar el repositorio; su primera ejecución real está pendiente (en `ubuntu-latest` el laboratorio netns necesita relajar la restricción de AppArmor, que el workflow intenta).
