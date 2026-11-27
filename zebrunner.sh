#!/bin/bash

#### Completion

# The commands of echo_help, of the completion and of the hint of an unknown command
COMMANDS="setup join migrate ansible status doctor autostart mdm version backup restore shutdown help completion"
# The groups of devices of zebrunner-farm and of ./zebrunner.sh mdm
DEVICE_GROUPS="ios android usb wireless android-sim ios-sim proxy"

# complete_devices: the udids and the names of the devices, one per line: the deployed list of zebrunner-farm (the
# one ./zebrunner.sh mdm selects from), else config/devices.yml; read only, nothing when there is none
complete_devices() {
  local dir list
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
  list="$(sed -n 's/^MCLOUD_DEVICES=//p' "${ZEBRUNNER_FARM_ENV:-/usr/local/etc/zebrunner-farm.env}" 2> /dev/null | tail -n 1)"
  list="${list//\'/}"
  list="${list//\"/}"
  list="${list:-/usr/local/bin/mcloud-devices.txt}"
  if [[ -r "$list" ]] && grep -Eq '(^|[|])id=' "$list"; then
    grep -v '^#' "$list" | tr '|' '\n' | sed -nE 's/^(id|name)=(.+)$/\2/p' | sort -u
    return 0
  fi
  [[ -r "${dir}/config/devices.yml" ]] || return 0
  # the block and the flow style of YAML: a field per line, the comments and the quotes away, the spaces of a name
  # are '_' as in the deployed list; tr: each of the characters of a flow mapping is a newline
  # shellcheck disable=SC2020
  sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' "${dir}/config/devices.yml" | tr '{},' '\n\n\n' |
    sed -nE 's/^[[:space:]]*(-[[:space:]]+)?(id|name):[[:space:]]*//p' | tr -d "\"'" |
    sed -e 's/[[:space:]]*$//' -e 's/[[:space:]]\{1,\}/_/g' | grep -v '^$' | sort -u
}

# complete_words <index> <words...>: the candidates of the word <index> of the command line, one per line
# (CONVENTIONS.md#completion): no docker, no network, no file written, no question
complete_words() {
  local index="$1"
  shift
  [[ "$index" =~ ^[1-9][0-9]{0,2}$ ]] || return 0
  local words=("$@")
  local current="${words[$((index - 1))]:-}"
  if [[ "$index" -eq 1 ]]; then
    # the words of the list
    # shellcheck disable=SC2086
    printf '%s\n' $COMMANDS --help -h
    return 0
  fi
  local command="${words[0]}"
  case "$command" in
  ansible)
    if [[ "$current" == -* ]]; then
      printf '%s\n' --help --check --diff --tags --skip-tags --limit --extra-vars --list-tasks --list-tags \
        --syntax-check --step --start-at-task -v -vv -vvv -vvvv
    elif [[ "$index" -eq 2 ]]; then
      echo devices
    fi
    ;;
  autostart)
    if [[ "$current" == -* ]]; then
      echo --help
    elif [[ "$index" -eq 2 ]]; then
      printf '%s\n' status enable disable
    fi
    ;;
  mdm)
    if [[ "$index" -eq 2 ]]; then
      if [[ "$current" == -* ]]; then
        echo --help
      else
        printf '%s\n' status enroll release supervise
      fi
    elif [[ "$current" == -* ]]; then
      printf '%s\n' --help -x --exclude -y --yes -q --quiet
      case "${words[1]}" in
      release) echo --uninstall ;;
      supervise) echo --force ;;
      esac
    else
      # the devices to select, also after -x: the words of the list
      # shellcheck disable=SC2086
      printf '%s\n' $DEVICE_GROUPS
      complete_devices
    fi
    ;;
  help)
    if [[ "$index" -eq 2 ]]; then
      # the words of the list
      # shellcheck disable=SC2086
      printf '%s\n' $COMMANDS
    fi
    ;;
  completion)
    if [[ "$current" == -* ]]; then
      echo --help
    elif [[ "$index" -eq 2 ]]; then
      printf '%s\n' bash zsh
    fi
    ;;
  *)
    # migrate: the files (nothing here, the completion of the shell offers them), the other commands: no argument
    if [[ "$current" == -* ]]; then
      echo --help
    fi
    ;;
  esac
}

# the completion answers before anything else runs: no cd, no sourced file, no check, nothing on stderr
if [[ "${1:-}" == "__complete" ]]; then
  complete_words "${@:2}" 2> /dev/null
  exit 0
fi

#### Setup

# The folder of the agent: the one of this script, whatever the current folder and the environment are; the deploy
# renders it into the settings of zebrunner-farm (README.md#settings)
MCLOUD_AGENT_DIR_NAME="ZEBRUNNER_MCLOUD_AGENT_DIR"
MCLOUD_AGENT_DIR_VALUE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ZEBRUNNER_MCLOUD_AGENT_DIR="$MCLOUD_AGENT_DIR_VALUE"
cd "${MCLOUD_AGENT_DIR_VALUE}" || exit

# The settings of this host and its devices (README.md#settings)
SETTINGS_FILE="config/settings.yml"
DEVICES_FILE="config/devices.yml"

# Load utility functions
source "${MCLOUD_AGENT_DIR_VALUE}/patch/utility.sh"
# Load the terminal output: the banner, the sections, the statuses, the prompts (CONVENTIONS.md#terminal-output)
# shellcheck source=patch/ui.sh
source "${MCLOUD_AGENT_DIR_VALUE}/patch/ui.sh"
# Load backup/restore functions
source "${MCLOUD_AGENT_DIR_VALUE}/patch/backup.sh"
# Load the checks of `./zebrunner.sh doctor`
source "${MCLOUD_AGENT_DIR_VALUE}/patch/doctor.sh"

# host_addresses: the IPv4 addresses of this host but the loopback and docker ones, separated by spaces
host_addresses() {
  if [[ "$(uname)" == "Darwin" ]]; then
    ifconfig 2> /dev/null | awk '$1 == "inet" && $2 != "127.0.0.1" { print $2 }'
  else
    ip -4 -o addr show scope global 2> /dev/null | awk '$2 !~ /^(docker|br-|veth)/ { sub(/\/.*/, "", $4); print $4 }'
  fi | paste -s -d ' ' -
}

# running_device_containers: the names of the running containers of the devices, one per line
running_device_containers() {
  docker ps --filter name=device- --format '{{.Names}}' 2> /dev/null | grep -E -- '-(connector|stf|appium|uploader)$'
}

# mdm <status|enroll|release|supervise> [devices...] [options]: the devices of this host in the MDM of its MCloud
# (patch/mdm.sh, README.md#mdm): the preparation of a device for the farm; zebrunner-farm keeps the work of the devices
mdm() {
  # the functions of zebrunner-farm: its settings (the env file of ./zebrunner.sh ansible), the selection of the
  # devices and their containers
  # shellcheck source=roles/common/files/zebrunner-farm
  source "${MCLOUD_AGENT_DIR_VALUE}/roles/common/files/zebrunner-farm" || return 1
  # shellcheck source=patch/mdm.sh
  source "${MCLOUD_AGENT_DIR_VALUE}/patch/mdm.sh"
  mdm_main "$@"
}

# setup: the settings of config/ from the examples (README.md#clone-and-setup), then the next steps
setup() {
  ui_banner "MCloud Agent"
  ui_info "MCloud Agent directory: ${MCLOUD_AGENT_DIR_VALUE}"

  ### The variable of the earlier versions in the shell profiles is not used anymore
  remove_profile_variable

  ### Create the settings of config/ according to OS
  ui_section "Settings of config/"
  os="$(uname)"
  ui_info "Current OS: ${os}"
  local vars="$SETTINGS_FILE"
  local devices="$DEVICES_FILE"
  local devices_example
  case "$os" in
  Linux) devices_example="config/devices.yml.original" ;;
  Darwin) devices_example="config/mac-devices.yml.original" ;;
  *)
    ui_fail "Unknown OS. Supported OS are Linux and macOS."
    exit 1
    ;;
  esac
  setup_file "${vars}.original" "$vars"
  setup_file "$devices_example" "$devices"
  local legacy
  legacy="$(legacy_settings_file)"
  if [[ -f "$legacy" ]]; then
    echo_warning "'${legacy}' of an earlier version overrides 'config/': ./zebrunner.sh migrate moves its settings to '${vars}' and its devices: to '${devices}' (README.md#settings)."
  fi

  ### Rosetta 2 of an Apple Silicon Mac
  if [[ "$os" == "Darwin" && "$(rosetta_state)" != "intel" ]]; then
    ui_section "Rosetta 2"
    rosetta_report
  fi

  ### Next steps
  ui_section "Next steps"
  local addresses
  addresses="$(host_addresses)"
  ui_muted "https://github.com/zebrunner/mcloud-agent#node-enrollment"
  echo ""
  ui_step 1 "The administrator of MCloud invites this host on its server: ./zebrunner.sh node-invite <label> <address>, the address is the one the MCloud server connects to: the addresses of this host are ${addresses:-unknown}; in the network of the MCloud server the address there (on the MCloud server itself its LAN address, not 127.0.0.1)."
  ui_step 2 "Enroll this host: ./zebrunner.sh join and paste the join string of step 1. It writes the connection to MCloud into '${vars}'."
  ui_step 3 "Declare the devices in 'devices:' of '${devices}': the udid (adb devices, idevice_id -l), a unique name and unique ports."
  ui_step 4 "Check the settings, the enrollment and the network to MCloud: ./zebrunner.sh doctor"
  ui_step 5 "Deploy the agent: ./zebrunner.sh ansible"
  ui_step 6 "Start the devices: zebrunner-farm start, then zebrunner-farm status and ./zebrunner.sh doctor. zebrunner-farm knows this folder: zebrunner-farm ansible deploys again from any folder."

  ui_rule
  ui_ok "Setting up MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished successfully"
}

# ansible [devices] [ansible-playbook arguments...]: deploys the agent (README.md#run-ansible-playbook); devices skips the
# download of the images and keeps the running containers of the devices
ansible() {
  ui_section "Deploy" "" "Deploying MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  ### Check if the operating system is Linux or macOS: agent.yml deploys the role of the OS
  file="${ZEBRUNNER_MCLOUD_AGENT_DIR}/agent.yml"
  if [[ "$(uname)" == "Linux" ]]; then
    ui_info "Operating system is Linux"
  elif [[ "$(uname)" == "Darwin" ]]; then
    ui_info "Operating system is macOS"
  else
    ui_callout error "This script is not running on a Linux or macOS system. Run ansible manually."
    exit 1
  fi

  ### Make a list of arguments
  # deploy: the run changes the deployment, the running containers of the devices keep the old one
  local deploy="true"
  local -a tags=()
  if [[ "$1" == "devices" ]]; then
    deploy=""
    tags=(--tag registerDevices)
    shift
  fi
  local -a args=("$@" "$file" "${tags[@]+"${tags[@]}"}")
  local arg
  for arg in "$@"; do
    case "$arg" in
    --check | -C | --syntax-check | --list-tasks | --list-tags | --list-hosts) deploy="" ;;
    esac
  done

  ### sudo-rs (the sudo of Ubuntu 25.10+) wraps the password prompt, ansible does not recognize it and times out
  if [[ "$(uname)" == "Linux" && "$*" != *ansible_become_exe* ]] && sudo --version 2> /dev/null | grep -q '^sudo-rs'; then
    if command -v sudo.ws > /dev/null 2>&1; then
      ui_info "sudo is sudo-rs: ansible becomes root with sudo.ws, the original sudo"
      args=(--extra-vars ansible_become_exe=sudo.ws "${args[@]}")
    else
      echo_warning "sudo is sudo-rs, whose password prompt ansible does not recognize: install the original sudo (sudo apt install sudo), it provides sudo.ws."
    fi
  fi

  ### The running containers of the devices keep the old settings and images
  if [[ -n "$deploy" ]]; then
    stop_running_devices
  fi

  ### Run ansible with arguments
  echo_warning "Sudo permissions are required to run this script!"
  echo ""
  ui_muted "ansible-playbook --ask-become-pass --inventory hosts ${args[*]}"
  ui_rule
  ansible-playbook --ask-become-pass --inventory hosts "${args[@]}" || {
    ui_callout error "Ansible playbook execution failed!"
    echo_telegram
    exit 1
  }

  ui_rule
  if [[ -n "$deploy" ]]; then
    ui_info "Run 'zebrunner-farm start' to create the containers of the connected devices."
  fi
  ui_ok "Deploying MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished successfully"
}

# stop_running_devices: asks to stop and remove the running containers of the devices before the deploy: they keep the
# settings and the images they were created with, zebrunner-farm start creates them again with the new ones
stop_running_devices() {
  local containers
  containers="$(running_device_containers)"
  [[ -n "$containers" ]] || return 0
  echo_warning "$(grep -c . <<< "$containers") containers of the devices are running: they keep the settings and the images they were created with: stop and remove them before the deploy, then 'zebrunner-farm start' creates them with the new ones."
  echo ""
  local device
  while IFS= read -r device; do
    ui_muted "  ${device}"
  done <<< "$(sed -E 's/-(connector|stf|appium|uploader)$//' <<< "$containers" | sort -u)"
  echo ""
  if confirm "" "Stop and remove them now (zebrunner-farm down)?" "y"; then
    if command -v zebrunner-farm > /dev/null 2>&1; then
      # no terminal for zebrunner-farm: it asks nothing, also the earlier versions without --quiet
      zebrunner-farm down < /dev/null
    else
      # the names of the containers are words
      # shellcheck disable=SC2086
      ui_spin "Removing the containers of the devices" docker rm -f $containers
    fi
  else
    ui_info "The containers keep running: run 'zebrunner-farm restart' after the deploy."
  fi
}

# remove_profile_variable: the ZEBRUNNER_MCLOUD_AGENT_DIR line of the earlier versions removed from the shell profiles:
# zebrunner.sh knows its folder and zebrunner-farm has it in its settings
remove_profile_variable() {
  local file
  for file in "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.zshrc" "${HOME}/.zprofile" "${HOME}/.profile"; do
    if [[ -f "$file" ]] && grep -q "^export ${MCLOUD_AGENT_DIR_NAME}=" "$file"; then
      ui_info "Removing the variable ${MCLOUD_AGENT_DIR_NAME} of an earlier version from ${file}"
      sed -i.bak "/^export ${MCLOUD_AGENT_DIR_NAME}=.*/d" "$file" && rm -f "${file}.bak"
    fi
  done
}

# remove_simulators_ssh_key: the ssh key of the iOS simulators (the mac-devices role) and its line of
# ~/.ssh/authorized_keys removed (the earlier versions and SIMULATOR_USER of the user of the deploy), the authorized keys
# of the user of the simulators (of root, sudo) too; that user and its simulators are kept
remove_simulators_ssh_key() {
  local keys="${HOME}/.ssh/authorized_keys"
  if [[ -f "$keys" ]] && grep -q "zebrunner-mcloud-simulators$" "$keys"; then
    ui_info "Removing the ssh key of the simulators from ${keys}"
    sed -i.bak "/zebrunner-mcloud-simulators$/d" "$keys" && rm -f "${keys}.bak"
  fi
  local user
  user="$(sed -n 's/^HOST_SSH_USER=//p' "${ZEBRUNNER_FARM_ENV:-/usr/local/etc/zebrunner-farm.env}" 2> /dev/null | tr -d "'")"
  if [[ "$user" =~ ^[a-z_][a-z0-9_.-]*$ && "$user" != "$(whoami)" && "$user" != root ]]; then
    keys="/Users/${user}/.ssh/authorized_keys"
    if sudo grep -q "zebrunner-mcloud-simulators$" "$keys" 2> /dev/null; then
      ui_info "Removing the ssh key of the simulators from ${keys}"
      sudo rm -f "$keys"
    fi
    if id -u "$user" > /dev/null 2>&1; then
      ui_info "The user ${user} of the simulators and its simulators are kept: sudo sysadminctl -deleteUser ${user} removes them"
    fi
  fi
  if [[ -d "${ZEBRUNNER_MCLOUD_AGENT_DIR}/ssh" ]]; then
    rm -rvf "${ZEBRUNNER_MCLOUD_AGENT_DIR}/ssh"
  fi
}

# setup_file <example> <file>: the file made from the example (private: the settings have secrets), a backup <file>.bak
# of an existing one
setup_file() {
  (
    umask 077
    if [[ -f "$2" ]]; then
      ui_info "'$2' already exists, making a backup '$2.bak'"
      cp "$2" "$2.bak"
    else
      cp "$1" "$2" && ui_ok "Creating '$2'"
    fi
  )
}

# legacy_settings_file: roles/.../vars/main.yml of the OS, the settings of an earlier version: they override config/
legacy_settings_file() {
  case "$(uname)" in
  Darwin) echo "roles/mac-devices/vars/main.yml" ;;
  *) echo "roles/devices/vars/main.yml" ;;
  esac
}

# settings_file: config/settings.yml, fails when it does not exist
settings_file() {
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    ui_callout error "'${SETTINGS_FILE}' does not exist, run './zebrunner.sh setup' first." >&2
    return 1
  fi
  echo "$SETTINGS_FILE"
}

# ensure_curve_key <settings file> <python with PyYAML>: STF_ZMQ_CURVE_SECRET_KEY of the settings made when it is
# empty, its public key in CURVE_PUBLIC_KEY
ensure_curve_key() {
  local vars="$1"
  local python="$2"
  local settings
  local secret
  CURVE_PUBLIC_KEY=""
  settings="$("$python" patch/settings.py dump "$vars")" || return 1
  secret="$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY=//p' <<< "$settings")"
  if [[ -z "$secret" ]]; then
    secret="$(python3 patch/curve_keygen.py | sed -n 's/^secret=//p')"
    if [[ ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
      ui_callout error "Unable to make the key with python3 patch/curve_keygen.py."
      return 1
    fi
    # the secret key on stdin: the arguments of a process are visible to every user (printf is a builtin)
    printf 'STF_ZMQ_CURVE_SECRET_KEY=%s\n' "$secret" | "$python" patch/settings.py set "$vars" - || return 1
    ui_ok "The key of this host is written to STF_ZMQ_CURVE_SECRET_KEY of '${vars}'."
  fi
  if ! CURVE_PUBLIC_KEY="$(printf '%s\n' "$secret" | python3 patch/curve_keygen.py - | sed -n 's/^public=//p')" ||
    [[ -z "$CURVE_PUBLIC_KEY" ]]; then
    ui_callout error "STF_ZMQ_CURVE_SECRET_KEY of '${vars}' is not a key of 64 hex characters."
    return 1
  fi
}

# join: enrolls this host in MCloud with the join string of `./zebrunner.sh node-invite` of mcloud, read from a hidden
# prompt or stdin (README.md#node-enrollment): the token of this host and the settings of MCloud go to the settings
join() {
  ui_banner "MCloud Agent"
  ui_section "Join MCloud"
  local vars
  vars="$(settings_file)" || exit 1
  if ! command -v python3 > /dev/null 2>&1 || ! command -v curl > /dev/null 2>&1; then
    ui_callout error "The enrollment needs python3 and curl."
    exit 1
  fi
  local python
  if ! python="$(yaml_python)"; then
    ui_callout error "The enrollment needs a python3 with PyYAML: the one of ansible has it (README.md#software-prerequisites)."
    exit 1
  fi
  ensure_curve_key "$vars" "$python" || exit 1
  "$python" patch/enroll.py "$vars" "$CURVE_PUBLIC_KEY" || exit 1
  ui_section "Next steps"
  ui_info "Next: ./zebrunner.sh doctor checks the settings, ./zebrunner.sh ansible deploys them and zebrunner-farm restart recreates the containers of the devices with the token of this host."
}

# rosetta_state: Rosetta 2 of the Mac for the linux/amd64 image of appium: 'intel' (not
# needed), 'missing', 'docker-off' (installed, Docker Desktop does not use it) or 'ok'
rosetta_state() {
  local settings="${HOME}/Library/Group Containers/group.com.docker/settings-store.json"
  if [[ "$(sysctl -n hw.optional.arm64 2> /dev/null)" != "1" ]]; then
    echo "intel"
  elif ! arch -x86_64 /usr/bin/true > /dev/null 2>&1; then
    echo "missing"
  else
    # the settings of Docker Desktop 4.35+, settings.json of the earlier ones; without the setting it is on
    [[ -f "$settings" ]] || settings="${HOME}/Library/Group Containers/group.com.docker/settings.json"
    if [[ -f "$settings" ]] && grep -qiE '"useVirtualizationFrameworkRosetta" *: *false' "$settings"; then
      echo "docker-off"
    else
      echo "ok"
    fi
  fi
}

# rosetta_report: the state of Rosetta 2 and the advice when it is not used
rosetta_report() {
  local use="turn on 'Use Rosetta for x86_64/amd64 emulation on Apple Silicon' in Docker Desktop (Settings, General) and restart Docker Desktop"
  case "$(rosetta_state)" in
  ok)
    ui_ok "Rosetta 2 is installed: Docker Desktop runs the linux/amd64 image of appium with it."
    ;;
  missing)
    ui_warn "Rosetta 2 is not installed: Docker Desktop runs the linux/amd64 image of appium under the much slower QEMU emulation. Install it and let Docker Desktop use it:" \
      "softwareupdate --install-rosetta --agree-to-license, then ${use}."
    ;;
  docker-off)
    ui_warn "Rosetta 2 is installed, but Docker Desktop runs the linux/amd64 image of appium under the much slower QEMU emulation:" \
      "${use}."
    ;;
  esac
}

# status_line <label> <value> [<problem>]: a component of the status: ok with its value, FAIL with the problem when the
# value is empty
status_line() {
  if [[ -n "$2" ]]; then
    ui_ok "$(printf '%-32s %s' "$1" "$2")"
  else
    ui_fail "$(printf '%-32s %s' "$1" "$3")"
  fi
}

# status: the state of the components of the agent: the tools, the deployed files, the launch agents
status() {
  ui_section "Status" "" "Status of MCloud Agent components"
  ui_info "MCloud Agent directory: ${MCLOUD_AGENT_DIR_VALUE}"

  os="$(uname)" 2> /dev/null
  status_line "Current OS:" "$os" "OS not detected"
  status_line "Current user:" "$(whoami 2> /dev/null)" "username not detected"
  status_line "Docker version:" "$(docker --version 2> /dev/null)" "'docker' not found"
  status_line "Docker compose version:" "$(docker compose version 2> /dev/null)" "'docker compose' not found"
  status_line "Ansible-playbook info:" "$(ansible-playbook --version 2> /dev/null | head -n 1)" "'ansible-playbook' not found"
  status_line "Zebrunner-farm script:" "$(which zebrunner-farm 2> /dev/null)" "'zebrunner-farm' not found"
  if [[ "$os" == "Darwin" ]]; then
    status_line "Socat tool:" "$(which socat 2> /dev/null)" "'socat' not found"
    case "$(rosetta_state)" in
    ok) status_line "Rosetta 2:" "installed, used by Docker Desktop" ;;
    missing) status_line "Rosetta 2:" "" "not installed: softwareupdate --install-rosetta --agree-to-license" ;;
    docker-off) status_line "Rosetta 2:" "" "installed, not used by Docker Desktop (Settings, General)" ;;
    *) ui_info "$(printf '%-32s %s' "Rosetta 2:" "not needed (Intel Mac)")" ;;
    esac
    shopt -s nullglob nocaseglob
    plists=("${HOME}/Library/LaunchAgents"/*zebrunner*)
    shopt -u nullglob nocaseglob
    if ((${#plists[@]} == 0)); then
      ui_fail "No deployed Zebrunner plist files found"
    else
      for f in "${plists[@]}"; do
        status_line "Deployed launchctl file:" "$f"
      done
    fi
    local jobs job
    jobs="$(launchctl list | grep -i zebrunner)"
    if [[ -z "$jobs" ]]; then
      ui_fail "No loaded Zebrunner jobs found"
    else
      while IFS= read -r job; do
        status_line "Loaded launchctl job:" "$job"
      done <<< "$jobs"
    fi
  else
    status_line "90_mcloud.rules:" "$(ls /etc/udev/rules.d/90_mcloud.rules 2> /dev/null)" "File not found"
    status_line "mcloud-device-restart@.service:" "$(ls /etc/systemd/system/mcloud-device-restart@.service 2> /dev/null)" "File not found"
    status_line "mcloud-device-down@.service:" "$(ls /etc/systemd/system/mcloud-device-down@.service 2> /dev/null)" "File not found"
  fi
  status_line "mcloud-devices.txt:" "$(ls "/usr/local/bin/mcloud-devices.txt" 2> /dev/null)" "File not found"
  status_line "zebrunner-farm.env:" "$(ls "/usr/local/etc/zebrunner-farm.env" 2> /dev/null)" "File not found"
  if autostart_enabled; then
    status_line "Autostart after a reboot:" "$(autostart_file)"
  else
    ui_info "$(printf '%-32s %s' "Autostart after a reboot:" "off (./zebrunner.sh autostart)")"
  fi
  status_line "config/settings.yml:" "$(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/${SETTINGS_FILE}" 2> /dev/null)" "File not found"
  status_line "config/devices.yml:" "$(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/${DEVICES_FILE}" 2> /dev/null)" "File not found"
  status_line "ansible-playbook:" "$(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/agent.yml" 2> /dev/null)" "File not found"
  status_line "versions.yml:" "$(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/versions.yml" 2> /dev/null)" "File not found"

  echo ""
  ui_rule
}

# remove_wireguard: the WireGuard tunnel to MCloud of the deploy (README.md#wireguard-tunnel): stopped, its config and
# its launch daemon (macOS) or the settings of wg-quick@mcloud-node, the order of docker after it and the unit
# mcloud-wireguard-up (Linux) removed; wireguard-tools stays installed
remove_wireguard() {
  if [[ "$(uname)" == "Darwin" ]]; then
    [[ -f /Library/LaunchDaemons/com.zebrunner.wireguard.plist ]] || return 0
    ui_info "Removing the WireGuard tunnel to MCloud: the launch daemon com.zebrunner.wireguard"
    sudo launchctl bootout system/com.zebrunner.wireguard 2> /dev/null
    if [[ -e /var/run/wireguard/mcloud-node.name ]]; then
      sudo env PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}" wg-quick down /etc/wireguard/mcloud-node.conf
    fi
    sudo rm -vf /Library/LaunchDaemons/com.zebrunner.wireguard.plist /etc/wireguard/mcloud-node.conf
  else
    # the config is readable by root only, the settings of the unit mark the deploy
    [[ -e /etc/systemd/system/wg-quick@mcloud-node.service.d/zebrunner.conf ]] || return 0
    ui_info "Removing the WireGuard tunnel to MCloud: wg-quick@mcloud-node"
    sudo systemctl disable --now wg-quick@mcloud-node
    sudo rm -vrf /etc/wireguard/mcloud-node.conf /etc/systemd/system/wg-quick@mcloud-node.service.d \
      /etc/systemd/system/docker.service.d/zebrunner-wireguard.conf /etc/systemd/system/mcloud-wireguard-up.service
    sudo systemctl daemon-reload
  fi
}

# shutdown: removes the containers of the devices, the deployed files and the settings after a confirmation
shutdown() {
  ui_banner "MCloud Agent"
  ui_section "Shutdown"
  ui_info "Shutting down MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  ### Confirm shutdown
  echo_warning "Shutdown will erase all settings and data for '${ZEBRUNNER_MCLOUD_AGENT_DIR}'!"
  ui_info "Also the docker volumes of the agent: the pair records of the iOS devices and the adb key of this host, so the devices ask to trust it again after a new setup."
  echo ""
  confirm "" "Do you want to continue?" "n" || {
    ui_info "Shutdown cancelled"
    exit 0
  }

  ### Ask for sudo permissions
  echo ""
  ask_for_sudo || {
    ui_callout error "Sudo permissions are required to run this script!"
    exit 1
  }

  ### Remove launch agents in case of macOS
  os="$(uname)"
  if [[ "$os" == "Darwin" ]]; then
    ui_section "Launch agents"
    ui_info "Current OS: $os"

    shopt -s nullglob nocaseglob
    plists=("${HOME}/Library/LaunchAgents"/*zebrunner*)
    shopt -u nullglob nocaseglob
    if ((${#plists[@]} == 0)); then
      ui_info "No Zebrunner plist files found"
    else
      for f in "${plists[@]}"; do
        ui_info "Found Zebrunner launchctl file: $f"
      done
    fi

    local loaded line
    loaded="$(launchctl list | grep -i zebrunner)"
    if [[ -z "$loaded" ]]; then
      ui_info "No loaded Zebrunner plists found"
    else
      while IFS= read -r line; do
        ui_info "Found loaded Zebrunner plist: ${line}"
      done <<< "$loaded"
    fi

    local plist
    for plist in ZebrunnerDevicesListener ZebrunnerUsbmuxd ZebrunnerWirelessWatchdog; do
      if [[ -f "${HOME}/Library/LaunchAgents/${plist}.plist" ]]; then
        if launchctl bootout gui/"$(id -u)" "${HOME}/Library/LaunchAgents/${plist}.plist" 2> /dev/null; then
          ui_ok "${plist}.plist unloaded successfully"
        else
          ui_warn "Failed to unload '${plist}.plist', it might be not loaded"
        fi
        rm -f "${HOME}/Library/LaunchAgents/${plist}.plist" && ui_ok "Removing ${plist}.plist file"
      else
        ui_info "${plist}.plist file not found"
      fi
    done

    # the adb server of the USB Android devices, deployed for them only
    if [[ -f "${HOME}/Library/LaunchAgents/ZebrunnerAdb.plist" ]]; then
      launchctl bootout gui/"$(id -u)" "${HOME}/Library/LaunchAgents/ZebrunnerAdb.plist" 2> /dev/null ||
        ui_warn "Failed to unload 'ZebrunnerAdb.plist', it might be not loaded"
      rm -f "${HOME}/Library/LaunchAgents/ZebrunnerAdb.plist" && ui_ok "Unloading and removing ZebrunnerAdb.plist launchctl file"
    fi
  fi

  ### The variable of the earlier versions in the shell profiles
  remove_profile_variable

  ### The ssh key of the iOS simulators
  remove_simulators_ssh_key

  ### The autostart of the devices after a reboot
  if autostart_enabled || [[ -f "$(autostart_file)" ]]; then
    ui_info "Removing the autostart: $(autostart_file)"
    autostart_remove
  fi

  ### Stop and remove containers
  ui_section "Containers"
  ui_info "Found MCloud Agent containers:"
  local container
  while IFS= read -r container; do
    [[ -z "$container" ]] || ui_muted "  ${container}"
  done <<< "$(docker ps -a --filter "name=device-" --format "{{.Names}}")"

  ui_info "Stopping and removing MCloud Agent containers:"
  if command -v zebrunner-farm > /dev/null 2>&1; then
    # no terminal for zebrunner-farm: it asks nothing
    zebrunner-farm down < /dev/null
  else
    ui_fail "Can't find 'zebrunner-farm' executable file"
  fi

  ### Remove the volumes of the agent: the ones of the devices zebrunner-farm down did not remove (the pair records
  ### of the iOS devices, device-*-lockdown, and the logs of the devices removed from the settings), the cache of the
  ### Developer Disk Images, the adb key of the host (also the times of the reboots of the Android devices) and the
  ### storage of the earlier appium
  ui_section "Volumes"
  local volume
  local volumes=()
  while IFS= read -r volume; do
    case "$volume" in
    device-* | devimages_cache | mcloud-key-volume | appium-storage-volume) volumes+=("$volume") ;;
    esac
  done <<< "$(docker volume ls --format '{{.Name}}' 2> /dev/null)"
  if ((${#volumes[@]} == 0)); then
    ui_info "No MCloud Agent volumes found"
  fi
  for volume in "${volumes[@]+"${volumes[@]}"}"; do
    ui_spin "Removing volume '${volume}'" docker volume rm "$volume" ||
      ui_warn "Volume '${volume}' is not removed: a container still uses it (docker ps -a --filter volume=${volume})"
  done

  ### Remove files
  ui_section "Files"
  ui_info "Removing MCloud Agent files and volumes (sudo privileges required):"
  # the settings of an earlier version too
  rm -vf "$SETTINGS_FILE" "$DEVICES_FILE" "$(legacy_settings_file)"
  if [[ "$os" == "Darwin" ]]; then
    sudo rm -vf /usr/local/bin/zebrunner-device-listener
    sudo rm -vf /usr/local/bin/usbmuxd_watch
    sudo rm -vf /etc/newsyslog.d/zebrunner-mcloud.conf
    # the completion of zebrunner-farm in Homebrew, a folder of the user
    if command -v brew > /dev/null 2>&1; then
      rm -vf "$(brew --prefix)/etc/bash_completion.d/zebrunner-farm"
    fi
  else
    sudo rm -vf /etc/udev/rules.d/90_mcloud.rules
    # the wireless watchdog, deployed for the wireless devices only
    if [[ -f /etc/systemd/system/mcloud-wireless-watchdog.timer ]]; then
      sudo systemctl disable --now mcloud-wireless-watchdog.timer > /dev/null 2>&1 ||
        ui_warn "Failed to stop mcloud-wireless-watchdog.timer, it might be not running"
    fi
    sudo rm -vf /etc/systemd/system/mcloud-wireless-watchdog.timer /etc/systemd/system/mcloud-wireless-watchdog.service
    sudo rm -vf /etc/systemd/system/mcloud-device-restart@.service
    sudo rm -vf /etc/systemd/system/mcloud-device-down@.service
    sudo rm -vf /etc/bash_completion.d/zebrunner-farm
    # udev and systemd keep the removed rules and units until they reload them
    sudo udevadm control --reload
    sudo systemctl daemon-reload
  fi
  sudo rm -vf /usr/local/bin/zebrunner-farm
  # the scripts zebrunner-farm sources
  sudo rm -vf /usr/local/lib/zebrunner-farm/utility.sh /usr/local/lib/zebrunner-farm/ui.sh \
    /usr/local/lib/zebrunner-farm/usb_stats.py /usr/local/lib/zebrunner-farm/usb_map.py
  sudo rmdir /usr/local/lib/zebrunner-farm 2> /dev/null
  sudo rm -vf /usr/local/etc/zebrunner-farm.env
  sudo rm -vf /usr/local/bin/mcloud-devices.txt
  # after the containers: their ports are published on the address of the tunnel
  remove_wireguard

  ### Final message
  ui_callout note "Restart current terminal session to apply all changes"
  echo ""
  ui_rule
  ui_ok "Shutting down MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished"
}

# version: the versions of the images of versions.yml, a NAME: value line each on stdout (data read by people and
# scripts, e.g. zebrunner-farm version); the header and the footer go to stderr
version() {
  ui_section "Versions" "" "The images of the devices of '${ZEBRUNNER_MCLOUD_AGENT_DIR}' (versions.yml)" >&2
  grep -i "version" "${ZEBRUNNER_MCLOUD_AGENT_DIR}/versions.yml" | grep -v '^\s*#' || exit 1
  {
    echo ""
    ui_muted "A line of config/settings.yml overrides one (README.md#run-ansible-playbook)."
    ui_rule
  } >&2
}

# The containers of the devices after a reboot (README.md#autostart), off by default: the USB devices are started by
# udev (Linux) and the devices listener (iOS of macOS) anyway, autostart starts all the devices once
AUTOSTART_UNIT="/etc/systemd/system/mcloud-farm.service"
AUTOSTART_PLIST="${HOME}/Library/LaunchAgents/ZebrunnerFarmStart.plist"

# autostart_file: the file of the autostart of the OS
autostart_file() {
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "$AUTOSTART_PLIST"
  else
    echo "$AUTOSTART_UNIT"
  fi
}

# autostart_enabled: 0 when the autostart is on
autostart_enabled() {
  if [[ "$(uname)" == "Darwin" ]]; then
    [[ -f "$AUTOSTART_PLIST" ]]
  else
    systemctl is-enabled --quiet mcloud-farm.service 2> /dev/null
  fi
}

# autostart_unit: the systemd unit of Linux, run once after docker at the boot
autostart_unit() {
  cat << 'EOF'
# The containers of all the devices after a boot: ./zebrunner.sh autostart enable made it, disable removes it
# (README.md#autostart). The log: journalctl -u mcloud-farm
[Unit]
Description=MCloud: the containers of the devices after a boot
Wants=docker.service network-online.target
# the ports of the devices are published on the address of the WireGuard tunnel to MCloud when it is on
After=docker.service network-online.target wg-quick@mcloud-node.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zebrunner-farm start --quiet
# the images may be pulled
TimeoutStartSec=30min

[Install]
WantedBy=multi-user.target
EOF
}

# autostart_plist: the launch agent of macOS, run once at the login when Docker Desktop answers and the WireGuard tunnel to
# MCloud is up when it is on (README.md#wireguard-tunnel: the ports of the devices are published on its address), 10
# minutes at most
autostart_plist() {
  cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- The containers of all the devices at the login: ./zebrunner.sh autostart enable made it, disable removes it -->
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.zebrunner.mcloud.autostart</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/bin:/usr/bin:/usr/local/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>-c</string>
      <string>for i in \$(seq 1 120); do docker info &gt; /dev/null 2&gt;&amp;1 &amp;&amp; /usr/local/bin/zebrunner-farm __tunnel-ready &amp;&amp; exec /usr/local/bin/zebrunner-farm start --quiet; sleep 5; done; echo "Docker Desktop does not answer or the WireGuard tunnel to MCloud is down" &gt;&amp;2; exit 1</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${MCLOUD_AGENT_DIR_VALUE}/logs/autostart.log</string>
    <key>StandardErrorPath</key>
    <string>${MCLOUD_AGENT_DIR_VALUE}/logs/autostart.log</string>
  </dict>
</plist>
EOF
}

# autostart [status|enable|disable]: the state of the autostart; enable and disable tell what they change and ask
autostart() {
  ui_section "Autostart" "" "Autostart of the devices after a reboot"
  local file
  file="$(autostart_file)"
  case "${1:-status}" in
  status)
    if autostart_enabled; then
      ui_ok "Autostart is on: ${file}"
    else
      ui_info "Autostart is off (by default): ./zebrunner.sh autostart enable tells what it adds and asks first."
    fi
    ;;
  enable)
    if autostart_enabled; then
      ui_info "Autostart is on already: ${file}"
      echo ""
      ui_rule
      return 0
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
      ui_paragraph "It creates ${file}: a launch agent of $(id -un 2> /dev/null || echo "this user") loaded at the next login, nothing starts now. At the login it waits for Docker Desktop (10 minutes at most: let Docker Desktop start at the login, its Settings, General) and for the WireGuard tunnel to MCloud when it is on, and runs 'zebrunner-farm start --quiet' once: the containers of all the devices, also the Android, wireless, emulator and proxy ones the devices listener does not start. Its log: ${MCLOUD_AGENT_DIR_VALUE}/logs/autostart.log. No sudo is needed."
      ui_muted "The content of ${file}:"
      echo ""
      autostart_plist
    else
      if ! command -v systemctl > /dev/null 2>&1; then
        ui_callout error "The autostart of Linux is a systemd unit: this host has no systemctl."
        exit 1
      fi
      ui_paragraph "It runs with sudo:"
      ui_step 1 "creates ${file} (mode 644): a systemd unit that runs 'zebrunner-farm start --quiet' once after docker at the boot: the containers of all the devices, also the wireless, emulator and proxy ones udev does not start (udev starts the USB devices anyway). Its log: journalctl -u mcloud-farm"
      ui_step 2 "systemctl daemon-reload"
      ui_step 3 "systemctl enable mcloud-farm.service: it runs at the next boot, nothing starts now."
      ui_muted "The content of ${file}:"
      echo ""
      autostart_unit
    fi
    echo ""
    confirm "" "Enable the autostart as described above?" "n" || exit 0
    if [[ "$(uname)" == "Darwin" ]]; then
      mkdir -p "$(dirname "$file")"
      autostart_plist > "$file"
    else
      autostart_unit | sudo tee "$file" > /dev/null || exit 1
      sudo chmod 644 "$file"
      sudo systemctl daemon-reload
      sudo systemctl enable mcloud-farm.service || exit 1
    fi
    ui_ok "Autostart is on: ${file}"
    ;;
  disable)
    if ! autostart_enabled && [[ ! -f "$file" ]]; then
      ui_info "Autostart is off already."
      echo ""
      ui_rule
      return 0
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
      ui_paragraph "It unloads and removes ${file}: the containers of the devices are not started at the login anymore, the running ones keep running."
    else
      ui_paragraph "It runs with sudo: systemctl disable mcloud-farm.service, removes ${file}, systemctl daemon-reload: the containers of the devices are not started at the boot anymore, the running ones keep running."
    fi
    confirm "" "Disable the autostart as described above?" "n" || exit 0
    autostart_remove
    ui_ok "Autostart is off."
    ;;
  *)
    ui_usage "./zebrunner.sh autostart [status|enable|disable]"
    exit 1
    ;;
  esac
  echo ""
  ui_rule
}

# autostart_remove: the autostart of the OS removed
autostart_remove() {
  if [[ "$(uname)" == "Darwin" ]]; then
    launchctl bootout gui/"$(id -u)" "$AUTOSTART_PLIST" > /dev/null 2>&1
    rm -f "$AUTOSTART_PLIST"
  else
    sudo systemctl disable mcloud-farm.service > /dev/null 2>&1
    sudo rm -f "$AUTOSTART_UNIT"
    sudo systemctl daemon-reload
  fi
}

# migrate [file...]: the settings of an earlier version moved to config/ (README.md#settings): the files given (e.g.
# vars/main.yml of a backup) or the ones of an earlier version in this folder; it shows the changes and asks first
migrate() {
  ui_section "Migrate" "" "Moving the settings of an earlier version to config/"
  local python
  if ! python="$(yaml_python)"; then
    ui_callout error "The migration needs a python3 with PyYAML: the one of ansible has it (README.md#software-prerequisites)."
    exit 1
  fi
  local farm_os=linux
  [[ "$(uname)" == "Darwin" ]] && farm_os=macos
  local -a files=("$@")
  if [[ "$(count_values "${files[@]}")" -eq 0 ]]; then
    [[ -f "$(legacy_settings_file)" ]] && files+=("$(legacy_settings_file)")
    [[ -f defaults/main.yml ]] && files+=(defaults/main.yml)
  fi
  if [[ "$(count_values "${files[@]}")" -eq 0 ]]; then
    ui_info "No settings of an earlier version: nothing to migrate."
    echo ""
    ui_rule
    return 0
  fi
  ui_info "The settings of an earlier version: ${files[*]}"
  echo ""
  local rc=0
  "$python" patch/migrate.py plan "$farm_os" "${files[@]}" || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 3 ]] || exit 1
  echo ""
  confirm "" "Write these changes to config/ and rename the files of an earlier version to *.migrated?" "n" || exit 0
  "$python" patch/migrate.py apply "$farm_os" "${files[@]}" || exit 1
  ui_callout note "Check them with ./zebrunner.sh doctor, then deploy: ./zebrunner.sh ansible"
  echo ""
  ui_rule
}

#### Help

# command_args <command>: the arguments of the command in the help
command_args() {
  case "$1" in
  migrate) echo "[files...]" ;;
  ansible) echo "[devices] [args...]" ;;
  autostart) echo "[status|enable|disable]" ;;
  mdm) echo "<status|enroll|release|supervise> [devices...] [options]" ;;
  help) echo "[command]" ;;
  completion) echo "bash|zsh" ;;
  esac
}

# echo_help: the usage of zebrunner.sh, the commands by their stage
echo_help() {
  ui_banner "MCloud Agent"
  ui_usage "./zebrunner.sh <command> [options]"

  ui_help_group "Set up"
  ui_help_cmd setup "" "Prepare MCloud Agent environment"
  ui_help_cmd join "" "Enroll this host in MCloud with the join string of ./zebrunner.sh node-invite (stdin)"
  ui_help_cmd migrate "$(command_args migrate)" "Move the settings of an earlier version to config/ (shows the changes, asks first)"
  ui_help_cmd ansible "$(command_args ansible)" "Deploy MCloud Agent: devices without the download of the images, args of ansible-playbook"

  ui_help_group "Operate"
  ui_help_cmd status "" "Status of MCloud Agent deployment"
  ui_help_cmd doctor "" "Check the settings, the deployment and the network to MCloud, tell what to fix"
  ui_help_cmd autostart "$(command_args autostart)" "The containers of the devices after a reboot (off by default, asks first)"
  ui_help_cmd mdm "$(command_args mdm)" "The devices in the MDM of MCloud (README.md#mdm): status: what the MDM knows; enroll: the agent as the device owner (Android), the enrollment profile (supervised iOS); release [--uninstall]: out of the MDM; supervise [--force] [--yes]: ERASES an iOS device, supervises it, joins MDM_WIFI_SSID, enrolls it"
  ui_help_cmd version "" "Version of MCloud Agent components"

  ui_help_group "Maintain"
  ui_help_cmd backup "" "Backup MCloud Agent setup"
  ui_help_cmd restore "" "Restore MCloud Agent setup"
  ui_help_cmd shutdown "" "Stop and remove MCloud Agent containers, clear volumes and environment"

  ui_help_group "Help"
  ui_help_cmd help "$(command_args help)" "This list, or the usage and the options of a command (also <command> --help)"
  ui_help_cmd completion "$(command_args completion)" "The completion of the commands, the options and the devices in bash and zsh (README.md#completion)"

  echo_telegram
  echo ""
}

# help_text <text>: the description of a command wrapped to the width, without the empty line of ui_paragraph: the
# groups of its options start with one
help_text() {
  ui_hang "  " 2 "$1" "$UI_WIDTH"
}

# command_help <command>: the usage, the description and the options of the command; the command does not run
command_help() {
  local command="$1"
  local args
  args="$(command_args "$command")"
  ui_usage "./zebrunner.sh ${command}${args:+ ${args}}"
  printf '\n'
  local readme="agent-management"
  case "$command" in
  setup)
    help_text "Prepares MCloud Agent in this folder: config/settings.yml and config/devices.yml from the examples of the OS (an existing file is kept, a copy goes to *.bak), the variable ZEBRUNNER_MCLOUD_AGENT_DIR of an earlier version is removed from the shell profiles; then it tells the next steps."
    readme="clone-and-setup"
    ;;
  join)
    help_text "Enrolls this host in MCloud with the join string of ./zebrunner.sh node-invite of mcloud: read from a hidden prompt at a terminal or from stdin (./zebrunner.sh join < file), never from an argument. The token of this host and the settings of MCloud go to config/settings.yml."
    readme="node-enrollment"
    ;;
  migrate)
    help_text "Moves the settings of an earlier version to config/: the files given or, without them, roles/<role>/vars/main.yml and defaults/main.yml of this folder. It shows the changes (the secrets hidden) and asks first; the files of this folder are renamed to *.migrated."
    ui_help_group "Arguments"
    ui_help_cmd "files..." "" "The settings of an earlier version, e.g. vars/main.yml and defaults/main.yml of a backup"
    readme="settings"
    ;;
  ansible)
    help_text "Deploys MCloud Agent with ansible-playbook (it asks for the password of sudo): agent.yml with the settings of config/. The running containers of the devices keep their settings and images: it offers to remove them first, zebrunner-farm start creates them again."
    ui_help_group "Arguments"
    ui_help_cmd devices "" "The files and the devices only: no download of the images, the running containers are kept"
    ui_help_cmd "args..." "" "Arguments of ansible-playbook, e.g. --check --diff, --tags files, -vvv; --check, --syntax-check and --list-* change nothing"
    ui_help_cmd "-h, --help" "" "This help, the deploy does not run; the options of ansible-playbook: ansible-playbook --help"
    readme="run-ansible-playbook"
    ;;
  status)
    help_text "The state of the components of the agent: the tools, Rosetta 2 of an Apple Silicon Mac, the deployed files, the launch agents, the autostart and the settings. It changes nothing."
    ;;
  doctor)
    help_text "Checks the host, the settings, the enrollment in MCloud, the deployment, the network to MCloud, the devices and their USB (Linux), and tells what to fix. It changes nothing; it exits with 1 when a check fails. zebrunner-farm doctor runs it from any folder; zebrunner-farm doctor usb-stats and usb-map show the details of the USB checks."
    readme="doctor"
    ;;
  autostart)
    help_text "The containers of all the devices after a reboot, off by default: a systemd unit (Linux, with sudo) or a launch agent of the user (macOS). enable and disable tell what they change and ask first; nothing starts at once."
    ui_help_group "Actions"
    ui_help_cmd status "" "Whether the autostart is on (the default action)"
    ui_help_cmd enable "" "Adds the autostart: zebrunner-farm start --quiet once after the boot (Linux) or the login (macOS)"
    ui_help_cmd disable "" "Removes it, the running containers keep running"
    readme="autostart"
    ;;
  mdm)
    help_text "The devices of this host in the MDM of MCloud, the preparation of a device for the farm; it needs the enrollment of ./zebrunner.sh join. The devices are selected as by zebrunner-farm, a change shows them at a terminal and asks first."
    ui_help_group "Actions"
    ui_help_cmd status "" "What the MDM knows, the device is not touched; all the devices without devices"
    ui_help_cmd enroll "" "Android: the agent of the MDM as the device owner; iOS: the enrollment profile of a supervised device"
    ui_help_cmd release "" "Out of the MDM; --uninstall removes the Android agent too"
    ui_help_cmd supervise "" "ERASES an iOS device, supervises it, joins MDM_WIFI_SSID and enrolls it; it asks for the word erase"
    ui_help_group "Options"
    ui_help_cmd "devices..." "" "Udids, names, groups (ios, android, usb, wireless, android-sim, ios-sim, proxy) or patterns in quotes ('Samsung_*')"
    ui_help_cmd "-x" "<devices>" "Skips these devices (also -e, --exclude, -x=<devices>), may be repeated"
    ui_help_cmd "-y, --yes" "" "No question (also -q, --quiet): supervise needs it without a terminal"
    ui_help_cmd "--uninstall" "" "release: uninstalls the Android agent too"
    ui_help_cmd "--force" "" "supervise: erases a supervised device too"
    readme="mdm"
    ;;
  version)
    help_text "The versions of the images of the devices of versions.yml, a NAME: value line each on stdout (the header and the footer on stderr); a line of config/settings.yml overrides one."
    readme="run-ansible-playbook"
    ;;
  backup)
    help_text "Saves config/settings.yml and config/devices.yml into a private folder backup/bak_<date>_<id>; it asks first."
    readme="settings"
    ;;
  restore)
    help_text "Brings config/ back from a folder of backup/: it asks first, then for the name of the folder. A backup of an earlier version goes to config/ with ./zebrunner.sh migrate."
    readme="settings"
    ;;
  shutdown)
    help_text "Removes the containers of the devices, the launch agents (macOS) or the udev rules (Linux), the autostart, the deployed files, the completion of zebrunner-farm, the WireGuard tunnel to MCloud and the settings of config/; it asks first and uses sudo."
    ;;
  help)
    help_text "The commands, or the usage, the description and the options of a command."
    ui_help_group "Arguments"
    ui_help_cmd command "" "A command of ./zebrunner.sh, e.g. ./zebrunner.sh help mdm (also ./zebrunner.sh mdm --help)"
    ;;
  completion)
    help_text "Prints the completion of bash and zsh for an eval: the commands, the actions, the options and the devices of this host. It runs only a zebrunner.sh of the current user or of root that others cannot write, and asks it for the candidates without docker, network or a change."
    ui_help_group "Arguments"
    ui_help_cmd bash "" "The completion of bash"
    ui_help_cmd zsh "" "The completion of zsh (with bashcompinit)"
    printf '\n'
    help_text "The lines of ~/.bashrc and ~/.zshrc:"
    # the lines whole, so they can be copied
    printf '    %s\n' "$(completion_line bash)" "$(completion_line zsh)"
    readme="completion"
    ;;
  esac
  printf '\n'
  ui_muted "README.md#${readme}"
  echo ""
}

#### Unknown commands

# is_command <word>: 0 for a command of zebrunner.sh
is_command() {
  [[ "$1" =~ ^[a-z]+$ && " ${COMMANDS} " == *" $1 "* ]]
}

# edit_distance <a> <b>: the Levenshtein distance of the words, by rows: no associative array for bash 3.2
edit_distance() {
  local a="$1"
  local b="$2"
  local i j cost best
  local -a prev=()
  local -a cur=()
  for ((j = 0; j <= ${#b}; j++)); do
    prev[j]=$j
  done
  for ((i = 1; i <= ${#a}; i++)); do
    cur=("$i")
    for ((j = 1; j <= ${#b}; j++)); do
      cost=1
      [[ "${a:i-1:1}" == "${b:j-1:1}" ]] && cost=0
      best=$((prev[j] + 1))
      [[ $((cur[j - 1] + 1)) -lt "$best" ]] && best=$((cur[j - 1] + 1))
      [[ $((prev[j - 1] + cost)) -lt "$best" ]] && best=$((prev[j - 1] + cost))
      cur[j]="$best"
    done
    prev=("${cur[@]}")
  done
  echo "${prev[${#b}]}"
}

# similar_commands <word>: the commands closest to the word, separated by spaces: an edit distance of 2 at most (less
# than the length of the word) or the word as their start
similar_commands() {
  local word
  word="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ ${#word} -le 32 ]] || return 0
  local command distance
  local best=3
  local found=""
  for command in $COMMANDS; do
    if [[ ${#word} -ge 2 && "$command" == "$word"* ]]; then
      distance=0
    else
      distance="$(edit_distance "$word" "$command")"
    fi
    [[ "$distance" -le 2 && "$distance" -lt ${#word} ]] || continue
    if [[ "$distance" -lt "$best" ]]; then
      best="$distance"
      found="$command"
    elif [[ "$distance" -eq "$best" ]]; then
      found="${found} ${command}"
    fi
  done
  echo "$found"
}

# unknown_command <word>: the error, the closest commands and the usage on stderr; exits with 2, the code of a wrong
# usage
unknown_command() {
  local similar
  similar="$(similar_commands "$1")"
  {
    ui_callout error "Unknown command '$1'."
    if [[ -n "$similar" ]]; then
      ui_info "Did you mean: ${similar// /, }?"
    fi
    ui_usage "./zebrunner.sh <command> [options]"
    ui_muted "./zebrunner.sh help lists the commands"
    echo ""
  } >&2
  exit 2
}

# wants_help <arguments...>: 0 when -h or --help is one of the arguments: the help of the command instead of the command
wants_help() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
      return 0
    fi
  done
  return 1
}

# completion_line <bash|zsh>: the line of the profile of the shell that loads the completion
completion_line() {
  # the line for the profile: its $( ) runs there
  # shellcheck disable=SC2016
  printf 'eval "$(%q completion %s)"' "${MCLOUD_AGENT_DIR_VALUE}/zebrunner.sh" "$1"
}

# completion <bash|zsh>: patch/completion.sh for the eval of the shell (README.md#completion), the hint of the setup on
# stderr at a terminal
completion() {
  case "${1:-}" in
  bash | zsh)
    cat "${MCLOUD_AGENT_DIR_VALUE}/patch/completion.sh" || exit 1
    if [[ -t 1 ]]; then
      {
        ui_callout note "Add this line to ~/.${1}rc, the completion is in every new shell then:"
        # the line whole, so it can be copied
        printf '  %s\n\n' "$(completion_line "$1")"
      } >&2
    fi
    ;;
  *)
    {
      ui_callout error "The completion is of bash or zsh."
      ui_usage "./zebrunner.sh completion bash|zsh"
      echo ""
    } >&2
    exit 2
    ;;
  esac
}

#### Commands

case "${1:-}" in
"" | -h | --help)
  echo_help
  ;;
help)
  if [[ -z "${2:-}" ]]; then
    echo_help
  elif wants_help "$2"; then
    command_help help
  elif is_command "$2"; then
    command_help "$2"
  else
    unknown_command "$2"
  fi
  ;;
*)
  is_command "$1" || unknown_command "$1"
  if wants_help "${@:2}"; then
    command_help "$1"
    exit 0
  fi
  case "$1" in
  setup)
    setup
    ;;
  ansible)
    ansible "${@:2}"
    ;;
  status)
    status "$2"
    ;;
  backup)
    backup
    ;;
  restore)
    restore
    ;;
  shutdown)
    shutdown
    ;;
  version)
    version
    ;;
  doctor)
    doctor
    ;;
  join)
    join
    ;;
  migrate)
    migrate "${@:2}"
    ;;
  autostart)
    autostart "$2"
    ;;
  mdm)
    mdm "${@:2}"
    ;;
  completion)
    completion "$2"
    ;;
  esac
  ;;
esac
