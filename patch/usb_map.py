#!/usr/bin/env python3
"""The USB tree of a Linux host: which device is in which port of which hub, the free ports (README.md#usb-map).

usb_map.py [--json] [--days N] [--devices FILE] [--device ID]... [--summary]

It reads sysfs: every hub with its ports, the whole tree, a hub behind a hub too. The chips of one physical hub are one
hub: a hub chip on the last ports of a hub chip (the ports from the last one down that hold a hub) is a part of the
same hub, unless the kernel tells it is removable or it lacks the USB3 half its parent has; a chip the hub descriptor
marks as fixed is a part too. The USB3 half of a hub (the peer of its port) is a part of the hub, a USB3 device is
shown on the port of the hub. Per port the device of the farm (by the serial: the adb serial of Android, the UDID of
iOS without its dash), an unknown USB device or nothing; per hub its chips and its controller. At the end the free
ports and the USB devices of the farm that are not on USB, with the port and the time the kernel log (all of it) last
saw them.
--days N adds the disconnections of every port in N days (patch/usb_stats.py). The status is 1 when a device of the
farm is not on USB, 2 without sysfs. --summary prints one line per device not on USB for ./zebrunner.sh doctor. The
standard library only, Python 3.8+.

The tests give the tree with USB_MAP_SYSFS (the folder of /sys/bus/usb/devices) and the kernel log with
USB_STATS_KERNEL_LOG.
"""

import argparse
import datetime
import json
import os
import re
import socket
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import usb_stats  # noqa: E402

# a USB device of sysfs: <bus>-<port>[.<port>]...
DEVICE = re.compile(r"^(\d+)-(\d+(?:\.\d+)*)$")
# the name of a port of a hub: usb<bus>-port<n> (a root hub) or <device>-port<n>
PORT = re.compile(r"^(usb\d+|\d+-[\d.]+)-port(\d+)$")
PCI = re.compile(r"^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$")
ROW = "{:>4} {:<12} {:<5} {:<40} {}"


class Device:
    def __init__(self, sysfs, name):
        self.name = name
        self.root = name.startswith("usb")
        self.bus = int(name[3:]) if self.root else int(name.split("-")[0])
        base = os.path.join(sysfs, name)

        def value(key):
            try:
                with open(os.path.join(base, key), encoding="utf-8", errors="replace") as file:
                    return file.read().strip()
            except OSError:
                return ""

        self.vendor = value("idVendor")
        self.product_id = value("idProduct")
        self.product = value("product")
        self.serial = value("serial")
        self.speed = value("speed")
        self.hub = value("bDeviceClass") == "09"
        self.maxchild = int(value("maxchild") or 0) if self.hub else 0
        self.removable = value("removable")
        self.real = os.path.realpath(base)

    @property
    def usb_id(self):
        return f"{self.vendor}:{self.product_id}"

    @property
    def superspeed(self):
        try:
            return float(self.speed) >= 5000
        except ValueError:
            return False


def path_key(name):
    """The order of the paths: the bus, then the ports as numbers."""
    return [int(part) for part in re.split(r"[-.]", name.replace("usb", "")) if part.isdigit()]


def speed_text(speed):
    try:
        mbps = float(speed)
    except ValueError:
        return ""
    if mbps >= 1000:
        return f"{mbps / 1000:g}G"
    return f"{mbps:g}M"


class Tree:
    """The USB devices of sysfs and the links between the USB2 and the USB3 halves of their ports."""

    def __init__(self, sysfs):
        self.sysfs = sysfs
        self.devices = {}
        for name in os.listdir(sysfs):
            if ":" in name or not (name.startswith("usb") or DEVICE.match(name)):
                continue
            self.devices[name] = Device(sysfs, name)
        self.roots = {device.bus: device for device in self.devices.values() if device.root}

    def child(self, hub, port):
        """The path of the device on the port of the hub."""
        return f"{hub.bus}-{port}" if hub.root else f"{hub.name}.{port}"

    def peer(self, hub, port):
        """The (hub, port) of the other half (USB2 or USB3) of the port of the hub, None without one."""
        interface = f"{hub.bus}-0:1.0" if hub.root else f"{hub.name}:1.0"
        link = os.path.join(self.sysfs, hub.name, interface, f"{hub.name}-port{port}", "peer")
        try:
            target = os.path.basename(os.readlink(link))
        except OSError:
            return None
        found = PORT.match(target)
        if not found or found.group(1) not in self.devices:
            return None
        return self.devices[found.group(1)], int(found.group(2))

    def upstream(self, device):
        """The (hub, port) the device is on."""
        if device.root:
            return None
        bus, ports = DEVICE.match(device.name).groups()
        parts = ports.split(".")
        parent = self.roots.get(int(bus)) if len(parts) == 1 else self.devices.get(f"{bus}-{'.'.join(parts[:-1])}")
        return (parent, int(parts[-1])) if parent else None

    def half(self, hub):
        """The other half of a hub: the hub on the peer of the port of the hub (the peer of a root hub's port 1)."""
        if hub.root:
            for port in range(1, hub.maxchild + 1):
                found = self.peer(hub, port)
                if found:
                    return found[0]
            return None
        upstream = self.upstream(hub)
        found = upstream and self.peer(*upstream)
        if not found:
            return None
        other = self.devices.get(self.child(*found))
        return other if other and other.hub else None

    def primary(self, hub):
        """A hub of a USB2 bus, or a USB3 hub without a USB2 half: the one that shows the ports of both."""
        return not hub.superspeed or self.half(hub) is None

    def occupant(self, hub, port):
        """The device on the port of a primary hub, of its USB2 or USB3 half: (device, its path) or (None, None)."""
        device = self.devices.get(self.child(hub, port))
        if device:
            return device, device.name
        half = self.half(hub)
        if not half:
            return None, None
        found = self.peer(hub, port)
        path = self.child(*found) if found else self.child(half, port)
        device = self.devices.get(path)
        return (device, path) if device else (None, None)


class Slot:
    def __init__(self, number, path, device, aliases=()):
        self.number = number
        self.path = path
        self.device = device
        # the paths of both halves of the port: the kernel log names a port by the half of its device
        self.aliases = {path, *aliases}


class Hub:
    """A physical hub: its chips, their USB3 halves and its ports in order."""

    def __init__(self, tree, top, parent):
        self.tree = tree
        self.top = top
        self.parent = parent
        self.chips = []
        self.slots = []
        self.walk(top)

    def cascade(self, chip):
        """The ports of the chip that lead to the other chips of the same hub."""
        tree = self.tree
        half = tree.half(chip) is not None

        def part(device):
            if not device or not device.hub or device.removable == "removable":
                return False
            return tree.half(device) is not None or not half

        ports = set()
        for port in range(chip.maxchild, 0, -1):
            device, _ = tree.occupant(chip, port)
            if not part(device):
                break
            ports.add(port)
        for port in range(1, chip.maxchild + 1):
            device, _ = tree.occupant(chip, port)
            if device and device.hub and device.removable == "fixed":
                ports.add(port)
        return ports

    def walk(self, chip):
        self.chips.append(chip)
        cascade = self.cascade(chip)
        for port in range(1, chip.maxchild + 1):
            device, path = self.tree.occupant(chip, port)
            if port in cascade:
                self.walk(device)
            else:
                aliases = [self.tree.child(chip, port)]
                found = self.tree.peer(chip, port)
                if found:
                    aliases.append(self.tree.child(*found))
                self.slots.append(Slot(len(self.slots) + 1, path or aliases[0], device, aliases))

    @property
    def half(self):
        return self.tree.half(self.top)


def controller_of(device, roots, names):
    """The PCI address and the lspci name of the controller of the bus of the device."""
    root = roots.get(device.bus)
    if not root:
        return "", ""
    address = root.serial if PCI.match(root.serial) else os.path.basename(os.path.dirname(root.real))
    if address not in names:
        name = ""
        try:
            result = subprocess.run(["lspci", "-s", address], capture_output=True, text=True, check=False, timeout=5)
            name = result.stdout.strip().split(": ", 1)[-1] if result.stdout.strip() else ""
        except (OSError, subprocess.SubprocessError):
            pass
        names[address] = name
    return address, names[address]


def read_kernel(days):
    """The connections and the disconnections of the kernel log of the days, of the whole log without them."""
    since = ["--since", f"-{days} days"] if days else []
    try:
        return usb_stats.read_log(
            "USB_STATS_KERNEL_LOG", ["_TRANSPORT=kernel", "--grep", "SerialNumber: |USB disconnect", *since]
        )
    except PermissionError:
        # a journalctl without the pattern matching: the lines of 30 days at least
        return usb_stats.read_log("USB_STATS_KERNEL_LOG", ["_TRANSPORT=kernel", "--since", f"-{max(days, 30)} days"])


def last_seen(kernel_lines):
    """The last port of every serial in the kernel log and the time it was last there: {serial: (port, time)}. A
    disconnection of a port is of the last serial of the port, as for patch/usb_stats.py."""
    holder = {}
    seen = {}
    for line in kernel_lines:
        match = usb_stats.LINE.match(line)
        if not match:
            continue
        date, clock, message = match.groups()
        stamp = f"{date} {clock}"
        found = usb_stats.SERIAL.match(message)
        if found:
            serial = usb_stats.usb_serial(found.group(2))
            holder[found.group(1)] = serial
            seen[serial] = (found.group(1), stamp)
            continue
        found = usb_stats.DISCONNECT.match(message)
        if found:
            serial = holder.get(found.group(1))
            if serial and seen.get(serial, ("",))[0] == found.group(1):
                seen[serial] = (found.group(1), stamp)
    return seen


def main():
    parser = argparse.ArgumentParser(description="The USB tree of this Linux host.")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--summary", action="store_true")
    parser.add_argument("--days", type=int, default=0)
    parser.add_argument("--devices", default=os.environ.get("MCLOUD_DEVICES", "/usr/local/bin/mcloud-devices.txt"))
    parser.add_argument("--device", action="append", default=[], help="an id of a device of the map, all without it")
    args = parser.parse_args()
    if args.days < 0:
        parser.error("--days is 1 or more")

    sysfs = os.environ.get("USB_MAP_SYSFS", "/sys/bus/usb/devices")
    try:
        tree = Tree(sysfs)
    except OSError as error:
        print(f"No USB devices in sysfs: {error}", file=sys.stderr)
        return 2

    devices = usb_stats.load_devices(args.devices)
    farm = {usb_stats.usb_serial(device["id"]): device for device in devices}
    chosen = set(args.device)
    selected = {
        usb_stats.usb_serial(device["id"])
        for device in devices
        if not chosen or chosen.intersection((device["id"], device["name"]))
    }
    expected = [
        device
        for device in devices
        if device.get("connection", "usb") == "usb" and usb_stats.usb_serial(device["id"]) in selected
    ]
    on_usb = {usb_stats.usb_serial(device.serial) for device in tree.devices.values() if device.serial}
    missing = [device for device in expected if usb_stats.usb_serial(device["id"]) not in on_usb]

    kernel = None
    note = ""
    if args.days or missing:
        try:
            # a device not on USB: its last port in the whole kernel log, else the days of --days
            kernel = read_kernel(None if missing else args.days)
        except (PermissionError, OSError) as error:
            note = f"The kernel log is not readable: {error} (the groups adm or systemd-journal read it, or sudo)."
    disconnects = {}
    if kernel is not None and args.days:
        ports, _, _ = usb_stats.analyze(kernel)
        start = str(datetime.date.today() - datetime.timedelta(days=args.days))
        disconnects = {
            name: sum(count for day, count in port.per_day.items() if day >= start) for name, port in ports.items()
        }
    seen = last_seen(kernel) if kernel is not None else {}

    # the physical hubs, from the root hubs down, the hubs behind a port of a hub too
    controllers = {}
    hubs = []
    host_ports = []
    queue = []
    for root in sorted(tree.roots.values(), key=lambda root: root.bus):
        if not tree.primary(root):
            continue
        for port in range(1, root.maxchild + 1):
            device, path = tree.occupant(root, port)
            if not device:
                continue
            if device.hub:
                queue.append((device, None))
            else:
                found = tree.peer(root, port)
                aliases = [tree.child(root, port)] + ([tree.child(*found)] if found else [])
                host_ports.append(Slot(port, path, device, aliases))
    while queue:
        top, parent = queue.pop(0)
        hub = Hub(tree, top, parent)
        hubs.append(hub)
        for slot in hub.slots:
            if slot.device and slot.device.hub:
                queue.append((slot.device, {"hub": hub.top.name, "port": slot.number}))
    hubs.sort(key=lambda hub: path_key(hub.top.name))

    def slot_json(slot):
        device = slot.device
        entry = {"port": slot.number, "path": slot.path, "state": "empty"}
        if device:
            serial = usb_stats.usb_serial(device.serial) if device.serial else ""
            entry.update(
                speed=speed_text(device.speed),
                usb_id=device.usb_id,
                product=device.product,
                serial=device.serial or None,
            )
            if device.hub:
                entry["state"] = "hub"
            elif serial in farm:
                known = farm[serial]
                entry["state"] = "farm"
                entry["device"] = {key: known.get(key) for key in ("id", "name", "os", "location")}
            else:
                entry["state"] = "unknown"
        if args.days:
            entry["disconnects"] = sum(disconnects.get(name, 0) for name in slot.aliases)
        return entry

    def controller_json(device):
        address, name = controller_of(device, tree.roots, controllers)
        return {"pci": address, "name": name}

    def wanted(slots):
        if not chosen:
            return True
        return any(
            slot.device and slot.device.serial and usb_stats.usb_serial(slot.device.serial) in selected
            for slot in slots
        )

    report_hubs = []
    for hub in hubs:
        if not wanted(hub.slots):
            continue
        half = hub.half
        report_hubs.append(
            {
                "path": hub.top.name,
                "usb3": half.name if half and half is not hub.top else None,
                "on": hub.parent,
                "ports": len(hub.slots),
                "chips": [chip.usb_id for chip in hub.chips],
                "built_in": hub.top.removable == "fixed",
                "controller": controller_json(hub.top),
                "slots": [slot_json(slot) for slot in hub.slots],
            }
        )
    report_host = [
        dict(slot_json(slot), controller=controller_json(slot.device))
        for slot in host_ports
        if not chosen or wanted([slot])
    ]
    external = [hub for hub in report_hubs if not hub["built_in"]]
    free = [slot["path"] for hub in external for slot in hub["slots"] if slot["state"] == "empty"]
    report = {
        "host": socket.gethostname(),
        "hubs": report_hubs,
        "host_ports": report_host,
        "free_ports": free,
        "ports": sum(hub["ports"] for hub in external),
        "used": sum(hub["ports"] for hub in external) - len(free),
        "not_on_usb": [
            {
                "id": device["id"],
                "name": device["name"],
                "location": device.get("location") or None,
                "last_port": seen.get(usb_stats.usb_serial(device["id"]), (None, None))[0],
                "last_seen": seen.get(usb_stats.usb_serial(device["id"]), (None, None))[1],
            }
            for device in missing
        ],
    }
    if args.days:
        report["days"] = args.days

    if args.json:
        print(json.dumps(report, indent=2))
    elif args.summary:
        for device in report["not_on_usb"]:
            print(f"{missing_text(device)} is not on USB{last_text(device)}")
    else:
        print_map(report, args.days)
    if note:
        print(note, file=sys.stderr)
    return 1 if missing else 0


def missing_text(device):
    location = f" ({device['location']})" if device["location"] else ""
    return f"{device['name']}{location} {device['id']}"


def last_text(device):
    return f" (last seen {device['last_seen']} on {device['last_port']})" if device["last_port"] else ""


def slot_text(slot, days):
    state = slot["state"]
    if state == "empty":
        text, ident = "-- empty --", ""
    elif state == "farm":
        device = slot["device"]
        location = f" ({device['location']})" if device["location"] else ""
        text, ident = f"{device['name']}{location}", device["id"]
    elif state == "hub":
        text, ident = f"hub {slot['path']}", slot["usb_id"]
    else:
        text, ident = f"unknown {slot['product'] or 'device'}", slot["serial"] or slot["usb_id"]
    if days and slot.get("disconnects"):
        ident = f"{ident}  disc{days}d={slot['disconnects']}".strip()
    return text, ident


def print_map(report, days):
    hubs = [hub for hub in report["hubs"] if not hub["built_in"]]
    built_in = len(report["hubs"]) - len(hubs)
    print(
        "{}: {} hubs{}, {} of {} ports used, {} farm devices not on USB".format(
            report["host"],
            len(hubs),
            f" (+{built_in} built in)" if built_in else "",
            report["used"],
            report["ports"],
            len(report["not_on_usb"]),
        )
    )
    for hub in report["hubs"]:
        print()
        parts = [hub["path"] + (f" (USB3 {hub['usb3']})" if hub["usb3"] else ""), f"{hub['ports']} ports"]
        if hub["built_in"]:
            parts.append("built in")
        if hub["on"]:
            parts.append(f"on port {hub['on']['port']} of {hub['on']['hub']}")
        parts.append("+".join(hub["chips"]))
        parts.append(" ".join(part for part in (hub["controller"]["pci"], hub["controller"]["name"]) if part))
        print(", ".join(part for part in parts if part))
        for slot in hub["slots"]:
            text, ident = slot_text(slot, days)
            print(ROW.format(slot["port"], slot["path"], slot.get("speed", ""), text[:40], ident).rstrip())
    by_controller = {}
    for slot in report["host_ports"]:
        controller = slot["controller"]
        by_controller.setdefault((controller["pci"], controller["name"]), []).append(slot)
    for (address, name), slots in by_controller.items():
        print()
        print(", ".join(part for part in ("Host ports", f"{address} {name}".strip()) if part))
        for slot in slots:
            text, ident = slot_text(slot, days)
            print(ROW.format("", slot["path"], slot.get("speed", ""), text[:40], ident).rstrip())
    print()
    print("Free ports: " + (" ".join(report["free_ports"]) or "none"))
    for device in report["not_on_usb"]:
        print(f"Not on USB: {missing_text(device)}{last_text(device)}")


if __name__ == "__main__":
    sys.exit(main())
