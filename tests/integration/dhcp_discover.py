#!/usr/bin/env python3
"""Envía un DHCPDISCOVER y muestra la IP que ofrece el servidor (yiaddr).

Uso: dhcp_discover.py <interfaz> <MAC>
Solo biblioteca estándar. Sale con 0 e imprime la IP ofrecida; con 1 si no hay OFFER en 3 s.
Se usa en el laboratorio de netns para comprobar el DHCP de dnsmasq sin un cliente DHCP instalado.
"""
import socket
import struct
import sys

XID = 0x1F2E3D4C
MAGIC_COOKIE = b"\x63\x82\x53\x63"
DHCP_OFFER = 2


def build_discover(mac: bytes) -> bytes:
    header = struct.pack("!BBBBIHH4s4s4s4s16s64s128s", 1, 1, 6, 0, XID, 0, 0x8000,
                         b"\0" * 4, b"\0" * 4, b"\0" * 4, b"\0" * 4, mac.ljust(16, b"\0"),
                         b"\0" * 64, b"\0" * 128)
    options = b"\x35\x01\x01" + b"\xff"  # opción 53 = DISCOVER, fin
    return header + MAGIC_COOKIE + options


def message_type(packet: bytes) -> int:
    options = packet[240:]
    i = 0
    while i < len(options) and options[i] != 255:
        if options[i] == 0:
            i += 1
            continue
        if options[i] == 53:
            return options[i + 2]
        i += 2 + options[i + 1]
    return -1


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 64
    interface, mac_text = sys.argv[1], sys.argv[2]
    mac = bytes(int(part, 16) for part in mac_text.split(":"))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode())
    sock.settimeout(8)  # dnsmasq hace un ping de comprobación (~3 s) antes de ofrecer una IP dinámica
    sock.bind(("0.0.0.0", 68))
    sock.sendto(build_discover(mac), ("255.255.255.255", 67))
    try:
        while True:
            packet, _ = sock.recvfrom(2048)
            if len(packet) > 240 and struct.unpack("!I", packet[4:8])[0] == XID \
                    and message_type(packet) == DHCP_OFFER:
                print(socket.inet_ntoa(packet[16:20]))
                return 0
    except socket.timeout:
        print("sin OFFER", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
