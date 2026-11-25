#!/usr/bin/env python3
"""The stability of the USB ports of a Linux host, whether the port or the device is to blame (README.md#usb-stability).

usb_stats.py [--days N] [--threshold N] [--json] [--devices FILE] [--device ID]... [--summary]

The kernel log (journalctl _TRANSPORT=kernel, every boot) has every connection of a port with the serial of the device,
every disconnection and the protocol errors; the docker log (journalctl -u docker) the failed starts of the containers
of an unplugged device (not a device node). A port is flapping when it has more than --threshold disconnections on a
day of the period; then the verdict: the port (different devices flapped on it, or its device is stable on another
port), the device (it flaps on different ports, or another device was stable on the port) or unknown (one device on
one port). The status is 1 with a flapping port, 2 when the logs cannot be read. --summary prints one line per
flapping port for ./zebrunner.sh doctor. The standard library only, Python 3.8+.

The tests give the logs with USB_STATS_KERNEL_LOG, USB_STATS_DOCKER_LOG (files of `journalctl -o short-iso`) and
USB_STATS_SYSFS (the folder of the USB devices, /sys/bus/usb/devices) instead of the ones of the host.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

# a line of `journalctl -o short-iso`: <time> <host> <unit>: <message>
LINE = re.compile(r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})\S*\s+\S+\s+[^:]+:\s+(.*)$")
SERIAL = re.compile(r"^usb (\d+-[\d.]+): SerialNumber: (\S+)")
# the kernel names a device by its driver: usb, or apple-mfi-fastcharge of an iPhone
DISCONNECT = re.compile(r"^\S+ (\d+-[\d.]+): USB disconnect")
# the errors of the USB protocol: -71 EPROTO, -110 ETIMEDOUT, -32 EPIPE, -62 ETIME
ERROR = re.compile(r"^\S+ (\d+-[\d.]+): .*error (-71|-110|-32|-62)\b")
# the columns of the table
ROW = "{:<12} {:<36} {:>6} {:>8} {:>7} {:>11}  {}"
# dockerd logs the message in quotes, its quotes escaped: \"/dev/device-...\"
NOT_A_NODE = re.compile(r'adding custom device \\?"/dev/(device-[^"\\]+)\\?": not a device node')


class Port:
    def __init__(self, name):
        self.name = name
        self.per_day = {}
        self.errors = 0
        # the devices of the port in the order of their connections: [serial, first, last]
        self.holders = []
        self.serial = None

    @property
    def disconnects(self):
        return sum(self.per_day.values())

    @property
    def max_per_day(self):
        return max(self.per_day.values()) if self.per_day else 0


def read_log(variable, args):
    """The lines of a log: the file of the variable (the tests), else journalctl with the arguments."""
    path = os.environ.get(variable)
    if path:
        with open(path, encoding="utf-8", errors="replace") as log:
            return log.read().splitlines()
    result = subprocess.run(
        ["journalctl", "--no-pager", "-o", "short-iso", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 and not result.stdout:
        raise PermissionError(result.stderr.strip() or "journalctl failed")
    return result.stdout.splitlines()


def load_devices(path):
    """The devices of mcloud-devices.txt: the key=value fields of a device per line."""
    devices = []
    try:
        with open(path, encoding="utf-8") as listing:
            for line in listing:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                fields = dict(field.split("=", 1) for field in line.split("|") if "=" in field)
                if fields.get("id"):
                    devices.append(fields)
    except OSError:
        pass
    return devices


def usb_serial(serial):
    """A serial to compare: upper case without dashes; the kernel gives the UDID of an iPhone with or without its dash,
    the adb serial of Android is the USB serial."""
    return serial.replace("-", "").upper()


def label(device):
    location = device.get("location")
    return "{} ({})".format(device["name"], location) if location else device.get("name", device["id"])


def current_ports(sysfs):
    """The port of every connected USB device by its serial, from sysfs."""
    ports = {}
    try:
        names = os.listdir(sysfs)
    except OSError:
        return ports
    for name in names:
        if ":" in name or "-" not in name:
            continue
        try:
            with open(os.path.join(sysfs, name, "serial"), encoding="utf-8", errors="replace") as serial:
                ports[usb_serial(serial.read().strip())] = name
        except OSError:
            continue
    return ports


def analyze(kernel_lines):
    """The ports of the kernel log, the daily disconnections of every (port, serial) and the first date of the log."""
    ports = {}
    by_serial = {}
    first_date = None
    for line in kernel_lines:
        match = LINE.match(line)
        if not match:
            continue
        date, clock, message = match.groups()
        first_date = first_date or date
        stamp = f"{date} {clock}"
        found = SERIAL.match(message)
        if found:
            port = ports.setdefault(found.group(1), Port(found.group(1)))
            serial = usb_serial(found.group(2))
            port.serial = serial
            if port.holders and port.holders[-1][0] == serial:
                port.holders[-1][2] = stamp
            else:
                port.holders.append([serial, stamp, stamp])
            continue
        found = DISCONNECT.match(message)
        if found:
            port = ports.setdefault(found.group(1), Port(found.group(1)))
            port.per_day[date] = port.per_day.get(date, 0) + 1
            if port.serial:
                if port.holders and port.holders[-1][0] == port.serial:
                    port.holders[-1][2] = stamp
                daily = by_serial.setdefault(port.serial, {}).setdefault(port.name, {})
                daily[date] = daily.get(date, 0) + 1
            continue
        found = ERROR.match(message)
        if found:
            ports.setdefault(found.group(1), Port(found.group(1))).errors += 1
    return ports, by_serial, first_date


def verdict(port, by_serial, held, threshold, names):
    """The verdict of a flapping port and its reason: port, device or unknown."""

    def flapping(serial, name):
        return any(count > threshold for count in by_serial.get(serial, {}).get(name, {}).values())

    holders = list(dict.fromkeys(holder[0] for holder in port.holders))
    flappers = [serial for serial in holders if flapping(serial, port.name)]
    if len(flappers) > 1:
        return "port", "different devices flapped here: " + ", ".join(names(serial) for serial in flappers)
    if not flappers:
        return "unknown", "the disconnections of a device without its serial in the kernel log"
    serial = flappers[0]
    other_ports = [name for name in held.get(serial, []) if name != port.name]
    flapped = [name for name in other_ports if flapping(serial, name)]
    if flapped:
        return "device", "{} flaps on {} too".format(names(serial), ", ".join(flapped))
    if other_ports:
        return "port", "{} flapped here, it is stable on {}".format(names(serial), ", ".join(other_ports))
    others = [other for other in holders if other != serial]
    if others:
        return "device", "{} flapped here, {} stable on this port".format(
            names(serial), ", ".join(names(other) for other in others)
        )
    return "unknown", f"one device on one port: {names(serial)}"


def main():
    parser = argparse.ArgumentParser(description="The stability of the USB ports of this Linux host.")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--threshold", type=int, default=10)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--summary", action="store_true")
    parser.add_argument("--devices", default=os.environ.get("MCLOUD_DEVICES", "/usr/local/bin/mcloud-devices.txt"))
    parser.add_argument("--device", action="append", default=[], help="an id of a device of the report, all without it")
    args = parser.parse_args()
    if args.days < 1 or args.threshold < 1:
        parser.error("--days and --threshold are 1 or more")

    since = f"-{args.days} days"
    try:
        # the kernel messages of every boot of the period: journalctl -k is the current boot only
        kernel = read_log("USB_STATS_KERNEL_LOG", ["_TRANSPORT=kernel", "--since", since])
        docker = read_log("USB_STATS_DOCKER_LOG", ["-u", "docker", "--since", since])
    except (PermissionError, OSError) as error:
        print(
            f"The logs are not readable: {error} (the groups adm or systemd-journal read them, or sudo).",
            file=sys.stderr,
        )
        return 2

    ports, by_serial, first_date = analyze(kernel)
    # the ports every device was connected to
    held = {}
    for port in ports.values():
        for serial in dict.fromkeys(holder[0] for holder in port.holders):
            held.setdefault(serial, []).append(port.name)
    devices = load_devices(args.devices)
    known = {usb_serial(device["id"]): device for device in devices}

    def names(serial):
        device = known.get(serial)
        return label(device) if device else f"unknown device {serial}"

    not_a_node = {}
    for line in docker:
        found = NOT_A_NODE.search(line)
        if found:
            not_a_node[found.group(1)] = not_a_node.get(found.group(1), 0) + 1
    connected = current_ports(os.environ.get("USB_STATS_SYSFS", "/sys/bus/usb/devices"))

    chosen = set(args.device)
    selected = {usb_serial(device["id"]) for device in devices if chosen.intersection((device["id"], device["name"]))}
    today = datetime.date.today()
    start = today - datetime.timedelta(days=args.days)
    rows = []
    for port in sorted(ports.values(), key=lambda port: [int(part) for part in re.split(r"[-.]", port.name)]):
        serials = [holder[0] for holder in port.holders]
        if args.device and not selected.intersection(serials):
            continue
        if not port.disconnects and not args.device:
            continue
        holder = port.holders[-1][0] if port.holders else None
        device = known.get(holder) if holder else None
        container = "device-{}-{}".format(device["name"], device["id"]) if device else None
        flapping = port.max_per_day > args.threshold
        kind, reason = verdict(port, by_serial, held, args.threshold, names) if flapping else ("ok", "")
        rows.append(
            {
                "port": port.name,
                "device": label(device) if device else (holder and f"unknown device {holder}"),
                "id": device["id"] if device else None,
                "serial": holder,
                "connected_now": bool(holder and connected.get(holder) == port.name),
                "disconnects": port.disconnects,
                "max_per_day": port.max_per_day,
                "per_day": dict(sorted(port.per_day.items())),
                "errors": port.errors,
                "not_a_device_node": not_a_node.get(container, 0) if container else 0,
                "flapping": flapping,
                "verdict": kind,
                "reason": reason,
                "holders": [
                    {"device": names(serial), "first": first, "last": last} for serial, first, last in port.holders
                ],
            }
        )
    flapping = [row for row in rows if row["flapping"]]
    report = {
        "days": args.days,
        "since": str(start),
        "until": str(today),
        "log_starts": first_date,
        "threshold": args.threshold,
        "ports": rows,
        "flapping": bool(flapping),
    }

    if args.json:
        print(json.dumps(report, indent=2))
    elif args.summary:
        for row in flapping:
            print(
                "USB port {} ({}): {} disconnects in {} days, up to {} a day; {}: {}".format(
                    row["port"],
                    row["device"] or "no device",
                    row["disconnects"],
                    args.days,
                    row["max_per_day"],
                    row["verdict"],
                    row["reason"],
                )
            )
    else:
        print_table(report, rows, ports, names)
    return 1 if flapping else 0


def holders_text(port, names):
    """The devices of a port in the order of their connections: the first one until its last time, the last one since
    its first time (it is still there), the ones between them with both."""
    parts = []
    last = len(port.holders) - 1
    for index, (serial, first, until) in enumerate(port.holders):
        if index == last:
            parts.append(f"{names(serial)} since {first[:10]}")
        elif index == 0:
            parts.append(f"{names(serial)} until {until[:10]}")
        else:
            parts.append(f"{names(serial)} {first[:10]} .. {until[:10]}")
    return ", ".join(parts)


def print_table(report, rows, ports, names):
    print(
        "USB stability, {} days ({} .. {}), threshold {} disconnects/day".format(
            report["days"], report["since"], report["until"], report["threshold"]
        )
    )
    if report["log_starts"] and report["log_starts"] > report["since"]:
        print(
            "The kernel log starts on {}: the earlier days are not in it (a volatile journal?).".format(
                report["log_starts"]
            )
        )
    if not rows:
        print("No disconnection of a USB device in the period.")
        return
    print()
    print(ROW.format("PORT", "DEVICE", "DISC", "MAX/DAY", "ERRORS", "NOT_A_NODE", "VERDICT"))
    for row in rows:
        verdict_text = "{}: {}".format(row["verdict"], row["reason"]) if row["flapping"] else "ok"
        print(
            ROW.format(
                row["port"],
                (row["device"] or "-")[:36],
                row["disconnects"],
                row["max_per_day"],
                row["errors"],
                row["not_a_device_node"],
                verdict_text,
            )
        )
    shared = [port for port in ports.values() if len({holder[0] for holder in port.holders}) > 1]
    if shared:
        print()
        print("Ports held by more than one device in the period:")
        for port in shared:
            print(f"{port.name:<12} {holders_text(port, names)}")
    if any(row["verdict"] == "unknown" for row in rows if row["flapping"]):
        print()
        print(
            "unknown: swap the device with a stable device of another port, "
            "then run zebrunner-farm doctor usb-stats again."
        )
    if any(row["verdict"] == "port" for row in rows if row["flapping"]):
        print("port: replace the cable or use another port of the hub (or another hub) for the device.")
    if any(row["verdict"] == "device" for row in rows if row["flapping"]):
        print("device: check the connector and the cable of the device, it flaps on any port.")


if __name__ == "__main__":
    sys.exit(main())
