#!/bin/bash
# zebrunner.sh commands on a copy of the repo with a temporary HOME. sudo, launchctl, docker,
# ansible-playbook, zebrunner-farm and uname (to test both Linux and macOS branches) are stubs,
# sudo only records its calls.
source "$(dirname "$0")/lib.sh"

AGENT="${WORK}/repo"
# a python with PyYAML for patch/settings.py: zbr runs zebrunner.sh without the PATH of the tests
YAML_PYTHON="$(command -v "$(source "${REPO}/patch/utility.sh" && yaml_python)")"
[[ -n "$YAML_PYTHON" ]] || {
  echo "no python3 with PyYAML (make test installs it into .venv)"
  exit 1
}
mkdir -p "$AGENT" "${WORK}/home"
(cd "$REPO" && tar --exclude=.git -cf - .) | (cd "$AGENT" && tar -xf -)
rm -rf "${AGENT}/backup/"bak_* "${AGENT}/config/"*.yml "${AGENT}/config/"*.yml.* "${AGENT}/roles/devices/vars" "${AGENT}/roles/mac-devices/vars"
mkdir -p "${AGENT}/config"
cp "${REPO}/config/"*.original "${AGENT}/config/"

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
# volume ls: the volumes of the agent and of other projects, FAKE_VOLUMES overrides them
[[ "$1 $2" == "volume ls" ]] && printf "%s\n" ${FAKE_VOLUMES-appium-storage-volume device-iPhone-0001-lockdown device-Old-0002 devimages_cache mcloud-key-volume mcloud_rethinkdb other-volume}
exit 0'
record_stub zebrunner-farm

# zbr <stdin text> <zebrunner.sh arguments...>: runs zebrunner.sh of the repo copy (unwrap: the messages on one line)
# without the user's
# environment; $OS sets uname, $AGENT_DIR the ZEBRUNNER_MCLOUD_AGENT_DIR variable of the shell when not empty (it is
# not used: zebrunner.sh knows its folder)
zbr() {
  local input="$1"
  shift
  printf '%b' "$input" | env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb \
    STUB_DIR="$WORK" ${FAKE_VOLUMES+FAKE_VOLUMES="$FAKE_VOLUMES"} FAKE_UNAME="${OS:-Linux}" ANSIBLE_EXIT="${ANSIBLE_EXIT:-0}" ZEBRUNNER_PYTHON="$YAML_PYTHON" \
    ${AGENT_DIR:+ZEBRUNNER_MCLOUD_AGENT_DIR=$AGENT_DIR} /bin/bash "${AGENT}/zebrunner.sh" "$@" 2>&1 | unwrap
  return "${PIPESTATUS[1]}"
}

# unwrapped <text>: the text as one line, without the bars of the callouts and the indents of the wrapped lines
unwrapped() {
  tr '\n' ' ' <<< "$1" | sed -E 's/ +\| / /g; s/ +/ /g'
}

# exports <profile>: the number of the lines of the variable of the earlier versions in the shell profile
exports() {
  grep -c "^export ZEBRUNNER_MCLOUD_AGENT_DIR=" "${WORK}/home/$1" 2> /dev/null || true
}

section "help"
output="$(zbr "")"
check_contains "help shows the banner" "[ ZEBRUNNER ] MCloud Agent" "$output"
check_contains "help shows the usage" "> ./zebrunner.sh <command> [options]" "$output"
for group in "SET UP" OPERATE MAINTAIN; do
  check_contains "help groups the commands: ${group}" "[ ${group} ]" "$output"
done
for command in setup ansible status backup restore shutdown version doctor join migrate autostart mdm; do
  check_contains "help lists ${command}" $'\n'"   ${command} " "$output"
done
check_contains "help tells where to get help" "For more help join telegram channel: https://t.me/zebrunner" "$output"
check "help is plain text without a terminal" "" "$(grep -c $'\033' <<< "$output" | grep -v '^0$')"
check "help --help is the help" "$output" "$(zbr "" --help)"
check "help -h is the help" "$output" "$(zbr "" -h)"
check "help help is the help" "$output" "$(zbr "" help)"
check "help with an empty command is the help" "$output" "$(zbr "" "")"
zbr "" help > /dev/null
check "the help exits with 0" "0" "$?"
check_contains "help groups the help commands" "[ HELP ]" "$output"
for command in help completion; do
  check_contains "help lists ${command}" $'\n'"   ${command} " "$output"
done

section "unknown commands"
reset_calls
output="$(zbr "" stauts)"
check "an unknown command exits with 2" "2" "$?"
check_contains "an unknown command is an error" $'  | ERROR\n  | Unknown command \'stauts\'.' "$output"
check_contains "the closest command is suggested" "Did you mean: status?" "$output"
check_contains "the usage follows" "> ./zebrunner.sh <command> [options]" "$output"
check_not_contains "an unknown command shows no help" "[ SET UP ]" "$output"
check "an unknown command runs nothing" "" "$(cat "${WORK}/calls.log")"
check "the error goes to stderr" "" "$(env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin" TERM=dumb /bin/bash "${AGENT}/zebrunner.sh" stauts 2> /dev/null)"
check_contains "a prefix suggests its command" "Did you mean: autostart?" "$(zbr "" auto)"
check_contains "a command in upper case suggests it" "Did you mean: doctor?" "$(zbr "" DOCTOR)"
check_contains "a typo suggests its command" "Did you mean: restore?" "$(zbr "" bestore)"
check_not_contains "a word 3 edits away suggests nothing" "Did you mean" "$(zbr "" backore)"
output="$(zbr "" xyzzy)"
check "a word like no command exits with 2 too" "2" "$?"
check_not_contains "a word like no command suggests nothing" "Did you mean" "$output"
check_not_contains "a short word suggests nothing" "Did you mean" "$(zbr "" x)"
zbr "" --version > /dev/null
check "an unknown option is an unknown command" "2" "$?"
output="$(zbr "" help stauts)"
check "the help of an unknown command exits with 2" "2" "$?"
check_contains "the help of an unknown command suggests one" "Did you mean: status?" "$output"

section "the help of a command"
reset_calls
cp -R "${AGENT}/config" "${WORK}/config.before-help"
for command in setup join migrate ansible status doctor autostart mdm version backup restore shutdown help completion; do
  output="$(zbr "" help "$command")"
  check "help ${command} exits with 0" "0" "$?"
  check_contains "help ${command} shows its usage" "> ./zebrunner.sh ${command}" "$output"
  check_contains "help ${command} tells its section of README.md" "README.md#" "$output"
  check "${command} --help is its help" "$output" "$(zbr "" "$command" --help)"
  check "${command} -h is its help" "$output" "$(zbr "" "$command" -h)"
done
check "the help of a command runs nothing" "" "$(cat "${WORK}/calls.log")"
check "the help of a command changes no setting" "" "$(diff -r "${WORK}/config.before-help" "${AGENT}/config")"
rm -rf "${WORK}/config.before-help"
check_contains "the help of mdm tells its actions" "   supervise " "$(zbr "" help mdm)"
check_contains "the help of mdm tells its options" "   --uninstall " "$(zbr "" help mdm)"
check_contains "the help of autostart tells its actions" "   enable " "$(zbr "" help autostart)"
check_contains "the help of migrate tells its arguments" "   files... " "$(zbr "" help migrate)"
check_contains "the help of ansible tells where the options of ansible-playbook are" "ansible-playbook --help" "$(unwrapped "$(zbr "" help ansible)")"
reset_calls
output="$(zbr "" ansible devices -vvv --help)"
check "ansible with --help among its arguments shows the help" "$(zbr "" help ansible)" "$output"
check "ansible with --help deploys nothing" "" "$(calls ansible-playbook)$(calls zebrunner-farm)"
check "mdm with --help among its arguments shows the help" "$(zbr "" help mdm)" "$(zbr "" mdm enroll Galaxy --help)"
check "join with --help reads no join string" "$(zbr "" help join)" "$(zbr "mcloud-join://x\n" join --help)"
check "shutdown with --help asks nothing" "$(zbr "" help shutdown)" "$(zbr "y\n" shutdown -h)"

section "setup"
printf 'alias ll="ls -l"\nexport ZEBRUNNER_MCLOUD_AGENT_DIR=/old/path\n' > "${WORK}/home/.bashrc"
output="$(OS=Linux zbr "" setup)"
check "the variable of an earlier version is removed from .bashrc" "0" "$(exports .bashrc)"
check "the other lines of .bashrc are kept" 'alias ll="ls -l"' "$(cat "${WORK}/home/.bashrc")"
check_contains "the removal is reported" "Removing the variable ZEBRUNNER_MCLOUD_AGENT_DIR of an earlier version from ${WORK}/home/.bashrc" "$output"
check "no profile is created" "no" "$([[ -f "${WORK}/home/.bash_profile" ]] && echo yes || echo no)"
check "the settings are created from the example" "same" \
  "$(cmp -s "${AGENT}/config/settings.yml" "${AGENT}/config/settings.yml.original" && echo same)"
check "the settings are private" "600" "$(stat -c '%a' "${AGENT}/config/settings.yml" 2> /dev/null || stat -f '%Lp' "${AGENT}/config/settings.yml")"
check "Linux devices are created from the example" "same" \
  "$(cmp -s "${AGENT}/config/devices.yml" "${AGENT}/config/devices.yml.original" && echo same)"
check_not_contains "no settings of an earlier version" "overrides 'config/'" "$output"
check_not_contains "no reload of the shell" "To apply the changes" "$output"
check_contains "the invite is the next step" "1. The administrator of MCloud invites this host on its server: ./zebrunner.sh node-invite" "$(unwrapped "$output")"
check_contains "the join is the next step" "2. Enroll this host: ./zebrunner.sh join and paste the join string" "$output"
check_contains "the devices are a step" "3. Declare the devices in 'devices:' of 'config/devices.yml'" "$output"
check_contains "the doctor is a step" "4. Check the settings, the enrollment and the network to MCloud: ./zebrunner.sh doctor" "$(unwrapped "$output")"
check_contains "the deploy is a step" "5. Deploy the agent: ./zebrunner.sh ansible" "$output"
check_not_contains "no manual settings" "variables.env" "$output"
output="$(OS=Linux zbr "" setup)"
check_contains "a second setup backs up existing settings" "making a backup" "$output"
check "the backup of the settings exists" "yes" "$([[ -f "${AGENT}/config/settings.yml.bak" ]] && echo yes)"
check "the backup of the devices exists" "yes" "$([[ -f "${AGENT}/config/devices.yml.bak" ]] && echo yes)"
mv "${AGENT}/config/devices.yml" "${WORK}/devices.yml"
mkdir -p "${AGENT}/roles/mac-devices/vars"
touch "${AGENT}/roles/mac-devices/vars/main.yml"
output="$(OS=Darwin zbr "" setup)"
check "macOS devices are created from the example" "same" \
  "$(cmp -s "${AGENT}/config/devices.yml" "${AGENT}/config/mac-devices.yml.original" && echo same)"
check_contains "the settings of an earlier version are reported" \
  "'roles/mac-devices/vars/main.yml' of an earlier version overrides 'config/': ./zebrunner.sh migrate moves its settings to 'config/settings.yml'" "$(unwrapped "$output")"
rm -rf "${AGENT}/roles/mac-devices/vars" "${AGENT}/config/"*.bak
mv "${WORK}/devices.yml" "${AGENT}/config/devices.yml"
check_contains "unknown OS is rejected" "Unknown OS" "$(OS=FreeBSD zbr "" setup)"

section "completion"
# candidates <index> <words...>: the candidates of zebrunner.sh __complete separated by spaces, stdout only; $FARM_ENV
# is ZEBRUNNER_FARM_ENV, the settings of the deployed zebrunner-farm
candidates() {
  env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    ZEBRUNNER_FARM_ENV="${FARM_ENV:-${WORK}/no-farm.env}" /bin/bash "${AGENT}/zebrunner.sh" __complete "$@" 2> /dev/null |
    paste -s -d ' ' -
}
# the tools of the commands fail when the completion runs them
mkdir -p "${WORK}/tools"
for tool in docker ansible-playbook sudo curl launchctl systemctl zebrunner-farm python3; do
  [[ -f "${WORK}/bin/${tool}" ]] && mv "${WORK}/bin/${tool}" "${WORK}/tools/${tool}"
  stub "$tool" "(IFS='|'; echo \"${tool}|\$*\") >> '${WORK}/calls.log'; exit 1"
done
reset_calls
touch "${WORK}/before-completion"
SECONDS=0
check "the commands" "setup join migrate ansible status doctor autostart mdm version backup restore shutdown help completion --help -h" "$(candidates 1 "")"
check "the commands of a typed prefix too, the shell keeps the ones of the prefix" "$(candidates 1 "")" "$(candidates 1 st)"
check "the actions of mdm" "status enroll release supervise" "$(candidates 2 mdm "")"
check "the devices of mdm: the groups and the devices of config/devices.yml" \
  "ios android usb wireless android-sim ios-sim proxy R28M1384YQY Samsung_Galaxy_S10 d6afc6b3a65584ca0813eb8957c6479b9b6ebb11 iPhone_8_Plus" \
  "$(candidates 3 mdm status "")"
check "the devices after -x" "$(candidates 3 mdm status "")" "$(candidates 5 mdm enroll Galaxy -x "")"
check "the options of mdm release" "--help -x --exclude -y --yes -q --quiet --uninstall" "$(candidates 3 mdm release --)"
check "the options of mdm supervise" "--help -x --exclude -y --yes -q --quiet --force" "$(candidates 4 mdm supervise iPhone -)"
printf '%s\n' "# The devices of zebrunner-farm: a comment with id=comment|name=comment" \
  "id=192.168.1.50:5555|os=android|name=WiFi_Phone|location=|connection=wireless" \
  "id=00008020-0005308201DA002E|os=ios|name=iPhone_XR|location=loc|connection=usb" > "${WORK}/devices.txt"
printf "FARM_OS=linux\nMCLOUD_DEVICES='%s'\nMCLOUD_NODE_TOKEN=secret\n" "${WORK}/devices.txt" > "${WORK}/farm.env"
check "the devices of mdm: the deployed ones, the ones mdm selects from" \
  "ios android usb wireless android-sim ios-sim proxy 00008020-0005308201DA002E 192.168.1.50:5555 WiFi_Phone iPhone_XR" \
  "$(FARM_ENV="${WORK}/farm.env" candidates 3 mdm status "")"
rm -f "${WORK}/devices.txt" "${WORK}/farm.env"
cp "${AGENT}/config/devices.yml" "${WORK}/devices.yml"
printf '%s\n' '  - {id: "emulator-5554", os: android, name: My Emulator, appium_port: 7501}  # the emulator' >> "${AGENT}/config/devices.yml"
output="$(candidates 3 mdm status "")"
check_contains "the udid of the flow style of YAML" " emulator-5554 " "$output"
check_contains "the name of the flow style of YAML, its spaces are _ as in the deployed list" " My_Emulator " "$output"
mv "${WORK}/devices.yml" "${AGENT}/config/devices.yml"
touch "${WORK}/before-completion"
check "ansible: devices" "devices" "$(candidates 2 ansible "")"
check_contains "ansible: the options of ansible-playbook" "--help --check --diff --tags" "$(candidates 2 ansible --)"
check "autostart: its actions" "status enable disable" "$(candidates 2 autostart "")"
check "help: the commands" "setup join migrate ansible status doctor autostart mdm version backup restore shutdown help completion" "$(candidates 2 help "")"
check "completion: the shells" "bash zsh" "$(candidates 2 completion "")"
check "migrate: nothing, the shell offers the files" "" "$(candidates 2 migrate "")"
check "a command without arguments: its help" "--help" "$(candidates 2 status -)"
check "a command without arguments: nothing else" "" "$(candidates 2 doctor "")"
check "an invalid index: nothing" "" "$(candidates x mdm)"
check "no index: nothing" "" "$(candidates)"
env -i PATH="${WORK}/bin:/usr/bin:/bin" /bin/bash "${AGENT}/zebrunner.sh" __complete 2 mdm "" > /dev/null 2>&1
check "the completion exits with 0" "0" "$?"
check "the completion answers at once" "yes" "$([[ "$SECONDS" -le 5 ]] && echo yes)"
check "the completion runs no tool: no docker, no ansible, no network" "" "$(cat "${WORK}/calls.log")"
check "the completion writes no file" "" "$(find "$AGENT" "${WORK}/home" -newer "${WORK}/before-completion" -type f)"
check "the completion prints nothing on stderr" "" \
  "$(env -i PATH="${WORK}/bin:/usr/bin:/bin" /bin/bash "${AGENT}/zebrunner.sh" __complete 3 mdm status "" 2>&1 > /dev/null)"
rm -f "${WORK}/before-completion"
for tool in docker ansible-playbook sudo curl launchctl systemctl zebrunner-farm python3; do
  rm -f "${WORK}/bin/${tool}"
  [[ -f "${WORK}/tools/${tool}" ]] && mv "${WORK}/tools/${tool}" "${WORK}/bin/${tool}"
done

check "completion bash prints patch/completion.sh" "same" \
  "$(zbr "" completion bash > "${WORK}/completion.sh" && cmp -s "${WORK}/completion.sh" "${AGENT}/patch/completion.sh" && echo same)"
check "completion zsh prints it too" "same" \
  "$(zbr "" completion zsh > "${WORK}/completion.sh" && cmp -s "${WORK}/completion.sh" "${AGENT}/patch/completion.sh" && echo same)"
output="$(zbr "" completion fish)"
check "completion of another shell exits with 2" "2" "$?"
check_contains "completion of another shell shows its usage" "> ./zebrunner.sh completion bash|zsh" "$output"
zbr "" completion > /dev/null
check "completion without a shell exits with 2" "2" "$?"
# complete_line <command line>: the completion of bash end to end, the function of complete for the command line of a
# person
complete_line() {
  # the code runs in a child bash
  # shellcheck disable=SC2016
  env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin" TERM=dumb /bin/bash -c '
    source "$1"
    COMP_LINE="$2"
    COMP_POINT=${#COMP_LINE}
    read -r -a COMP_WORDS <<< "$COMP_LINE"
    [[ "$COMP_LINE" == *" " ]] && COMP_WORDS+=("")
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    _zebrunner_complete
    printf "%s\n" "${COMPREPLY[@]}"' _ "${WORK}/completion.sh" "$1" | paste -s -d ' ' -
}
check "bash completes a command" "autostart" "$(complete_line "${AGENT}/zebrunner.sh au")"
check "bash completes an action of mdm" "release" "$(complete_line "${AGENT}/zebrunner.sh mdm rel")"
check "bash completes a device" "iPhone_8_Plus" "$(complete_line "${AGENT}/zebrunner.sh mdm status iP")"
chmod g+w "${AGENT}/zebrunner.sh"
check "bash runs no zebrunner.sh that others can write" "" "$(complete_line "${AGENT}/zebrunner.sh au")"
chmod g-w "${AGENT}/zebrunner.sh"
rm -f "${WORK}/completion.sh"

section "version"
check_contains "versions of the folder of zebrunner.sh" "DEVICE_VERSION:" "$(zbr "" version)"
check "stdout has the NAME: value lines of versions.yml only" "$(grep -i version "${AGENT}/versions.yml" | grep -v '^ *#')" \
  "$(env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin" TERM=dumb /bin/bash "${AGENT}/zebrunner.sh" version 2> /dev/null)"
check_contains "the header goes to stderr" "[ VERSIONS ]" \
  "$(env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin" TERM=dumb /bin/bash "${AGENT}/zebrunner.sh" version 2>&1 > /dev/null)"
output="$(cd / && AGENT_DIR=/old/path zbr "" version)"
check_contains "versions of the folder of zebrunner.sh from any folder, whatever the variable" "APPIUM_VERSION:" "$output"
check_not_contains "no variable is needed" "is not set" "$output"

section "ansible"
reset_calls
zbr "" ansible > /dev/null
check_contains "ansible runs the playbook of the folder of zebrunner.sh without the variable" "|${AGENT}/agent.yml" "$(calls ansible-playbook)"
reset_calls
OS=Linux zbr "" ansible > /dev/null
check "Linux playbook" "--ask-become-pass|--inventory|hosts|${AGENT}/agent.yml" "$(calls ansible-playbook)"
reset_calls
OS=Darwin zbr "" ansible > /dev/null
check "macOS playbook" "--ask-become-pass|--inventory|hosts|${AGENT}/agent.yml" "$(calls ansible-playbook)"
reset_calls
OS=Darwin zbr "" ansible devices > /dev/null
check "devices registration only" "--ask-become-pass|--inventory|hosts|${AGENT}/agent.yml|--tag|registerDevices" "$(calls ansible-playbook)"
reset_calls
OS=Linux zbr "" ansible --user=bob --extra-vars "app_name=a b" > /dev/null
check "custom arguments keep their words" "--ask-become-pass|--inventory|hosts|--user=bob|--extra-vars|app_name=a b|${AGENT}/agent.yml" "$(calls ansible-playbook)"
reset_calls
OS=Linux zbr "" ansible devices -vvv --extra-vars "app_name=a b" > /dev/null
check "the registration of the devices keeps the custom arguments" "--ask-become-pass|--inventory|hosts|-vvv|--extra-vars|app_name=a b|${AGENT}/agent.yml|--tag|registerDevices" "$(calls ansible-playbook)"
output="$(OS=Linux zbr "" ansible)"
check_contains "the deploy suggests zebrunner-farm start" "Run 'zebrunner-farm start'" "$output"
check_not_contains "the registration of the devices does not" "zebrunner-farm start" "$(OS=Linux zbr "" ansible devices)"
# sudo-rs of Ubuntu 25.10+: ansible does not recognize its password prompt, sudo.ws is the original sudo
cp "${WORK}/bin/sudo" "${WORK}/sudo"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub sudo '(IFS="|"; echo "sudo|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "--version" ]] && echo "sudo-rs 0.2.13"
exit 0'
record_stub sudo.ws
reset_calls
output="$(OS=Linux zbr "" ansible)"
check "sudo-rs: ansible becomes root with sudo.ws" "--ask-become-pass|--inventory|hosts|--extra-vars|ansible_become_exe=sudo.ws|${AGENT}/agent.yml" "$(calls ansible-playbook)"
check_contains "sudo-rs: sudo.ws is reported" "sudo is sudo-rs: ansible becomes root with sudo.ws" "$output"
reset_calls
OS=Linux zbr "" ansible --extra-vars ansible_become_exe=/usr/local/bin/sudo > /dev/null
check "sudo-rs: the become_exe of the arguments is kept" "--ask-become-pass|--inventory|hosts|--extra-vars|ansible_become_exe=/usr/local/bin/sudo|${AGENT}/agent.yml" "$(calls ansible-playbook)"
reset_calls
OS=Darwin zbr "" ansible > /dev/null
check "sudo-rs: macOS is not changed" "--ask-become-pass|--inventory|hosts|${AGENT}/agent.yml" "$(calls ansible-playbook)"
rm -f "${WORK}/bin/sudo.ws"
if ! command -v sudo.ws > /dev/null 2>&1; then
  reset_calls
  output="$(OS=Linux zbr "" ansible)"
  check "sudo-rs without sudo.ws: the playbook is run as is" "--ask-become-pass|--inventory|hosts|${AGENT}/agent.yml" "$(calls ansible-playbook)"
  check_contains "sudo-rs without sudo.ws: the original sudo is asked" "install the original sudo (sudo apt install sudo)" "$output"
else
  skip_check "sudo-rs without sudo.ws" "sudo.ws of the system"
fi
mv "${WORK}/sudo" "${WORK}/bin/sudo"
# the running containers of the devices keep the old settings: the deploy offers to remove them first
cp "${WORK}/bin/docker" "${WORK}/docker"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "ps" ]] && printf "%s\n" device-Galaxy-R28-connector device-Galaxy-R28-stf device-Pixel-45-appium node_exporter
exit 0'
reset_calls
output="$(OS=Linux zbr "\n" ansible)"
check_contains "running containers are reported" "3 containers of the devices are running" "$output"
check_contains "the devices of the running containers are listed" "device-Galaxy-R28" "$output"
check "the default answer removes them with zebrunner-farm" "down" "$(calls zebrunner-farm)"
check_contains "then the playbook runs" "${AGENT}/agent.yml" "$(calls ansible-playbook)"
reset_calls
output="$(OS=Linux zbr "n\n" ansible)"
check "a declined removal keeps them" "" "$(calls zebrunner-farm)"
check_contains "a declined removal suggests the restart" "run 'zebrunner-farm restart' after the deploy" "$output"
check_contains "a declined removal deploys anyway" "${AGENT}/agent.yml" "$(calls ansible-playbook)"
reset_calls
OS=Linux zbr "" ansible devices > /dev/null
check "the registration of the devices keeps the containers" "" "$(calls zebrunner-farm)"
for dry in --check -C --syntax-check --list-tasks; do
  reset_calls
  output="$(OS=Linux zbr "" ansible -v "$dry")"
  check "a run with ${dry} keeps the containers" "" "$(calls zebrunner-farm)"
  check_not_contains "a run with ${dry} asks nothing" "containers of the devices are running" "$output"
  check_not_contains "a run with ${dry} suggests no zebrunner-farm start" "zebrunner-farm start" "$output"
done
reset_calls
output="$(OS=Linux zbr "\n" ansible --tags files)"
check "a deploy with arguments offers the removal" "down" "$(calls zebrunner-farm)"
mv "${WORK}/docker" "${WORK}/bin/docker"
output="$(ANSIBLE_EXIT=2 zbr "" ansible)"
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
    FAKE_UNAME=Darwin FAKE_ARM64="$arm64" FAKE_ROSETTA="$installed" /bin/bash "${AGENT}/zebrunner.sh" "$@" 2>&1 | unwrap
  return "${PIPESTATUS[1]}"
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
check_contains "setup: Rosetta 2 not used by Docker Desktop is reported" "Docker Desktop runs the linux/amd64 image of appium under" "$(rosetta 1 1 setup)"
check_contains "status: Rosetta 2 not used by Docker Desktop" "installed, not used by Docker Desktop" "$(rosetta 1 1 status)"
rm -f "${settings_dir}/settings-store.json"
echo '{"useVirtualizationFrameworkRosetta": false}' > "${settings_dir}/settings.json"
check_contains "the settings of an earlier Docker Desktop" "installed, not used by Docker Desktop" "$(rosetta 1 1 status)"
rm -rf "${WORK}/home/Library"
check_not_contains "setup of an Intel Mac says nothing about Rosetta 2" "Rosetta" "$(rosetta 0 0 setup)"
check_contains "status of an Intel Mac" "not needed (Intel Mac)" "$(rosetta 0 0 status)"
check_not_contains "setup of Linux says nothing about Rosetta 2" "Rosetta" "$(OS=Linux zbr "" setup)"
check_not_contains "status of Linux says nothing about Rosetta 2" "Rosetta" "$(OS=Linux zbr "" status)"
rm -f "${WORK}/bin/sysctl" "${WORK}/bin/arch"

section "status"
output="$(OS=Linux zbr "" status)"
check_contains "ansible version" "ansible-playbook [core 2.21.5]" "$output"
check_contains "zebrunner-farm location" "${WORK}/bin/zebrunner-farm" "$output"
check_contains "settings file" "${AGENT}/config/settings.yml" "$output"
check_contains "devices file" "${AGENT}/config/devices.yml" "$output"
# a stub that behaves as a missing command, removing the stub would expose an ansible-playbook of the system
cp "${WORK}/bin/ansible-playbook" "${WORK}/ansible-playbook"
stub ansible-playbook 'echo "ansible-playbook: command not found" >&2; exit 127'
check_contains "missing ansible-playbook is reported" "'ansible-playbook' not found" "$(zbr "" status)"
mv "${WORK}/ansible-playbook" "${WORK}/bin/ansible-playbook"
mkdir -p "${WORK}/home/Library/LaunchAgents"
touch "${WORK}/home/Library/LaunchAgents/ZebrunnerDevicesListener.plist" "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist"
output="$(OS=Darwin zbr "" status)"
check_contains "macOS deployed launch agents" "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" "$output"
check_contains "macOS settings file" "${AGENT}/config/settings.yml" "$output"

section "join"
# a fake MCloud: curl records its arguments, its stdin (the body or the headers) goes to ${WORK}/mcloud/<call>_input, it
# answers ${WORK}/mcloud/<call>_answer with the code of <call>_code or exits with <call>_exit; <call> is enroll or self
mkdir -p "${WORK}/mcloud"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub curl '(IFS="|"; echo "curl|$*") >> "${STUB_DIR}/calls.log"
case "$*" in
*/api/v1/nodes/enroll*) call=enroll ;;
*/api/v1/nodes/self*) call=self ;;
*) exit 0 ;;
esac
cat > "${STUB_DIR}/mcloud/${call}_input"
exit_code="$(cat "${STUB_DIR}/mcloud/${call}_exit" 2> /dev/null)"
if [[ "${exit_code:-0}" != "0" ]]; then
  echo "curl: (${exit_code}) SSL: public key does not match pinned public key" >&2
  exit "$exit_code"
fi
printf "%s\n%s" "$(cat "${STUB_DIR}/mcloud/${call}_answer")" "$(cat "${STUB_DIR}/mcloud/${call}_code")"'
vars="${AGENT}/config/settings.yml"
cp "$vars" "${WORK}/vars.before-join"
cp "${AGENT}/config/settings.yml.original" "$vars"
pin="$(printf '%043d' 0 | tr 0 Q)="
invite="mci1.$(printf '%043d' 0 | tr 0 i)"
node_token="mcn1.build-ua.$(printf '%043d' 0 | tr 0 n)"
join_string="mcloud-join://192.168.50.2:443?label=build-ua&grid=192.168.50.2:4446&pin=${pin//=/%3D}&token=${invite}"
server_key="$(printf '%064d' 0 | tr 0 c)"
# enroll_answer <token> <address>: the answer of the enrollment
enroll_answer() {
  printf '{"nodeToken":"%s","label":"build-ua","address":"%s","serverPublicKey":"%s","stfUrl":"https://demo.zebrunner.farm",' "$1" "$2" "$server_key"
  printf '"endpoints":{"sub":"tcp://192.168.50.2:7250","push":"tcp://192.168.50.2:7270","appDealer":"tcp://192.168.50.2:7160","devDealer":"tcp://192.168.50.2:7260"}}'
}
enroll_answer "$node_token" 192.168.30.2 > "${WORK}/mcloud/enroll_answer"
echo 200 > "${WORK}/mcloud/enroll_code"
reset_calls
# the pythons of zebrunner.sh record their arguments: the secret key of the host is in none of them
real_python3="$(command -v python3)"
stub python3 "printf '%s\\n' \"\$*\" >> '${WORK}/python-args.log'; exec '${real_python3}' \"\$@\""
stub yaml-python "printf '%s\\n' \"\$*\" >> '${WORK}/python-args.log'; exec '${YAML_PYTHON}' \"\$@\""
: > "${WORK}/python-args.log"
output="$(OS=Linux YAML_PYTHON="${WORK}/bin/yaml-python" zbr "${join_string}\n" join)"
check "join enrolls the host" "0" "$?"
rm -f "${WORK}/bin/python3" "${WORK}/bin/yaml-python"
check_contains "join reports the label and the address" "enrolled in MCloud 192.168.50.2 as build-ua, its address is 192.168.30.2" "$output"
check_contains "the enrollment goes to MCloud over HTTPS with the pinned key only" "--pinnedpubkey|sha256//${pin}|" "$(calls curl)"
check_contains "the enrollment URL" "https://192.168.50.2:443/api/v1/nodes/enroll" "$(calls curl)"
check_not_contains "the invite is not in the arguments of curl" "$invite" "$(calls curl)"
body="$(cat "${WORK}/mcloud/enroll_input")"
check_contains "the body has the invite" "\"invite\": \"${invite}\"" "$body"
check_contains "the body has the label" "\"label\": \"build-ua\"" "$body"
secret="$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY: "\(.*\)"$/\1/p' "$vars")"
check "join makes the CURVE key of the host" "64" "${#secret}"
check_contains "the body has the public key of the host" \
  "\"publicKey\": \"$(printf '%s\n' "$secret" | python3 "${REPO}/patch/curve_keygen.py" - | sed -n 's/^public=//p')\"" "$body"
check_not_contains "the secret key is not sent" "$secret" "$body"
wg_public_key="$(sed -n 's/.*"wgPublicKey": "\([^"]*\)".*/\1/p' <<< "$body")"
check "the body has the public WireGuard key of a new pair of the host" "yes" \
  "$([[ "$wg_public_key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] && echo yes)"
check "MCloud without the WireGuard tunnel: no WG_ setting is written" "0" "$(grep -c '^WG_' "$vars")"
check "the script makes the public key of RFC 7748" "public=8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" \
  "$(echo 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a | python3 "${REPO}/patch/curve_keygen.py" - | head -1)"
check_contains "the script takes no secret key as an argument, every user sees them" "usage:" \
  "$(python3 "${REPO}/patch/curve_keygen.py" 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a 2>&1)"
check_contains "the script refuses an invalid secret key" "must be 64 hex characters" "$(echo abc | python3 "${REPO}/patch/curve_keygen.py" - 2>&1)"
check "the secret key of the host is in no argument of python" "" "$(grep -F -- "$secret" "${WORK}/python-args.log")"
check_contains "the arguments of python are recorded" "patch/settings.py set config/settings.yml -" "$(cat "${WORK}/python-args.log")"
for line in 'MCLOUD_URL: "https://192.168.50.2:443"' "MCLOUD_TLS_PIN: \"${pin}\"" "MCLOUD_NODE_TOKEN: \"${node_token}\"" \
  "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY: \"${server_key}\"" 'PUBLIC_IP: "demo.zebrunner.farm"' 'PUBLIC_IP_PORT: "443"' \
  'PUBLIC_IP_PROTOCOL: "https"' 'STF_PROVIDER_CONNECT_SUB: "tcp://192.168.50.2:7250"' \
  'STF_PROVIDER_CONNECT_DEV_DEALER: "tcp://192.168.50.2:7260"' 'SELENIUM_HUB_HOST: "192.168.50.2"' \
  'SELENIUM_HUB_PORT: "4446"' 'STF_PROVIDER_HOST: "192.168.30.2"'; do
  check "join writes ${line%%:*}" "1" "$(grep -cxF -- "$line" "$vars")"
done
check "the settings are private" "600" "$(stat -c '%a' "$vars" 2> /dev/null || stat -f '%Lp' "$vars")"
backup="$(find "$(dirname "$vars")" -name 'settings.yml.bak-join-*' | head -1)"
check "the previous settings are kept, private too" "600" "$(stat -c '%a' "$backup" 2> /dev/null || stat -f '%Lp' "$backup")"
check_not_contains "the token is not printed" "$node_token" "$output"
check_not_contains "the invite is not printed" "$invite" "$output"
check_contains "the next steps are printed" "./zebrunner.sh ansible deploys them" "$output"
rm -f "${vars}".bak-join-*

cp "$vars" "${WORK}/vars.joined"
check_contains "a wrong join string fails" "not a join string of ./zebrunner.sh node-invite" "$(OS=Linux zbr "https://example.com\n" join)"
check_contains "a join string without the pin fails" "the pin of the join string is not a sha256 in base64" \
  "$(OS=Linux zbr "${join_string/pin=/pinx=}\n" join)"
echo 90 > "${WORK}/mcloud/enroll_exit"
check_contains "another TLS key of the server stops the enrollment" "the TLS key of the server is not the pinned one" \
  "$(OS=Linux zbr "${join_string}\n" join)"
rm -f "${WORK}/mcloud/enroll_exit"
echo 403 > "${WORK}/mcloud/enroll_code"
check_contains "a refused invite is explained" "MCloud refused the enrollment (HTTP 403)" "$(OS=Linux zbr "${join_string}\n" join)"
echo 200 > "${WORK}/mcloud/enroll_code"
enroll_answer "mcn1.other-host.$(printf '%043d' 0 | tr 0 n)" 192.168.30.2 > "${WORK}/mcloud/enroll_answer"
check_contains "a token of another label is refused" "MCloud answered no valid token of this label" "$(OS=Linux zbr "${join_string}\n" join)"
enroll_answer "$node_token" '192.168.30.2\nMCLOUD_NODE_TOKEN: x' > "${WORK}/mcloud/enroll_answer"
output="$(OS=Linux zbr "${join_string}\n" join)"
check_contains "an answer cannot inject settings" "the address of this host is not a host name or address" "$output"
check "a failed enrollment changes no setting" "same" "$(cmp -s "$vars" "${WORK}/vars.joined" && echo same)"
rm -f "${vars}".bak-join-*

# the WireGuard tunnel of MCloud on (README.md#wireguard-tunnel): the address of the invite is the one of the host in
# the tunnel, the grid and ZeroMQ go to MCloud at its address there
wg_server_key="$(printf '%042d' 0 | tr 0 S)A="
# enroll_answer_wg <address> <server address> <network>: the answer of the enrollment of MCloud with the tunnel on
enroll_answer_wg() {
  enroll_answer "$node_token" "$1" | sed 's/}$//'
  printf ',"wireguard":{"endpoint":"demo.zebrunner.farm:51820","publicKey":"%s","serverAddress":"%s","address":"%s",' "$wg_server_key" "$2" "$1"
  printf '"network":"%s","persistentKeepalive":25}}' "$3"
}
enroll_answer_wg 10.234.0.2 10.234.0.1 10.234.0.0/24 > "${WORK}/mcloud/enroll_answer"
stub python3 "printf '%s\\n' \"\$*\" >> '${WORK}/python-args.log'; exec '${real_python3}' \"\$@\""
stub yaml-python "printf '%s\\n' \"\$*\" >> '${WORK}/python-args.log'; exec '${YAML_PYTHON}' \"\$@\""
: > "${WORK}/python-args.log"
output="$(OS=Linux YAML_PYTHON="${WORK}/bin/yaml-python" zbr "${join_string}\n" join)"
check "join with the WireGuard tunnel of MCloud" "0" "$?"
rm -f "${WORK}/bin/python3" "${WORK}/bin/yaml-python"
check_contains "join reports the tunnel" "The WireGuard tunnel of MCloud is on: MCloud is 10.234.0.1 in it" "$output"
wg_public_key="$(sed -n 's/.*"wgPublicKey": "\([^"]*\)".*/\1/p' "${WORK}/mcloud/enroll_input")"
wg_private_key="$(sed -n 's/^WG_PRIVATE_KEY: "\(.*\)"$/\1/p' "$vars")"
check "the private WireGuard key is written" "44" "${#wg_private_key}"
check "the private WireGuard key is the one of the public key sent" "$wg_public_key" \
  "$(python3 -c 'import base64, sys; sys.path.insert(0, sys.argv[1]); from curve_keygen import x25519_base
print(base64.b64encode(x25519_base(base64.b64decode(sys.stdin.read()))).decode())' "${REPO}/patch" <<< "$wg_private_key")"
check_not_contains "the private WireGuard key is not sent" "$wg_private_key" "$(cat "${WORK}/mcloud/enroll_input")"
check_not_contains "the private WireGuard key is not printed" "$wg_private_key" "$output"
check "the private WireGuard key is in no argument of python" "" "$(grep -F -- "$wg_private_key" "${WORK}/python-args.log")"
for line in 'WG_ENABLED: true' 'WG_ADDRESS: "10.234.0.2"' 'WG_SERVER_ADDRESS: "10.234.0.1"' "WG_SERVER_PUBLIC_KEY: \"${wg_server_key}\"" \
  'WG_ENDPOINT: "demo.zebrunner.farm:51820"' 'WG_NETWORK: "10.234.0.0/24"' 'WG_PERSISTENT_KEEPALIVE: 25' \
  'STF_PROVIDER_HOST: "10.234.0.2"' 'SELENIUM_HUB_HOST: "10.234.0.1"' 'SELENIUM_HUB_PORT: "4446"' \
  'STF_PROVIDER_CONNECT_SUB: "tcp://10.234.0.1:7250"' 'STF_PROVIDER_CONNECT_PUSH: "tcp://10.234.0.1:7270"' \
  'MCLOUD_URL: "https://192.168.50.2:443"' 'PUBLIC_IP: "demo.zebrunner.farm"'; do
  check "the tunnel: join writes ${line%%:*}" "1" "$(grep -cxF -- "$line" "$vars")"
done
check "the settings with the private WireGuard key are private" "600" "$(stat -c '%a' "$vars" 2> /dev/null || stat -f '%Lp' "$vars")"
cp "$vars" "${WORK}/vars.wireguard"
rm -f "${vars}".bak-join-*
enroll_answer_wg 10.234.1.2 10.234.0.1 10.234.0.0/24 > "${WORK}/mcloud/enroll_answer"
check_contains "an address of the tunnel out of its network is refused" "are not in the network 10.234.0.0/24" \
  "$(OS=Linux zbr "${join_string}\n" join)"
enroll_answer_wg 10.234.0.2 10.234.0.1 10.234.0.0/24 | sed 's/"publicKey":"[^"]*"/"publicKey":"x\\nWG_ENABLED: false"/' > "${WORK}/mcloud/enroll_answer"
check_contains "an answer cannot inject settings with the key of the tunnel" "MCloud answered no valid WireGuard key" \
  "$(OS=Linux zbr "${join_string}\n" join)"
check "a failed enrollment with the tunnel changes no setting" "same" "$(cmp -s "$vars" "${WORK}/vars.wireguard" && echo same)"
# MCloud turned the tunnel off: a new join clears the settings of the tunnel, the private key too
enroll_answer "$node_token" 192.168.30.2 > "${WORK}/mcloud/enroll_answer"
OS=Linux zbr "${join_string}\n" join > /dev/null
check "the tunnel off: join turns it off" "1" "$(grep -cxF 'WG_ENABLED: false' "$vars")"
check "the tunnel off: the private WireGuard key is removed" "1" "$(grep -cx 'WG_PRIVATE_KEY:' "$vars")"
check "the tunnel off: the endpoints of the join string again" "1" "$(grep -cxF 'STF_PROVIDER_CONNECT_SUB: "tcp://192.168.50.2:7250"' "$vars")"
cp "${WORK}/vars.joined" "$vars"
chmod 600 "$vars"
rm -f "${vars}".bak-join-*

section "doctor"
# a fake network of ${WORK}/net: `hosts` (<name> <address>), `closed` (<host>:<port>), `local` and `source` (addresses)
mkdir -p "${WORK}/net"
cp "${AGENT}/patch/netcheck.py" "${WORK}/netcheck.py"
cat > "${AGENT}/patch/netcheck.py" << 'PYTHON'
import ipaddress
import os
import sys

net = os.path.join(os.environ["STUB_DIR"], "net")


def lines(name):
    path = os.path.join(net, name)
    return open(path).read().split("\n") if os.path.exists(path) else []


def address(host):
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        return next((line.split()[1] for line in lines("hosts") if line.split()[:1] == [host]), "")


command, args = sys.argv[1], sys.argv[2:]
if command == "resolve":
    print(address(args[0]))
    sys.exit(0 if address(args[0]) else 1)
if command == "tcp":
    if "%s:%s" % (args[0], args[1]) in lines("closed"):
        print("Connection refused", file=sys.stderr)
        sys.exit(1)
elif command == "source":
    print(lines("source")[0])
elif command == "local":
    sys.exit(0 if args[0] in lines("local") else 1)
elif command == "kind":
    ip = ipaddress.ip_address(args[0])
    print("loopback" if ip.is_loopback else "private" if ip.is_private else "public")
PYTHON
# the certificate of MCloud: ${WORK}/net/tls is "pinned" (a self-signed one of the pin) or "fail <reason>", a public CA
# without it
cp "${AGENT}/patch/tlstrust.py" "${WORK}/tlstrust.py"
cat > "${AGENT}/patch/tlstrust.py" << 'PYTHON'
import os
import sys

path = os.path.join(os.environ["STUB_DIR"], "net", "tls")
state = open(path).read().strip() if os.path.exists(path) else ""
if state == "pinned":
    print("-----BEGIN CERTIFICATE-----")
elif state.startswith("fail "):
    print(state[5:], file=sys.stderr)
    sys.exit(1)
PYTHON
cp "${WORK}/bin/docker" "${WORK}/docker"
# docker of no container (inspect fails) and no device
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '[[ "$1" == "inspect" ]] && exit 1
exit 0'
echo "demo.zebrunner.farm 192.168.50.2" > "${WORK}/net/hosts"
echo "192.168.30.2" > "${WORK}/net/local"
echo "192.168.30.2" > "${WORK}/net/source"
: > "${WORK}/net/closed"
# the answer of MCloud about this host: a bound present device and an unbound absent one
self_answer() {
  printf '{"label":"build-ua","address":"%s","status":"active","devices":[' "$1"
  printf '{"serial":"R28M1384YQY","platform":"android","present":true,"bound":true},'
  printf '{"serial":"emu1","platform":"android","present":false,"bound":false}]}'
}
self_answer 192.168.30.2 > "${WORK}/mcloud/self_answer"
echo 200 > "${WORK}/mcloud/self_code"
# doctor_run: ./zebrunner.sh doctor of a Linux host without the deployed files
doctor_run() {
  printf '' | env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    FAKE_UNAME=Linux DOCTOR_FARM="${WORK}/farm" DOCTOR_FARM_ENV="${WORK}/farm.env" DOCTOR_DEVICES="${WORK}/devices.txt" \
    ZEBRUNNER_PYTHON="$YAML_PYTHON" USB_STATS_KERNEL_LOG="${WORK}/kernel.log" USB_STATS_DOCKER_LOG="${WORK}/docker.log" \
    USB_STATS_SYSFS="${WORK}/sysfs" USB_MAP_SYSFS="${WORK}/usb-sysfs" /bin/bash "${AGENT}/zebrunner.sh" doctor 2>&1 | unwrap
  return "${PIPESTATUS[1]}"
}
# the kernel log of the USB stability (patch/usb_stats.py): no disconnection
: > "${WORK}/kernel.log"
# the USB tree of sysfs (patch/usb_map.py): a root hub
mkdir -p "${WORK}/usb-sysfs/usb1"
echo 09 > "${WORK}/usb-sysfs/usb1/bDeviceClass"
echo 4 > "${WORK}/usb-sysfs/usb1/maxchild"
: > "${WORK}/docker.log"
rm -f "${WORK}/farm" "${WORK}/devices.txt"
cp "${WORK}/vars.joined" "$vars"
chmod 600 "$vars"

reset_calls
output="$(doctor_run)"
check "an enrolled host passes" "0" "$?"
check_contains "the enrollment is checked with MCloud" "this host is enrolled and active in MCloud as build-ua" "$output"
check_contains "the check goes to MCLOUD_URL with the pinned key" "--pinnedpubkey|sha256//${pin}|" "$(calls curl)"
check_contains "the check URL" "https://192.168.50.2:443/api/v1/nodes/self" "$(calls curl)"
check_contains "the token goes in the header on stdin" "Authorization: Bearer ${node_token}" "$(cat "${WORK}/mcloud/self_input")"
check_not_contains "the token is not in the arguments of curl" "$node_token" "$(calls curl)"
check_contains "the devices of STF are counted" "STF knows 2 devices of this host, 1 bound to it" "$output"
check_contains "an unbound device is reported" "STF refuses the device emu1 (android) of this host" "$output"
check_contains "an absent device is reported" "STF knows the device emu1 (android), it is not connected now" "$output"
check_contains "the endpoints of the server are checked" "mcloud-grid (SELENIUM_HUB_HOST): 192.168.50.2:4446 (192.168.50.2) accepts connections" "$output"
check_contains "an address of this host" "STF_PROVIDER_HOST 192.168.30.2 is an address of this host" "$output"
check_contains "not deployed agent" "zebrunner-farm is not deployed" "$output"
check_contains "doctor starts with the banner" "[ ZEBRUNNER ] MCloud Agent doctor" "$output"
check_contains "the checks are grouped in sections, badges without colors" "[ HOST ] ---" "$output"
check_contains "a warning tells the fix under it" $'   warn zebrunner-farm is not deployed\n     `- fix ./zebrunner.sh ansible' "$output"
check "the summary counts every status without colors" \
  "  $(grep -c '^   ok ' <<< "$output") ok, $(grep -c '^   warn ' <<< "$output") warn, 0 fail" \
  "$(grep -E '^  [0-9]+ ok, [0-9]+ warn, [0-9]+ fail$' <<< "$output")"
check_contains "the advice follows the summary" "No problems, $(grep -c '^   warn ' <<< "$output") warnings" "$output"
check "the output is plain text without a terminal" "0" "$(grep -c $'\033' <<< "$output")"
check_contains "the USB stability of a host without a flapping port" "no USB port flapped (more than 10 disconnects a day) in 7 days" "$output"
# a port that flaps on a day: a warning with the summary of patch/usb_stats.py
python3 -c 'import datetime
day = datetime.date.today() - datetime.timedelta(days=1)
print("\n".join(["%sT10:00:00+0100 host kernel: usb 1-6.4.2: SerialNumber: R28M1384YQY" % day]
    + ["%sT10:%02d:00+0100 host kernel: usb 1-6.4.2: USB disconnect, device number 5" % (day, i) for i in range(12)]))' \
  > "${WORK}/kernel.log"
usb_output="$(doctor_run)"
check "a flapping USB port is a warning, not a problem" "0" "$?"
check_contains "a flapping USB port is reported with its counts" "USB port 1-6.4.2 (unknown device R28M1384YQY): 12 disconnects in 7 days, up to 12 a day; unknown: one device on one port" "$usb_output"
check_contains "the fix of a flapping USB port" "zebrunner-farm doctor usb-stats: the details and the hint" "$usb_output"
check_contains "no USB device of the farm is missing" "every USB device of the farm is on USB" "$usb_output"
# a USB device of the farm that is not on USB: a warning with the last port of the kernel log
printf '%s\n' "id=R28M1384YQY|os=android|name=Galaxy|location=S3_A1|connection=usb" \
  "id=emu1|os=android|name=Emu|location=|connection=android-sim" > "${WORK}/devices.txt"
usb_output="$(doctor_run)"
check "a device not on USB is a warning, not a problem" "0" "$?"
check_contains "a device not on USB is reported with its last port" \
  "Galaxy (S3_A1) R28M1384YQY is not on USB (last seen $(date -d yesterday +%F 2> /dev/null || date -v-1d +%F) 10:11:00 on 1-6.4.2)" \
  "$usb_output"
check_contains "the fix of a device not on USB" "zebrunner-farm doctor usb-map shows the hubs and the free ports" "$usb_output"
check_not_contains "a simulator is not on USB" "Emu is not on USB" "$usb_output"
mkdir -p "${WORK}/usb-sysfs/1-6"
echo R28M1384YQY > "${WORK}/usb-sysfs/1-6/serial"
check_contains "a device on USB" "every USB device of the farm is on USB" "$(doctor_run)"
rm -rf "${WORK}/usb-sysfs/1-6" "${WORK}/devices.txt"
: > "${WORK}/kernel.log"
rm -f "${WORK}/kernel.log"
check_contains "unreadable logs of the USB stability are a fact" "info not checked: The logs are not readable" "$(doctor_run)"
: > "${WORK}/kernel.log"
for secret in "$node_token" "$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY: "\(.*\)"$/\1/p' "$vars")"; do
  check_not_contains "a secret is not printed" "$secret" "$output"
done

self_answer 192.168.30.9 > "${WORK}/mcloud/self_answer"
check_contains "another address of the host in MCloud is a problem" \
  "STF_PROVIDER_HOST 192.168.30.2 is not the address of this host in MCloud (192.168.30.9)" "$(doctor_run)"
self_answer 192.168.30.2 > "${WORK}/mcloud/self_answer"
echo 401 > "${WORK}/mcloud/self_code"
check_contains "an unknown token is a problem" "MCloud does not know the token of this host" "$(doctor_run)"
echo 403 > "${WORK}/mcloud/self_code"
check_contains "a revoked host is a problem" "MCloud revoked this host" "$(doctor_run)"
echo 200 > "${WORK}/mcloud/self_code"
echo 90 > "${WORK}/mcloud/self_exit"
check_contains "another TLS key of MCloud is a problem" "the TLS key of MCloud https://192.168.50.2:443 is not the pinned one" "$(doctor_run)"
rm -f "${WORK}/mcloud/self_exit"

# the public address of a NAT as the address of the host while MCloud is in its network
sed -i.bak 's/^STF_PROVIDER_HOST:.*/STF_PROVIDER_HOST: "185.237.20.136"/' "$vars" && rm -f "${vars}.bak"
self_answer 185.237.20.136 > "${WORK}/mcloud/self_answer"
output="$(doctor_run)"
check "a broken agent fails" "1" "$?"
check "the summary counts the problem" "  $(grep -c '^   ok ' <<< "$output") ok, $(grep -c '^   warn ' <<< "$output") warn, 1 fail" \
  "$(grep -E '^  [0-9]+ ok, [0-9]+ warn, [0-9]+ fail$' <<< "$output")"
check_contains "the advice of a problem" "1 problems and" "$output"
check_contains "the public address of a NAT in the network of the server is a problem" \
  "STF_PROVIDER_HOST 185.237.20.136 (185.237.20.136) is a public address of a NAT" "$output"
check_contains "a new invite with the address of this host in that network is the fix" \
  "a new invite of this host with the address 192.168.30.2 (./zebrunner.sh node-invite <label> 192.168.30.2 of mcloud)" "$output"
cp "${WORK}/vars.joined" "$vars"
chmod 600 "$vars"
self_answer 192.168.30.2 > "${WORK}/mcloud/self_answer"

# the remote debug through the adb relay of mcloud
printf '%s\n' "id=emu1|os=android|name=Emu|location=loc|appium_port=7471|adb_port=7472|min_port=7475|max_port=7480|connection=android-sim|wda_file=/dev/null|wda_bundleid=x|address=host:5557|wda_port=|mjpeg_port=|connect_port=" > "${WORK}/devices.txt"
check_contains "the deployed devices are checked" "Emu: no running container" "$(doctor_run)"
check_contains "the remote debug of a private address is explained" \
  "adb connect of STF (the remote debug) reaches 192.168.30.2 from its network only" "$(doctor_run)"
sed -i.bak 's/^REMOTE_CONNECT_HOST:.*/REMOTE_CONNECT_HOST: demo.zebrunner.farm/' "$vars" && rm -f "${vars}.bak"
check_contains "the adb relay is checked on the remote debug port of the devices" \
  "adb relay of mcloud (REMOTE_CONNECT_HOST): demo.zebrunner.farm:7476 (192.168.50.2) accepts connections" "$(doctor_run)"
printf '%s\n' "id=emu1|os=android|name=Emu|location=loc|appium_port=7471|adb_port=7472|min_port=7475|max_port=7480|connection=android-sim|wda_file=/dev/null|wda_bundleid=x|address=host:5557|wda_port=|mjpeg_port=|connect_port=7499" > "${WORK}/devices.txt"
check_contains "connect_port is the remote debug port" "the remote debug ports of this host (ADB_RELAY_PORTS of mcloud must have them): 192.168.30.2:7499" "$(doctor_run)"
echo "demo.zebrunner.farm:7499" > "${WORK}/net/closed"
check_contains "a missing relay tells the setting of mcloud" "ADB_RELAY=true of .env of mcloud" "$(doctor_run)"
: > "${WORK}/net/closed"
cp "${WORK}/vars.joined" "$vars"
chmod 600 "$vars"

# MCloud on this machine: the devices must not use its ports
echo "192.168.50.2" >> "${WORK}/net/local"
printf '%s\n' "id=emu1|os=android|name=Emu|location=loc|appium_port=4446|adb_port=7472|min_port=7475|max_port=7480|connection=android-sim|wda_file=/dev/null|wda_bundleid=x|address=host:5557|wda_port=|mjpeg_port=|connect_port=" > "${WORK}/devices.txt"
output="$(doctor_run)"
check_contains "MCloud on this machine is reported" "MCloud runs on this machine (192.168.50.2)" "$output"
check_contains "a port of MCloud used by a device is a problem" "the devices use the ports 4446 of MCloud on this machine" "$output"
printf '%s\n' "id=emu1|os=android|name=Emu|location=loc|appium_port=7471|adb_port=7472|min_port=7475|max_port=7480|connection=android-sim|wda_file=/dev/null|wda_bundleid=x|address=host:5557|wda_port=|mjpeg_port=|connect_port=" > "${WORK}/devices.txt"
check_contains "no port of MCloud used by the devices" "the devices use no port of MCloud on this machine" "$(doctor_run)"
echo "192.168.30.2" > "${WORK}/net/local"
rm -f "${WORK}/devices.txt"

# the WireGuard tunnel to MCloud (README.md#wireguard-tunnel): wg shows the time of the last handshake of
# ${WORK}/wg_handshake, fails without it (no root)
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub wg '(IFS="|"; echo "wg|$*") >> "${STUB_DIR}/calls.log"
[[ -f "${STUB_DIR}/wg_handshake" ]] || exit 1
printf "%s\t%s\n" "server-key" "$(cat "${STUB_DIR}/wg_handshake")"'
check_not_contains "the tunnel off: no check of the tunnel" "WireGuard" "$(doctor_run)"
cp "${WORK}/vars.wireguard" "$vars"
chmod 600 "$vars"
self_answer 10.234.0.2 > "${WORK}/mcloud/self_answer"
echo "10.234.0.2" > "${WORK}/net/local"
echo "10.234.0.2" > "${WORK}/net/source"
date +%s > "${WORK}/wg_handshake"
reset_calls
output="$(doctor_run)"
check "the tunnel up passes" "0" "$?"
check_contains "the tunnel has a section" "[ WIREGUARD TUNNEL ]" "$output"
check_contains "the interface of the tunnel is up" "the interface mcloud-node is up with WG_ADDRESS 10.234.0.2" "$output"
check_contains "a recent handshake" "the last handshake with MCloud 10.234.0.1 was" "$output"
check_contains "the handshakes of the interface mcloud-node" "show|mcloud-node|latest-handshakes" "$(calls wg)"
check_contains "mcloud-grid answers through the tunnel" \
  "mcloud-grid through the tunnel (WG_SERVER_ADDRESS): 10.234.0.1:4446 (10.234.0.1) accepts connections" "$output"
check_not_contains "the private WireGuard key is not printed" "$(sed -n 's/^WG_PRIVATE_KEY: "\(.*\)"$/\1/p' "$vars")" "$output"
echo $(($(date +%s) - 600)) > "${WORK}/wg_handshake"
check_contains "an old handshake is a problem" "seconds ago (more than 3 minutes)" "$(doctor_run)"
echo 0 > "${WORK}/wg_handshake"
check_contains "no handshake is a problem" "no handshake with MCloud 10.234.0.1 yet" "$(doctor_run)"
rm -f "${WORK}/wg_handshake"
check_contains "wg without root: the handshake is not checked" "the handshake is not checked: wg show needs root" "$(doctor_run)"
echo "10.234.0.1:4446" > "${WORK}/net/closed"
check_contains "mcloud-grid not answering through the tunnel is a problem" \
  "mcloud-grid through the tunnel (WG_SERVER_ADDRESS): 10.234.0.1:4446 (10.234.0.1) does not accept connections" "$(doctor_run)"
: > "${WORK}/net/closed"
echo "192.168.30.2" > "${WORK}/net/local"
output="$(doctor_run)"
check "the tunnel down fails" "1" "$?"
check_contains "the interface of the tunnel is down" "the interface mcloud-node is down: WG_ADDRESS 10.234.0.2 is not an address of this host" "$output"
check_contains "the fix of the tunnel down" "sudo systemctl restart wg-quick@mcloud-node" "$output"
sed -i.bak 's/^WG_SERVER_PUBLIC_KEY:.*/WG_SERVER_PUBLIC_KEY: "abc"/' "$vars" && rm -f "${vars}.bak"
check_contains "an invalid WireGuard key is a problem" "WG_SERVER_PUBLIC_KEY is not a WireGuard key of ./zebrunner.sh join" "$(doctor_run)"
rm -f "${WORK}/bin/wg"
echo "192.168.30.2" > "${WORK}/net/source"
self_answer 192.168.30.2 > "${WORK}/mcloud/self_answer"
cp "${WORK}/vars.joined" "$vars"
chmod 600 "$vars"

# the settings of zebrunner-farm rendered with another STF_PROVIDER_HOST, then with the settings
if command -v ansible > /dev/null 2>&1; then
  # render_farm_env [ansible arguments...]: the settings of zebrunner-farm of the deploy of the current settings
  render_farm_env() {
    render "${AGENT}/roles/common/templates/zebrunner-farm.env" "${WORK}/farm.env" --extra-vars common_farm_os=linux \
      --extra-vars "@${AGENT}/roles/common/defaults/main.yml" --extra-vars "@${AGENT}/roles/devices/defaults/main.yml" \
      --extra-vars "@${AGENT}/versions.yml" --extra-vars "@${vars}" "$@"
  }
  cp "$FARM_SCRIPT" "${WORK}/farm"
  render_farm_env --extra-vars "STF_PROVIDER_HOST=185.237.20.136" || exit 1
  check_contains "a deployment with other settings is reported" "zebrunner-farm is deployed with other values of STF_PROVIDER_HOST" "$(doctor_run)"
  render_farm_env --extra-vars "DEVICE_VERSION=0.1" || exit 1
  check_contains "a deployment with another version is reported" "zebrunner-farm is deployed with other values of DEVICE_VERSION" "$(doctor_run)"
  mkdir -p "${WORK}/farm-lib"
  render_farm_env --extra-vars "common_farm_lib_dir=${WORK}/farm-lib" || exit 1
  check_contains "the scripts zebrunner-farm sources, missing in the folder of the deploy, are reported" \
    "the scripts zebrunner-farm sources (${WORK}/farm-lib) are missing or not the ones of this folder: utility.sh ui.sh" "$(doctor_run)"
  cp "${AGENT}/patch/utility.sh" "${AGENT}/patch/ui.sh" "${WORK}/farm-lib/"
  check_not_contains "the scripts zebrunner-farm sources are the ones of this folder" "are missing or not the ones" "$(doctor_run)"
  echo "# changed" >> "${WORK}/farm-lib/ui.sh"
  check_contains "another script zebrunner-farm sources is reported" "are missing or not the ones of this folder: ui.sh" "$(doctor_run)"
  render_farm_env || exit 1
  chmod 644 "${WORK}/farm.env"
  output="$(doctor_run)"
  check_contains "a deployment with the settings" "zebrunner-farm is deployed with the current settings" "$output"
  check_contains "readable settings of zebrunner-farm are reported" \
    "the settings of zebrunner-farm have the secrets of the host and are readable by every user (mode 644)" "$output"
  chmod 600 "${WORK}/farm.env"
  check_not_contains "private settings of zebrunner-farm" "readable by every user" "$(doctor_run)"
  rm -f "${WORK}/farm.env"
  check_contains "the settings of a deployment are missing" "the settings of zebrunner-farm (${WORK}/farm.env) are not readable" "$(doctor_run)"
  rm -f "${WORK}/farm"
else
  skip_check "the settings of the deployed zebrunner-farm" "no ansible"
fi

check_contains "a certificate of a public CA" "a public CA signs the certificate of MCloud" "$(doctor_run)"
echo pinned > "${WORK}/net/tls"
check_contains "the pinned self-signed certificate" "the containers of STF trust the pinned certificate of MCloud" "$(doctor_run)"
echo "fail the TLS key is not the pinned one" > "${WORK}/net/tls"
check_contains "a certificate the containers do not trust is a problem" \
  "the containers of STF do not trust the certificate of MCloud: the TLS key is not the pinned one" "$(doctor_run)"
echo 'STF_TLS_INSECURE: true' >> "$vars"
check_contains "STF_TLS_INSECURE is a warning" "STF_TLS_INSECURE: the containers of STF do not verify the certificate of MCloud" \
  "$(doctor_run)"
sed -i.bak '/^STF_TLS_INSECURE:/d' "$vars" && rm -f "${vars}.bak"
rm -f "${WORK}/net/tls"
echo "192.168.50.2:4446" > "${WORK}/net/closed"
check_contains "a closed port is a problem" "192.168.50.2:4446 (192.168.50.2) does not accept connections: Connection refused" "$(doctor_run)"
: > "${WORK}/net/closed"
echo "mcloud.other.com 10.0.0.1" > "${WORK}/net/hosts"
check_contains "an unresolved server is a problem" "MCloud (PUBLIC_IP): demo.zebrunner.farm is not resolved" "$(doctor_run)"
echo "demo.zebrunner.farm 192.168.50.2" > "${WORK}/net/hosts"

sed -i.bak 's/^MCLOUD_NODE_TOKEN:.*/MCLOUD_NODE_TOKEN: "mcn1.x"/' "$vars" && rm -f "${vars}.bak"
check_contains "an invalid token is a problem" "MCLOUD_NODE_TOKEN is not a token of ./zebrunner.sh join" "$(doctor_run)"
check_not_contains "no access token of an admin of STF" "STF_AUTH_TOKEN" "$(doctor_run)"
echo 'STF_AUTH_TOKEN: "admin-token"' >> "$vars"
output="$(doctor_run)"
check_contains "an access token of an admin of STF is reported" \
  "STF_AUTH_TOKEN is not used: appium marks its device Unhealthy with the node token of this host" "$output"
check_contains "removing it is the fix" "delete its access token in STF (Settings, Keys)" "$output"
check_not_contains "the token is not shown" "admin-token" "$output"
chmod 644 "$vars"
check_contains "readable settings are reported" "have secrets and are readable by other users (mode 644)" "$(doctor_run)"
cp "${AGENT}/config/settings.yml.original" "$vars"
output="$(doctor_run)"
check_contains "a host without the enrollment is reported" "this host is not enrolled, empty: MCLOUD_URL MCLOUD_TLS_PIN MCLOUD_NODE_TOKEN" "$output"
check_contains "join is the fix" "./zebrunner.sh join with the join string of ./zebrunner.sh node-invite of mcloud" "$output"
mkdir -p "${AGENT}/roles/devices/vars"
touch "${AGENT}/roles/devices/vars/main.yml"
check_contains "the settings of an earlier version are a problem" \
  "roles/devices/vars/main.yml of an earlier version overrides config/settings.yml" "$(doctor_run)"
rm -rf "${AGENT}/roles/devices/vars"
mv "${AGENT}/config/devices.yml" "${WORK}/devices.yml"
check_contains "no devices file" "config/devices.yml does not exist" "$(doctor_run)"
mv "${WORK}/devices.yml" "${AGENT}/config/devices.yml"
check_contains "the devices are checked as by the deploy" "2 devices are declared, their settings are valid" "$(doctor_run)"
cp "${AGENT}/config/devices.yml" "${WORK}/devices.yml"
printf '  - {id: R28M1384YQY, os: android, name: Other, appium_port: 7501, min_port: 7505, max_port: 7510}\n' >> "${AGENT}/config/devices.yml"
check_contains "a duplicate device is a problem" "Duplicate devices found! Duplicate IDs: ['R28M1384YQY']" "$(doctor_run)"
cp "${WORK}/devices.yml" "${AGENT}/config/devices.yml"
printf '  - {id: sim1, os: ios, name: Sim, appium_port: 7501, min_port: 7505, max_port: 7510, connection: ios-sim}\n' >> "${AGENT}/config/devices.yml"
check_contains "a connection of another OS is a problem" "Invalid connection 'ios-sim' of device 'Sim'" "$(doctor_run)"
cp "${WORK}/devices.yml" "${AGENT}/config/devices.yml"
cp "$vars" "${WORK}/settings.yml"
echo "PUBLIC_IP: [demo" >> "$vars"
check_contains "settings of invalid YAML are a problem" "config/settings.yml is not valid YAML" "$(doctor_run)"
cp "${WORK}/settings.yml" "$vars"
rm -f "$vars"
check_contains "no settings" "config/settings.yml does not exist" "$(doctor_run)"
mv "${WORK}/docker" "${WORK}/bin/docker"
mv "${WORK}/netcheck.py" "${AGENT}/patch/netcheck.py"
mv "${WORK}/tlstrust.py" "${AGENT}/patch/tlstrust.py"
rm -f "${WORK}/bin/curl"
mv "${WORK}/vars.before-join" "$vars"

section "backup and restore"
zbr "n\n" backup > /dev/null
check "declined backup creates nothing" "0" "$(find "${AGENT}/backup" -name 'bak_*' | wc -l | tr -d ' ')"
OS=Linux zbr "y\n" backup > /dev/null
backup="$(cd "${AGENT}/backup" && ls -d bak_* 2> /dev/null)"
check "backup dir is created" "1" "$(echo "$backup" | grep -c '^bak_')"
for file in config/settings.yml config/devices.yml; do
  check "backup has ${file}" "yes" "$([[ -f "${AGENT}/backup/${backup}/${file}" ]] && echo yes)"
done
check "backup has the settings only" "2" "$(find "${AGENT}/backup/${backup}" -type f | wc -l | tr -d ' ')"
check "the backup is private" "700" "$(stat -c '%a' "${AGENT}/backup/${backup}" 2> /dev/null || stat -f '%Lp' "${AGENT}/backup/${backup}")"
cp "${AGENT}/config/settings.yml" "${WORK}/settings.yml"
cp "${AGENT}/config/devices.yml" "${WORK}/devices.yml"
echo "CHANGED: true" >> "${AGENT}/config/settings.yml"
rm "${AGENT}/config/devices.yml"
output="$(OS=Linux zbr "y\n${backup}\n" restore)"
check_contains "restore prints its header" "Restore MCloud Agent" "$output"
check "restore brings the settings back" "same" "$(cmp -s "${AGENT}/config/settings.yml" "${WORK}/settings.yml" && echo same)"
check "restore brings the devices back" "same" "$(cmp -s "${AGENT}/config/devices.yml" "${WORK}/devices.yml" && echo same)"
check_contains "restore asks again for an unknown backup" "does not exist" "$(OS=Linux zbr "y\nbak_none\n${backup}\n" restore)"
OS=Linux zbr "y\n" restore > /dev/null
check "restore stops at the end of the input" "1" "$?"
mkdir -p "${AGENT}/backup/bak_old/vars"
touch "${AGENT}/backup/bak_old/vars/main.yml"
check_contains "a backup of an earlier version is explained" "is a backup of an earlier version: ./zebrunner.sh migrate backup/bak_old/vars/main.yml backup/bak_old/defaults/main.yml" \
  "$(unwrapped "$(OS=Linux zbr "y\nbak_old\n" restore)")"
rm -rf "${AGENT}/backup/bak_old"

section "migrate"
cp "${AGENT}/config/settings.yml" "${WORK}/settings.saved"
cp "${AGENT}/config/devices.yml" "${WORK}/devices.saved"
cp "${AGENT}/config/settings.yml.original" "${AGENT}/config/settings.yml"
cp "${AGENT}/config/devices.yml.original" "${AGENT}/config/devices.yml"
check_contains "nothing to migrate without the files of an earlier version" "nothing to migrate" "$(OS=Linux zbr "" migrate)"
mkdir -p "${AGENT}/roles/devices/vars" "${AGENT}/defaults"
cat > "${AGENT}/roles/devices/vars/main.yml" << 'EOF'
---
STF_DOCKER_NETWORK: infra
PUBLIC_IP: old.example.com
PUBLIC_IP_PORT: 80
MCLOUD_NODE_TOKEN: "mcn1.old-host.secret-token-value"
STF_PROVIDER_NAME: mcloud-linux
# the devices of the earlier version
devices:
  # the phone on the desk
  - id: OLD1
    os: android
    name: Old_Phone
    appium_port: 7421
    min_port: 7425
    max_port: 7430
EOF
printf 'DEVICE_IMAGE: public.ecr.aws/zebrunner/mcloud-device\nDEVICE_VERSION: 9.9-local\nAPPIUM_RELAXED_SECURITY: true\n' > "${AGENT}/defaults/main.yml"
output="$(OS=Linux zbr "n\n" migrate)"
check_contains "the files of an earlier version are found" "roles/devices/vars/main.yml defaults/main.yml" "$output"
check_contains "a changed setting is shown" '+PUBLIC_IP: "old.example.com"' "$output"
check_contains "a number keeps its type" "+PUBLIC_IP_PORT: 80" "$output"
check_contains "a secret is hidden" "+MCLOUD_NODE_TOKEN: ******" "$output"
check_not_contains "the value of a secret is not shown" "secret-token-value" "$output"
check_contains "a changed version is shown" '+DEVICE_VERSION: "9.9-local"' "$output"
check_contains "a changed option of Appium is shown" "+APPIUM_RELAXED_SECURITY: true" "$output"
check_not_contains "a value the deploy has already is not shown" "STF_PROVIDER_NAME" "$output"
check_not_contains "an unchanged image is not shown" "DEVICE_IMAGE" "$output"
check_contains "the devices are shown" "+  - id: OLD1" "$output"
check "a declined migration changes nothing" "same" "$(cmp -s "${AGENT}/config/settings.yml" "${AGENT}/config/settings.yml.original" && echo same)"
check "a declined migration keeps the files of an earlier version" "yes" "$([[ -f "${AGENT}/roles/devices/vars/main.yml" ]] && echo yes)"
output="$(OS=Linux zbr "y\n" migrate)"
check_contains "the migration writes the settings" "Written: config/settings.yml" "$output"
check "the setting is migrated" 'PUBLIC_IP: "old.example.com"' "$(grep '^PUBLIC_IP:' "${AGENT}/config/settings.yml")"
check "the version is migrated" 'DEVICE_VERSION: "9.9-local"' "$(grep '^DEVICE_VERSION:' "${AGENT}/config/settings.yml")"
check "the migrated settings are private" "600" "$(stat -c '%a' "${AGENT}/config/settings.yml" 2> /dev/null || stat -f '%Lp' "${AGENT}/config/settings.yml")"
check "the previous settings are kept" "same" "$(cmp -s "${AGENT}/config/settings.yml.bak" "${AGENT}/config/settings.yml.original" && echo same)"
check_contains "the devices are migrated with their comments" "  # the phone on the desk
  - id: OLD1" "$(cat "${AGENT}/config/devices.yml")"
check_not_contains "the example devices are replaced" "R28M1384YQY" "$(cat "${AGENT}/config/devices.yml")"
check "the settings of an earlier version are renamed" "no yes" \
  "$([[ -f "${AGENT}/roles/devices/vars/main.yml" ]] && echo yes || echo no) $([[ -f "${AGENT}/roles/devices/vars/main.yml.migrated" ]] && echo yes)"
check "the defaults of an earlier version are renamed" "yes" "$([[ -f "${AGENT}/defaults/main.yml.migrated" ]] && echo yes)"
check_contains "a second migration has nothing to do" "nothing to migrate" "$(OS=Linux zbr "" migrate)"
mkdir -p "${WORK}/old-backup"
printf 'PUBLIC_IP: backup.example.com\n' > "${WORK}/old-backup/main.yml"
OS=Linux zbr "y\n" migrate "${WORK}/old-backup/main.yml" > /dev/null
check "a file given is migrated" 'PUBLIC_IP: "backup.example.com"' "$(grep '^PUBLIC_IP:' "${AGENT}/config/settings.yml")"
check "a file given is not renamed" "yes" "$([[ -f "${WORK}/old-backup/main.yml" ]] && echo yes)"
rm -rf "${AGENT}/roles/devices/vars" "${AGENT}/defaults" "${AGENT}/config/"*.bak
mv "${WORK}/settings.saved" "${AGENT}/config/settings.yml"
mv "${WORK}/devices.saved" "${AGENT}/config/devices.yml"

section "autostart"
# systemctl: is-enabled answers by ${WORK}/autostart_on, the other calls are recorded
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub systemctl '(IFS="|"; echo "systemctl|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "is-enabled" ]] && { [[ -f "${STUB_DIR}/autostart_on" ]]; exit; }
exit 0'
reset_calls
check_contains "Linux: autostart is off by default" "Autostart is off (by default)" "$(OS=Linux zbr "" autostart)"
check "Linux: the status adds nothing" "" "$(calls sudo)"
output="$(OS=Linux zbr "n\n" autostart enable)"
check_contains "Linux: enable tells the unit" "creates /etc/systemd/system/mcloud-farm.service (mode 644)" "$output"
check_contains "Linux: enable shows the content of the unit" "ExecStart=/usr/local/bin/zebrunner-farm start --quiet" "$output"
check_contains "Linux: enable tells nothing starts now" "it runs at the next boot, nothing starts now" "$(unwrapped "$output")"
check "Linux: a declined enable changes nothing" "" "$(calls sudo)"
OS=Linux zbr "y\n" autostart enable > /dev/null
check "Linux: enable creates and enables the unit with sudo" "tee|/etc/systemd/system/mcloud-farm.service
chmod|644|/etc/systemd/system/mcloud-farm.service
systemctl|daemon-reload
systemctl|enable|mcloud-farm.service" "$(calls sudo)"
touch "${WORK}/autostart_on"
check_contains "Linux: the status of the enabled autostart" "Autostart is on: /etc/systemd/system/mcloud-farm.service" "$(OS=Linux zbr "" autostart)"
check_contains "Linux: status of the agent shows the autostart" "/etc/systemd/system/mcloud-farm.service" "$(OS=Linux zbr "" status)"
reset_calls
OS=Linux zbr "n\n" autostart disable > /dev/null
check "Linux: a declined disable changes nothing" "" "$(calls sudo)"
OS=Linux zbr "y\n" autostart disable > /dev/null
check "Linux: disable removes the unit with sudo" "systemctl|disable|mcloud-farm.service
rm|-f|/etc/systemd/system/mcloud-farm.service
systemctl|daemon-reload" "$(calls sudo)"
rm -f "${WORK}/autostart_on"

plist="${WORK}/home/Library/LaunchAgents/ZebrunnerFarmStart.plist"
output="$(OS=Darwin zbr "n\n" autostart enable)"
check_contains "macOS: enable tells the launch agent" "It creates ${plist}: a launch agent" "$(unwrapped "$output")"
check_contains "macOS: enable shows its content" "exec /usr/local/bin/zebrunner-farm start --quiet" "$output"
check "macOS: a declined enable creates nothing" "no" "$([[ -f "$plist" ]] && echo yes || echo no)"
reset_calls
OS=Darwin zbr "y\n" autostart enable > /dev/null
check "macOS: enable creates the launch agent" "yes" "$([[ -f "$plist" ]] && echo yes)"
check "macOS: the launch agent is valid XML" "ok" "$(python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb")); print("ok")' "$plist" 2>&1)"
check_contains "macOS: the launch agent logs into the agent dir" "${AGENT}/logs/autostart.log" "$(cat "$plist")"
check_contains "macOS: the launch agent waits for the WireGuard tunnel when it is on" \
  "/usr/local/bin/zebrunner-farm __tunnel-ready &amp;&amp; exec /usr/local/bin/zebrunner-farm start --quiet" "$(cat "$plist")"
check "macOS: enable needs no sudo and loads nothing now" "" "$(calls sudo)$(calls launchctl)"
check_contains "macOS: the status of the enabled autostart" "Autostart is on: ${plist}" "$(OS=Darwin zbr "" autostart)"
OS=Darwin zbr "y\n" autostart disable > /dev/null
check "macOS: disable removes the launch agent" "no" "$([[ -f "$plist" ]] && echo yes || echo no)"
check_contains "macOS: disable unloads it" "bootout|" "$(calls launchctl)"
check_contains "an unknown action shows the usage" "> ./zebrunner.sh autostart [status|enable|disable]" "$(zbr "" autostart on)"
OS=Darwin zbr "y\n" autostart enable > /dev/null

section "shutdown"
for profile in .bashrc .zshrc; do
  echo "export ZEBRUNNER_MCLOUD_AGENT_DIR=${AGENT}" > "${WORK}/home/${profile}"
done
output="$(OS=Darwin zbr "n\n" shutdown)"
check_contains "declined shutdown is cancelled" "Shutdown cancelled" "$output"
check "declined shutdown keeps the variable" "1" "$(exports .zshrc)"
check "declined shutdown keeps the launch agents" "yes" "$([[ -f "${WORK}/home/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" ]] && echo yes)"

reset_calls
mkdir -p "${WORK}/home/.ssh" "${AGENT}/ssh"
printf 'ssh-ed25519 AAAA other@host\nrestrict ssh-ed25519 BBBB zebrunner-mcloud-simulators\n' > "${WORK}/home/.ssh/authorized_keys"
touch "${AGENT}/ssh/id_ed25519" "${AGENT}/ssh/id_ed25519.pub"
touch "${WORK}/home/Library/LaunchAgents/ZebrunnerWirelessWatchdog.plist"
OS=Darwin zbr "y\n" shutdown > /dev/null
check "macOS: the ssh key of the simulators is unauthorized, the other keys are kept" "ssh-ed25519 AAAA other@host" \
  "$(cat "${WORK}/home/.ssh/authorized_keys")"
check "macOS: the ssh key of the simulators is removed" "no" "$([[ -e "${AGENT}/ssh" ]] && echo yes || echo no)"
check "macOS: launch agents are unloaded: the listener, usbmuxd, the wireless watchdog and the autostart" "4" \
  "$(calls launchctl | grep -c '^bootout|')"
check "macOS: launch agents are removed" "0" "$(find "${WORK}/home/Library/LaunchAgents" -name '*.plist' | wc -l | tr -d ' ')"
check "macOS: the variable is removed from the profiles" "0 0" "$(exports .bashrc) $(exports .zshrc)"
check "macOS: containers are removed" "down" "$(calls zebrunner-farm)"
check "macOS: the volumes of the agent are removed, the others are kept" "volume|rm|appium-storage-volume
volume|rm|device-iPhone-0001-lockdown
volume|rm|device-Old-0002
volume|rm|devimages_cache
volume|rm|mcloud-key-volume" "$(calls docker | grep '^volume|rm|')"
check "macOS: deployed files are removed" "rm|-vf|/usr/local/bin/zebrunner-device-listener
rm|-vf|/usr/local/bin/usbmuxd_watch
rm|-vf|/etc/newsyslog.d/zebrunner-mcloud.conf
rm|-vf|/usr/local/bin/zebrunner-farm
rm|-vf|/usr/local/lib/zebrunner-farm/utility.sh|/usr/local/lib/zebrunner-farm/ui.sh
rm|-vf|/usr/local/etc/zebrunner-farm.env
rm|-vf|/usr/local/bin/mcloud-devices.txt" "$(calls sudo | grep '^rm|')"
check "macOS: no udev and systemd" "" "$(calls sudo | grep -E '^(udevadm|systemctl)\|')"
check "macOS: the autostart is removed" "no" "$([[ -f "${WORK}/home/Library/LaunchAgents/ZebrunnerFarmStart.plist" ]] && echo yes || echo no)"
check "macOS: settings are removed" "no no" \
  "$([[ -f "${AGENT}/config/settings.yml" ]] && echo yes || echo no) $([[ -f "${AGENT}/config/devices.yml" ]] && echo yes || echo no)"
touch "${AGENT}/config/settings.yml" "${AGENT}/config/devices.yml"

reset_calls
OS=Linux zbr "y\n" shutdown > /dev/null
check "Linux: no launch agents" "" "$(calls launchctl)"
check "Linux: the pair records of the iOS devices are removed" "volume|rm|device-iPhone-0001-lockdown" \
  "$(calls docker | grep '^volume|rm|device-iPhone')"
check "Linux: udev rules and deployed files are removed" "rm|-vf|/etc/udev/rules.d/90_mcloud.rules
rm|-vf|/etc/systemd/system/mcloud-wireless-watchdog.timer|/etc/systemd/system/mcloud-wireless-watchdog.service
rm|-vf|/etc/systemd/system/mcloud-device-restart@.service
rm|-vf|/etc/systemd/system/mcloud-device-down@.service
rm|-vf|/etc/bash_completion.d/zebrunner-farm
rm|-vf|/usr/local/bin/zebrunner-farm
rm|-vf|/usr/local/lib/zebrunner-farm/utility.sh|/usr/local/lib/zebrunner-farm/ui.sh
rm|-vf|/usr/local/etc/zebrunner-farm.env
rm|-vf|/usr/local/bin/mcloud-devices.txt" "$(calls sudo | grep '^rm|')"
check "Linux: udev and systemd forget the removed rules and units" "udevadm|control|--reload
systemctl|daemon-reload" "$(calls sudo | grep -E '^(udevadm|systemctl)\|')"
check "Linux: settings are removed" "no no" \
  "$([[ -f "${AGENT}/config/settings.yml" ]] && echo yes || echo no) $([[ -f "${AGENT}/config/devices.yml" ]] && echo yes || echo no)"

touch "${AGENT}/config/settings.yml" "${AGENT}/config/devices.yml"
reset_calls
output="$(FAKE_VOLUMES="other-volume" OS=Linux zbr "y\n" shutdown)"
check_contains "no volume of the agent is reported" "No MCloud Agent volumes found" "$output"
check "no volume of the agent: nothing is removed" "" "$(calls docker | grep '^volume|rm|')"
check_contains "the confirmation tells that the devices trust the host again" "the devices ask to trust it again after a new setup" "$output"

finish
