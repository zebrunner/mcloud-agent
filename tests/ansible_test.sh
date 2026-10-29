#!/bin/bash
# Ansible roles: registerDevices tag, duplicates check, prechecks and file tasks of the role of the
# current OS (check mode), the images download with a stubbed docker, and the rendered templates.
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

# make_play <role>: a playbook dir using the role from the repo with the example vars as its settings
make_play() {
  local dir="${WORK}/play-$1"
  local part
  mkdir -p "${dir}/roles/$1/vars"
  for part in tasks templates files; do
    [[ -d "${REPO}/roles/$1/${part}" ]] && ln -s "${REPO}/roles/$1/${part}" "${dir}/roles/$1/${part}"
  done
  if [[ -f "${REPO}/roles/$1/vars/main.yml.original" ]]; then
    cp "${REPO}/roles/$1/vars/main.yml.original" "${dir}/roles/$1/vars/main.yml"
  fi
  cat > "${dir}/play.yml" << EOF
- hosts: localhost
  connection: local
  gather_subset: [min]
  vars_files:
    - ${REPO}/defaults/main.yml
  vars:
    STF_DOCKER_NETWORK: infra
  roles:
    - $1
EOF
}

# playbook <role> <ansible-playbook arguments...>
playbook() {
  local role="$1"
  shift
  (cd "${WORK}/play-${role}" && ZEBRUNNER_MCLOUD_AGENT_DIR="$REPO" PATH="${WORK}/bin:${PATH}" ansible-playbook play.yml "$@" < /dev/null 2>&1)
}

for role in devices mac-devices download; do
  make_play "$role"
done

section "registerDevices tag"
for role in devices mac-devices; do
  tasks="$(playbook "$role" --list-tasks --tags registerDevices)"
  check_contains "${role}: the tag selects the prechecks" "Check OS compatibility" "$tasks"
  check_contains "${role}: the tag selects the files" "Copy 'zebrunner-farm' script file" "$tasks"
  check_contains "${role}: the tag selects the duplicates check" "Check for duplicate device IDs or names" "$tasks"
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
EOF
done
while IFS='=' read -r devices expected; do
  check_contains "mac-devices: ${devices}" "$expected" "$(playbook mac-devices --tags validate --extra-vars "{\"devices\": ${devices}}")"
done << 'EOF'
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "wireless": true}]=failed=0
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "wireless": true, "wda_host": "10.0.0.5"}]=failed=0
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "proxy"}]=Invalid connection 'proxy' of device 'TV'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "bluetooth"}]=Invalid connection 'bluetooth' of device 'A'
[{"id": "a", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim"}]=Invalid connection 'ios-sim' of device 'Sim'
[{"id": "a", "name": "Sim", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}]=Invalid connection 'ios-sim' of device 'Sim'
[{"id": "a", "name": "Emu", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "android-sim"}]=Invalid connection 'android-sim' of device 'Emu'
[{"id": "a", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}, {"id": "b", "name": "Emu", "os": "android", "appium_port": 5, "adb_port": 6, "min_port": 7, "max_port": 8, "connection": "android-sim", "address": "host.docker.internal:5555"}]=failed=0
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "simulator", "wda_port": 8110}]=Invalid connection 'simulator' of device 'A'
[{"id": "a", "name": "A", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}, {"id": "b", "name": "B", "os": "ios", "appium_port": 5, "adb_port": 6, "min_port": 7, "max_port": 8, "connection": "ios-sim", "wda_port": 8111}]=The host ports [8110, 8111, 8111, 8112] of the iOS simulators
[{"id": "a", "name": "A", "os": "ios", "appium_port": 8110, "adb_port": 2, "min_port": 3, "max_port": 4}, {"id": "b", "name": "B", "os": "ios", "appium_port": 5, "adb_port": 6, "min_port": 7, "max_port": 8, "connection": "ios-sim", "wda_port": 8110}]=The host ports [8110, 8111] of the iOS simulators
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "adb_port": 7422, "min_port": 3, "max_port": 4}, {"id": "b", "name": "B", "os": "android", "appium_port": 5, "adb_port": 7422, "min_port": 7, "max_port": 8}]=The host ports [7422, 7422] of the iOS simulators
[{"id": "a", "name": "A", "os": "android", "appium_port": 1, "adb_port": 7422, "min_port": 3, "max_port": 4}, {"id": "b", "name": "B", "os": "android", "appium_port": 5, "adb_port": 7422, "min_port": 7, "max_port": 8, "connection": "wireless"}]=failed=0
EOF
while IFS='=' read -r devices expected; do
  check_contains "devices: ${devices}" "$expected" "$(playbook devices --tags validate --extra-vars "{\"devices\": ${devices}}")"
done << 'EOF'
[{"id": "a", "name": "WiFi", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "wireless"}]=Invalid connection 'wireless' of device 'WiFi'
[{"id": "a", "name": "WiFi", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "wireless", "address": "10.0.0.7"}]=failed=0
[{"id": "a", "name": "WiFi", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "wireless": true}]=failed=0
[{"id": "a", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}]=Invalid connection 'ios-sim' of device 'Sim'
[{"id": "a", "name": "Emu", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "android-sim", "address": "10.0.0.9:5555"}]=failed=0
[{"id": "a", "name": "Emu", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "android-sim"}]=Invalid connection 'android-sim' of device 'Emu'
[{"id": "a", "name": "Emu", "os": "android", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "redroid"}]=Invalid connection 'redroid' of device 'Emu'
[{"id": "a", "name": "TV", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "proxy", "address": "10.0.0.5"}]=failed=0
EOF

section "prechecks of ${OS_ROLE}"
output="$(playbook "$OS_ROLE" --check --tags precheck)"
check_contains "OS is compatible" "OS is compatible: $(uname)" "$output"
check_contains "setup is done" "Setup is ready" "$output"
check_contains "agent dir env variable is set" "env variable is defined" "$output"
check_contains "prechecks pass" "failed=0" "$output"
output="$(cd "${WORK}/play-${OS_ROLE}" && env -u ZEBRUNNER_MCLOUD_AGENT_DIR ansible-playbook play.yml --check --tags precheck < /dev/null 2>&1)"
check_contains "unset agent dir env variable fails" "You have to set up 'ZEBRUNNER_MCLOUD_AGENT_DIR' env variable in advance!" "$output"
output="$(cd "${WORK}/play-${OS_ROLE}" && ZEBRUNNER_MCLOUD_AGENT_DIR="" ansible-playbook play.yml --check --tags precheck < /dev/null 2>&1)"
check_contains "empty agent dir env variable fails" "You have to set up 'ZEBRUNNER_MCLOUD_AGENT_DIR' env variable in advance!" "$output"
mv "${WORK}/play-${OS_ROLE}/roles/${OS_ROLE}/vars/main.yml" "${WORK}/vars.yml"
check_contains "missing setup fails" "You have to set up services in advance using: ./zebrunner.sh setup!" "$(playbook "$OS_ROLE" --check --tags precheck)"
mv "${WORK}/vars.yml" "${WORK}/play-${OS_ROLE}/roles/${OS_ROLE}/vars/main.yml"
check_contains "ZeroMQ without CURVE by default" "ZeroMQ of STF without CURVE." "$(playbook "$OS_ROLE" --check --tags precheck)"
server_key="$(printf '%064d' 0 | tr 0 a)"
secret_key="$(printf '%064d' 0 | tr 0 b)"
output="$(playbook "$OS_ROLE" --check --tags precheck \
  --extra-vars "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${server_key} STF_ZMQ_CURVE_SECRET_KEY=${secret_key}")"
check_contains "the CURVE keys pass" "ZeroMQ of STF with CURVE." "$output"
check_contains "the CURVE keys pass the prechecks" "failed=0" "$output"
check_contains "the key of the server needs the key of the host" "run ./zebrunner.sh curve-key" \
  "$(playbook "$OS_ROLE" --check --tags precheck --extra-vars "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${server_key}")"
check_contains "an invalid key of the server fails" "must be the 64 hex characters" \
  "$(playbook "$OS_ROLE" --check --tags precheck \
    --extra-vars "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=abc STF_ZMQ_CURVE_SECRET_KEY=${secret_key}")"

section "file tasks of ${OS_ROLE} (check mode)"
output="$(playbook "$OS_ROLE" --check --tags files)"
check_contains "file tasks pass" "failed=0" "$output"
check_contains "zebrunner-farm is deployed" "Copy 'zebrunner-farm' script file" "$output"
if [[ "$OS_ROLE" == "mac-devices" ]]; then
  check_contains "usbmuxd_watch binary is copied, not templated" "Copy 'usbmuxd_watch' binary file" "$output"
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
reset_calls
output="$(playbook download)"
check_contains "all images pulled" "failed=0" "$output"
check "network is created after pulling" "1" "$(calls docker | grep -c '^network|')"
check "mcloud-device is pulled for the platform of the host" "pull|public.ecr.aws/zebrunner/mcloud-device:" \
  "$(calls docker | grep '^pull|.*mcloud-device:' | sed 's/:[^:]*$/:/')"
check "the other images are pulled for linux/amd64" "4" "$(calls docker | grep -c '^pull|--platform|linux/amd64|')"
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

section "templates"
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/farm" || exit 1
  farm="$(cat "${WORK}/farm")"
  check_contains "${role}: agent dir is rendered into zebrunner-farm" "export ZEBRUNNER_MCLOUD_AGENT_DIR=\"${REPO}\"" "$farm"
  check_contains "${role}: relaxed security default" "RELAXED_SECURITY=\"true\"" "$farm"
  check_contains "${role}: app size check default" "APPIUM_APP_SIZE_DISABLE=\"false\"" "$farm"
  render_farm "$role" "${WORK}/farm" --extra-vars '{"APPIUM_RELAXED_SECURITY": false, "APPIUM_APP_SIZE_DISABLE": true}' || exit 1
  farm="$(cat "${WORK}/farm")"
  check_contains "${role}: relaxed security false is lower case" "RELAXED_SECURITY=\"false\"" "$farm"
  check_contains "${role}: app size check true is lower case" "APPIUM_APP_SIZE_DISABLE=\"true\"" "$farm"
done

cat > "${WORK}/devices.yml" << 'EOF'
devices:
  - {id: " R28M-1384YQY ", os: android, name: " Galaxy S10 ", appium_port: 1, adb_port: 2, min_port: 3, max_port: 4}
  - {id: 12345, os: android, name: Numeric, appium_port: 5, adb_port: 6, proxy_port: 7, server_proxy_port: 8, min_port: 9, max_port: 10, wireless: "True"}
  - {id: abc, os: ios, name: Phone, appium_port: 11, adb_port: 12, min_port: 13, max_port: 14, wireless: false, wda_file: /wda.ipa, wda_bundleid: my.wda, wda_host: 10.0.0.5, wda_port: 8101}
  - {id: tv, os: ios, name: TV, appium_port: 15, adb_port: 16, min_port: 17, max_port: 18, wireless: true, wda_host: 10.0.0.6}
  - {id: sim, os: ios, name: Sim, appium_port: 19, adb_port: 20, min_port: 21, max_port: 22, connection: iOS-Sim, wda_port: 8110, mjpeg_port: 8111}
  - {id: phone, os: ios, name: WiFi, appium_port: 23, adb_port: 24, min_port: 25, max_port: 26, connection: wireless, address: 10.0.0.7}
EOF
render "${REPO}/roles/devices/templates/mcloud-devices.txt" "${WORK}/linux.txt" --extra-vars "@${WORK}/devices.yml" || exit 1
check "Linux devices list" "R28M-1384YQY|android|Galaxy_S10||1|2|0|0|3|4|usb|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|||
12345|android|Numeric||5|6|7|8|9|10|wireless|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|||
abc|ios|Phone||11|12|0|0|13|14|usb|/wda.ipa|my.wda||8101|
tv|ios|TV||15|16|0|0|17|18|wireless|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|||
sim|ios|Sim||19|20|0|0|21|22|ios-sim|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner||8110|8111
phone|ios|WiFi||23|24|0|0|25|26|wireless|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|10.0.0.7||" "$(cat "${WORK}/linux.txt")"
render "${REPO}/roles/mac-devices/templates/mcloud-devices.txt" "${WORK}/mac.txt" --extra-vars "@${WORK}/devices.yml" || exit 1
check "macOS devices list" "R28M-1384YQY|android|Galaxy_S10||1|2|0|0|3|4|usb|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|||
12345|android|Numeric||5|6|7|8|9|10|wireless|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|||
abc|ios|Phone||11|12|0|0|13|14|usb|/wda.ipa|my.wda|10.0.0.5|8101|
tv|ios|TV||15|16|0|0|17|18|proxy|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|10.0.0.6||
sim|ios|Sim||19|20|0|0|21|22|ios-sim|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner||8110|8111
phone|ios|WiFi||23|24|0|0|25|26|wireless|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|10.0.0.7||" "$(cat "${WORK}/mac.txt")"
render "${REPO}/roles/devices/templates/90_mcloud.rules" "${WORK}/rules" --extra-vars "@${WORK}/devices.yml" || exit 1
cat > "${WORK}/expected_rules" << 'EOF'
SUBSYSTEM=="usb", ENV{ID_SERIAL_SHORT}=="R28M1384YQY", MODE="0666", SYMLINK+="device-Galaxy_S10-R28M-1384YQY"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_SERIAL_SHORT}=="R28M1384YQY", RUN+="/usr/bin/systemctl --no-block start mcloud-device-down@R28M-1384YQY.service"
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_SERIAL_SHORT}=="R28M1384YQY", RUN+="/usr/bin/systemctl --no-block start mcloud-device-restart@R28M-1384YQY.service"
EOF
check "udev rules" "$(cat "${WORK}/expected_rules")" "$(head -3 "${WORK}/rules")"
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
if command -v systemd-analyze > /dev/null 2>&1; then
  # verify needs an executable ExecStart: zebrunner-farm is not installed on the test host, a stub replaces it
  stub zebrunner-farm "exit 0"
  for unit in restart down; do
    sed "s|/usr/local/bin/zebrunner-farm|${WORK}/bin/zebrunner-farm|" "${WORK}/${unit}.service" \
      > "${WORK}/mcloud-device-${unit}@.service"
  done
  run_check "the units are valid (systemd-analyze verify)" \
    systemd-analyze verify "${WORK}/mcloud-device-restart@.service" "${WORK}/mcloud-device-down@.service"
else
  skip_check "the units are valid (systemd-analyze verify)" "no systemd-analyze"
fi

render "${REPO}/roles/mac-devices/templates/zebrunner-mcloud.newsyslog.conf" "${WORK}/newsyslog.conf" || exit 1
check "log rotation of the listener log: owner, mode, 7 archives of 10 MB, bzip2, no signal" \
  "${REPO}/logs/listener.log|${USER}:staff|644|7|10240|*|JN" \
  "$(grep -v '^#' "${WORK}/newsyslog.conf" | awk '{print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7}')"
# newsyslog needs root even for a dry run: passwordless sudo is available on CI macOS runners
if [[ "$(uname)" == "Darwin" ]] && sudo -n true 2> /dev/null; then
  mkdir -p "${WORK}/agent/logs"
  echo "line" > "${WORK}/agent/logs/listener.log"
  ZEBRUNNER_MCLOUD_AGENT_DIR="${WORK}/agent" ansible localhost --connection local --module-name template \
    --args "src=${REPO}/roles/mac-devices/templates/zebrunner-mcloud.newsyslog.conf dest=${WORK}/agent/newsyslog.conf" > /dev/null 2>&1
  output="$(sudo -n /usr/sbin/newsyslog -nvF -f "${WORK}/agent/newsyslog.conf" 2>&1)"
  check "newsyslog accepts the rotation settings" "0" "$?"
  check_contains "newsyslog would rotate the listener log" "${WORK}/agent/logs/listener.log" "$output"
else
  skip_check "newsyslog dry run" "needs macOS and passwordless sudo"
fi

for plist in ZebrunnerDevicesListener ZebrunnerUsbmuxd; do
  render "${REPO}/roles/mac-devices/templates/${plist}.plist" "${WORK}/${plist}.plist" || exit 1
  check_contains "${plist}: runs in the agent dir" "<string>${REPO}</string>" "$(cat "${WORK}/${plist}.plist")"
  check_contains "${plist}: logs into the agent dir" "<string>${REPO}/logs/" "$(cat "${WORK}/${plist}.plist")"
  if command -v plutil > /dev/null 2>&1; then
    check "${plist}: valid plist" "${WORK}/${plist}.plist: OK" "$(plutil -lint "${WORK}/${plist}.plist")"
  fi
done

finish
