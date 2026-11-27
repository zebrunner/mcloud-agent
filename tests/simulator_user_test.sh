#!/bin/bash
# The user of the iOS simulators of macOS for real (README.md#ios-simulators): the simulators block of the mac-devices
# role creates SIMULATOR_USER and authorizes the ssh key of the simulators for it; the key runs xcrun simctl of that user
# over ssh as the containers of a simulator do, a simulator is created and booted as that user, and the user reads no
# file of the user of the deploy. It creates a macOS user, so it runs only with MCLOUD_SIMULATOR_E2E=1 (the macOS runner
# of CI), on macOS with passwordless sudo and Xcode; the user and the files are removed at the end.
source "$(dirname "$0")/lib.sh"
require_os Darwin
require_cmd ansible-playbook
require_cmd xcrun
[[ "${MCLOUD_SIMULATOR_E2E:-}" == "1" ]] || skip "creates a macOS user: MCLOUD_SIMULATOR_E2E=1 (CI)"
sudo -n true 2> /dev/null || skip "needs passwordless sudo"

SIM_USER="mcloud-sim-test"
AGENT="${WORK}/agent"
mkdir -p "${AGENT}/config"
# a secret of the user of the deploy in the agent folder (config/settings.yml is mode 600)
(umask 077 && echo "MCLOUD_NODE_TOKEN: secret" > "${AGENT}/config/settings.yml")
SIM_UDID=""

# the cleanup of lib.sh on exit
# shellcheck disable=SC2329
cleanup() {
  [[ -z "$SIM_UDID" ]] || sim xcrun simctl delete "$SIM_UDID" > /dev/null 2>&1
  local entry="user:${SIM_USER} deny list,search,readattr,readextattr,readsecurity,add_file,add_subdirectory,delete_child"
  chmod -a "$entry" "$HOME" 2> /dev/null
  sudo -n /usr/bin/pkill -u "$SIM_USER" > /dev/null 2>&1
  sudo -n /usr/sbin/sysadminctl -deleteUser "$SIM_USER" > /dev/null 2>&1
  sudo -n /usr/sbin/dseditgroup -o delete "$SIM_USER" > /dev/null 2>&1
  sudo -n rm -rf "/Users/${SIM_USER}" /usr/local/bin/zebrunner-simulator-ssh
}

# sim <command...>: the command as the user of the simulators with the ssh key of the simulators, as the containers
sim() {
  ssh -i "${AGENT}/ssh/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=${AGENT}/ssh/known_hosts" -o LogLevel=ERROR -o ConnectTimeout=10 "${SIM_USER}@127.0.0.1" "$@"
}

# Remote Login of the runner
if ! nc -z -G 3 127.0.0.1 22 > /dev/null 2>&1; then
  sudo -n launchctl load -w /System/Library/LaunchDaemons/ssh.plist > /dev/null 2>&1 ||
    sudo -n systemsetup -f -setremotelogin on > /dev/null 2>&1
  for _ in $(seq 1 20); do
    nc -z -G 1 127.0.0.1 22 > /dev/null 2>&1 && break
    sleep 1
  done
fi
nc -z -G 3 127.0.0.1 22 > /dev/null 2>&1 || skip "Remote Login cannot be turned on"

# deploy <devices JSON>: the simulators block of the mac-devices role, as the deploy runs it (root, the user's HOME)
deploy() {
  local dir="${WORK}/play"
  mkdir -p "${dir}/roles/mac-devices" "${dir}/roles/common"
  local part
  for part in tasks templates files defaults meta; do
    [[ -e "${dir}/roles/mac-devices/${part}" || ! -d "${REPO}/roles/mac-devices/${part}" ]] ||
      ln -s "${REPO}/roles/mac-devices/${part}" "${dir}/roles/mac-devices/${part}"
    [[ -e "${dir}/roles/common/${part}" || ! -d "${REPO}/roles/common/${part}" ]] ||
      ln -s "${REPO}/roles/common/${part}" "${dir}/roles/common/${part}"
  done
  printf '%s\n' '- hosts: localhost' '  connection: local' '  gather_subset: [min]' '  become: true' '  roles:' \
    '    - mac-devices' > "${dir}/play.yml"
  (cd "$dir" && ansible-playbook play.yml --tags simulators --extra-vars "agent_dir=${AGENT}" \
    --extra-vars "{\"SIMULATOR_USER\": \"${SIM_USER}\", \"devices\": $1}" < /dev/null 2>&1)
}

device() {
  printf '[{"id": "%s", "name": "Sim", "os": "ios", "appium_port": 1, "adb_port": 2, "min_port": 3, "max_port": 4, "connection": "ios-sim", "wda_port": 8110}]' "$1"
}

section "the deploy of the user of the simulators"
output="$(deploy "$(device 00000000-0000-0000-0000-000000000000)")"
check_contains "the deploy passes" "failed=0" "$output"
check "the user of the simulators exists" "yes" "$(id -u "$SIM_USER" > /dev/null 2>&1 && echo yes)"
check_contains "it is hidden" "IsHidden: 1" "$(dscl . -read "/Users/${SIM_USER}" IsHidden 2>&1)"
check "its primary group is its own" "$(dscl . -read "/Groups/${SIM_USER}" PrimaryGroupID 2> /dev/null | awk '{print $2}')" \
  "$(id -g "$SIM_USER" 2> /dev/null)"
check "its home is private" "700 ${SIM_USER}" "$(stat -f '%Lp %Su' "/Users/${SIM_USER}")"
check "its authorized keys are of root" "644 root" "$(sudo -n stat -f '%Lp %Su' "/Users/${SIM_USER}/.ssh/authorized_keys")"
check_contains "the key: no forwarding, the loopback, the forced command" \
  'restrict,from="127.0.0.1,::1",command="/usr/local/bin/zebrunner-simulator-ssh" ssh-ed25519 ' \
  "$(sudo -n cat "/Users/${SIM_USER}/.ssh/authorized_keys")"
check_not_contains "the key is not authorized for the user of the deploy" "zebrunner-mcloud-simulators" \
  "$(cat "${HOME}/.ssh/authorized_keys" 2> /dev/null)"
check_contains "a simulator of another user is reported" \
  "the simulators 00000000-0000-0000-0000-000000000000 are not simulators of ${SIM_USER}" "$output"
check_contains "the deploy is idempotent" "failed=0" "$(deploy "$(device 00000000-0000-0000-0000-000000000000)")"

section "the ssh key of the simulators"
check "the commands run as the user of the simulators" "$SIM_USER" "$(sim id -un 2>&1)"
# the command is expanded by the shell of the host
# shellcheck disable=SC2016
check "with the environment of the forced command" "/usr/bin:/bin:/usr/sbin:/sbin 0077" "$(sim 'echo "$PATH $(umask)"' 2>&1)"
check_contains "no interactive shell" "runs commands only, no interactive shell" "$(sim < /dev/null 2>&1)"
check_not_contains "the user of the simulators does not read the settings of the user of the deploy" "secret" \
  "$(sim cat "${AGENT}/config/settings.yml" 2>&1)"
check_contains "nor list the home of the user of the deploy" "Permission denied" "$(sim ls "$HOME" 2>&1)"
check_contains "nor its ssh folder" "Permission denied" "$(sim ls "${HOME}/.ssh" 2>&1)"
check_contains "the forced command is not writable by the user" "Permission denied" \
  "$(sim 'echo x >> /usr/local/bin/zebrunner-simulator-ssh' 2>&1)"
check_contains "nor its authorized keys" "Permission denied" "$(sim "echo x >> /Users/${SIM_USER}/.ssh/authorized_keys" 2>&1)"

section "a simulator of the user of the simulators"
runtimes="$(sim xcrun simctl list runtimes --json 2>&1)"
runtime="$(python3 -c 'import json, sys
runtimes = [r for r in json.loads(sys.stdin.read()).get("runtimes", []) if r.get("isAvailable") and r.get("platform") == "iOS"]
print(runtimes[-1]["identifier"] if runtimes else "")' <<< "$runtimes" 2> /dev/null)"
if [[ -z "$runtime" ]]; then
  fail "xcrun simctl of the user of the simulators lists the iOS runtimes" "no available iOS runtime" "$runtimes"
  finish
fi
pass "xcrun simctl of the user of the simulators lists the iOS runtimes: ${runtime}"
type="$(sim xcrun simctl list devicetypes --json 2>&1 | python3 -c 'import json, sys
types = [t["identifier"] for t in json.loads(sys.stdin.read()).get("devicetypes", []) if ".iPhone-" in t["identifier"]]
print(types[-1] if types else "")' 2> /dev/null)"
SIM_UDID="$(sim xcrun simctl create mcloud-test "$type" "$runtime" 2>&1)"
check_contains "a simulator is created as the user of the simulators" "-" "$SIM_UDID"
run_check "the simulator boots headless over the ssh key" sim xcrun simctl bootstatus "$SIM_UDID" -b
check_contains "the deploy finds the simulator of the device" "The simulators of the devices are simulators of ${SIM_USER}." \
  "$(deploy "$(device "$SIM_UDID")")"
check "the simulator is not one of the user of the deploy" "0" "$(xcrun simctl list devices 2> /dev/null | grep -c "$SIM_UDID")"
sim xcrun simctl shutdown "$SIM_UDID" > /dev/null 2>&1

finish
