#!/usr/bin/env python3
"""The enrollment of this host in MCloud (README.md#node-enrollment): `./zebrunner.sh join` runs it.

  enroll.py <settings file: config/settings.yml> <public CURVE key of this host>

Reads the join string of `./zebrunner.sh node-invite` of mcloud from a hidden prompt (a terminal) or from stdin, never
from the command line:

  mcloud-join://<host>:<port>?label=<label>&grid=<host>:<port>&pin=<pin>&token=<invite>

sends the invite with the label, the public key and the public key of a new WireGuard key pair of this host to
POST /api/v1/nodes/enroll of MCloud over HTTPS, trusting only the server whose TLS key has the pin (curl
--pinnedpubkey), and writes the settings of the answer into the settings file (mode 600): the URL and the TLS pin of
MCloud, the token of this host, the CURVE key of the server, the endpoints of MCloud and the address of this host; with
the WireGuard tunnel of MCloud on (`wireguard` in the answer, README.md#wireguard-tunnel) also the WG_* settings, the
endpoints of MCloud and the address of this host are then the ones of the tunnel. The secrets go to curl on stdin, not
in its arguments. It needs PyYAML (patch/settings.py writes the settings): zebrunner.sh runs it with yaml_python of
patch/utility.sh.
"""

import base64
import getpass
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import parse_qs, unquote, urlsplit

from curve_keygen import x25519_base
from settings import SettingsError, load, write_settings

LABEL = r"[a-z0-9][a-z0-9-]{0,39}"
HOST = r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?"
INVITE = re.compile(r"^mci1\.[A-Za-z0-9_-]{43}$")
PIN = re.compile(r"^[A-Za-z0-9+/]{43}=$")
NODE_TOKEN = r"^mcn1\.(" + LABEL + r")\.[A-Za-z0-9_-]{43}$"
CURVE_KEY = re.compile(r"^[0-9a-fA-F]{64}$")
# a WireGuard key: the base64 of 32 bytes (wg genkey, wg pubkey)
WG_KEY = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$")
# the settings of the WireGuard tunnel, cleared by a join with the tunnel of MCloud off
WG_SETTINGS = (
    "WG_PRIVATE_KEY",
    "WG_ADDRESS",
    "WG_SERVER_ADDRESS",
    "WG_SERVER_PUBLIC_KEY",
    "WG_ENDPOINT",
    "WG_NETWORK",
    "WG_PERSISTENT_KEEPALIVE",
)


class EnrollError(Exception):
    pass


def port_of(value, name):
    if not re.fullmatch(r"[0-9]{1,5}", value or "") or not 0 < int(value) < 65536:
        raise EnrollError(f"{name} is not a port: {value!r}")
    return int(value)


def host_of(value, name):
    if not re.fullmatch(HOST, value or ""):
        raise EnrollError(f"{name} is not a host name or address: {value!r}")
    return value


def wireguard_keys():
    """A new WireGuard key pair (private, public) in base64: X25519 as the CURVE keys (patch/curve_keygen.py), in Python
    only: the LibreSSL of macOS has no X25519 and wg is not installed before the deploy. The private key is clamped as
    `wg genkey` does."""
    secret = bytearray(os.urandom(32))
    secret[0] &= 248
    secret[31] = (secret[31] & 127) | 64
    secret = bytes(secret)
    return base64.b64encode(secret).decode(), base64.b64encode(x25519_base(secret)).decode()


def parse_join(text):
    """The parts of the join string, validated."""
    parts = urlsplit(text.strip())
    if parts.scheme != "mcloud-join" or not parts.hostname or parts.path not in ("", "/"):
        raise EnrollError("not a join string of ./zebrunner.sh node-invite (mcloud-join://...)")
    query = {key: values[0] for key, values in parse_qs(parts.query, strict_parsing=True).items()}
    grid = query.get("grid", "")
    grid_host, _, grid_port = grid.rpartition(":")
    join = {
        "host": host_of(parts.hostname, "the host"),
        "port": port_of(str(parts.port or ""), "the port"),
        "label": query.get("label", ""),
        "grid_host": host_of(grid_host, "the host of the grid"),
        "grid_port": port_of(grid_port, "the port of the grid"),
        "pin": unquote(query.get("pin", "")),
        "invite": query.get("token", ""),
    }
    if not re.fullmatch(LABEL, join["label"]):
        raise EnrollError("the label of the join string is not valid")
    if not PIN.match(join["pin"]):
        raise EnrollError("the pin of the join string is not a sha256 in base64")
    if not INVITE.match(join["invite"]):
        raise EnrollError("the invite of the join string is not valid")
    return join


def read_join():
    if sys.stdin.isatty():
        return getpass.getpass("Paste the join string of ./zebrunner.sh node-invite (hidden): ")
    return sys.stdin.readline()


def enroll(join, public_key, wg_public_key):
    """The answer of the enrollment, over HTTPS to the server with the pinned key only. MCloud without the WireGuard
    tunnel ignores wgPublicKey."""
    body = json.dumps(
        {"invite": join["invite"], "label": join["label"], "publicKey": public_key, "wgPublicKey": wg_public_key}
    )
    url = f"https://{join['host']}:{join['port']}/api/v1/nodes/enroll"
    # -k: a self-signed certificate is common, the pin is the trust; curl still refuses any other key
    command = [
        "curl",
        "-sS",
        "-k",
        "--max-time",
        "30",
        "--pinnedpubkey",
        f"sha256//{join['pin']}",
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        "@-",
        url,
        "-w",
        "\n%{http_code}",
    ]
    try:
        result = subprocess.run(command, input=body, capture_output=True, text=True, check=False)
    except FileNotFoundError as err:
        raise EnrollError("curl is not installed") from err
    if result.returncode != 0:
        reason = result.stderr.strip() or f"curl exit code {result.returncode}"
        if result.returncode == 90:
            reason = "the TLS key of the server is not the pinned one: a wrong host or a man in the middle"
        raise EnrollError(f"MCloud {join['host']}:{join['port']} is not reachable: {reason}")
    answer, _, code = result.stdout.rpartition("\n")
    if code == "429":
        raise EnrollError("MCloud refused too many attempts, wait a minute")
    if code != "200":
        raise EnrollError(
            f"MCloud refused the enrollment (HTTP {code}): the invite is used, expired, of another label or "
            "replaced by a newer one; ask for a new one (./zebrunner.sh node-invite of mcloud)"
        )
    try:
        return json.loads(answer)
    except ValueError as err:
        raise EnrollError("MCloud answered no JSON") from err


def ipv4_of(value, name):
    try:
        return str(ipaddress.IPv4Address(value))
    except ValueError as err:
        raise EnrollError(f"{name} is not an IPv4 address: {value!r}") from err


def wireguard_of(answer, wg_private_key):
    """The settings of the WireGuard tunnel of the answer (README.md#wireguard-tunnel), validated; None when MCloud has
    the tunnel off (or is an earlier version): no `wireguard` in the answer."""
    wireguard = answer.get("wireguard")
    if wireguard is None:
        return None
    if not isinstance(wireguard, dict):
        raise EnrollError("MCloud answered no valid WireGuard settings")
    try:
        network = ipaddress.IPv4Network(str(wireguard.get("network", "")))
    except ValueError as err:
        raise EnrollError("MCloud answered no valid WireGuard network") from err
    address = ipv4_of(str(wireguard.get("address", "")), "the WireGuard address of this host")
    server = ipv4_of(str(wireguard.get("serverAddress", "")), "the WireGuard address of MCloud")
    if ipaddress.IPv4Address(address) not in network or ipaddress.IPv4Address(server) not in network:
        raise EnrollError(f"the WireGuard addresses {address} and {server} are not in the network {network}")
    if address == server:
        raise EnrollError("MCloud answered its own WireGuard address as the one of this host")
    server_key = str(wireguard.get("publicKey", ""))
    if not WG_KEY.match(server_key):
        raise EnrollError("MCloud answered no valid WireGuard key")
    endpoint_host, _, endpoint_port = str(wireguard.get("endpoint", "")).rpartition(":")
    endpoint = f"{host_of(endpoint_host, 'the WireGuard endpoint')}:{port_of(endpoint_port, 'the WireGuard port')}"
    keepalive = wireguard.get("persistentKeepalive", 25)
    if isinstance(keepalive, bool) or not isinstance(keepalive, int) or not 0 <= keepalive < 65536:
        raise EnrollError("MCloud answered no valid persistentKeepalive")
    return {
        "WG_ENABLED": True,
        "WG_PRIVATE_KEY": wg_private_key,
        "WG_ADDRESS": address,
        "WG_SERVER_ADDRESS": server,
        "WG_SERVER_PUBLIC_KEY": server_key,
        "WG_ENDPOINT": endpoint,
        "WG_NETWORK": str(network),
        "WG_PERSISTENT_KEEPALIVE": keepalive,
    }


def settings_of(join, answer, wg_private_key=""):
    """The settings of the answer, validated: a server must not inject anything into the settings file."""
    token = str(answer.get("nodeToken", ""))
    match = re.match(NODE_TOKEN, token)
    if not match or match.group(1) != join["label"]:
        raise EnrollError("MCloud answered no valid token of this label")
    server_key = str(answer.get("serverPublicKey", ""))
    if not CURVE_KEY.match(server_key):
        raise EnrollError("MCloud answered no valid CURVE key")
    address = host_of(str(answer.get("address", "")), "the address of this host")
    stf = urlsplit(str(answer.get("stfUrl", "")))
    if stf.scheme not in ("http", "https") or not stf.hostname:
        raise EnrollError("MCloud answered no valid URL")
    endpoints = answer.get("endpoints") or {}
    wireguard = wireguard_of(answer, wg_private_key)
    # with the tunnel MCloud connects to this host at its address of the tunnel (the address of the invite) and this
    # host to MCloud at the address of MCloud there: the grid and ZeroMQ go through the tunnel
    server_host = wireguard["WG_SERVER_ADDRESS"] if wireguard else join["host"]
    if wireguard and address != wireguard["WG_ADDRESS"]:
        raise EnrollError(f"the address of this host {address} is not its WireGuard address {wireguard['WG_ADDRESS']}")
    settings = {
        "MCLOUD_URL": f"https://{join['host']}:{join['port']}",
        "MCLOUD_TLS_PIN": join["pin"],
        "MCLOUD_NODE_TOKEN": token,
        "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY": server_key,
        "PUBLIC_IP": host_of(stf.hostname, "the host of MCloud"),
        "PUBLIC_IP_PORT": str(stf.port or (443 if stf.scheme == "https" else 80)),
        "PUBLIC_IP_PROTOCOL": stf.scheme,
        "SELENIUM_HUB_HOST": server_host if wireguard else join["grid_host"],
        "SELENIUM_HUB_PORT": str(join["grid_port"]),
        "STF_PROVIDER_HOST": address,
    }
    # the ports of the triproxies of the answer on the host this host reaches MCloud with
    for name, key in (("SUB", "sub"), ("PUSH", "push"), ("APP_DEALER", "appDealer"), ("DEV_DEALER", "devDealer")):
        endpoint = str(endpoints.get(key, ""))
        port = endpoint.rpartition(":")[2]
        settings[f"STF_PROVIDER_CONNECT_{name}"] = f"tcp://{server_host}:{port_of(port, 'a ZeroMQ port')}"
    if wireguard:
        settings.update(wireguard)
    return settings


def without_wireguard(path):
    """The settings that turn off the tunnel of an earlier join (its private key removed), nothing for a settings file
    that never had it: a join of MCloud without the tunnel writes the same settings as before."""
    if not any(name == "WG_ENABLED" or name in WG_SETTINGS for name in load(path)):
        return {}
    return {"WG_ENABLED": False, **dict.fromkeys(WG_SETTINGS, "")}


def main():
    if len(sys.argv) != 3 or not CURVE_KEY.match(sys.argv[2]):
        print(__doc__, file=sys.stderr)
        return 2
    path, public_key = sys.argv[1], sys.argv[2]
    try:
        join = parse_join(read_join())
        wg_private_key, wg_public_key = wireguard_keys()
        settings = settings_of(join, enroll(join, public_key, wg_public_key), wg_private_key)
        if "WG_ENABLED" not in settings:
            settings.update(without_wireguard(path))
        backup = f"{path}.bak-join-{time.strftime('%Y%m%d%H%M%S')}"
        write_settings(path, settings, backup)
    except (EnrollError, SettingsError, ValueError) as err:
        print(f"The enrollment failed: {err}", file=sys.stderr)
        return 1
    address = settings["STF_PROVIDER_HOST"]
    print(f"This host is enrolled in MCloud {join['host']} as {join['label']}, its address is {address}.")
    if settings.get("WG_ENABLED"):
        print(
            f"The WireGuard tunnel of MCloud is on: MCloud is {settings['WG_SERVER_ADDRESS']} in it, the interface "
            "mcloud of this host is set up by ./zebrunner.sh ansible."
        )
    print(f"The settings are written to {path} (mode 600), the previous ones to {backup}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
