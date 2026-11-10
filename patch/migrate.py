#!/usr/bin/env python3
"""The settings of an earlier version moved to config/ (README.md#settings): `./zebrunner.sh migrate` runs it.

  migrate.py plan <linux|macos> <file>...     prints the changes of config/ (the secrets hidden), exit code 3 if none
  migrate.py apply <linux|macos> <file>...    writes them (the previous files kept as <file>.bak), then renames the
                                              files of an earlier version of the agent to <file>.migrated

The files are read in their order: roles/<role>/vars/main.yml (the settings and the devices of an earlier version),
defaults/main.yml (the images and the options of Appium) or their copies, e.g. vars/main.yml of a backup. A setting
goes to config/settings.yml when its value is not the one the deploy has already (the values by default of the roles,
versions.yml, config/settings.yml); the devices: of the last file with them replace the ones of config/devices.yml.
"""

import difflib
import os
import re
import sys

from settings import SettingsError, load, text_of, updated_text, write_private

SETTINGS = "config/settings.yml"
DEVICES = "config/devices.yml"
ROLES = {"linux": "devices", "macos": "mac-devices"}
# the files of an earlier version of the agent, renamed after the migration: the deploy refuses the first ones
EARLIER = ["roles/devices/vars/main.yml", "roles/mac-devices/vars/main.yml", "defaults/main.yml"]
SECRET = re.compile(r"(TOKEN|SECRET|PASSWORD|_KEY\b|_PIN\b)")


def read(path):
    with open(path, encoding="utf-8") as file:
        return file.read()


def current(path, example):
    """The text of the file of config/, of its example when it does not exist."""
    return read(path) if os.path.exists(path) else read(example)


def devices_block(text):
    """The `devices:` of the text as it is (with its comments): from its line to the next top level key."""
    lines = text.split("\n")
    start = next((i for i, line in enumerate(lines) if re.match(r"^devices:", line)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^[^\s#-]", lines[i])), len(lines))
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    return "\n".join(lines[start:end])


def plan(farm_os, paths):
    """The new texts of config/settings.yml and config/devices.yml."""
    role = ROLES[farm_os]
    settings_text = current(SETTINGS, f"{SETTINGS}.original")
    devices_text = current(DEVICES, f"config/{role}.yml.original")
    deployed = {}
    for path in ("roles/common/defaults/main.yml", f"roles/{role}/defaults/main.yml", "versions.yml"):
        deployed.update(load(path))
    deployed.update(load(SETTINGS) if os.path.exists(SETTINGS) else {})
    changes = {}
    devices = None
    for path in paths:
        for name, value in load(path).items():
            if name == "devices":
                devices = devices_block(read(path))
            elif not isinstance(value, (dict, list)) and text_of(value) != text_of(deployed.get(name)):
                changes[name] = value
                deployed[name] = value
    new_settings = updated_text(settings_text, changes, SETTINGS) if changes else settings_text
    new_devices = devices_text
    if devices is not None:
        old = devices_block(devices_text)
        new_devices = (
            devices_text.replace(old, devices) if old is not None else f"{devices_text.rstrip()}\n\n{devices}\n"
        )
    return {SETTINGS: (settings_text, new_settings), DEVICES: (devices_text, new_devices)}


def hidden(line):
    """The line of a diff without the value of a secret."""
    match = re.match(r"^([-+ ]?)([A-Z][A-Z0-9_]*):\s*\S", line)
    if match and SECRET.search(match.group(2)):
        return f"{match.group(1)}{match.group(2)}: ******"
    return line


def diff(texts):
    lines = []
    for path, (old, new) in texts.items():
        source = path if os.path.exists(path) else f"{path} (new)"
        for line in difflib.unified_diff(old.split("\n"), new.split("\n"), source, path, lineterm=""):
            lines.append(hidden(line))
    return lines


def main(args):
    if len(args) < 3 or args[0] not in ("plan", "apply") or args[1] not in ROLES:
        print(__doc__, file=sys.stderr)
        return 2
    command, farm_os, paths = args[0], args[1], args[2:]
    texts = plan(farm_os, paths)
    changes = diff(texts)
    if command == "plan":
        print("\n".join(changes) if changes else "No change of config/: the deploy has these settings already.")
        return 0 if changes else 3
    for path, (old, new) in texts.items():
        if new != old or not os.path.exists(path):
            write_private(path, new, f"{path}.bak" if os.path.exists(path) else None)
            print(f"Written: {path}")
    for path in paths:
        if path in EARLIER and os.path.exists(path):
            os.rename(path, f"{path}.migrated")
            print(f"Renamed: {path} -> {path}.migrated")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SettingsError as err:
        print(err, file=sys.stderr)
        sys.exit(1)
