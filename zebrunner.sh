#!/bin/bash

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
  print_step 1 "The administrator of MCloud invites this host on its server: ./zebrunner.sh node-invite <label> <address>, the address is the one the MCloud server connects to: the addresses of this host are ${addresses:-unknown}; in the network of the MCloud server the address there (on the MCloud server itself its LAN address, not 127.0.0.1)."
  print_step 2 "Enroll this host: ./zebrunner.sh join and paste the join string of step 1. It writes the connection to MCloud into '${vars}'."
  print_step 3 "Declare the devices in 'devices:' of '${devices}': the udid (adb devices, idevice_id -l), a unique name and unique ports."
  print_step 4 "Check the settings, the enrollment and the network to MCloud: ./zebrunner.sh doctor"
  print_step 5 "Deploy the agent: ./zebrunner.sh ansible"
  print_step 6 "Start the devices: zebrunner-farm start, then zebrunner-farm status and ./zebrunner.sh doctor. zebrunner-farm knows this folder: zebrunner-farm ansible deploys again from any folder."

  ui_rule
  ui_ok "Setting up MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished successfully"
}

# ansible [devices] [ansible-playbook arguments...]: deploys the agent (README.md#run-ansible-playbook); devices skips the
# download of the images and keeps the running containers of the devices
ansible() {
  print_section "Deploy" "Deploying MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

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
# ~/.ssh/authorized_keys removed, the key gives a shell of the user
remove_simulators_ssh_key() {
  local keys="${HOME}/.ssh/authorized_keys"
  if [[ -f "$keys" ]] && grep -q "zebrunner-mcloud-simulators$" "$keys"; then
    ui_info "Removing the ssh key of the simulators from ${keys}"
    sed -i.bak "/zebrunner-mcloud-simulators$/d" "$keys" && rm -f "${keys}.bak"
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
  print_section "Status" "Status of MCloud Agent components"
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

# shutdown: removes the containers of the devices, the deployed files and the settings after a confirmation
shutdown() {
  ui_banner "MCloud Agent"
  ui_section "Shutdown"
  ui_info "Shutting down MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  ### Confirm shutdown
  echo_warning "Shutdown will erase all settings and data for '${ZEBRUNNER_MCLOUD_AGENT_DIR}'!"
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
    for plist in ZebrunnerDevicesListener ZebrunnerUsbmuxd; do
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

  if docker volume ls | grep -q "appium-storage-volume"; then
    ui_spin "Removing volume 'appium-storage-volume'" docker volume rm appium-storage-volume
  else
    ui_info "Volume 'appium-storage-volume' not found"
  fi

  ### Remove files
  ui_section "Files"
  ui_info "Removing MCloud Agent files and volumes (sudo privileges required):"
  # the settings of an earlier version too
  rm -vf "$SETTINGS_FILE" "$DEVICES_FILE" "$(legacy_settings_file)"
  if [[ "$os" == "Darwin" ]]; then
    sudo rm -vf /usr/local/bin/zebrunner-device-listener
    sudo rm -vf /usr/local/bin/usbmuxd_watch
    sudo rm -vf /etc/newsyslog.d/zebrunner-mcloud.conf
  else
    sudo rm -vf /etc/udev/rules.d/90_mcloud.rules
    sudo rm -vf /etc/systemd/system/mcloud-device-restart@.service
    sudo rm -vf /etc/systemd/system/mcloud-device-down@.service
    # udev and systemd keep the removed rules and units until they reload them
    sudo udevadm control --reload
    sudo systemctl daemon-reload
  fi
  sudo rm -vf /usr/local/bin/zebrunner-farm
  sudo rm -vf /usr/local/etc/zebrunner-farm.env
  sudo rm -vf /usr/local/bin/mcloud-devices.txt

  ### Final message
  ui_callout note "Restart current terminal session to apply all changes"
  echo ""
  ui_rule
  ui_ok "Shutting down MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished"
}

# version: the versions of the images of versions.yml
version() {
  print_section "Versions" "Zebrunner MCloud Agent components versions for '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"
  grep -i "version" "${ZEBRUNNER_MCLOUD_AGENT_DIR}/versions.yml" | grep -v '^\s*#' || exit 1
  echo ""
  ui_rule
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
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zebrunner-farm start --quiet
# the images may be pulled
TimeoutStartSec=30min

[Install]
WantedBy=multi-user.target
EOF
}

# autostart_plist: the launch agent of macOS, run once at the login when Docker Desktop answers (10 minutes at most)
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
      <string>for i in \$(seq 1 120); do docker info &gt; /dev/null 2&gt;&amp;1 &amp;&amp; exec /usr/local/bin/zebrunner-farm start --quiet; sleep 5; done; echo "Docker Desktop does not answer" &gt;&amp;2; exit 1</string>
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
  print_section "Autostart" "Autostart of the devices after a reboot"
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
      print_paragraph "It creates ${file}: a launch agent of $(id -un 2> /dev/null || echo "this user") loaded at the next login, nothing starts now. At the login it waits for Docker Desktop (10 minutes at most: let Docker Desktop start at the login, its Settings, General) and runs 'zebrunner-farm start --quiet' once: the containers of all the devices, also the Android, wireless, emulator and proxy ones the devices listener does not start. Its log: ${MCLOUD_AGENT_DIR_VALUE}/logs/autostart.log. No sudo is needed."
      ui_muted "The content of ${file}:"
      echo ""
      autostart_plist
    else
      if ! command -v systemctl > /dev/null 2>&1; then
        ui_callout error "The autostart of Linux is a systemd unit: this host has no systemctl."
        exit 1
      fi
      print_paragraph "It runs with sudo:"
      print_step 1 "creates ${file} (mode 644): a systemd unit that runs 'zebrunner-farm start --quiet' once after docker at the boot: the containers of all the devices, also the wireless, emulator and proxy ones udev does not start (udev starts the USB devices anyway). Its log: journalctl -u mcloud-farm"
      print_step 2 "systemctl daemon-reload"
      print_step 3 "systemctl enable mcloud-farm.service: it runs at the next boot, nothing starts now."
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
      print_paragraph "It unloads and removes ${file}: the containers of the devices are not started at the login anymore, the running ones keep running."
    else
      print_paragraph "It runs with sudo: systemctl disable mcloud-farm.service, removes ${file}, systemctl daemon-reload: the containers of the devices are not started at the boot anymore, the running ones keep running."
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
  print_section "Migrate" "Moving the settings of an earlier version to config/"
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

# echo_help: the usage of zebrunner.sh, the commands by their stage
echo_help() {
  ui_banner "MCloud Agent"
  ui_usage "./zebrunner.sh <command> [options]"

  ui_help_group "Set up"
  ui_help_cmd setup "" "Prepare MCloud Agent environment"
  ui_help_cmd join "" "Enroll this host in MCloud with the join string of ./zebrunner.sh node-invite (stdin)"
  ui_help_cmd migrate "[files...]" "Move the settings of an earlier version to config/ (shows the changes, asks first)"
  ui_help_cmd ansible "[devices] [args...]" "Deploy MCloud Agent: devices without the download of the images, args of ansible-playbook"

  ui_help_group "Operate"
  ui_help_cmd status "" "Status of MCloud Agent deployment"
  ui_help_cmd doctor "" "Check the settings, the deployment and the network to MCloud, tell what to fix"
  ui_help_cmd autostart "[status|enable|disable]" "The containers of the devices after a reboot (off by default, asks first)"
  ui_help_cmd mdm "<status|enroll|release|supervise> [devices] [options]" "The devices in the MDM of MCloud (README.md#mdm): status: what the MDM knows; enroll: the agent as the device owner (Android), the enrollment profile (supervised iOS); release [--uninstall]: out of the MDM; supervise [--force] [--yes]: ERASES an iOS device, supervises it, joins MDM_WIFI_SSID, enrolls it"
  ui_help_cmd version "" "Version of MCloud Agent components"

  ui_help_group "Maintain"
  ui_help_cmd backup "" "Backup MCloud Agent setup"
  ui_help_cmd restore "" "Restore MCloud Agent setup"
  ui_help_cmd shutdown "" "Stop and remove MCloud Agent containers, clear volumes and environment"

  echo_telegram
  echo ""
}

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
*)
  echo_help
  ;;
esac
