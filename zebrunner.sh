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

  echo "MCloud Agent directory: ${MCLOUD_AGENT_DIR_VALUE}"

  ### The variable of the earlier versions in the shell profiles is not used anymore
  remove_profile_variable

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
    echo_warning "'${legacy}' of an earlier version overrides 'config/': ./zebrunner.sh migrate moves its settings to '${vars}' and its devices: to '${devices}' (README.md#settings)."
  fi

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

  1. The administrator of MCloud invites this host on its server: ./zebrunner.sh node-invite <label> <address>, the
     address is the one the MCloud server connects to: the addresses of this host are ${addresses:-unknown}; in the
     network of the MCloud server the address there (on the MCloud server itself its LAN address, not 127.0.0.1).

  2. Enroll this host: ./zebrunner.sh join and paste the join string of step 1. It writes the connection to MCloud
     into '${vars}'.

  3. Declare the devices in 'devices:' of '${devices}': the udid (adb devices, idevice_id -l), a unique name and
     unique ports.

  4. Check the settings, the enrollment and the network to MCloud: ./zebrunner.sh doctor

  5. Deploy the agent: ./zebrunner.sh ansible

  6. Start the devices: zebrunner-farm start, then zebrunner-farm status and ./zebrunner.sh doctor. zebrunner-farm
     knows this folder: zebrunner-farm ansible deploys again from any folder."

  delimiter "Setting up MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished successfully"
}

ansible() {
  delimiter "Deploying MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  ### Check if the operating system is Linux or macOS: agent.yml deploys the role of the OS
  delimiter "*"
  file="${ZEBRUNNER_MCLOUD_AGENT_DIR}/agent.yml"
  if [[ "$(uname)" == "Linux" ]]; then
    echo "Operating system is Linux"
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo "Operating system is macOS"
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

# remove_profile_variable: the ZEBRUNNER_MCLOUD_AGENT_DIR line of the earlier versions removed from the shell profiles:
# zebrunner.sh knows its folder and zebrunner-farm has it in its settings
remove_profile_variable() {
  local file
  for file in "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.zshrc" "${HOME}/.zprofile" "${HOME}/.profile"; do
    if [[ -f "$file" ]] && grep -q "^export ${MCLOUD_AGENT_DIR_NAME}=" "$file"; then
      echo "Removing the variable ${MCLOUD_AGENT_DIR_NAME} of an earlier version from ${file}"
      sed -i.bak "/^export ${MCLOUD_AGENT_DIR_NAME}=.*/d" "$file" && rm -f "${file}.bak"
    fi
  done
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
      echo_warning "Unable to make the key with python3 patch/curve_keygen.py."
      return 1
    fi
    # the secret key on stdin: the arguments of a process are visible to every user (printf is a builtin)
    printf 'STF_ZMQ_CURVE_SECRET_KEY=%s\n' "$secret" | "$python" patch/settings.py set "$vars" - || return 1
    echo "The key of this host is written to STF_ZMQ_CURVE_SECRET_KEY of '${vars}'."
  fi
  if ! CURVE_PUBLIC_KEY="$(printf '%s\n' "$secret" | python3 patch/curve_keygen.py - | sed -n 's/^public=//p')" ||
    [[ -z "$CURVE_PUBLIC_KEY" ]]; then
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
  local python
  if ! python="$(yaml_python)"; then
    echo_warning "The enrollment needs a python3 with PyYAML: the one of ansible has it (README.md#software-prerequisites)."
    exit 1
  fi
  ensure_curve_key "$vars" "$python" || exit 1
  "$python" patch/enroll.py "$vars" "$CURVE_PUBLIC_KEY" || exit 1
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
  echo "MCloud Agent directory:           ${MCLOUD_AGENT_DIR_VALUE}"
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
  else
    echo "90_mcloud.rules:                  $(ls /etc/udev/rules.d/90_mcloud.rules 2> /dev/null || failed "File not found")"
    echo ""
    echo "mcloud-device-restart@.service:   $(ls /etc/systemd/system/mcloud-device-restart@.service 2> /dev/null || failed "File not found")"
    echo ""
    echo "mcloud-device-down@.service:      $(ls /etc/systemd/system/mcloud-device-down@.service 2> /dev/null || failed "File not found")"
    echo ""
  fi
  echo "mcloud-devices.txt:               $(ls "/usr/local/bin/mcloud-devices.txt" 2> /dev/null || failed "File not found")"
  echo ""
  echo "zebrunner-farm.env:               $(ls "/usr/local/etc/zebrunner-farm.env" 2> /dev/null || failed "File not found")"
  echo ""
  echo "Autostart after a reboot:         $(if autostart_enabled; then autostart_file; else echo "off (./zebrunner.sh autostart)"; fi)"
  echo ""
  echo "config/settings.yml:              $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/${SETTINGS_FILE}" 2> /dev/null || failed "File not found")"
  echo ""
  echo "config/devices.yml:               $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/${DEVICES_FILE}" 2> /dev/null || failed "File not found")"
  echo ""
  echo "ansible-playbook:                 $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/agent.yml" 2> /dev/null || failed "File not found")"
  echo ""
  echo "versions.yml:                     $(ls "${ZEBRUNNER_MCLOUD_AGENT_DIR}/versions.yml" 2> /dev/null || failed "File not found")"

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

  ### The variable of the earlier versions in the shell profiles
  remove_profile_variable

  ### The autostart of the devices after a reboot
  if autostart_enabled || [[ -f "$(autostart_file)" ]]; then
    echo "Removing the autostart: $(autostart_file)"
    autostart_remove
  fi

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
  sudo rm -vf /usr/local/etc/zebrunner-farm.env
  sudo rm -vf /usr/local/bin/mcloud-devices.txt

  ### Final message
  delimiter "*"
  warn ">>> Restart current terminal session to apply all changes <<<"

  delimiter "Shutting down MCloud Agent from '${ZEBRUNNER_MCLOUD_AGENT_DIR}' finished"
}

version() {
  delimiter "Zebrunner MCloud Agent components versions for '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"
  grep -i "version" "${ZEBRUNNER_MCLOUD_AGENT_DIR}/versions.yml" | grep -v '^\s*#' || exit 1
  delimiter
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
  delimiter "Autostart of the devices after a reboot"
  local file
  file="$(autostart_file)"
  case "${1:-status}" in
  status)
    if autostart_enabled; then
      succeed "Autostart is on: ${file}"
    else
      echo "Autostart is off (by default): ./zebrunner.sh autostart enable tells what it adds and asks first."
    fi
    ;;
  enable)
    if autostart_enabled; then
      echo "Autostart is on already: ${file}"
      delimiter
      return 0
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "
      It creates ${file}: a launch agent of $(id -un 2> /dev/null || echo "this user") loaded at the next login, nothing
      starts now. At the login it waits for Docker Desktop (10 minutes at most: let Docker Desktop start at the
      login, its Settings, General) and runs 'zebrunner-farm start --quiet' once: the containers of all the devices,
      also the Android, wireless, emulator and proxy ones the devices listener does not start. Its log:
      ${MCLOUD_AGENT_DIR_VALUE}/logs/autostart.log. No sudo is needed.

      The content of ${file}:
"
      autostart_plist
    else
      if ! command -v systemctl > /dev/null 2>&1; then
        echo_warning "The autostart of Linux is a systemd unit: this host has no systemctl."
        exit 1
      fi
      echo "
      It runs with sudo:
        1. creates ${file} (mode 644): a systemd unit that runs 'zebrunner-farm start --quiet' once after docker at
           the boot: the containers of all the devices, also the wireless, emulator and proxy ones udev does not
           start (udev starts the USB devices anyway). Its log: journalctl -u mcloud-farm
        2. systemctl daemon-reload
        3. systemctl enable mcloud-farm.service: it runs at the next boot, nothing starts now.

      The content of ${file}:
"
      autostart_unit
    fi
    echo ""
    confirm "" "      Enable the autostart as described above?" "n" || exit 0
    if [[ "$(uname)" == "Darwin" ]]; then
      mkdir -p "$(dirname "$file")"
      autostart_plist > "$file"
    else
      autostart_unit | sudo tee "$file" > /dev/null || exit 1
      sudo chmod 644 "$file"
      sudo systemctl daemon-reload
      sudo systemctl enable mcloud-farm.service || exit 1
    fi
    succeed "Autostart is on: ${file}"
    ;;
  disable)
    if ! autostart_enabled && [[ ! -f "$file" ]]; then
      echo "Autostart is off already."
      delimiter
      return 0
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "
      It unloads and removes ${file}: the containers of the devices are not started at the login anymore, the
      running ones keep running."
    else
      echo "
      It runs with sudo: systemctl disable mcloud-farm.service, removes ${file}, systemctl daemon-reload: the
      containers of the devices are not started at the boot anymore, the running ones keep running."
    fi
    echo ""
    confirm "" "      Disable the autostart as described above?" "n" || exit 0
    autostart_remove
    succeed "Autostart is off."
    ;;
  *)
    echo "Usage: ./zebrunner.sh autostart [status|enable|disable]"
    exit 1
    ;;
  esac
  delimiter
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
  delimiter "Moving the settings of an earlier version to config/"
  local python
  if ! python="$(yaml_python)"; then
    echo_warning "The migration needs a python3 with PyYAML: the one of ansible has it (README.md#software-prerequisites)."
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
    echo "No settings of an earlier version: nothing to migrate."
    delimiter
    return 0
  fi
  echo "The settings of an earlier version: ${files[*]}"
  echo ""
  local rc=0
  "$python" patch/migrate.py plan "$farm_os" "${files[@]}" || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 3 ]] || exit 1
  echo ""
  confirm "" "      Write these changes to config/ and rename the files of an earlier version to *.migrated?" "n" || exit 0
  "$python" patch/migrate.py apply "$farm_os" "${files[@]}" || exit 1
  echo ""
  warn "Check them with ./zebrunner.sh doctor, then deploy: ./zebrunner.sh ansible"
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
         join                 Enroll this host in MCloud with the join string of ./zebrunner.sh node-invite (stdin)
         migrate [files...]   Move the settings of an earlier version to config/ (shows the changes, asks first)
         autostart [status|enable|disable]  The containers of the devices after a reboot (off by default, asks first)"
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
migrate)
  migrate "${@:2}"
  ;;
autostart)
  autostart "$2"
  ;;
*)
  echo_help
  ;;
esac
