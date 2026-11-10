#!/usr/bin/env python3
"""The settings of the agent in YAML (README.md#settings): read with PyYAML, written line by line to keep the comments.

  settings.py dump <file>...              NAME=value of the top level settings, a later file overrides an earlier one
  settings.py set <file> NAME=value...    sets the settings: the lines replaced, the missing ones at the end, mode 600

zebrunner.sh runs it with a python with PyYAML (yaml_python of patch/utility.sh): python3 or the one of ansible.
A file that is not valid YAML is an error with its reason on stderr, exit code 1.
"""

import json
import os
import re
import shutil
import stat
import sys

import yaml

NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")


class SettingsError(Exception):
    pass


def load(path):
    """The top level mapping of the file, empty for an empty file."""
    try:
        with open(path, encoding="utf-8") as file:
            data = yaml.safe_load(file)
    except OSError as err:
        raise SettingsError(f"{path}: {err.strerror}") from err
    except yaml.YAMLError as err:
        raise SettingsError(f"{path} is not valid YAML: {err}") from err
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise SettingsError(f"{path} is not a mapping of settings")
    return data


def text_of(value):
    """The value as the templates of ansible render it: true/false, no None, one line."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return " ".join(str(value).split("\n"))


def dump(paths):
    settings = {}
    for path in paths:
        settings.update(load(path))
    return [
        f"{name}={text_of(value)}"
        for name, value in settings.items()
        if isinstance(name, str) and NAME.match(name) and not isinstance(value, (dict, list))
    ]


def updated_text(text, settings, path):
    """The text with the settings: the lines replaced, the missing ones at its end. The values are written as JSON
    (YAML double-quoted strings, numbers, true/false); the new text is parsed, so a value never changes another one."""
    for name, value in settings.items():
        if not NAME.match(name) or "\n" in text_of(value) or isinstance(value, (dict, list)):
            raise SettingsError(f"invalid setting {name!r}")
    lines = text.split("\n")
    for name, value in settings.items():
        line = f"{name}: {json.dumps(value)}" if value not in ("", None) else f"{name}:"
        index = next((i for i, line_text in enumerate(lines) if re.match(rf"^{name}:", line_text)), None)
        if index is None:
            lines.insert(len(lines) - 1 if lines[-1] == "" else len(lines), line)
        else:
            lines[index] = line
    text = "\n".join(lines)
    try:
        written = yaml.safe_load(text) or {}
    except yaml.YAMLError as err:
        raise SettingsError(f"{path} is not valid YAML: {err}") from err
    changed = [name for name, value in settings.items() if text_of(written.get(name)) != text_of(value)]
    if changed:
        raise SettingsError(f"{path}: the settings {', '.join(changed)} are not read back as written")
    return text


def write_private(path, text, backup=None):
    """The text in the file, mode 600, a copy of the file to backup first."""
    if backup and os.path.exists(path):
        shutil.copyfile(path, backup)
        os.chmod(backup, stat.S_IRUSR | stat.S_IWUSR)
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_CREAT, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write(text)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def write_settings(path, settings, backup=None):
    """The settings in the file (updated_text), mode 600, a copy to backup first."""
    with open(path, encoding="utf-8") as file:
        text = updated_text(file.read(), settings, path)
    write_private(path, text, backup)


def main(args):
    command = args[0] if args else ""
    if command == "dump" and len(args) > 1:
        print("\n".join(dump(args[1:])))
    elif command == "set" and len(args) > 2 and all("=" in arg for arg in args[2:]):
        write_settings(args[1], dict(arg.split("=", 1) for arg in args[2:]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SettingsError as err:
        print(err, file=sys.stderr)
        sys.exit(1)
