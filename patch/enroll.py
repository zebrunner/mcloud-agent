#!/usr/bin/env python3
"""The enrollment of this host in MCloud (README.md#node-enrollment): `./zebrunner.sh join` runs it.

  enroll.py <settings file> <public CURVE key of this host>

Reads the join string of `./zebrunner.sh node-invite` of mcloud from a hidden prompt (a terminal) or from stdin, never
from the command line:

  mcloud-join://<host>:<port>?label=<label>&grid=<host>:<port>&pin=<pin>&token=<invite>

sends the invite with the label and the public key to POST /api/v1/nodes/enroll of MCloud over HTTPS, trusting only the
server whose TLS key has the pin (curl --pinnedpubkey), and writes the settings of the answer into the settings file
(mode 600): the URL and the TLS pin of MCloud, the token of this host, the CURVE key of the server, the endpoints of
MCloud and the address of this host. The secrets go to curl on stdin, not in its arguments.
"""

import getpass
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from urllib.parse import parse_qs, unquote, urlsplit

LABEL = r"[a-z0-9][a-z0-9-]{0,39}"
HOST = r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?"
INVITE = re.compile(r"^mci1\.[A-Za-z0-9_-]{43}$")
PIN = re.compile(r"^[A-Za-z0-9+/]{43}=$")
NODE_TOKEN = r"^mcn1\.(" + LABEL + r")\.[A-Za-z0-9_-]{43}$"
CURVE_KEY = re.compile(r"^[0-9a-fA-F]{64}$")


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


def enroll(join, public_key):
    """The answer of the enrollment, over HTTPS to the server with the pinned key only."""
    body = json.dumps({"invite": join["invite"], "label": join["label"], "publicKey": public_key})
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


def settings_of(join, answer):
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
    settings = {
        "MCLOUD_URL": f"https://{join['host']}:{join['port']}",
        "MCLOUD_TLS_PIN": join["pin"],
        "MCLOUD_NODE_TOKEN": token,
        "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY": server_key,
        "PUBLIC_IP": host_of(stf.hostname, "the host of MCloud"),
        "PUBLIC_IP_PORT": str(stf.port or (443 if stf.scheme == "https" else 80)),
        "PUBLIC_IP_PROTOCOL": stf.scheme,
        "SELENIUM_HUB_HOST": join["grid_host"],
        "SELENIUM_HUB_PORT": str(join["grid_port"]),
        "STF_PROVIDER_HOST": address,
    }
    # the ports of the triproxies of the answer on the host this host reaches MCloud with
    for name, key in (("SUB", "sub"), ("PUSH", "push"), ("APP_DEALER", "appDealer"), ("DEV_DEALER", "devDealer")):
        endpoint = str(endpoints.get(key, ""))
        port = endpoint.rpartition(":")[2]
        settings[f"STF_PROVIDER_CONNECT_{name}"] = f"tcp://{join['host']}:{port_of(port, 'a ZeroMQ port')}"
    return settings


def write_settings(path, settings):
    """The settings in the file (the lines replaced, the missing ones before `devices:`), mode 600, a backup first."""
    with open(path, encoding="utf-8") as file:
        lines = file.read().split("\n")
    backup = f"{path}.bak-join-{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copyfile(path, backup)
    os.chmod(backup, stat.S_IRUSR | stat.S_IWUSR)
    for name, value in settings.items():
        line = f'{name}: "{value}"' if value else f"{name}:"
        index = next((i for i, text in enumerate(lines) if re.match(rf"^{name}:", text)), None)
        if index is None:
            index = next((i for i, text in enumerate(lines) if text.startswith("devices:")), len(lines))
            lines.insert(index, line)
        else:
            lines[index] = line
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_CREAT, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write("\n".join(lines))
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    return backup


def main():
    if len(sys.argv) != 3 or not CURVE_KEY.match(sys.argv[2]):
        print(__doc__, file=sys.stderr)
        return 2
    path, public_key = sys.argv[1], sys.argv[2]
    try:
        join = parse_join(read_join())
        settings = settings_of(join, enroll(join, public_key))
        backup = write_settings(path, settings)
    except (EnrollError, ValueError) as err:
        print(f"The enrollment failed: {err}", file=sys.stderr)
        return 1
    address = settings["STF_PROVIDER_HOST"]
    print(f"This host is enrolled in MCloud {join['host']} as {join['label']}, its address is {address}.")
    print(f"The settings are written to {path} (mode 600), the previous ones to {backup}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
