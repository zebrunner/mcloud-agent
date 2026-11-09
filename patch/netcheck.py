#!/usr/bin/env python3
"""The network probes of `./zebrunner.sh doctor`, the same on Linux and macOS (the standard library only).

resolve <host>           the IPv4 addresses of the host, one per line; fails when it is not resolved
tcp <host> <port> [sec]  connects to the port; fails with the reason when it cannot
source <address>         the address of this host the connections to the address go from (its route)
local <address>          succeeds when the address is one of this host
kind <address>           loopback, private or public
"""

import ipaddress
import socket
import sys


def resolve(host):
    addresses = sorted({info[4][0] for info in socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)})
    print("\n".join(addresses))


def tcp(host, port, timeout="5"):
    with socket.create_connection((host, int(port)), timeout=float(timeout)):
        pass


def source(address):
    # a UDP socket sends nothing on connect, it only takes the route to the address
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect((address, 9))
        print(sock.getsockname()[0])


def local(address):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((address, 0))


def kind(address):
    ip = ipaddress.ip_address(address)
    if ip.is_loopback:
        print("loopback")
    elif ip.is_private:
        print("private")
    else:
        print("public")


def main():
    commands = {"resolve": resolve, "tcp": tcp, "source": source, "local": local, "kind": kind}
    if len(sys.argv) < 3 or sys.argv[1] not in commands:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        commands[sys.argv[1]](*sys.argv[2:])
    except (OSError, ValueError) as err:
        print(getattr(err, "strerror", None) or str(err) or type(err).__name__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
