#!/bin/bash
# patch/settings.py: the settings read with PyYAML and written line by line, with a python with PyYAML
source "$(dirname "$0")/lib.sh"
source "${REPO}/patch/utility.sh"

if ! python="$(yaml_python)"; then
  skip_check "settings.py" "no python3 with PyYAML"
  finish
fi
settings() {
  "$python" "${REPO}/patch/settings.py" "$@" 2>&1
}

section "dump"
cat > "${WORK}/defaults.yml" << 'YAML'
---
STF_PROVIDER_NAME: mcloud-linux
APPIUM_RELAXED_SECURITY: true
RESTARTS_LIMIT: 50
YAML
cat > "${WORK}/settings.yml" << 'YAML'
---
# a comment
PUBLIC_IP: "demo.zebrunner.farm" # the public name
PUBLIC_IP_PORT: 443
S3_SECRET: 'a#b: c'
WDA_FILE:
APPIUM_RELAXED_SECURITY: false
devices:
  - id: a
YAML
output="$(settings dump "${WORK}/defaults.yml" "${WORK}/settings.yml")"
check_contains "the quotes and the comment are not in the value" $'\n'"PUBLIC_IP=demo.zebrunner.farm"$'\n' $'\n'"${output}"$'\n'
check_contains "a number" "PUBLIC_IP_PORT=443" "$output"
check_contains "'#' and ':' in quotes are the value" "S3_SECRET=a#b: c" "$output"
check_contains "an empty value" $'\n'"WDA_FILE="$'\n' $'\n'"${output}"$'\n'
check_contains "a later file overrides an earlier one" "APPIUM_RELAXED_SECURITY=false" "$output"
check_contains "an earlier file without an override" "STF_PROVIDER_NAME=mcloud-linux" "$output"
check_not_contains "no list" "devices=" "$output"
check "an empty file has no settings" "" "$(: > "${WORK}/empty.yml" && settings dump "${WORK}/empty.yml")"
echo "PUBLIC_IP: [demo" > "${WORK}/invalid.yml"
check_contains "invalid YAML is an error" "invalid.yml is not valid YAML" "$(settings dump "${WORK}/invalid.yml")"
settings dump "${WORK}/invalid.yml" > /dev/null
check "invalid YAML fails" "1" "$?"
check_contains "a list is not settings" "is not a mapping of settings" "$(echo "- a" > "${WORK}/list.yml" && settings dump "${WORK}/list.yml")"
check_contains "a missing file is an error" "missing.yml" "$(settings dump "${WORK}/missing.yml")"

section "devices"
check "the devices are counted" "1" "$(settings devices "${WORK}/settings.yml")"
check "no devices" "0" "$(settings devices "${WORK}/defaults.yml")"
check_contains "devices: is a list" "is not a list" "$(echo "devices: a" > "${WORK}/devices.yml" && settings devices "${WORK}/devices.yml")"

section "set"
cp "${WORK}/settings.yml" "${WORK}/set.yml"
settings set "${WORK}/set.yml" "PUBLIC_IP=mcloud.example.com" "MCLOUD_URL=https://10.0.0.1:443" "WDA_FILE=" > /dev/null
check "set succeeds" "0" "$?"
check "a line is replaced" 'PUBLIC_IP: "mcloud.example.com"' "$(grep '^PUBLIC_IP:' "${WORK}/set.yml")"
check "a missing setting is added at the end" 'MCLOUD_URL: "https://10.0.0.1:443"' "$(tail -n 1 "${WORK}/set.yml")"
check "an empty value" "WDA_FILE:" "$(grep '^WDA_FILE' "${WORK}/set.yml")"
check "the comments are kept" "# a comment" "$(grep '^# a comment' "${WORK}/set.yml")"
check "the devices are kept" "1" "$(settings devices "${WORK}/set.yml")"
check "the settings are private" "600" "$(stat -c '%a' "${WORK}/set.yml" 2> /dev/null || stat -f '%Lp' "${WORK}/set.yml")"
check_contains "the values are read back" "MCLOUD_URL=https://10.0.0.1:443" "$(settings dump "${WORK}/set.yml")"
printf 'PUBLIC_IP: a\nPUBLIC_IP: b\n' > "${WORK}/twice.yml"
cp "${WORK}/twice.yml" "${WORK}/twice.before"
check_contains "a value that is not read back is refused" "the settings PUBLIC_IP are not read back as written" \
  "$(settings set "${WORK}/twice.yml" "PUBLIC_IP=c")"
check "a refused value changes nothing" "same" "$(cmp -s "${WORK}/twice.yml" "${WORK}/twice.before" && echo same)"
check_contains "a lower case name is refused" "invalid setting" "$(settings set "${WORK}/set.yml" "name=x")"
check_contains "no arguments print the usage" "settings.py dump <file>" "$(settings set "${WORK}/set.yml")"

finish
