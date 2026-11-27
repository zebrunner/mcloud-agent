#!/bin/bash
# Ansible roles: registerDevices tag, duplicates check, prechecks and file tasks of the role of the
# current OS (check mode), the images download with a stubbed docker, the clone of the Developer Disk Images and the
# rendered templates.
source "$(dirname "$0")/lib.sh"
require_cmd ansible-playbook

# Facts are gathered by the first playbook only and cached for the others: on the GitHub macOS runner
# socket.getfqdn() of the platform facts takes 70 seconds (two 35 seconds DNS timeouts of the VM).
export ANSIBLE_GATHERING=smart
export ANSIBLE_CACHE_PLUGIN=jsonfile
export ANSIBLE_CACHE_PLUGIN_CONNECTION="${WORK}/facts"

if [[ "$(uname)" == "Darwin" ]]; then
  OS_ROLE=mac-devices
else
  OS_ROLE=devices
fi

server_key="$(printf '%064d' 0 | tr 0 a)"
# the settings of the WireGuard tunnel of ./zebrunner.sh join with MCloud with the tunnel on
wireguard="{\"WG_ENABLED\": true, \"WG_PRIVATE_KEY\": \"$(printf '%042d' 0 | tr 0 P)A=\", \"WG_SERVER_PUBLIC_KEY\": \"$(printf '%042d' 0 | tr 0 S)A=\",
  \"WG_ADDRESS\": \"10.234.0.2\", \"WG_SERVER_ADDRESS\": \"10.234.0.1\", \"WG_ENDPOINT\": \"mcloud.example.com:51820\",
  \"WG_NETWORK\": \"10.234.0.0/24\", \"STF_PROVIDER_HOST\": \"10.234.0.2\"}"
secret_key="$(printf '%064d' 0 | tr 0 b)"
node_token="mcn1.build-ua.$(printf '%043d' 0 | tr 0 A)"

# make_play <role>: a playbook dir using the role from the repo with the example settings and devices of the role in its
# config/ (as ./zebrunner.sh setup makes them), the obligatory settings of the node enrollment set as ./zebrunner.sh join
# sets them
make_play() {
  local dir="${WORK}/play-$1"
  local part
  mkdir -p "${dir}/roles/$1" "${dir}/config"
  for part in tasks templates files defaults meta; do
    [[ -d "${REPO}/roles/$1/${part}" ]] && ln -s "${REPO}/roles/$1/${part}" "${dir}/roles/$1/${part}"
  done
  # the dependency of the roles of the OS (meta/main.yml)
  [[ -d "${REPO}/roles/$1/meta" ]] && ln -s "${REPO}/roles/common" "${dir}/roles/common"
  if [[ -f "${REPO}/config/$1.yml.original" ]]; then
    cp "${REPO}/config/$1.yml.original" "${dir}/config/devices.yml"
    sed -e "s/^MCLOUD_NODE_TOKEN:.*/MCLOUD_NODE_TOKEN: \"${node_token}\"/" \
      -e 's/^STF_PROVIDER_HOST:.*/STF_PROVIDER_HOST: "192.168.30.2"/' -e 's/^PUBLIC_IP:.*/PUBLIC_IP: "mcloud.example.com"/' \
      -e 's|^STF_PROVIDER_CONNECT_SUB:.*|STF_PROVIDER_CONNECT_SUB: "tcp://192.168.50.2:7250"|' \
      -e 's|^STF_PROVIDER_CONNECT_PUSH:.*|STF_PROVIDER_CONNECT_PUSH: "tcp://192.168.50.2:7270"|' \
      -e 's/^SELENIUM_HUB_HOST:.*/SELENIUM_HUB_HOST: "192.168.50.2"/' -e 's/^SELENIUM_HUB_PORT:.*/SELENIUM_HUB_PORT: "4446"/' \
      -e "s/^STF_ZMQ_CURVE_SERVER_PUBLIC_KEY:.*/STF_ZMQ_CURVE_SERVER_PUBLIC_KEY: \"${server_key}\"/" \
      -e "s/^STF_ZMQ_CURVE_SECRET_KEY:.*/STF_ZMQ_CURVE_SECRET_KEY: \"${secret_key}\"/" \
      "${REPO}/config/settings.yml.original" > "${dir}/config/settings.yml"
  fi
  cat > "${dir}/play.yml" << EOF
- hosts: localhost
  connection: local
  gather_subset: [min]
  vars_files:
    - ${REPO}/versions.yml
    - [config/settings.yml, ${REPO}/versions.yml]
    - [config/devices.yml, ${REPO}/versions.yml]
  vars:
    agent_dir: ${REPO}
  roles:
    - $1
EOF
}

# playbook <role> <ansible-playbook arguments...>
playbook() {
  local role="$1"
  shift
  (cd "${WORK}/play-${role}" && env -u ZEBRUNNER_MCLOUD_AGENT_DIR PATH="${WORK}/bin:${PATH}" ansible-playbook play.yml "$@" < /dev/null 2>&1)
}

for role in devices mac-devices download; do
  make_play "$role"
done

section "the playbook of both OS"
# the tasks tagged always only: the check of the OS and the group of the host
output="$(cd "$REPO" && ansible-playbook --inventory hosts agent.yml --tags never < /dev/null 2>&1)"
check_contains "agent.yml: the OS is compatible" "OS is compatible: $(uname)" "$output"
check_contains "agent.yml: the play of the OS has the host" "PLAY [Deploy MCloud agent for the Android and iOS devices of a $([[ "$OS_ROLE" == devices ]] && echo "Linux server" || echo "macOS host")]" "$output"
check_contains "agent.yml: the play of the other OS has no host" "skipping: no hosts matched" "$output"
check_not_contains "agent.yml: the groups of the OS are declared" "Could not match supplied host pattern" "$output"
tasks="$(cd "$REPO" && ansible-playbook --inventory hosts agent.yml --list-tasks --tags registerDevices 2>&1)"
check_contains "agent.yml: the role of Linux" "devices : Copy rules file" "$tasks"
check_contains "agent.yml: the role of macOS" "mac-devices : Copy 'zebrunner-device-listener' script file" "$tasks"
check_contains "devices.yml of the earlier commands imports agent.yml" "Group the hosts by their OS" \
  "$(cd "$REPO" && ansible-playbook --inventory hosts devices.yml --list-tasks 2>&1)"

section "registerDevices tag"
for role in devices mac-devices; do
  tasks="$(playbook "$role" --list-tasks --tags registerDevices)"
  check_contains "${role}: the tag selects the prechecks" "Check OS compatibility" "$tasks"
  check_contains "${role}: the tag selects the files" "Copy 'zebrunner-farm' script file" "$tasks"
  check_contains "${role}: the tag selects the duplicates check" "Check for duplicate device IDs or names" "$tasks"
  check_contains "${role}: the tag selects the enrollment settings check" "Check the settings of the node enrollment" "$tasks"
done

section "duplicates check"
for role in devices mac-devices; do
  while IFS='=' read -r devices expected; do
    output="$(playbook "$role" --tags dedup --extra-vars "{\"devices\": ${devices}}")"
    check_contains "${role}: ${devices}" "$expected" "$output"
  done << 'EOF'
[{"id": "abc", "name": "A"}]=All device IDs and names are unique.
[{"id": "abc", "name": "A"}, {"id": "def", "name": "B"}]=All device IDs and names are unique.
[{"id": 12345, "name": "A"}, {"id": "12345 ", "name": "B"}]=Duplicate IDs: ['12345']
[{"id": "abc", "name": "A"}, {"id": " abc ", "name": "B"}]=Duplicate IDs: ['abc']
[{"id": "abc", "name": "iPhone 8"}, {"id": "def", "name": "iPhone_8"}]=Duplicate Names: ['iPhone_8']
EOF
done

section "devices settings check"
for role in devices mac-devices; do
  check_contains "${role}: example settings are valid" "failed=0" "$(playbook "$role" --tags validate)"
  while IFS='=' read -r devices expected; do
    output="$(playbook "$role" --tags validate --extra-vars "{\"devices\": ${devices}}")"
    check_contains "${role}: ${devices}" "$expected" "$output"
  done << 'EOF'
[{"id": "a", "name": "A", "os": "ios", "adb_port": 2, "min_port": 3, "max_port": 4}]=Invalid settings of device 'A'
[{"id": "a", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4}]=Invalid settings of device 'a'
[{"id": "a", "name": "A", "os": "windows", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4}]=Invalid settings of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 9, "max_port": 4}]=Invalid settings of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 70000}]=Invalid settings of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 7421, "adb_port": 2, "min_port": 7425, "max_port": 7430}, {"id": "b", "name": "B", "os": "ios", "appium_port": 7427, "adb_port": 2, "min_port": 7435, "max_port": 7440}]=Host ports [7427] of device 'B'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 7421, "adb_port": 2, "min_port": 7425, "max_port": 7430}, {"id": "b", "name": "B", "os": "ios", "appium_port": 7421, "adb_port": 2, "min_port": 7435, "max_port": 7440}]=Host ports [7421] of device 'B'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 7421, "adb_port": 2, "min_port": 7425, "max_port": 7430}, {"id": "b", "name": "B", "os": "ios", "appium_port": 7441, "adb_port": 2, "min_port": 7430, "max_port": 7440}]=Host ports [7430] of device 'B'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 7426, "adb_port": 2, "min_port": 7425, "max_port": 7430}]=Host ports [7426] of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 7421, "adb_port": 7422, "min_port": 7425, "max_port": 7430}, {"id": "b", "name": "B", "os": "android", "appium_port": 7431, "adb_port": 7422, "min_port": 7432, "max_port": 7440}]=failed=0
[{"id": "a", "name": "A", "os": "android", "appium_port": 7421, "min_port": 7425, "max_port": 7430, "connect_port": 7426, "connection": "wireless"}]=failed=0
[{"id": "a", "name": "A", "os": "android", "appium_port": 7421, "min_port": 7425, "max_port": 7430, "connect_port": 7499, "connection": "wireless"}]=failed=0
[{"id": "a", "name": "A", "os": "ios", "appium_port": 7421, "min_port": 7425, "max_port": 7430, "connect_port": 7499}]=Invalid settings of device 'A'
[{"id": "a", "name": "A", "os": "android", "appium_port": 7421, "min_port": 7425, "max_port": 7430, "connect_port": 80, "connection": "wireless"}]=Invalid settings of device 'A'
[{"id": "a", "name": "A", "os": "android", "appium_port": 7421, "min_port": 7425, "max_port": 7430, "connect_port": 7421, "connection": "wireless"}]=Host ports [7421] of device 'A'
[{"id": "a", "name": "A", "os": "android", "appium_port": 7421, "min_port": 7425, "max_port": 7430, "connect_port": 7499, "connection": "wireless"}, {"id": "b", "name": "B", "os": "android", "appium_port": 7431, "min_port": 7495, "max_port": 7500, "connection": "wireless"}]=Host ports [7499] of device 'B'
[{"id": " 00008101-000A1D0E3C38001E ", "name": " iPhone 12 ", "location": "lab-2.rack_1", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 3}]=failed=0
[{"id": "emulator-5554", "name": "Emu", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "connection": "wireless"}]=failed=0
[{"id": "10.0.0.7:5555", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "connection": "wireless"}]=Invalid id '10.0.0.7:5555' of device 'A'
[{"id": "a", "name": "A|B", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6}]=Invalid name 'A|B' of device 'A|B'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "allow_reboot": true}]=failed=0
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "allow_reboot": false, "connection": "wireless", "address": "10.0.0.7"}]=failed=0
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "allow_reboot": "yes"}]=Invalid allow_reboot of device 'A'
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "allow_reboot": true, "connection": "wireless"}]=failed=0
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "allow_reboot": true, "connection": "android-sim", "address": "emu:5555"}]=failed=0
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "allow_reboot": "true", "connection": "wireless"}]=Invalid allow_reboot of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "allow_reboot": true, "connection": "proxy", "address": "10.0.0.7"}]=Invalid allow_reboot of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "unavailable_timeout": 0}]=failed=0
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "unavailable_timeout": 1800, "connection": "wireless", "address": "10.0.0.7"}]=failed=0
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "unavailable_timeout": -1}]=Invalid unavailable_timeout of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "unavailable_timeout": "600"}]=Invalid unavailable_timeout of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "unavailable_timeout": true}]=Invalid unavailable_timeout of device 'A'
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "unavailable_timeout": 600, "connection": "wireless"}]=Invalid unavailable_timeout of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6, "unavailable_timeout": 600, "connection": "proxy", "address": "10.0.0.7"}]=Invalid unavailable_timeout of device 'A'
[{"id": "a", "name": "-A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6}]=Invalid name '-A' of device '-A'
[{"id": "a/b", "name": "", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6}]=Invalid id 'a/b', name '' of device ''
[{"id": "a", "name": "A", "location": "NYC, 2nd floor", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 6}]=Invalid location 'NYC, 2nd floor' of device 'A'
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 5, "connection": "wireless"}]=The range min_port-max_port of device 'A' has 3 ports
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "connect_port": 1024, "connection": "wireless"}]=failed=0
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 1024, "max_port": 1027, "connect_port": 1024, "connection": "wireless"}]=The range min_port-max_port of device 'A' has 4 ports
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 1024, "max_port": 1028, "connect_port": 1024, "connection": "wireless"}]=failed=0
EOF
done
while IFS='=' read -r devices expected; do
  check_contains "mac-devices: ${devices}" "$expected" "$(playbook mac-devices --tags validate --extra-vars "{\"devices\": ${devices}}")"
done << 'EOF'
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "wireless"}]=failed=0
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "proxy", "address": "10.0.0.5"}]=failed=0
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "proxy"}]=Invalid connection 'proxy' of device 'TV'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "bluetooth"}]=Invalid connection 'bluetooth' of device 'A'
[{"id": "a", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim"}]=Invalid connection 'ios-sim' of device 'Sim'
[{"id": "a", "name": "Sim", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 6, "connection": "ios-sim", "wda_port": 8110}]=Invalid connection 'ios-sim' of device 'Sim'
[{"id": "a", "name": "Emu", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "android-sim"}]=Invalid connection 'android-sim' of device 'Emu'
[{"id": "a", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}, {"id": "b", "name": "Emu", "os": "android", "appium_port": 5, "adb_port": 6, "min_port": 7, "max_port": 10, "connection": "android-sim", "address": "host.docker.internal:5555"}]=failed=0
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "simulator", "wda_port": 8110}]=Invalid connection 'simulator' of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}, {"id": "b", "name": "B", "os": "ios", "appium_port": 5, "adb_port": 6, "min_port": 7, "max_port": 8, "connection": "ios-sim", "wda_port": 8111}]=The host ports [8110, 8111, 8111, 8112] of the iOS simulators
[{"id": "a", "name": "A", "os": "ios", "appium_port": 8110, "adb_port": 2, "min_port": 3, "max_port": 4}, {"id": "b", "name": "B", "os": "ios", "appium_port": 5, "adb_port": 6, "min_port": 7, "max_port": 8, "connection": "ios-sim", "wda_port": 8110}]=The host ports [8110, 8111] of the iOS simulators
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "adb_port": 7422, "min_port": 3, "max_port": 6}, {"id": "b", "name": "B", "os": "android", "appium_port": 7, "adb_port": 7422, "min_port": 8, "max_port": 11}]=The host ports [7422, 7422] of the iOS simulators
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "adb_port": 7422, "min_port": 3, "max_port": 6}, {"id": "b", "name": "B", "os": "android", "appium_port": 7, "adb_port": 7422, "min_port": 8, "max_port": 11, "connection": "wireless"}]=failed=0
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 4}]=Invalid settings of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "min_port": 3, "max_port": 4}]=failed=0
EOF
while IFS='=' read -r devices expected; do
  check_contains "devices: ${devices}" "$expected" "$(playbook devices --tags validate --extra-vars "{\"devices\": ${devices}}")"
done << 'EOF'
[{"id": "a", "name": "WiFi", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "wireless"}]=Invalid connection 'wireless' of device 'WiFi'
[{"id": "a", "name": "WiFi", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "wireless", "address": "10.0.0.7"}]=failed=0
[{"id": "a", "name": "WiFi", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 6, "connection": "wireless"}]=failed=0
[{"id": "a", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}]=Invalid connection 'ios-sim' of device 'Sim'
[{"id": "a", "name": "Emu", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 6, "connection": "android-sim", "address": "10.0.0.9:5555"}]=failed=0
[{"id": "a", "name": "Emu", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "android-sim"}]=Invalid connection 'android-sim' of device 'Emu'
[{"id": "a", "name": "Emu", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 6, "connection": "emulator"}]=Invalid connection 'emulator' of device 'Emu'
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "proxy", "address": "10.0.0.5"}]=failed=0
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 6, "connection": "wireless"}]=failed=0
EOF

# the shared checks of the role common with the parameters of the role of the OS
extra='{"devices": [{"id": "a", "name": "A", "os": "android", "appium_port": 1, "min_port": 3, "max_port": 4, "connect_port": 1}]}'
check_contains "mac-devices: adb_port is obligatory for a USB Android device" "are obligatory, adb_port for a USB Android device;" \
  "$(playbook mac-devices --tags validate --extra-vars "$extra")"
check_contains "devices: an invalid USB_DEVICE_GROUP fails" "USB_DEVICE_GROUP must be the name of a group" \
  "$(playbook devices --tags validate --extra-vars '{"USB_DEVICE_GROUP": "plug dev"}')"
check_contains "devices: adb_port is not obligatory" "max_port are obligatory;" "$(playbook devices --tags validate --extra-vars "$extra")"

section "prechecks of ${OS_ROLE}"
output="$(playbook "$OS_ROLE" --check --tags precheck)"
check_contains "OS is compatible" "OS is compatible: $(uname)" "$output"
check_contains "setup is done" "Setup is ready" "$output"
check_contains "no settings of an earlier version" "No settings of an earlier version." "$output"
check_contains "prechecks pass" "failed=0" "$output"
check_contains "the settings of the node enrollment pass" "The settings of the node enrollment are set." "$output"
check_contains "the CURVE keys pass" "The CURVE keys of ZeroMQ are valid." "$output"
for file in settings devices; do
  mv "${WORK}/play-${OS_ROLE}/config/${file}.yml" "${WORK}/${file}.yml"
  check_contains "missing config/${file}.yml fails" "You have to set up services in advance using: ./zebrunner.sh setup!" \
    "$(playbook "$OS_ROLE" --check --tags precheck)"
  mv "${WORK}/${file}.yml" "${WORK}/play-${OS_ROLE}/config/${file}.yml"
done
mkdir -p "${WORK}/play-${OS_ROLE}/roles/${OS_ROLE}/vars"
cp "${WORK}/play-${OS_ROLE}/config/settings.yml" "${WORK}/play-${OS_ROLE}/roles/${OS_ROLE}/vars/main.yml"
check_contains "the settings of an earlier version fail" \
  "roles/${OS_ROLE}/vars/main.yml of an earlier version overrides config/: ./zebrunner.sh migrate moves its settings to config/settings.yml" \
  "$(playbook "$OS_ROLE" --check --tags precheck)"
rm -rf "${WORK}/play-${OS_ROLE}/roles/${OS_ROLE}/vars"
output="$(playbook "$OS_ROLE" --check --tags precheck --extra-vars "@${REPO}/config/settings.yml.original")"
check_contains "the example settings fail without the enrollment" \
  "missing or invalid in config/settings.yml: MCLOUD_NODE_TOKEN, STF_PROVIDER_HOST, PUBLIC_IP" "$output"
check_contains "the enrollment sets them" "Enroll this host with ./zebrunner.sh join" "$output"

section "settings of the node enrollment"
for role in devices mac-devices; do
  for setting in MCLOUD_NODE_TOKEN STF_PROVIDER_HOST PUBLIC_IP STF_PROVIDER_CONNECT_SUB SELENIUM_HUB_HOST STF_ZMQ_CURVE_SERVER_PUBLIC_KEY STF_ZMQ_CURVE_SECRET_KEY; do
    extra="{\"${setting}\": \" \"}"
    check_contains "${role}: a blank ${setting} fails" "are missing or invalid in config/settings.yml: ${setting}." \
      "$(playbook "$role" --tags validate --extra-vars "$extra")"
  done
  check_contains "${role}: the settings of join pass" "The settings of the node enrollment are set." "$(playbook "$role" --tags validate)"
  # the JSON in variables: bash 3.2 misparses the escaped quotes of a command substitution in double quotes
  extra='{"MCLOUD_NODE_TOKEN": "mcn1.Bad_Label.x"}'
  check_contains "${role}: an invalid token fails" "are missing or invalid in config/settings.yml: MCLOUD_NODE_TOKEN." \
    "$(playbook "$role" --tags validate --extra-vars "$extra")"
  extra='{"STF_PROVIDER_CLEANUP": "yes"}'
  check_contains "${role}: an invalid setting of the cleanup fails" \
    "STF_PROVIDER_CLEANUP of config/settings.yml is empty (the default of mcloud-device), true or false, not 'yes'" \
    "$(playbook "$role" --tags validate --extra-vars "$extra")"
  check_contains "${role}: the settings of the cleanup pass" "The setting of the cleanup is valid." \
    "$(playbook "$role" --tags validate)"
  check_contains "${role}: the settings of the unavailable devices and of the wireless watchdog pass" \
    "The settings of the unavailable devices and of the wireless watchdog are valid." \
    "$(playbook "$role" --tags validate --extra-vars '{"DEVICE_UNAVAILABLE_TIMEOUT": 0, "WIRELESS_WATCHDOG_INTERVAL": 0}')"
  for extra in '{"DEVICE_UNAVAILABLE_TIMEOUT": "10m"}' '{"DEVICE_UNAVAILABLE_TIMEOUT": -1}' '{"WIRELESS_WATCHDOG_INTERVAL": ""}' \
    '{"WIRELESS_WATCHDOG_INTERVAL": "5m"}'; do
    check_contains "${role}: ${extra} fails" "DEVICE_UNAVAILABLE_TIMEOUT of config/settings.yml is empty (the default of the connector) or the seconds" \
      "$(playbook "$role" --tags validate --extra-vars "$extra")"
  done
  check_contains "${role}: the tunnel is off by default" "The WireGuard tunnel to MCloud is off." "$(playbook "$role" --tags validate)"
  check_contains "${role}: the tunnel without its settings fails" \
    "WG_ENABLED is true, the settings of the WireGuard tunnel are missing or invalid in config/settings.yml: WG_PRIVATE_KEY, WG_SERVER_PUBLIC_KEY, WG_ADDRESS, WG_SERVER_ADDRESS, WG_ENDPOINT, STF_PROVIDER_HOST" \
    "$(playbook "$role" --tags validate --extra-vars '{"WG_ENABLED": true}')"
  check_contains "${role}: the settings of the tunnel pass" "The settings of the WireGuard tunnel are valid." \
    "$(playbook "$role" --tags validate --extra-vars "$wireguard")"
  extra="$(sed 's/"WG_ENDPOINT": "[^"]*"/"WG_ENDPOINT": "mcloud.example.com:70000"/' <<< "$wireguard")"
  check_contains "${role}: an invalid endpoint of the tunnel fails" "invalid in config/settings.yml: WG_ENDPOINT (" \
    "$(playbook "$role" --tags validate --extra-vars "$extra")"
  extra="$(sed 's/"WG_ADDRESS": "[^"]*"/"WG_ADDRESS": "10.234.0.2\\n[Peer]"/' <<< "$wireguard")"
  check_contains "${role}: a line of the config in a setting of the tunnel fails" "invalid in config/settings.yml: WG_ADDRESS, STF_PROVIDER_HOST (" \
    "$(playbook "$role" --tags validate --extra-vars "$extra")"
  check_contains "${role}: an invalid key of the server fails" "must be the 64 hex characters" \
    "$(playbook "$role" --tags validate --extra-vars "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=abc")"
  check_contains "${role}: an invalid key of the host fails" "must be the 64 hex characters" \
    "$(playbook "$role" --tags validate --extra-vars "STF_ZMQ_CURVE_SECRET_KEY=${server_key}0")"
done

section "file tasks of ${OS_ROLE} (check mode)"
# the folder of the bash completions of the test: the system one is of root (Linux), the one of Homebrew of the user
mkdir -p "${WORK}/bash_completion.d"
output="$(playbook "$OS_ROLE" --check --tags files --extra-vars "common_farm_completion_dir=${WORK}/bash_completion.d")"
check_contains "file tasks pass" "failed=0" "$output"
check_contains "zebrunner-farm is deployed" "Copy 'zebrunner-farm' script file" "$output"
check_contains "the scripts zebrunner-farm sources are copied, owned by root" "TASK [common : Copy the scripts 'zebrunner-farm' sources and runs]" "$output"
if [[ "$OS_ROLE" == "mac-devices" ]]; then
  check_contains "usbmuxd_watch binary is copied, not templated" "Copy 'usbmuxd_watch' binary file" "$output"
  completion_task="Copy the bash completion of 'zebrunner-farm' into the folder of Homebrew"
else
  completion_task="Copy the bash completion of 'zebrunner-farm'"
fi
check_contains "the completion of zebrunner-farm is deployed into the folder of bash-completion" \
  "TASK [common : ${completion_task}] **"$'\n'"changed: [localhost]" "$(sed -E 's/\*+$/**/' <<< "$output")"
output="$(playbook "$OS_ROLE" --check --tags files --start-at-task "Check the folder of the bash completions" \
  --extra-vars "common_farm_completion_dir=${WORK}/no-bash-completion")"
check_contains "without bash-completion the deploy passes" "failed=0" "$output"
check_not_contains "without bash-completion the completion is not deployed" "changed: [localhost]" \
  "$(sed -n "/${completion_task}/,/^\$/p" <<< "$output")"

section "wireless watchdog of ${OS_ROLE} (check mode)"
tasks="$(playbook "$OS_ROLE" --list-tasks --tags watchdog)"
if [[ "$OS_ROLE" == "devices" ]]; then
  check_contains "Linux: the timer of the wireless watchdog is deployed" "Start the timer of the wireless watchdog (mcloud-wireless-watchdog.timer)" "$tasks"
  check_contains "Linux: the timer of the wireless watchdog is removed without wireless devices" "Remove the units of the wireless watchdog" "$tasks"
  watchdog_task="Copy the units of the wireless watchdog"
else
  check_contains "macOS: the launch agent of the wireless watchdog is loaded" "Load ZebrunnerWirelessWatchdog agent via launchctl" "$tasks"
  check_contains "macOS: the launch agent of the wireless watchdog is removed without wireless devices" \
    "Remove ZebrunnerWirelessWatchdog.plist without wireless devices" "$tasks"
  watchdog_task="Copy ZebrunnerWirelessWatchdog.plist into LaunchAgents"
fi
wireless_device='{"devices": [{"id": "a", "name": "WiFi", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 6, "connection": "wireless"}]}'
usb_device='{"devices": [{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 6}]}'
# task_result <name of the task> <output of the playbook>: the first result line of the task
task_result() {
  grep -A1 -F ": ${1}]" <<< "$2" | grep -v '^TASK' | head -1
}
output="$(playbook "$OS_ROLE" --check --tags files --extra-vars "$wireless_device" --extra-vars "common_farm_completion_dir=${WORK}/bash_completion.d")"
check_contains "a wireless device: the tasks pass" "failed=0" "$output"
check_contains "a wireless device: the wireless watchdog is deployed" "changed: [localhost]" "$(task_result "$watchdog_task" "$output")"
output="$(playbook "$OS_ROLE" --check --tags files --extra-vars "$usb_device" --extra-vars "common_farm_completion_dir=${WORK}/bash_completion.d")"
check_contains "no wireless device: the wireless watchdog is not deployed" "skipping: [localhost]" "$(task_result "$watchdog_task" "$output")"
output="$(playbook "$OS_ROLE" --check --tags files --extra-vars "$wireless_device" --extra-vars '{"WIRELESS_WATCHDOG_INTERVAL": 0}' \
  --extra-vars "common_farm_completion_dir=${WORK}/bash_completion.d")"
check_contains "WIRELESS_WATCHDOG_INTERVAL 0: the wireless watchdog is not deployed" "skipping: [localhost]" \
  "$(task_result "$watchdog_task" "$output")"

section "WireGuard tunnel of ${OS_ROLE} (check mode)"
tasks="$(playbook "$OS_ROLE" --list-tasks --tags registerDevices)"
check_contains "the tunnel is deployed by the role of the OS" "Copy the WireGuard config of the tunnel to MCloud" "$tasks"
check_contains "the tunnel is removed by the role of the OS" \
  "$([[ "$OS_ROLE" == devices ]] && echo "Stop and disable the tunnel to MCloud (wg-quick@mcloud-node)" || echo "Remove the launch daemon and the WireGuard config")" "$tasks"
if [[ "$OS_ROLE" == "devices" ]]; then
  check_contains "Linux: docker starts after the tunnel" "Start docker after the tunnel to MCloud at the boot" "$tasks"
  check_contains "Linux: the unit of the devices once the tunnel is up" "Copy the unit of the devices once the tunnel to MCloud is up (mcloud-wireguard-up)" "$tasks"
  check_contains "Linux: without the tunnel the order of docker goes" "Remove the unit of the devices of the tunnel and the order of docker after it" "$tasks"
fi
output="$(playbook "$OS_ROLE" --check --tags wireguard)"
check_contains "the tunnel off: the tasks pass" "failed=0" "$output"
check_contains "the tunnel off: nothing changes on a host without it" "changed=0" "$output"
if [[ "$OS_ROLE" == "mac-devices" ]]; then
  # the config of the tunnel is not written in check mode, the brew of the host is not run (a command)
  output="$(playbook "$OS_ROLE" --check --tags wireguard --extra-vars "$wireguard")"
  check_contains "the tunnel on: the tasks pass" "failed=0" "$output"
  check_contains "the tunnel on: the config is deployed" "TASK [common : Copy the WireGuard config of the tunnel to MCloud]" "$output"
  check_not_contains "the tunnel on: the private key is not shown" "$(printf '%042d' 0 | tr 0 P)A=" \
    "$(playbook "$OS_ROLE" --check --diff --tags wireguard --extra-vars "$wireguard")"
else
  skip_check "the tunnel on in check mode" "apt of the runner"
fi

section "images download"
# docker: pulls fail for images matching $FAIL_PULL, only images matching $LOCAL_IMAGE exist locally
cat > "${WORK}/bin/docker" << 'EOF'
#!/bin/bash
(IFS='|'; echo "docker|$*") >> "${STUB_DIR}/calls.log"
case "$1 $2" in
  "pull "*)
    if [[ -n "$FAIL_PULL" && "$*" == *"$FAIL_PULL"* ]]; then echo "simulated pull failure" >&2; exit 1; fi ;;
  "image inspect")
    if [[ -n "$LOCAL_IMAGE" && "$3" == *"$LOCAL_IMAGE"* ]]; then echo "[{}]"; exit 0; fi
    echo "Error: No such image: $3" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/docker"
export STUB_DIR="$WORK"
# the Developer Disk Images: a local repository instead of GitHub, cloned into the work folder
ddi_commit() {
  mkdir -p "${WORK}/ddi-origin/$1"
  echo "$1" > "${WORK}/ddi-origin/$1/DeveloperDiskImage.dmg"
  git -C "${WORK}/ddi-origin" add -A
  git -C "${WORK}/ddi-origin" -c user.name=test -c user.email=test@example.com commit -q -m "$1"
}
git init -q -b main "${WORK}/ddi-origin"
git -C "${WORK}/ddi-origin" config uploadpack.allowFilter true
ddi_commit DeveloperDiskImages/15.0
ddi_commit PersonalizedImages/Xcode_iOS_DDI_Personalized
ddi_commit PersonalizedImages/Xcode_iOS_DDI_Cryptex
git -C "${WORK}/ddi-origin" tag v1
ddi_commit DeveloperDiskImages/16.7
printf 'DDI_REPO: "file://%s"\nDDI_DIR: "%s"\n' "${WORK}/ddi-origin" "${WORK}/ddi" > "${WORK}/play-download/config/settings.yml"
reset_calls
output="$(playbook download)"
check_contains "all images pulled" "failed=0" "$output"
check "no shared network with a network per device (the default)" "0" "$(calls docker | grep -c '^network|')"
printf 'DEVICE_NETWORK_ISOLATION: false\n' >> "${WORK}/play-download/config/settings.yml"
reset_calls
playbook download > /dev/null
check "DEVICE_NETWORK_ISOLATION=false: the shared network is created after pulling" "network|inspect|infra" \
  "$(calls docker | grep '^network|')"
check "the images are pulled for the platform of the host" "4" "$(calls docker | grep -c '^pull|public.ecr.aws/')"
check "appium is pulled for linux/amd64" "pull|--platform|linux/amd64|public.ecr.aws/zebrunner/appium:" \
  "$(calls docker | grep '^pull|.*appium:' | sed 's/:[^:]*$/:/')"
check "both connectors are pulled without a list of devices" "2" "$(calls docker | grep -c '^pull|.*-connector:')"
reset_calls
output="$(playbook download --extra-vars '{"devices": [{"id": "a", "os": "android"}, {"id": "b", "os": "android"}]}')"
check_contains "the pulls for the Android devices" "failed=0" "$output"
check "the Android devices: the android connector only" "pull|public.ecr.aws/zebrunner/mcloud-android-connector:" \
  "$(calls docker | grep '^pull|.*-connector:' | sed 's/:[^:]*$/:/')"
check "the Android devices: the other images" "3" "$(calls docker | grep -c '^pull|public.ecr.aws/')"
reset_calls
output="$(playbook download --extra-vars '{"devices": [{"id": "a", "os": "ios"}]}')"
check "the iOS devices: the ios connector only" "pull|public.ecr.aws/zebrunner/mcloud-ios-connector:" \
  "$(calls docker | grep '^pull|.*-connector:' | sed 's/:[^:]*$/:/')"
reset_calls
output="$(FAIL_PULL=appium LOCAL_IMAGE=appium playbook download)"
check_contains "failed pull of a local image is reported" "ignoring" "$output"
check_contains "failed pull of a local image does not stop the deploy" "failed=0" "$output"
check "deploy continues with the network" "1" "$(calls docker | grep -c '^network|')"
reset_calls
output="$(FAIL_PULL=appium playbook download)"
check_contains "missing image stops the deploy" "No such image: public.ecr.aws/zebrunner/appium" "$output"
check "deploy stops before the network" "0" "$(calls docker | grep -c '^network|')"
check_contains "check mode skips the pulls" "failed=0" "$(FAIL_PULL=appium playbook download --check)"
# the plays of agent.yml become root: docker runs as the user all the same, become of a task would call the stub and fail
stub become "(IFS='|'; echo \"become|\$*\") >> '${WORK}/calls.log'; exit 1"
reset_calls
output="$(playbook download --become --extra-vars "ansible_become_exe=${WORK}/bin/become")"
check_contains "the pulls of a play that becomes root pass" "failed=0" "$output"
check "docker runs as the user, not as root" "" "$(calls become)"
check "docker runs as the user: the pulls" "4" "$(calls docker | grep -c '^pull|public.ecr.aws/')"

section "Developer Disk Images"
ddi="${WORK}/ddi/DeveloperDiskImages"
# ddi_versions <folder>: the versions of the images of a clone
ddi_versions() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null | sort | paste -s -d ' ' -
}
check "the images are cloned without a list of devices" "15.0 16.7" "$(ddi_versions "$ddi")"
check "the clone is shallow" "true" "$(git -C "${WORK}/ddi" rev-parse --is-shallow-repository 2> /dev/null)"
check "the personalized images are checked out, the Cryptex ones are not" "Xcode_iOS_DDI_Personalized" \
  "$(ddi_versions "${WORK}/ddi/PersonalizedImages")"
output="$(playbook download)"
check_contains "an update without a new commit is not a change" "changed=0" "$output"
ddi_commit DeveloperDiskImages/17.0
output="$(playbook download --extra-vars '{"devices": [{"id": "a", "os": "ios"}]}')"
check_contains "the update for the iOS devices" "failed=0" "$output"
check "the iOS devices: the clone is updated" "15.0 16.7 17.0" "$(ddi_versions "$ddi")"
check_contains "a new commit is a change" "changed=1" "$output"
echo "local" > "${ddi}/16.7/DeveloperDiskImage.dmg"
playbook download > /dev/null
check "a local change is dropped" "DeveloperDiskImages/16.7" "$(cat "${ddi}/16.7/DeveloperDiskImage.dmg")"
output="$(playbook download --extra-vars '{"devices": [{"id": "a", "os": "ios"}], "DDI_VERSION": "v1"}')"
check "DDI_VERSION: a tag" "15.0" "$(ddi_versions "$ddi")"
rm -rf "${WORK}/ddi"
git clone -q "file://${WORK}/ddi-origin" "${WORK}/ddi"
output="$(playbook download)"
check "an earlier full clone: the Cryptex images are removed" "Xcode_iOS_DDI_Personalized" \
  "$(ddi_versions "${WORK}/ddi/PersonalizedImages")"
check "an earlier full clone: the images are kept" "15.0 16.7 17.0" "$(ddi_versions "$ddi")"
rm -rf "${WORK}/ddi"
output="$(playbook download --extra-vars '{"devices": [{"id": "a", "os": "android"}]}')"
check "the Android devices: no clone" "no" "$([[ -e "${WORK}/ddi" ]] && echo yes || echo no)"
output="$(playbook download --extra-vars '{"devices": [{"id": "a", "os": "ios"}], "DDI_ENABLED": false}')"
check "DDI_ENABLED false: no clone" "no" "$([[ -e "${WORK}/ddi" ]] && echo yes || echo no)"
mkdir -p "${WORK}/agent"
output="$(playbook download --extra-vars "{\"devices\": [{\"id\": \"a\", \"os\": \"ios\"}], \"DDI_DIR\": \"\", \"agent_dir\": \"${WORK}/agent\"}")"
check "DDI_DIR empty: DeveloperDiskImages of the agent folder" "15.0 16.7 17.0" \
  "$(ddi_versions "${WORK}/agent/DeveloperDiskImages/DeveloperDiskImages")"
output="$(playbook download --extra-vars "{\"devices\": [{\"id\": \"a\", \"os\": \"ios\"}], \"DDI_REPO\": \"file://${WORK}/missing\"}")"
check_contains "a failed clone is reported" "The Developer Disk Images of file://${WORK}/missing (main) are not updated" "$output"
check_contains "a failed clone does not stop the deploy" "failed=0" "$output"

section "templates"
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/farm" || exit 1
  farm="$(cat "${WORK}/farm")"
  check_contains "${role}: agent dir is rendered into the settings of zebrunner-farm" "ZEBRUNNER_MCLOUD_AGENT_DIR=${REPO}" "$farm"
  check_contains "${role}: relaxed security is off by default" "APPIUM_RELAXED_SECURITY=false" "$farm"
  check_contains "${role}: adb shell is on by default" "APPIUM_ADB_SHELL=true" "$farm"
  check_contains "${role}: chromedriver autodownload is on by default" "APPIUM_CHROMEDRIVER_AUTODOWNLOAD=true" "$farm"
  check_contains "${role}: the cleanup is the default of the image by default" "STF_PROVIDER_CLEANUP=''" "$farm"
  check_contains "${role}: no keep list of the host by default" "CLEANUP_KEEP_PACKAGES=''" "$farm"
  check_contains "${role}: no forward networks by default" "STF_FORWARD_ALLOW=''" "$farm"
  check_contains "${role}: app size check default" "APPIUM_APP_SIZE_DISABLE=false" "$farm"
  render_farm "$role" "${WORK}/farm" --extra-vars '{"APPIUM_RELAXED_SECURITY": true, "APPIUM_APP_SIZE_DISABLE": true}' || exit 1
  farm="$(cat "${WORK}/farm")"
  check_contains "${role}: relaxed security true is lower case" "APPIUM_RELAXED_SECURITY=true" "$farm"
  check_contains "${role}: app size check true is lower case" "APPIUM_APP_SIZE_DISABLE=true" "$farm"
  extra='{"STF_PROVIDER_CLEANUP": false, "CLEANUP_KEEP_PACKAGES": "com.example.app,com.example.tools.*", "STF_FORWARD_ALLOW": "10.1.2.0/24"}'
  render_farm "$role" "${WORK}/farm" --extra-vars "$extra" || exit 1
  farm="$(cat "${WORK}/farm")"
  check_contains "${role}: the cleanup false is lower case" "STF_PROVIDER_CLEANUP=false" "$farm"
  check_contains "${role}: the keep list of the host" "CLEANUP_KEEP_PACKAGES='com.example.app,com.example.tools.*'" "$farm"
  check_contains "${role}: the forward networks of the host" "STF_FORWARD_ALLOW=10.1.2.0/24" "$farm"
  render_farm "$role" "${WORK}/farm" || exit 1
  farm="$(cat "${WORK}/farm")"
  check_contains "${role}: the tunnel is off by default" "WG_ENABLED=false" "$farm"
  check_contains "${role}: no address of the tunnel by default" "WG_ADDRESS=''" "$farm"
  render_farm "$role" "${WORK}/farm" --extra-vars "$wireguard" || exit 1
  farm="$(cat "${WORK}/farm")"
  check_contains "${role}: the tunnel on" "WG_ENABLED=true" "$farm"
  check_contains "${role}: the address of the tunnel" "WG_ADDRESS=10.234.0.2" "$farm"
  check_not_contains "${role}: zebrunner-farm needs no key of the tunnel" "WG_PRIVATE_KEY" "$farm"
done

render "${REPO}/roles/common/templates/mcloud-wireguard.conf" "${WORK}/mcloud-node.conf" --extra-vars "$wireguard" || exit 1
check "the config of the tunnel" "[Interface]
PrivateKey = $(printf '%042d' 0 | tr 0 P)A=
Address = 10.234.0.2/32
[Peer]
PublicKey = $(printf '%042d' 0 | tr 0 S)A=
Endpoint = mcloud.example.com:51820
AllowedIPs = 10.234.0.1/32
PersistentKeepalive = 25" "$(grep -v -e '^#' -e '^$' "${WORK}/mcloud-node.conf")"
render "${REPO}/roles/common/templates/ZebrunnerWireguard.plist" "${WORK}/ZebrunnerWireguard.plist" \
  --extra-vars "common_wg_bin=/opt/homebrew/bin" || exit 1
check_contains "the launch daemon of the tunnel runs wg-quick up of the config" "<string>/opt/homebrew/bin/wg-quick</string>
        <string>up</string>
        <string>/etc/wireguard/mcloud-node.conf</string>" "$(cat "${WORK}/ZebrunnerWireguard.plist")"
if command -v plutil > /dev/null 2>&1; then
  check "ZebrunnerWireguard: valid plist" "${WORK}/ZebrunnerWireguard.plist: OK" "$(plutil -lint "${WORK}/ZebrunnerWireguard.plist")"
fi
render "${REPO}/roles/devices/templates/mcloud-device-restart@.service" "${WORK}/restart.service" || exit 1
check "the tunnel off: the unit of a device after docker" "After=docker.service" "$(grep '^After=' "${WORK}/restart.service")"
render "${REPO}/roles/devices/templates/mcloud-device-restart@.service" "${WORK}/restart.service" --extra-vars "$wireguard" || exit 1
check "the tunnel on: the unit of a device after the tunnel" "After=docker.service wg-quick@mcloud-node.service" \
  "$(grep '^After=' "${WORK}/restart.service")"
render "${REPO}/roles/common/templates/mcloud-wireguard-up.service" "${WORK}/wireguard-up.service" || exit 1
check "the unit of the devices once the tunnel is up: zebrunner-farm after docker and the tunnel" \
  "After=docker.service wg-quick@mcloud-node.service
ExecStart=/usr/local/bin/zebrunner-farm __tunnel-up" "$(grep -E '^(After|ExecStart)=' "${WORK}/wireguard-up.service")"
# dropin <name of the task>: the content of a drop-in of systemd of roles/common/tasks/wireguard.yml, its lines of settings
dropin() {
  python3 -c 'import sys, yaml
for block in yaml.safe_load(open(sys.argv[1])):
    for task in block.get("block", []):
        if task["name"] == sys.argv[2]:
            print("\n".join(l for l in task["ansible.builtin.copy"]["content"].splitlines() if l and not l.startswith("#")))' \
    "${REPO}/roles/common/tasks/wireguard.yml" "$1"
}
check "Linux: docker starts after the tunnel at the boot" "[Unit]
Wants=wg-quick@mcloud-node.service
After=wg-quick@mcloud-node.service" "$(dropin "Start docker after the tunnel to MCloud at the boot")"
check "Linux: a try of wg-quick ends, then the devices that failed without the tunnel" "[Service]
Restart=on-failure
RestartSec=10
TimeoutStartSec=90
ExecStartPost=-/usr/bin/systemctl --no-block start mcloud-wireguard-up.service" "$(dropin "Copy the settings of wg-quick@mcloud-node")"

# the optional settings removed from config/settings.yml: the values by default of the roles, no undefined variable
grep -v -E '^(STF_DOCKER_NETWORK|STF_API_URL|S3_[A-Z_]+|WDA_FILE|WDA_BUNDLEID|WDA_SIMULATOR_FILE|REMOTE_CONNECT_HOST):' \
  "${REPO}/config/settings.yml.original" > "${WORK}/required.yml"
for role in devices mac-devices; do
  if output="$(render "${REPO}/roles/common/templates/zebrunner-farm.env" "${WORK}/farm" --extra-vars common_farm_os=linux \
    --extra-vars "@${REPO}/roles/common/defaults/main.yml" --extra-vars "@${REPO}/roles/${role}/defaults/main.yml" \
    --extra-vars "@${REPO}/versions.yml" --extra-vars "@${WORK}/required.yml")"; then
    farm="$(cat "${WORK}/farm")"
    pass "${role}: the settings of zebrunner-farm without the optional settings"
    check_contains "${role}: the docker network by default" "STF_DOCKER_NETWORK=infra" "$farm"
    check_contains "${role}: zebrunner-farm sources the scripts of the deploy owned by root" \
      "ZEBRUNNER_FARM_LIB=/usr/local/lib/zebrunner-farm" "$farm"
    check "${role}: the simulators run as the user of the simulators" \
      "HOST_SSH_USER=$([[ "$role" == mac-devices ]] && echo mcloud-sim || echo "$USER")" "$(grep '^HOST_SSH_USER=' "${WORK}/farm")"
    check_contains "${role}: a network per device by default" "DEVICE_NETWORK_ISOLATION=true" "$farm"
    check_contains "${role}: the subnets of the networks of the devices" "DEVICE_NETWORK_SUBNETS=10.233.0.0/16" "$farm"
    check "${role}: no certificate of MCloud by default" "MCLOUD_CA_PEM=''" "$(grep '^MCLOUD_CA_PEM=' "${WORK}/farm")"
    check "${role}: STF verifies the certificate by default" "STF_TLS_INSECURE=false" "$(grep '^STF_TLS_INSECURE=' "${WORK}/farm")"
    for name in STF_API_URL S3_BUCKET S3_TENANT S3_ENDPOINT S3_ACCESS_KEY_ID S3_SECRET S3_REGION WDA_FILE WDA_BUNDLEID; do
      check "${role}: ${name} is empty by default" "${name}=''" "$(grep "^${name}=" "${WORK}/farm")"
    done
  else
    fail "${role}: the settings of zebrunner-farm without the optional settings" "the template failed" "$output"
  fi
done
check "the example settings leave STF_DOCKER_NETWORK to the value by default" "" \
  "$(grep '^STF_DOCKER_NETWORK:' "${REPO}/config/settings.yml.original")"

cat > "${WORK}/devices.yml" << 'EOF'
devices:
  - {id: " R28M-1384YQY ", os: android, name: " Galaxy S10 ", appium_port: 1, adb_port: 2, min_port: 3, max_port: 4}
  - {id: 12345, os: android, name: Numeric, appium_port: 5, adb_port: 6, proxy_port: 7, server_proxy_port: 8, min_port: 9, max_port: 10, connection: Wireless, connect_port: 7999}
  - {id: abc, os: ios, name: Phone, appium_port: 11, adb_port: 12, min_port: 13, max_port: 14, wda_file: /wda.ipa, wda_bundleid: my.wda, wda_port: 8101, allow_reboot: true}
  - {id: tv, os: ios, name: TV, appium_port: 15, adb_port: 16, min_port: 17, max_port: 18, connection: proxy, address: 10.0.0.6}
  - {id: sim, os: ios, name: Sim, appium_port: 19, adb_port: 20, min_port: 21, max_port: 22, connection: iOS-Sim, wda_port: 8110, mjpeg_port: 8111}
  - {id: phone, os: ios, name: WiFi, appium_port: 23, adb_port: 24, min_port: 25, max_port: 26, connection: wireless, address: 10.0.0.7, allow_reboot: false, unavailable_timeout: 0}
EOF
render "${REPO}/roles/common/templates/mcloud-devices.txt" "${WORK}/devices.txt" --extra-vars "@${WORK}/devices.yml" || exit 1
check "devices list: the fields key=value of every device" "id=R28M-1384YQY|os=android|name=Galaxy_S10|location=|appium_port=1|adb_port=2|min_port=3|max_port=4|connection=usb|wda_file=|wda_bundleid=|address=|wda_port=|mjpeg_port=|connect_port=
id=12345|os=android|name=Numeric|location=|appium_port=5|adb_port=6|min_port=9|max_port=10|connection=wireless|wda_file=|wda_bundleid=|address=|wda_port=|mjpeg_port=|connect_port=7999
id=abc|os=ios|name=Phone|location=|appium_port=11|adb_port=12|min_port=13|max_port=14|connection=usb|wda_file=/wda.ipa|wda_bundleid=my.wda|address=|wda_port=8101|mjpeg_port=|connect_port=|allow_reboot=true
id=tv|os=ios|name=TV|location=|appium_port=15|adb_port=16|min_port=17|max_port=18|connection=proxy|wda_file=|wda_bundleid=|address=10.0.0.6|wda_port=|mjpeg_port=|connect_port=
id=sim|os=ios|name=Sim|location=|appium_port=19|adb_port=20|min_port=21|max_port=22|connection=ios-sim|wda_file=|wda_bundleid=|address=|wda_port=8110|mjpeg_port=8111|connect_port=
id=phone|os=ios|name=WiFi|location=|appium_port=23|adb_port=24|min_port=25|max_port=26|connection=wireless|wda_file=|wda_bundleid=|address=10.0.0.7|wda_port=|mjpeg_port=|connect_port=|allow_reboot=false|unavailable_timeout=0" "$(grep -v '^#' "${WORK}/devices.txt")"
check "devices list: the comment of its format" "# One device per line, its fields key=value separated by '|' in any order; an empty value is the value by default." \
  "$(grep '^# One device' "${WORK}/devices.txt")"
render "${REPO}/roles/devices/templates/90_mcloud.rules" "${WORK}/rules" --extra-vars "@${REPO}/roles/devices/defaults/main.yml" \
  --extra-vars "@${WORK}/devices.yml" || exit 1
cat > "${WORK}/expected_rules" << 'EOF'
SUBSYSTEM=="usb", ENV{ID_SERIAL_SHORT}=="R28M1384YQY", MODE="0660", GROUP="plugdev", SYMLINK+="device-Galaxy_S10-R28M-1384YQY"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_SERIAL_SHORT}=="R28M1384YQY", RUN+="/usr/bin/systemctl --no-block start mcloud-device-down@R28M-1384YQY.service"
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_SERIAL_SHORT}=="R28M1384YQY", RUN+="/usr/bin/systemctl --no-block start mcloud-device-restart@R28M-1384YQY.service"
EOF
check "udev rules" "$(cat "${WORK}/expected_rules")" "$(head -3 "${WORK}/rules")"
render "${REPO}/roles/devices/templates/90_mcloud.rules" "${WORK}/rules-group" --extra-vars "@${WORK}/devices.yml" \
  --extra-vars "USB_DEVICE_GROUP=adbusers" || exit 1
check_contains "udev rules: the group of the USB devices" 'MODE="0660", GROUP="adbusers"' "$(cat "${WORK}/rules-group")"
check_not_contains "udev rules: no USB device is writable by every user" '0666' "$(cat "${WORK}/rules")"
check "udev rules of the usb devices only" "R28M1384YQY abc" \
  "$(grep -o 'SUBSYSTEM=="usb", ENV{ID_SERIAL_SHORT}=="[^"]*' "${WORK}/rules" | sed 's/.*"//' | paste -s -d ' ' -)"
check_not_contains "udev runs no zebrunner-farm itself" "zebrunner-farm" "$(cat "${WORK}/rules")"
for unit in restart down; do
  render "${REPO}/roles/devices/templates/mcloud-device-${unit}@.service" "${WORK}/${unit}.service" || exit 1
  service="$(cat "${WORK}/${unit}.service")"
  check_contains "the ${unit} unit runs zebrunner-farm ${unit} for the device" "ExecStart=/usr/local/bin/zebrunner-farm ${unit} %i" "$service"
  check_contains "the ${unit} unit is a oneshot job" "Type=oneshot" "$service"
done
check_contains "a disconnection cancels an unfinished restart" "Conflicts=mcloud-device-down@%i.service" \
  "$(cat "${WORK}/restart.service")"
check_contains "a connection cancels an unfinished down" "Conflicts=mcloud-device-restart@%i.service" \
  "$(cat "${WORK}/down.service")"
# the listener of macOS runs zebrunner-farm restart and down of its USB iOS devices as the units of Linux
check "the macOS listener waits for an action as long as the restart unit of Linux" \
  "$(($(sed -n 's/^TimeoutStartSec=\([0-9]*\)min$/\1/p' "${WORK}/restart.service") * 60))" \
  "$(sed -n 's/^ACTION_TIMEOUT_SECONDS=//p' "${REPO}/roles/mac-devices/templates/zebrunner-device-listener")"
render "${REPO}/roles/devices/templates/mcloud-wireless-watchdog.service" "${WORK}/watchdog.service" || exit 1
check "the wireless watchdog: a oneshot zebrunner-farm after docker" "After=docker.service
Type=oneshot
ExecStart=/usr/local/bin/zebrunner-farm __wireless-watchdog" "$(grep -E '^(After|Type|ExecStart)=' "${WORK}/watchdog.service")"
render "${REPO}/roles/devices/templates/mcloud-wireless-watchdog.service" "${WORK}/watchdog.service" --extra-vars "$wireguard" || exit 1
check "the tunnel on: the wireless watchdog after the tunnel" "After=docker.service wg-quick@mcloud-node.service" \
  "$(grep '^After=' "${WORK}/watchdog.service")"
render "${REPO}/roles/devices/templates/mcloud-wireless-watchdog.timer" "${WORK}/watchdog.timer" \
  --extra-vars "@${REPO}/roles/common/defaults/main.yml" || exit 1
check "the timer of the wireless watchdog: every WIRELESS_WATCHDOG_INTERVAL after its last run, enabled for the boot" "OnBootSec=300s
OnUnitInactiveSec=300s
WantedBy=timers.target" "$(grep -E '^(OnBootSec|OnUnitInactiveSec|WantedBy)=' "${WORK}/watchdog.timer")"
if command -v systemd-analyze > /dev/null 2>&1; then
  # verify needs an executable ExecStart: zebrunner-farm is not installed on the test host, a stub replaces it
  stub zebrunner-farm "exit 0"
  for unit in restart down; do
    sed "s|/usr/local/bin/zebrunner-farm|${WORK}/bin/zebrunner-farm|" "${WORK}/${unit}.service" \
      > "${WORK}/mcloud-device-${unit}@.service"
  done
  sed "s|/usr/local/bin/zebrunner-farm|${WORK}/bin/zebrunner-farm|" "${WORK}/wireguard-up.service" \
    > "${WORK}/mcloud-wireguard-up.service"
  sed "s|/usr/local/bin/zebrunner-farm|${WORK}/bin/zebrunner-farm|" "${WORK}/watchdog.service" \
    > "${WORK}/mcloud-wireless-watchdog.service"
  cp "${WORK}/watchdog.timer" "${WORK}/mcloud-wireless-watchdog.timer"
  run_check "the units are valid (systemd-analyze verify)" systemd-analyze verify "${WORK}/mcloud-device-restart@.service" \
    "${WORK}/mcloud-device-down@.service" "${WORK}/mcloud-wireguard-up.service" "${WORK}/mcloud-wireless-watchdog.service" \
    "${WORK}/mcloud-wireless-watchdog.timer"
else
  skip_check "the units are valid (systemd-analyze verify)" "no systemd-analyze"
fi

render "${REPO}/roles/mac-devices/templates/zebrunner-mcloud.newsyslog.conf" "${WORK}/newsyslog.conf" || exit 1
check "log rotation of the listener and the wireless watchdog logs: owner, mode, 7 archives of 10 MB, bzip2, no signal" \
  "${REPO}/logs/listener.log|${USER}:staff|644|7|10240|*|JN
${REPO}/logs/wireless-watchdog.log|${USER}:staff|644|7|10240|*|JN" \
  "$(grep -v '^#' "${WORK}/newsyslog.conf" | awk '{print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7}')"
# newsyslog needs root even for a dry run: passwordless sudo is available on CI macOS runners
if [[ "$(uname)" == "Darwin" ]] && sudo -n true 2> /dev/null; then
  mkdir -p "${WORK}/agent/logs"
  echo "line" > "${WORK}/agent/logs/listener.log"
  ansible localhost --connection local --module-name template --extra-vars "agent_dir=${WORK}/agent" \
    --args "src=${REPO}/roles/mac-devices/templates/zebrunner-mcloud.newsyslog.conf dest=${WORK}/agent/newsyslog.conf" > /dev/null 2>&1
  output="$(sudo -n /usr/sbin/newsyslog -nvF -f "${WORK}/agent/newsyslog.conf" 2>&1)"
  check "newsyslog accepts the rotation settings" "0" "$?"
  check_contains "newsyslog would rotate the listener log" "${WORK}/agent/logs/listener.log" "$output"
else
  skip_check "newsyslog dry run" "needs macOS and passwordless sudo"
fi

for plist in ZebrunnerDevicesListener ZebrunnerUsbmuxd ZebrunnerAdb ZebrunnerWirelessWatchdog; do
  render "${REPO}/roles/mac-devices/templates/${plist}.plist" "${WORK}/${plist}.plist" \
    --extra-vars "@${REPO}/roles/mac-devices/defaults/main.yml" --extra-vars "@${REPO}/roles/common/defaults/main.yml" \
    --extra-vars "mac_devices_adb_path=/opt/homebrew/bin/adb" || exit 1
  check_contains "${plist}: runs in the agent dir" "<string>${REPO}</string>" "$(cat "${WORK}/${plist}.plist")"
  check_contains "${plist}: logs into the agent dir" "<string>${REPO}/logs/" "$(cat "${WORK}/${plist}.plist")"
  if command -v plutil > /dev/null 2>&1; then
    check "${plist}: valid plist" "${WORK}/${plist}.plist: OK" "$(plutil -lint "${WORK}/${plist}.plist")"
  fi
done
check_contains "the wireless watchdog runs zebrunner-farm every WIRELESS_WATCHDOG_INTERVAL seconds" "<string>/usr/local/bin/zebrunner-farm</string>
        <string>__wireless-watchdog</string>
      </array>

    <key>StartInterval</key>
      <integer>300</integer>" "$(cat "${WORK}/ZebrunnerWirelessWatchdog.plist")"
# the launch agents listen on the ports of the addresses the containers reach them with
check_contains "socat of usbmuxd listens on the port of USBMUXD_SOCKET_ADDRESS" "<string>TCP-LISTEN:2222,reuseaddr,fork,bind=127.0.0.1</string>" \
  "$(cat "${WORK}/ZebrunnerUsbmuxd.plist")"
check_contains "the adb server listens on the port of ADB_SERVER_SOCKET_ADDRESS" "<string>-P</string>
        <string>5037</string>" "$(cat "${WORK}/ZebrunnerAdb.plist")"
render "${REPO}/roles/mac-devices/templates/ZebrunnerUsbmuxd.plist" "${WORK}/usbmuxd.plist" \
  --extra-vars "USBMUXD_SOCKET_ADDRESS=host.docker.internal:2345" || exit 1
check_contains "socat of usbmuxd listens on another port of USBMUXD_SOCKET_ADDRESS" "<string>TCP-LISTEN:2345," "$(cat "${WORK}/usbmuxd.plist")"
render "${REPO}/roles/mac-devices/templates/ZebrunnerAdb.plist" "${WORK}/adb.plist" \
  --extra-vars "ADB_SERVER_SOCKET_ADDRESS=host.docker.internal:5038 mac_devices_adb_path=adb" || exit 1
check_contains "the adb server listens on another port of ADB_SERVER_SOCKET_ADDRESS" "<string>5038</string>" "$(cat "${WORK}/adb.plist")"
for address in USBMUXD_SOCKET_ADDRESS=host.docker.internal ADB_SERVER_SOCKET_ADDRESS=host.docker.internal:70000 USBMUXD_SOCKET_ADDRESS=:2222; do
  check_contains "mac-devices: an invalid ${address} fails" "USBMUXD_SOCKET_ADDRESS and ADB_SERVER_SOCKET_ADDRESS are <host>:<port>" \
    "$(playbook mac-devices --tags validate --extra-vars "$address")"
done
# the user of the iOS simulators (README.md#ios-simulators)
sim='{"id": "B1B07E76-0000-0000-0000-000000000001", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}'
check_contains "mac-devices: the user of the simulators passes" "failed=0" \
  "$(playbook mac-devices --tags validate --extra-vars "{\"devices\": [${sim}]}")"
for extra in '"SIMULATOR_USER": "root"' '"SIMULATOR_USER": "Sim User"' '"SIMULATOR_SSH_FROM": "127.0.0.1\" x"' '"SIMULATOR_SSH_FROM": ""'; do
  # the JSON is made outside of the command substitution: bash brace-expands it there
  json="{\"devices\": [${sim}], ${extra}}"
  check_contains "mac-devices: an invalid ${extra} fails" "SIMULATOR_USER must be the name of a macOS user other than root" \
    "$(playbook mac-devices --tags validate --extra-vars "$json")"
done
tasks="$(playbook mac-devices --list-tasks --tags simulators)"
for task in "Create the user of the simulators" "Authorize the ssh key of the simulators for the user of the simulators" \
  "Deny the user of the simulators the home and the agent folder of the user of the deploy" \
  "Remove the ssh key of the simulators from the user of the deploy" "Copy the forced command of the ssh key of the simulators" \
  "Report the simulators of the devices that the user of the simulators does not have"; do
  check_contains "mac-devices: the simulators: ${task}" "$task" "$tasks"
done
key_options="$(sed -n 's/^ *restrict,from=/restrict,from=/p' "${REPO}/roles/mac-devices/tasks/usbmuxd.yml")"
check "mac-devices: the key of the simulators: no forwarding, the loopback, the forced command" \
  'restrict,from="{{ SIMULATOR_SSH_FROM }}",command="/usr/local/bin/zebrunner-simulator-ssh"' "$key_options"
forced="${REPO}/roles/mac-devices/files/zebrunner-simulator-ssh"
env -u SSH_ORIGINAL_COMMAND bash "$forced" > /dev/null 2>&1
check "the forced command refuses an interactive shell" "1" "$?"
check "the forced command runs the command with a fixed PATH and private files" "/usr/bin:/bin:/usr/sbin:/sbin 0077" \
  "$(SSH_ORIGINAL_COMMAND='echo "$PATH $(umask)"' PATH="/opt/evil:${PATH}" bash "$forced" 2>&1)"
check "the forced command reads no login file of the user" "" \
  "$(HOME="$WORK" BASH_ENV="${WORK}/evil" SSH_ORIGINAL_COMMAND='echo "${BASH_ENV:-}"' bash "$forced" 2>&1)"
check_contains "mac-devices: the addresses of the settings pass" "failed=0" \
  "$(playbook mac-devices --tags validate --extra-vars "USBMUXD_SOCKET_ADDRESS=10.0.0.5:2345 ADB_SERVER_SOCKET_ADDRESS=host.docker.internal:5038")"

finish
