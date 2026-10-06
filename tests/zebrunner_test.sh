#!/bin/bash
# zebrunner.sh commands on a copy of the repo with a temporary HOME. sudo, launchctl, docker,
# ansible-playbook, zebrunner-farm and uname (to test both Linux and macOS branches) are stubs,
# sudo only records its calls.
source "$(dirname "$0")/lib.sh"

AGENT="${WORK}/repo"
mkdir -p "$AGENT" "${WORK}/home"
(cd "$REPO" && tar --exclude=.git -cf - .) | (cd "$AGENT" && tar -xf -)
rm -rf "${AGENT}/backup/"bak_* "${AGENT}/roles/devices/vars/main.yml" "${AGENT}/roles/mac-devices/vars/main.yml"

stub uname 'echo "$FAKE_UNAME"'
stub ansible-playbook '(IFS="|"; echo "ansible-playbook|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "--version" ]] && echo "ansible-playbook [core 2.21.5]"
exit "${ANSIBLE_EXIT:-0}"'
stub sudo '(IFS="|"; echo "sudo|$*") >> "${STUB_DIR}/calls.log"'
stub launchctl '(IFS="|"; echo "launchctl|$*") >> "${STUB_DIR}/calls.log"'
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

echo "# help"
output="$(zbr "")"
check_contains "help shows the usage" "Usage: ./zebrunner.sh [option]" "$output"
for command in setup ansible status backup restore shutdown version; do
  check_contains "help lists ${command}" "         ${command} " "$output"
done

echo "# setup"
echo "export ZEBRUNNER_MCLOUD_AGENT_DIR=/old/path" > "${WORK}/home/.bashrc"
output="$(OS=Linux zbr "" setup)"
check "the agent dir replaces an old value in .bashrc" "1" "$(exports .bashrc)"
check "the old value is gone" "0" "$(grep -c '/old/path' "${WORK}/home/.bashrc")"
check "the agent dir is added to .bash_profile" "1" "$(exports .bash_profile)"
check "Linux settings are created from the example" "same" \
  "$(cmp -s "${AGENT}/roles/devices/vars/main.yml" "${AGENT}/roles/devices/vars/main.yml.original" && echo same)"
check_contains "the reload of the shell is suggested" "To apply the changes" "$output"
output="$(OS=Linux zbr "" setup)"
check "a second setup does not duplicate the variable" "1" "$(exports .bashrc)"
check_contains "a second setup backs up existing settings" "making a backup" "$output"
check "the backup of the settings exists" "yes" "$([[ -f "${AGENT}/roles/devices/vars/main.yml.bak" ]] && echo yes)"
OS=Darwin zbr "" setup > /dev/null
check "macOS settings are created from the example" "same" \
  "$(cmp -s "${AGENT}/roles/mac-devices/vars/main.yml" "${AGENT}/roles/mac-devices/vars/main.yml.original" && echo same)"
check_contains "unknown OS is rejected" "Unknown OS" "$(OS=FreeBSD zbr "" setup)"

echo "# version"
check_contains "versions from the agent dir" "DEVICE_VERSION:" "$(AGENT_DIR="$AGENT" zbr "" version)"
output="$(zbr "" version)"
check_contains "missing agent dir variable is reported" "is not set" "$output"
check_contains "versions from the current dir without the variable" "APPIUM_VERSION:" "$output"

echo "# ansible"
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
AGENT_DIR="$AGENT" OS=Linux zbr "" ansible --user=bob --extra-vars "ansible_sudo_pass=a b" > /dev/null
check "custom arguments keep their words" "--ask-become-pass|--inventory|hosts|--user=bob|--extra-vars|ansible_sudo_pass=a b|${AGENT}/devices.yml" "$(calls ansible-playbook)"
output="$(ANSIBLE_EXIT=2 AGENT_DIR="$AGENT" zbr "" ansible)"
check "failed playbook fails" "1" "$?"
check_contains "failed playbook is reported" "Ansible playbook execution failed!" "$output"

echo "# status"
output="$(AGENT_DIR="$AGENT" OS=Linux zbr "" status)"
check_contains "ansible version" "ansible-playbook [core 2.21.5]" "$output"
check_contains "zebrunner-farm location" "${WORK}/bin/zebrunner-farm" "$output"
check_contains "Linux settings file" "${AGENT}/roles/devices/vars/main.yml" "$output"
mv "${WORK}/bin/ansible-playbook" "${WORK}/ansible-playbook"
check_contains "missing ansible-playbook is reported" "'ansible-playbook' not found" "$(AGENT_DIR="$AGENT" zbr "" status)"
mv "${WORK}/ansible-playbook" "${WORK}/bin/ansible-playbook"
mkdir -p "${WORK}/home/Library/LaunchAgents"
touch "${WORK}/home/Library/LaunchAgents/ZebrunnerDevicesListener.plist" "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist"
output="$(AGENT_DIR="$AGENT" OS=Darwin zbr "" status)"
check_contains "macOS deployed launch agents" "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" "$output"
check_contains "macOS settings file" "${AGENT}/roles/mac-devices/vars/main.yml" "$output"

echo "# backup and restore"
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

echo "# shutdown"
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
rm|-vf|/usr/local/bin/zebrunner-farm
rm|-vf|/usr/local/bin/mcloud-devices.txt" "$(calls sudo | grep '^rm|')"
check "macOS: settings are removed" "no" "$([[ -f "${AGENT}/roles/mac-devices/vars/main.yml" ]] && echo yes || echo no)"

reset_calls
OS=Linux zbr "y\n" shutdown > /dev/null
check "Linux: no launch agents" "" "$(calls launchctl)"
check "Linux: udev rules and deployed files are removed" "rm|-vf|/etc/udev/rules.d/90_mcloud.rules
rm|-vf|/usr/local/bin/zebrunner-farm
rm|-vf|/usr/local/bin/mcloud-devices.txt" "$(calls sudo | grep '^rm|')"
check "Linux: settings are removed" "no" "$([[ -f "${AGENT}/roles/devices/vars/main.yml" ]] && echo yes || echo no)"

finish
