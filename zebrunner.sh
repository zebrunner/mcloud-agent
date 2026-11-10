#!/bin/bash

# Define Mcloud Agent dir environment variable name
MCLOUD_AGENT_DIR_NAME="ZEBRUNNER_MCLOUD_AGENT_DIR"
MCLOUD_AGENT_DIR_VALUE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${MCLOUD_AGENT_DIR_VALUE}" || exit

# The settings of this host and its devices (README.md#settings)
SETTINGS_FILE="config/settings.yml"
DEVICES_FILE="config/devices.yml"

# Load utility functions
source "${MCLOUD_AGENT_DIR_VALUE}/patch/utility.sh"
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

setup() {
  delimiter "Setting up MCloud Agent"

  ### Detect MCloud Agent directory and set environment variable
  echo "Detected MCloud Agent directory: ${MCLOUD_AGENT_DIR_VALUE}"
  # Apply the variable in the current session
  echo "Applying env var '${MCLOUD_AGENT_DIR_NAME}=${MCLOUD_AGENT_DIR_VALUE}' in the current session"
  export "$MCLOUD_AGENT_DIR_NAME"="$MCLOUD_AGENT_DIR_VALUE"

  ### Install environment variable to shell profiles
  delimiter "*"
  # Array to hold target files
  TARGET_FILES=()
  echo "Shells found in this system:"
  # Bash
  if command -v bash > /dev/null 2>&1; then
    echo "BASH"
    TARGET_FILES+=("${HOME}/.bashrc" "${HOME}/.bash_profile")
  fi
  # Zsh
  if command -v zsh > /dev/null 2>&1; then
    echo "ZSH"
    TARGET_FILES+=("${HOME}/.zshrc" "${HOME}/.zprofile")
  fi
  # Other
  if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
    echo "Other (Except 'BASH' or 'ZSH') shell detected"
    TARGET_FILES+=("${HOME}/.profile")
  fi
  # Loop through target files and add or update the environment variable
  delimiter "*"
  echo "Adding '${MCLOUD_AGENT_DIR_NAME}=${MCLOUD_AGENT_DIR_VALUE}' to:"
  for file in "${TARGET_FILES[@]}"; do
    if [[ -f "$file" ]] && grep -q "^export ${MCLOUD_AGENT_DIR_NAME}=" "$file"; then
      echo "$file"
      sed -i.bak "s|^export ${MCLOUD_AGENT_DIR_NAME}=.*|export ${MCLOUD_AGENT_DIR_NAME}=${MCLOUD_AGENT_DIR_VALUE}|" "$file" && rm -f "${file}.bak"
    else
      echo "$file"
      echo "export ${MCLOUD_AGENT_DIR_NAME}=${MCLOUD_AGENT_DIR_VALUE}" >> "$file"
    fi
  done

  ### Create the settings of config/ according to OS
  delimiter "*"
  os="$(uname)"
  echo "Current OS: ${os}"
  echo ""
  local vars="$SETTINGS_FILE"
  local devices="$DEVICES_FILE"
  local devices_example
  case "$os" in
  Linux) devices_example="config/devices.yml.original" ;;
  Darwin) devices_example="config/mac-devices.yml.original" ;;
  *)
    echo "Unknown OS. Supported OS are Linux and macOS."
    exit 1
    ;;
  esac
  echo "Setting up the settings of 'config/' according to OS:"
  setup_file "${vars}.original" "$vars"
  setup_file "$devices_example" "$devices"
  local legacy
  legacy="$(legacy_settings_file)"
  if [[ -f "$legacy" ]]; then
    echo_warning "'${legacy}' of an earlier version overrides 'config/': move its settings to '${vars}' and its devices: to '${devices}' (README.md#settings), then remove it."
  fi

  ### Shell reload help message
  delimiter "*"
  current_shell="$(basename "$SHELL")"
  echo "Current shell: ${current_shell}"
  echo ""
  warn "To apply the changes, please restart your terminal session or run the appropriate command below:"
  case "$current_shell" in
  bash)
    if [[ -f "${HOME}/.bashrc" ]]; then
      succeed ">\tsource ~/.bashrc"
    elif [[ -f "${HOME}/.bash_profile" ]]; then
      succeed ">\tsource ~/.bash_profile"
    fi
    ;;
  zsh)
    if [[ -f "${HOME}/.zshrc" ]]; then
      succeed ">\tsource ~/.zshrc"
    elif [[ -f "${HOME}/.zprofile" ]]; then
      succeed ">\tsource ~/.zprofile"
    fi
    ;;
  *)
    if [[ -f "${HOME}/.profile" ]]; then
      succeed ">\tsource ~/.profile"
    fi
    ;;
  esac
  echo ""
  warn ">>> Changes in other shells will be applied automatically <<<"

  ### Rosetta 2 of an Apple Silicon Mac
  if [[ "$os" == "Darwin" ]]; then
    delimiter "*"
    rosetta_report
  fi

  ### Next steps
  delimiter "*"
  local addresses
  addresses="$(host_addresses)"
  echo "Next steps (https://github.com/zebrunner/mcloud-agent#node-enrollment):

  1. Open a new terminal (or run the command above) to have ZEBRUNNER_MCLOUD_AGENT_DIR.

  2. The administrator of MCloud invites this host on its server: ./zebrunner.sh node-invite <label> <address>, the
     address is the one the MCloud server connects to: the addresses of this host are ${addresses:-unknown}; in the
     network of the MCloud server the address there (on the MCloud server itself its LAN address, not 127.0.0.1).

  3. Enroll this host: ./zebrunner.sh join and paste the join string of step 2. It writes the connection to MCloud
     into '${vars}'.

  4. Declare the devices in 'devices:' of '${devices}': the udid (adb devices, idevice_id -l), a unique name and
     unique ports.

  5. Check the settings, the enrollment and the network to MCloud: ./zebrunner.sh doctor

  6. Deploy the agent: ./zebrunner.sh ansible

  7. Start the devices: zebrunner-farm start, then zebrunner-farm status and ./zebrunner.sh doctor."

  delimiter "Setting up MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished successfully"
}

ansible() {
  delimiter "Deploying MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  ### Check if the environment variable is set
  if [[ -z "$ZEBRUNNER_MCLOUD_AGENT_DIR" ]]; then
    echo_warning "Environment variable '${MCLOUD_AGENT_DIR_NAME}' is not set."
    echo "Please, run './zebrunner.sh setup' first, or restart your terminal if you've already done so!"
    exit 1
  fi

  ### Check if the operating system is Linux or macOS
  delimiter "*"
  if [[ "$(uname)" == "Linux" ]]; then
    echo "Operating system is Linux"
    file="${ZEBRUNNER_MCLOUD_AGENT_DIR}/devices.yml"
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo "Operating system is macOS"
    file="${ZEBRUNNER_MCLOUD_AGENT_DIR}/mac-devices.yml"
  else
    echo_warning "This script is not running on a Linux or macOS system. Run ansible manually."
    exit 1
  fi

  ### Make a list of arguments
  delimiter "*"
  local -a args
  if [[ -z "$1" ]]; then
    args=("$file")
  elif [[ "$1" == "devices" ]]; then
    args=("$file" --tag registerDevices)
  else
    args=("$@" "$file")
  fi

  ### sudo-rs (the sudo of Ubuntu 25.10+) wraps the password prompt, ansible does not recognize it and times out
  if [[ "$(uname)" == "Linux" && "$*" != *ansible_become_exe* ]] && sudo --version 2> /dev/null | grep -q '^sudo-rs'; then
    if command -v sudo.ws > /dev/null 2>&1; then
      echo "sudo is sudo-rs: ansible becomes root with sudo.ws, the original sudo"
      args=(--extra-vars ansible_become_exe=sudo.ws "${args[@]}")
    else
      echo_warning "sudo is sudo-rs, whose password prompt ansible does not recognize: install the original sudo (sudo apt install sudo), it provides sudo.ws."
    fi
  fi

  ### The running containers of the devices keep the old settings and images
  if [[ "$1" != "devices" ]]; then
    stop_running_devices
  fi

  ### Run ansible with arguments
  echo_warning "Sudo permissions are required to run this script!"
  echo "ansible-playbook --ask-become-pass --inventory hosts ${args[*]}"
  delimiter "*"
  ansible-playbook --ask-become-pass --inventory hosts "${args[@]}" || {
    echo_warning "Ansible playbook execution failed!"
    echo_telegram
    exit 1
  }

  if [[ "$1" != "devices" ]]; then
    echo "Run 'zebrunner-farm start' to create the containers of the connected devices."
  fi
  delimiter "Deploying MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished successfully"
}

# stop_running_devices: asks to stop and remove the running containers of the devices before the deploy: they keep the
# settings and the images they were created with, zebrunner-farm start creates them again with the new ones
stop_running_devices() {
  local containers
  containers="$(running_device_containers)"
  [[ -n "$containers" ]] || return 0
  delimiter "*"
  echo_warning "$(grep -c . <<< "$containers") containers of the devices are running:"
  sed -E -e 's/-(connector|stf|appium|uploader)$//' -e 's/^/        /' <<< "$containers" | sort -u
  echo "
      They keep the settings and the images they were created with: stop and remove them before the deploy, then
      'zebrunner-farm start' creates them with the new ones."
  if confirm "" "      Stop and remove them now (zebrunner-farm down)?" "y"; then
    if command -v zebrunner-farm > /dev/null 2>&1; then
      # no terminal for zebrunner-farm: it asks nothing, also the earlier versions without --quiet
      zebrunner-farm down < /dev/null
    else
      # the names of the containers are words
      # shellcheck disable=SC2086
      docker rm -f $containers > /dev/null
    fi
  else
    echo "The containers keep running: run 'zebrunner-farm restart' after the deploy."
  fi
}

# setup_file <example> <file>: the file made from the example (private: the settings have secrets), a backup <file>.bak
# of an existing one
setup_file() {
  (
    umask 077
    if [[ -f "$2" ]]; then
      echo "'$2' already exists, making a backup '$2.bak'"
      cp "$2" "$2.bak"
    else
      echo "Creating '$2'"
      cp "$1" "$2"
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
    echo_warning "'${SETTINGS_FILE}' does not exist, run './zebrunner.sh setup' first." >&2
    return 1
  fi
  echo "$SETTINGS_FILE"
}

# ensure_curve_key <settings file>: STF_ZMQ_CURVE_SECRET_KEY of the settings made when it is empty, its public key in
# CURVE_PUBLIC_KEY
ensure_curve_key() {
  local vars="$1"
  local secret
  CURVE_PUBLIC_KEY=""
  if ! grep -q '^STF_ZMQ_CURVE_SECRET_KEY:' "$vars"; then
    echo_warning "'${vars}' has no STF_ZMQ_CURVE_SECRET_KEY line: add it as in '${vars}.original'."
    return 1
  fi
  secret="$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY:[[:space:]]*//p' "$vars" | tr -d "\"' ")"
  if [[ -z "$secret" ]]; then
    secret="$(python3 patch/curve_keygen.py | sed -n 's/^secret=//p')"
    if [[ ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
      echo_warning "Unable to make the key with python3 patch/curve_keygen.py."
      return 1
    fi
    sed -i.bak "s/^STF_ZMQ_CURVE_SECRET_KEY:.*/STF_ZMQ_CURVE_SECRET_KEY: \"${secret}\"/" "$vars" && rm -f "${vars}.bak"
    echo "The key of this host is written to STF_ZMQ_CURVE_SECRET_KEY of '${vars}'."
  fi
  if ! CURVE_PUBLIC_KEY="$(python3 patch/curve_keygen.py "$secret" | sed -n 's/^public=//p')" || [[ -z "$CURVE_PUBLIC_KEY" ]]; then
    echo_warning "STF_ZMQ_CURVE_SECRET_KEY of '${vars}' is not a key of 64 hex characters."
    return 1
  fi
}

# join: enrolls this host in MCloud with the join string of `./zebrunner.sh node-invite` of mcloud, read from a hidden
# prompt or stdin (README.md#node-enrollment): the token of this host and the settings of MCloud go to the settings
join() {
  local vars
  vars="$(settings_file)" || exit 1
  if ! command -v python3 > /dev/null 2>&1 || ! command -v curl > /dev/null 2>&1; then
    echo_warning "The enrollment needs python3 and curl."
    exit 1
  fi
  ensure_curve_key "$vars" || exit 1
  python3 patch/enroll.py "$vars" "$CURVE_PUBLIC_KEY" || exit 1
  echo "
      Next: ./zebrunner.sh doctor checks the settings, ./zebrunner.sh ansible deploys them and zebrunner-farm restart
      recreates the containers of the devices with the token of this host."
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
  case "$(rosetta_state)" in
  ok)
    succeed "Rosetta 2 is installed: Docker Desktop runs the linux/amd64 image of appium with it."
    ;;
  missing)
    warn "Rosetta 2 is not installed: Docker Desktop runs the linux/amd64 image of appium under the much slower QEMU"
    warn "emulation. Install it and let Docker Desktop use it:"
    warn ">\tsoftwareupdate --install-rosetta --agree-to-license"
    warn "then turn on 'Use Rosetta for x86_64/amd64 emulation on Apple Silicon' in Docker Desktop (Settings, General)"
    warn "and restart Docker Desktop."
    ;;
  docker-off)
    warn "Rosetta 2 is installed, but Docker Desktop runs the linux/amd64 image of appium under the much slower QEMU"
    warn "emulation:"
    warn "turn on 'Use Rosetta for x86_64/amd64 emulation on Apple Silicon' in Docker Desktop (Settings, General) and"
    warn "restart Docker Desktop."
    ;;
  esac
}

status() {
  delimiter "Status of MCloud Agent components"

  os="$(uname)" 2> /dev/null
  echo "Env var for Mcloud Agent path:    $(env | grep "$MCLOUD_AGENT_DIR_NAME" 2> /dev/null || failed "$MCLOUD_AGENT_DIR_NAME not set")"
  echo ""
  echo "Current OS:                       $(if [[ -n "$os" ]]; then echo "$os"; else failed "OS not detected"; fi)"
  echo ""
  echo "Current user:                     $(whoami 2> /dev/null || failed username not detected)"
  echo ""
  echo "Docker version:                   $(docker --version 2> /dev/null || failed "'docker' not found")"
  echo ""
  echo "Docker compose version:           $(docker compose version 2> /dev/null || failed "'docker compose' not found")"
  echo ""
  echo "Ansible-playbook info:            $(ansible-playbook --version 2> /dev/null | head -n 1 | grep . || failed "'ansible-playbook' not found")"
  echo ""
  echo "Zebrunner-farm script:            $(which zebrunner-farm 2> /dev/null || failed "'zebrunner-farm' not found")"
  echo ""
  if [[ "$os" == "Darwin" ]]; then
    echo "Socat tool:                       $(which socat 2> /dev/null || failed "'socat' not found")"
    echo ""
    case "$(rosetta_state)" in
    ok) echo "Rosetta 2:                        installed, used by Docker Desktop" ;;
    missing) echo "Rosetta 2:                        $(failed "not installed: softwareupdate --install-rosetta --agree-to-license")" ;;
    docker-off) echo "Rosetta 2:                        $(failed "installed, not used by Docker Desktop (Settings, General)")" ;;
    *) echo "Rosetta 2:                        not needed (Intel Mac)" ;;
    esac
    echo ""
    echo "Deployed launchctl Zebrunner files:"
    shopt -s nullglob nocaseglob
    plists=("${HOME}/Library/LaunchAgents"/*zebrunner*)
    shopt -u nullglob nocaseglob
    if ((${#plists[@]} == 0)); then
      failed "No deployed Zebrunner plist files found"
    else
      for f in "${plists[@]}"; do
        echo "$f"
      done
    fi
    echo ""
    echo "Loaded launchctl Zebrunner jobs:"
    launchctl list | grep -i zebrunner || failed "No loaded Zebrunner jobs found"
    echo ""
    echo "MacOS ansible-playbook:           $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/mac-devices.yml" 2> /dev/null || failed "File not found")"
    echo ""
  else
    echo "Linux ansible-playbook:           $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/devices.yml" 2> /dev/null || failed "File not found")"
    echo ""
    echo "90_mcloud.rules:                  $(ls /etc/udev/rules.d/90_mcloud.rules 2> /dev/null || failed "File not found")"
    echo ""
    echo "mcloud-device-restart@.service:   $(ls /etc/systemd/system/mcloud-device-restart@.service 2> /dev/null || failed "File not found")"
    echo ""
    echo "mcloud-device-down@.service:      $(ls /etc/systemd/system/mcloud-device-down@.service 2> /dev/null || failed "File not found")"
    echo ""
  fi
  echo "mcloud-devices.txt:               $(ls "/usr/local/bin/mcloud-devices.txt" 2> /dev/null || failed "File not found")"
  echo ""
  echo "config/settings.yml:              $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/${SETTINGS_FILE}" 2> /dev/null || failed "File not found")"
  echo ""
  echo "config/devices.yml:               $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/${DEVICES_FILE}" 2> /dev/null || failed "File not found")"
  echo ""
  echo "defaults/main.yml:                $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/defaults/main.yml" 2> /dev/null || failed "File not found")"

  delimiter
}

shutdown() {
  delimiter "Shutting down MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  ### Confirm shutdown
  echo_warning "Shutdown will erase all settings and data for '${ZEBRUNNER_MCLOUD_AGENT_DIR}' !"
  confirm "" "      Do you want to continue?" "n" || {
    echo "Shutdown cancelled"
    exit 0
  }

  ### Ask for sudo permissions
  echo ""
  ask_for_sudo || {
    echo_warning "Sudo permissions are required to run this script!"
    exit 1
  }

  ### Remove launch agents in case of macOS
  os="$(uname)"
  if [[ "$os" == "Darwin" ]]; then
    delimiter "*"
    echo "Current OS: $os"
    delimiter "*"

    echo "Found Zebrunner launchctl files:"
    shopt -s nullglob nocaseglob
    plists=("${HOME}/Library/LaunchAgents"/*zebrunner*)
    shopt -u nullglob nocaseglob
    if ((${#plists[@]} == 0)); then
      failed "No Zebrunner plist files found"
    else
      for f in "${plists[@]}"; do
        echo "$f"
      done
    fi

    delimiter "*"
    echo "Found loaded Zebrunner plists:"
    launchctl list | grep -i zebrunner || failed "No loaded Zebrunner plists found"

    delimiter "*"
    echo "Unloading and removing ZebrunnerDevicesListener.plist launchctl file:"
    if [[ -f "${HOME}/Library/LaunchAgents/ZebrunnerDevicesListener.plist" ]]; then
      if launchctl bootout gui/"$(id -u)" "${HOME}/Library/LaunchAgents/ZebrunnerDevicesListener.plist" 2> /dev/null; then
        echo "ZebrunnerDevicesListener.plist unloaded successfully"
      else
        failed "Failed to unload 'ZebrunnerDevicesListener.plist', it might be not loaded"
      fi
      echo ""
      echo "Removing ZebrunnerDevicesListener.plist file:"
      rm -vf "${HOME}/Library/LaunchAgents/ZebrunnerDevicesListener.plist"
    else
      failed "ZebrunnerDevicesListener.plist file not found"
    fi

    delimiter "*"
    echo "Unloading and removing ZebrunnerUsbmuxd.plist launchctl file:"
    if [[ -f "${HOME}/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" ]]; then
      if launchctl bootout gui/"$(id -u)" "${HOME}/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" 2> /dev/null; then
        echo "ZebrunnerUsbmuxd.plist unloaded successfully"
      else
        failed "Failed to unload 'ZebrunnerUsbmuxd.plist', it might be not loaded"
      fi
      echo ""
      echo "Removing ZebrunnerUsbmuxd.plist file:"
      rm -vf "${HOME}/Library/LaunchAgents/ZebrunnerUsbmuxd.plist"
    else
      failed "ZebrunnerUsbmuxd.plist file not found"
    fi

    # the adb server of the USB Android devices, deployed for them only
    if [[ -f "${HOME}/Library/LaunchAgents/ZebrunnerAdb.plist" ]]; then
      delimiter "*"
      echo "Unloading and removing ZebrunnerAdb.plist launchctl file:"
      launchctl bootout gui/"$(id -u)" "${HOME}/Library/LaunchAgents/ZebrunnerAdb.plist" 2> /dev/null ||
        failed "Failed to unload 'ZebrunnerAdb.plist', it might be not loaded"
      rm -vf "${HOME}/Library/LaunchAgents/ZebrunnerAdb.plist"
    fi
  fi

  ### Remove environment variable from shell profiles
  delimiter "*"
  echo "Removing var 'ZEBRUNNER_MCLOUD_AGENT_DIR' from shell profiles:"
  TARGET_FILES+=("${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.zshrc" "${HOME}/.zprofile" "${HOME}/.profile")
  for file in "${TARGET_FILES[@]}"; do
    if [[ -f "$file" ]] && grep -q "export ${MCLOUD_AGENT_DIR_NAME}=" "$file"; then
      echo "$file"
      sed -i.bak "/^export ${MCLOUD_AGENT_DIR_NAME}=.*/d" "$file" && rm -f "${file}.bak"
    fi
  done

  ### Stop and remove containers
  delimiter "*"
  echo "Found MCloud Agent containers:"
  docker ps -a --filter "name=device-" --format "{{.Names}}"

  delimiter "*"
  echo "Stopping and removing MCloud Agent containers:"
  if command -v zebrunner-farm > /dev/null 2>&1; then
    # no terminal for zebrunner-farm: it asks nothing
    zebrunner-farm down < /dev/null
  else
    failed "Can't find 'zebrunner-farm' executable file"
  fi

  delimiter "*"
  echo "Removing volume 'appium-storage-volume':"
  if docker volume ls | grep -q "appium-storage-volume"; then
    docker volume rm appium-storage-volume
  else
    failed "Volume 'appium-storage-volume' not found"
  fi

  ### Remove files
  delimiter "*"
  echo "Removing MCloud Agent files and volumes (sudo privileges required):"
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
  fi
  sudo rm -vf /usr/local/bin/zebrunner-farm
  sudo rm -vf /usr/local/bin/mcloud-devices.txt

  ### Final message
  delimiter "*"
  warn ">>> Restart current terminal session to apply all changes <<<"

  delimiter "Shutting down MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished"
}

version() {
  delimiter "Zebrunner MCloud Agent components versions for '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"
  if [[ -z "$ZEBRUNNER_MCLOUD_AGENT_DIR" ]]; then
    echo_warning "Environment variable '${MCLOUD_AGENT_DIR_NAME}' is not set"
    echo "Please, run './zebrunner.sh setup' first, or restart your terminal if you've already done so!"
    delimiter "*"
    echo "Versions from 'defaults/main.yml' in the current directory:"
    grep -i "version" "defaults/main.yml" | grep -v '^\s*#' || exit 1
  else
    grep -i "version" "${ZEBRUNNER_MCLOUD_AGENT_DIR}/defaults/main.yml" | grep -v '^\s*#'
  fi
  delimiter
}

echo_help() {
  delimiter "Zebrunner MCloud Agent help"
  echo "
      Usage: ./zebrunner.sh [option]
      Options:
         setup                Prepare MCloud Agent environment
         ansible ['devices']  Deploy MCloud Agent with custom or predefined args
         status               Status of MCloud Agent deployment
         backup               Backup MCloud Agent setup
         restore              Restore MCloud Agent setup
         shutdown             Stop and remove MCloud Agent containers, clear volumes and environment
         version              Version of MCloud Agent components
         doctor               Check the settings, the deployment and the network to MCloud, tell what to fix
         join                 Enroll this host in MCloud with the join string of ./zebrunner.sh node-invite (stdin)"
  echo_telegram
  delimiter
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
*)
  echo_help
  ;;
esac
