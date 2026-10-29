#!/bin/bash
# zebrunner.sh commands on a copy of the repo with a temporary HOME. sudo, launchctl, docker,
# ansible-playbook, zebrunner-farm and uname (to test both Linux and macOS branches) are stubs,
# sudo only records its calls.
source "$(dirname "$0")/lib.sh"

AGENT="${WORK}/repo"
mkdir -p "$AGENT" "${WORK}/home"
(cd "$REPO" && tar --exclude=.git -cf - .) | (cd "$AGENT" && tar -xf -)
rm -rf "${AGENT}/backup/"bak_* "${AGENT}/roles/devices/vars/main.yml" "${AGENT}/roles/mac-devices/vars/main.yml"

# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub uname 'echo "$FAKE_UNAME"'
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub ansible-playbook '(IFS="|"; echo "ansible-playbook|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "--version" ]] && echo "ansible-playbook [core 2.21.5]"
exit "${ANSIBLE_EXIT:-0}"'
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub sudo '(IFS="|"; echo "sudo|$*") >> "${STUB_DIR}/calls.log"'
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub launchctl '(IFS="|"; echo "launchctl|$*") >> "${STUB_DIR}/calls.log"'
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1 $2" == "volume ls" ]] && echo "local     appium-storage-volume"
exit 0'
record_stub zebrunner-farm

# zbr <stdin text> <zebrunner.sh arguments...>: runs zebrunner.sh of the repo copy without the user's
# environment; $OS sets uname, $AGENT_DIR the ZEBRUNNER_MCLOUD_AGENT_DIR variable when not empty
zbr() {
  local input="$1"
  shift
  printf '%b' "$input" | env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb \
    STUB_DIR="$WORK" FAKE_UNAME="${OS:-Linux}" ANSIBLE_EXIT="${ANSIBLE_EXIT:-0}" \
    ${AGENT_DIR:+ZEBRUNNER_MCLOUD_AGENT_DIR=$AGENT_DIR} /bin/bash "${AGENT}/zebrunner.sh" "$@" 2>&1
}

exports() {
  grep -c "^export ZEBRUNNER_MCLOUD_AGENT_DIR=${AGENT}\$" "${WORK}/home/$1" 2> /dev/null || true
}

section "help"
output="$(zbr "")"
check_contains "help shows the usage" "Usage: ./zebrunner.sh [option]" "$output"
for command in setup ansible status backup restore shutdown version curve-key; do
  check_contains "help lists ${command}" "         ${command} " "$output"
done

section "setup"
echo "export ZEBRUNNER_MCLOUD_AGENT_DIR=/old/path" > "${WORK}/home/.bashrc"
output="$(OS=Linux zbr "" setup)"
check "the agent dir replaces an old value in .bashrc" "1" "$(exports .bashrc)"
check "the old value is gone" "0" "$(grep -c '/old/path' "${WORK}/home/.bashrc")"
check "the agent dir is added to .bash_profile" "1" "$(exports .bash_profile)"
check "Linux settings are created from the example" "same" \
  "$(cmp -s "${AGENT}/roles/devices/vars/main.yml" "${AGENT}/roles/devices/vars/main.yml.original" && echo same)"
check_contains "the reload of the shell is suggested" "To apply the changes" "$output"
check_contains "the settings of the server are the next step" "Set the settings of the MCloud server in 'roles/devices/vars/main.yml'" "$output"
output="$(OS=Linux zbr "" setup)"
check "a second setup does not duplicate the variable" "1" "$(exports .bashrc)"
check_contains "a second setup backs up existing settings" "making a backup" "$output"
check "the backup of the settings exists" "yes" "$([[ -f "${AGENT}/roles/devices/vars/main.yml.bak" ]] && echo yes)"
OS=Darwin zbr "" setup > /dev/null
check "macOS settings are created from the example" "same" \
  "$(cmp -s "${AGENT}/roles/mac-devices/vars/main.yml" "${AGENT}/roles/mac-devices/vars/main.yml.original" && echo same)"
check_contains "unknown OS is rejected" "Unknown OS" "$(OS=FreeBSD zbr "" setup)"

section "curve-key"
for os in Linux Darwin; do
  vars="${AGENT}/roles/$([[ "$os" == Linux ]] && echo devices || echo mac-devices)/vars/main.yml"
  output="$(OS="$os" zbr "" curve-key)"
  secret="$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY: "\([0-9a-f]*\)"$/\1/p' "$vars")"
  check "${os}: the key of the host is written" "64" "${#secret}"
  public="$(python3 "${REPO}/patch/curve_keygen.py" "$secret" | sed -n 's/^public=//p')"
  check_contains "${os}: its public key is printed" "The public key of this host: ${public}" "$output"
  check_not_contains "${os}: the secret key is not printed" "$secret" "$output"
  OS="$os" zbr "" curve-key > /dev/null
  check "${os}: the key is kept" "$secret" "$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY: "\(.*\)"$/\1/p' "$vars")"
done
vars="${AGENT}/roles/devices/vars/main.yml"
cp "$vars" "${WORK}/vars.saved"
grep -v '^STF_ZMQ_CURVE_' "${WORK}/vars.saved" > "$vars"
printf 'LAST: value' >> "$vars"
OS=Linux zbr "" curve-key > /dev/null
check "the key is added to the settings of an earlier agent" "1" "$(grep -c '^STF_ZMQ_CURVE_SECRET_KEY: "[0-9a-f]\{64\}"$' "$vars")"
check "the last line of the settings is kept" "1" "$(grep -cx 'LAST: value' "$vars")"
cp "${WORK}/vars.saved" "$vars"
check_contains "the settings are needed" "run './zebrunner.sh setup' first" \
  "$(rm -f "${AGENT}/roles/devices/vars/main.yml" && OS=Linux zbr "" curve-key)"
cp "${WORK}/vars.saved" "$vars"
check "the script makes the public key of RFC 7748" "public=8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" \
  "$(python3 "${REPO}/patch/curve_keygen.py" 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a | head -1)"

section "version"
check_contains "versions from the agent dir" "DEVICE_VERSION:" "$(AGENT_DIR="$AGENT" zbr "" version)"
output="$(zbr "" version)"
check_contains "missing agent dir variable is reported" "is not set" "$output"
check_contains "versions from the current dir without the variable" "APPIUM_VERSION:" "$output"

section "ansible"
check_contains "ansible needs the agent dir variable" "is not set" "$(zbr "" ansible)"
reset_calls
AGENT_DIR="$AGENT" OS=Linux zbr "" ansible > /dev/null
check "Linux playbook" "--ask-become-pass|--inventory|hosts|${AGENT}/devices.yml" "$(calls ansible-playbook)"
reset_calls
AGENT_DIR="$AGENT" OS=Darwin zbr "" ansible > /dev/null
check "macOS playbook" "--ask-become-pass|--inventory|hosts|${AGENT}/mac-devices.yml" "$(calls ansible-playbook)"
reset_calls
AGENT_DIR="$AGENT" OS=Darwin zbr "" ansible devices > /dev/null
check "devices registration only" "--ask-become-pass|--inventory|hosts|${AGENT}/mac-devices.yml|--tag|registerDevices" "$(calls ansible-playbook)"
reset_calls
AGENT_DIR="$AGENT" OS=Linux zbr "" ansible --user=bob --extra-vars "app_name=a b" > /dev/null
check "custom arguments keep their words" "--ask-become-pass|--inventory|hosts|--user=bob|--extra-vars|app_name=a b|${AGENT}/devices.yml" "$(calls ansible-playbook)"
output="$(AGENT_DIR="$AGENT" OS=Linux zbr "" ansible)"
check_contains "the deploy suggests zebrunner-farm start" "Run 'zebrunner-farm start'" "$output"
check_not_contains "the registration of the devices does not" "zebrunner-farm start" "$(AGENT_DIR="$AGENT" OS=Linux zbr "" ansible devices)"
# sudo-rs of Ubuntu 25.10+: ansible does not recognize its password prompt, sudo.ws is the original sudo
cp "${WORK}/bin/sudo" "${WORK}/sudo"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub sudo '(IFS="|"; echo "sudo|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "--version" ]] && echo "sudo-rs 0.2.13"
exit 0'
record_stub sudo.ws
reset_calls
output="$(AGENT_DIR="$AGENT" OS=Linux zbr "" ansible)"
check "sudo-rs: ansible becomes root with sudo.ws" "--ask-become-pass|--inventory|hosts|--extra-vars|ansible_become_exe=sudo.ws|${AGENT}/devices.yml" "$(calls ansible-playbook)"
check_contains "sudo-rs: sudo.ws is reported" "sudo is sudo-rs: ansible becomes root with sudo.ws" "$output"
reset_calls
AGENT_DIR="$AGENT" OS=Linux zbr "" ansible --extra-vars ansible_become_exe=/usr/local/bin/sudo > /dev/null
check "sudo-rs: the become_exe of the arguments is kept" "--ask-become-pass|--inventory|hosts|--extra-vars|ansible_become_exe=/usr/local/bin/sudo|${AGENT}/devices.yml" "$(calls ansible-playbook)"
reset_calls
AGENT_DIR="$AGENT" OS=Darwin zbr "" ansible > /dev/null
check "sudo-rs: macOS is not changed" "--ask-become-pass|--inventory|hosts|${AGENT}/mac-devices.yml" "$(calls ansible-playbook)"
rm -f "${WORK}/bin/sudo.ws"
if ! command -v sudo.ws > /dev/null 2>&1; then
  reset_calls
  output="$(AGENT_DIR="$AGENT" OS=Linux zbr "" ansible)"
  check "sudo-rs without sudo.ws: the playbook is run as is" "--ask-become-pass|--inventory|hosts|${AGENT}/devices.yml" "$(calls ansible-playbook)"
  check_contains "sudo-rs without sudo.ws: the original sudo is asked" "install the original sudo (sudo apt install sudo)" "$output"
else
  skip_check "sudo-rs without sudo.ws" "sudo.ws of the system"
fi
mv "${WORK}/sudo" "${WORK}/bin/sudo"
output="$(ANSIBLE_EXIT=2 AGENT_DIR="$AGENT" zbr "" ansible)"
check "failed playbook fails" "1" "$?"
check_contains "failed playbook is reported" "Ansible playbook execution failed!" "$output"

section "rosetta"
# the stub bodies are expanded when the stubs run: FAKE_ARM64=1 an Apple Silicon Mac, FAKE_ROSETTA=1 Rosetta 2 installed
# shellcheck disable=SC2016
stub sysctl '[[ "$*" == "-n hw.optional.arm64" ]] && echo "${FAKE_ARM64:-0}"'
# shellcheck disable=SC2016
stub arch '[[ "$1" == "-x86_64" && "$FAKE_ROSETTA" == "1" ]]'
# rosetta <arm64> <rosetta> <zebrunner.sh args...>: the output of zebrunner.sh on a Mac with these
rosetta() {
  local arm64="$1" installed="$2"
  shift 2
  printf '' | env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    FAKE_UNAME=Darwin FAKE_ARM64="$arm64" FAKE_ROSETTA="$installed" ZEBRUNNER_MCLOUD_AGENT_DIR="$AGENT" \
    /bin/bash "${AGENT}/zebrunner.sh" "$@" 2>&1
}
settings_dir="${WORK}/home/Library/Group Containers/group.com.docker"
mkdir -p "$settings_dir"
output="$(rosetta 1 0 setup)"
check_contains "setup: missing Rosetta 2 is reported" "Rosetta 2 is not installed" "$output"
check_contains "setup: the install command is advised" "softwareupdate --install-rosetta --agree-to-license" "$output"
check_contains "status: missing Rosetta 2" "not installed: softwareupdate --install-rosetta --agree-to-license" "$(rosetta 1 0 status)"
output="$(rosetta 1 1 setup)"
check_contains "setup: Rosetta 2 used by Docker Desktop is reported" "Rosetta 2 is installed: Docker Desktop runs" "$output"
check_contains "status: Rosetta 2 used by Docker Desktop" "installed, used by Docker Desktop" "$(rosetta 1 1 status)"
echo '{"UseVirtualizationFrameworkRosetta": false}' > "${settings_dir}/settings-store.json"
check_contains "setup: Rosetta 2 not used by Docker Desktop is reported" "Docker Desktop runs the linux/amd64 images under" "$(rosetta 1 1 setup)"
check_contains "status: Rosetta 2 not used by Docker Desktop" "installed, not used by Docker Desktop" "$(rosetta 1 1 status)"
rm -f "${settings_dir}/settings-store.json"
echo '{"useVirtualizationFrameworkRosetta": false}' > "${settings_dir}/settings.json"
check_contains "the settings of an earlier Docker Desktop" "installed, not used by Docker Desktop" "$(rosetta 1 1 status)"
rm -rf "${WORK}/home/Library"
check_not_contains "setup of an Intel Mac says nothing about Rosetta 2" "Rosetta" "$(rosetta 0 0 setup)"
check_contains "status of an Intel Mac" "not needed (Intel Mac)" "$(rosetta 0 0 status)"
check_not_contains "setup of Linux says nothing about Rosetta 2" "Rosetta" "$(OS=Linux zbr "" setup)"
check_not_contains "status of Linux says nothing about Rosetta 2" "Rosetta" "$(AGENT_DIR="$AGENT" OS=Linux zbr "" status)"
rm -f "${WORK}/bin/sysctl" "${WORK}/bin/arch"

section "status"
output="$(AGENT_DIR="$AGENT" OS=Linux zbr "" status)"
check_contains "ansible version" "ansible-playbook [core 2.21.5]" "$output"
check_contains "zebrunner-farm location" "${WORK}/bin/zebrunner-farm" "$output"
check_contains "Linux settings file" "${AGENT}/roles/devices/vars/main.yml" "$output"
# a stub that behaves as a missing command, removing the stub would expose an ansible-playbook of the system
cp "${WORK}/bin/ansible-playbook" "${WORK}/ansible-playbook"
stub ansible-playbook 'echo "ansible-playbook: command not found" >&2; exit 127'
check_contains "missing ansible-playbook is reported" "'ansible-playbook' not found" "$(AGENT_DIR="$AGENT" zbr "" status)"
mv "${WORK}/ansible-playbook" "${WORK}/bin/ansible-playbook"
mkdir -p "${WORK}/home/Library/LaunchAgents"
touch "${WORK}/home/Library/LaunchAgents/ZebrunnerDevicesListener.plist" "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist"
output="$(AGENT_DIR="$AGENT" OS=Darwin zbr "" status)"
check_contains "macOS deployed launch agents" "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" "$output"
check_contains "macOS settings file" "${AGENT}/roles/mac-devices/vars/main.yml" "$output"

section "backup and restore"
zbr "n\n" backup > /dev/null
check "declined backup creates nothing" "0" "$(find "${AGENT}/backup" -name 'bak_*' | wc -l | tr -d ' ')"
OS=Linux zbr "y\n" backup > /dev/null
backup="$(cd "${AGENT}/backup" && ls -d bak_* 2> /dev/null)"
check "backup dir is created" "1" "$(echo "$backup" | grep -c '^bak_')"
for file in defaults/main.yml download/main.yml tasks/udev.yml templates/zebrunner-farm vars/main.yml; do
  check "backup has ${file}" "yes" "$([[ -f "${AGENT}/backup/${backup}/${file}" ]] && echo yes)"
done
cp "${AGENT}/defaults/main.yml" "${WORK}/defaults.yml"
echo "CHANGED: true" >> "${AGENT}/defaults/main.yml"
output="$(OS=Linux zbr "y\n${backup}\n" restore)"
check_contains "restore prints its header" "Restore MCloud Agent" "$output"
check "restore brings the settings back" "same" "$(cmp -s "${AGENT}/defaults/main.yml" "${WORK}/defaults.yml" && echo same)"
check_contains "restore asks again for an unknown backup" "does not exist" "$(OS=Linux zbr "y\nbak_none\n${backup}\n" restore)"

section "shutdown"
for profile in .bashrc .zshrc; do
  echo "export ZEBRUNNER_MCLOUD_AGENT_DIR=${AGENT}" > "${WORK}/home/${profile}"
done
output="$(OS=Darwin zbr "n\n" shutdown)"
check_contains "declined shutdown is cancelled" "Shutdown cancelled" "$output"
check "declined shutdown keeps the variable" "1" "$(exports .zshrc)"
check "declined shutdown keeps the launch agents" "yes" "$([[ -f "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" ]] && echo yes)"

reset_calls
OS=Darwin zbr "y\n" shutdown > /dev/null
check "macOS: launch agents are unloaded" "2" "$(calls launchctl | grep -c '^bootout|')"
check "macOS: launch agents are removed" "0" "$(find "${WORK}/home/Library/LaunchAgents" -name '*.plist' | wc -l | tr -d ' ')"
check "macOS: the variable is removed from the profiles" "0 0" "$(exports .bashrc) $(exports .zshrc)"
check "macOS: containers are removed" "down" "$(calls zebrunner-farm)"
check "macOS: appium storage is removed" "volume|rm|appium-storage-volume" "$(calls docker | grep '^volume|rm|')"
check "macOS: deployed files are removed" "rm|-vf|/usr/local/bin/zebrunner-device-listener
rm|-vf|/usr/local/bin/usbmuxd_watch
rm|-vf|/etc/newsyslog.d/zebrunner-mcloud.conf
rm|-vf|/usr/local/bin/zebrunner-farm
rm|-vf|/usr/local/bin/mcloud-devices.txt" "$(calls sudo | grep '^rm|')"
check "macOS: settings are removed" "no" "$([[ -f "${AGENT}/roles/mac-devices/vars/main.yml" ]] && echo yes || echo no)"

reset_calls
OS=Linux zbr "y\n" shutdown > /dev/null
check "Linux: no launch agents" "" "$(calls launchctl)"
check "Linux: udev rules and deployed files are removed" "rm|-vf|/etc/udev/rules.d/90_mcloud.rules
rm|-vf|/etc/systemd/system/mcloud-device-restart@.service
rm|-vf|/etc/systemd/system/mcloud-device-down@.service
rm|-vf|/usr/local/bin/zebrunner-farm
rm|-vf|/usr/local/bin/mcloud-devices.txt" "$(calls sudo | grep '^rm|')"
check "Linux: settings are removed" "no" "$([[ -f "${AGENT}/roles/devices/vars/main.yml" ]] && echo yes || echo no)"

finish
