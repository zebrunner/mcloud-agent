#!/usr/bin/env python3
"""The checks of the devices of config/devices.yml (README.md#run-ansible-playbook), the same for the deploy and doctor.

  devices.py dedup <linux|macos>          the ids and the names of the devices of stdin (JSON) are unique
  devices.py validate <linux|macos>       the settings, the host ports and the connections of the devices of stdin
  devices.py file <linux|macos> <file>    both checks of the devices: of the YAML file, prints their number

The checks print their result: a success line, or the problems of the first failed group of checks with exit code 1.
The roles run them with the python of ansible (the devices as JSON on stdin), doctor with a python with PyYAML.
"""

import json
import re
import sys

CONNECTIONS = {
    "linux": ["usb", "wireless", "android-sim", "proxy"],
    "macos": ["usb", "wireless", "android-sim", "ios-sim", "proxy"],
}


class DevicesError(Exception):
    pass


def to_int(value):
    """The int filter of Jinja: the number of the value, 0 when it is not one."""
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0


def text(device, key, default=""):
    """The `default('') | string` of Jinja: a defined None is 'None'."""
    return str(device[key]) if key in device else default


def connection(device):
    return text(device, "connection", "usb").lower()


def label(device):
    return str(device.get("name", device.get("id", "?")))


def unique(values):
    return list(dict.fromkeys(values))


def dedup(devices):
    """The ids (trimmed) and the names (trimmed, the spaces as '_') used by more than one device."""
    ids = [str(device.get("id", "")).strip() for device in devices]
    names = [re.sub(r"\s+", "_", str(device.get("name", "")).strip()) for device in devices]
    dup_ids = [value for value in unique(ids) if ids.count(value) > 1]
    dup_names = [value for value in unique(names) if names.count(value) > 1]
    if dup_ids or dup_names:
        return [f"Duplicate devices found! Duplicate IDs: {dup_ids} Duplicate Names: {dup_names}"]
    return []


def settings_problems(devices, farm_os):
    adb_port = farm_os == "macos"
    problems = []
    for device in devices:
        valid = (
            "id" in device
            and "name" in device
            and device.get("os") in ("android", "ios")
            and all(key in device for key in ("appium_port", "min_port", "max_port"))
            and 0 < to_int(device["appium_port"]) < 65536
            and 0 < to_int(device["min_port"]) <= to_int(device["max_port"]) < 65536
            and (
                "connect_port" not in device
                or (device["os"] == "android" and 1023 < to_int(device["connect_port"]) < 65536)
            )
            and (not adb_port or "adb_port" in device or device["os"] != "android" or connection(device) != "usb")
        )
        if not valid:
            obligatory = ", adb_port for a USB Android device" if adb_port else ""
            problems.append(
                f"Invalid settings of device '{label(device)}': id, name, os (android or ios), appium_port, min_port "
                f"and max_port are obligatory{obligatory}; ports are 1-65535 and min_port is not greater than "
                "max_port; connect_port is of an Android device only, 1024-65535."
            )
    return problems


def own_ports(device):
    """appium_port, min_port-max_port and a connect_port out of the range: the ports published on the host."""
    ports = list(range(to_int(device["min_port"]), to_int(device["max_port"]) + 1))
    connect = [to_int(device["connect_port"])] if "connect_port" in device else []
    return [to_int(device["appium_port"])] + ports + [port for port in connect if port not in ports], ports + connect


def ports_problems(devices):
    published = [own_ports(device)[0] for device in devices]
    problems = []
    for index, device in enumerate(devices):
        others = [port for i, ports in enumerate(published) if i != index for port in ports]
        shared = [port for port in unique(published[index]) if port in others]
        appium = to_int(device["appium_port"])
        if appium in own_ports(device)[1] and appium not in shared:
            shared.append(appium)
        if shared:
            problems.append(
                f"Host ports {shared} of device '{device['name']}' are used by another device "
                "or by both its appium_port and min_port-max_port range or connect_port."
            )
    return problems


def connection_problems(devices, farm_os):
    problems = []
    for device in devices:
        kind = connection(device)
        address = len(text(device, "address")) > 0
        valid = kind in CONNECTIONS[farm_os] and (kind != "android-sim" or device["os"] == "android")
        if farm_os == "linux":
            valid = valid and (kind != "proxy" or device["os"] == "ios")
            valid = valid and (kind not in ("wireless", "proxy") or device["os"] == "android" or address)
            reason = (
                "usb, wireless (an iOS device needs address, its IP), android-sim (an Android emulator started outside "
                "the farm, address is its adb address) or proxy (iOS, needs address where its WebDriverAgent is "
                "published); the iOS simulators (ios-sim) run on a macOS host only."
            )
        else:
            valid = valid and (kind not in ("ios-sim", "proxy") or device["os"] == "ios")
            valid = valid and (kind != "ios-sim" or len(text(device, "wda_port")) > 0)
            valid = valid and (kind != "proxy" or address)
            reason = (
                "usb, wireless, android-sim (an Android emulator started outside the farm, address is its adb "
                "address), ios-sim (an iOS simulator of the host, needs wda_port: the unique port of its "
                "WebDriverAgent on the host) or proxy (iOS, needs address where its WebDriverAgent is published)."
            )
        if not valid:
            problems.append(f"Invalid connection '{kind}' of device '{device['name']}': {reason}")
    return problems


def host_ports_problems(devices):
    """macOS: the WebDriverAgent ports of the iOS simulators and the adb forwards of the USB Android devices."""
    host_ports = []
    for device in devices:
        if connection(device) == "ios-sim":
            wda_port = to_int(device.get("wda_port", 0))
            host_ports += [wda_port, to_int(device.get("mjpeg_port", wda_port + 1))]
        elif connection(device) == "usb" and device["os"] == "android":
            host_ports.append(to_int(device["adb_port"]))
    published = {port for device in devices for port in own_ports(device)[0]}
    if len(host_ports) != len(set(host_ports)) or set(host_ports) & published:
        return [
            f"The host ports {host_ports} of the iOS simulators (wda_port, mjpeg_port) and of the USB Android devices "
            "(adb_port) must be unique and not used by appium_port or min_port-max_port of the devices."
        ]
    return []


def validate(devices, farm_os):
    """The problems of the first failed group of checks, in the order of the deploy."""
    groups = [
        lambda: settings_problems(devices, farm_os),
        lambda: ports_problems(devices),
        lambda: connection_problems(devices, farm_os),
    ]
    if farm_os == "macos":
        groups.append(lambda: host_ports_problems(devices))
    for group in groups:
        problems = group()
        if problems:
            return problems
    return []


def devices_of(data):
    if data is None:
        return []
    if not isinstance(data, list) or not all(isinstance(device, dict) for device in data):
        raise DevicesError("devices: is not a list of the settings of the devices")
    return data


def load_file(path):
    # the checks of the deploy need no PyYAML
    import yaml

    try:
        with open(path, encoding="utf-8") as file:
            data = yaml.safe_load(file) or {}
    except OSError as err:
        raise DevicesError(f"{path}: {err.strerror}") from err
    except yaml.YAMLError as err:
        raise DevicesError(f"{path} is not valid YAML: {err}") from err
    if not isinstance(data, dict):
        raise DevicesError(f"{path} is not a mapping of settings")
    return devices_of(data.get("devices"))


def main(args):
    if len(args) < 2 or args[1] not in CONNECTIONS:
        print(__doc__, file=sys.stderr)
        return 2
    command, farm_os = args[0], args[1]
    if command in ("dedup", "validate") and len(args) == 2:
        devices = devices_of(json.load(sys.stdin))
        if command == "dedup":
            problems, success = dedup(devices), "All device IDs and names are unique."
        else:
            problems, success = validate(devices, farm_os), f"The settings of the {len(devices)} devices are valid."
    elif command == "file" and len(args) == 3:
        devices = load_file(args[2])
        problems, success = dedup(devices) or validate(devices, farm_os), str(len(devices))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print("\n".join(problems) if problems else success)
    return 1 if problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (DevicesError, ValueError) as err:
        print(err)
        sys.exit(1)
