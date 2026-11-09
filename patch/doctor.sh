#!/bin/bash
# `./zebrunner.sh doctor` (README.md#doctor): checks the host, the settings of the agent, the deployment, the network to
# the MCloud server and the devices, and tells what to fix. Sourced by zebrunner.sh after patch/utility.sh; never prints
# the secrets of the settings. The network probes are the ones of patch/netcheck.py.

DOCTOR_PROBLEMS=0
DOCTOR_WARNINGS=0
DOCTOR_VARS=""
DOCTOR_FARM="${DOCTOR_FARM:-/usr/local/bin/zebrunner-farm}"
DOCTOR_DEVICES="${DOCTOR_DEVICES:-/usr/local/bin/mcloud-devices.txt}"

# doctor_ok <message>: a passed check
doctor_ok() {
  echo -e "  ${GREEN}ok${NC}    $1"
}

# doctor_info <message>: a fact for the person, not a problem
doctor_info() {
  echo -e "  info  $1"
}

# doctor_warn <message> [fix]: a check that may break the farm
doctor_warn() {
  DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
  echo -e "  ${YELLOW}warn${NC}  $1"
  [[ -z "$2" ]] || echo -e "        fix: $2"
}

# doctor_fail <message> [fix]: a check that breaks the farm
doctor_fail() {
  DOCTOR_PROBLEMS=$((DOCTOR_PROBLEMS + 1))
  echo -e "  ${RED}FAIL${NC}  $1"
  [[ -z "$2" ]] || echo -e "        fix: $2"
}

# doctor_section <title>: the title of a group of checks, after an empty line but the first one
doctor_section() {
  [[ "$1" == "Host" ]] || echo ""
  echo "$1"
}

# setting_of <file> <name>: the value of a top level setting of a YAML file, without its quotes and comment
setting_of() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n 1 |
    sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/"
}

# setting <name>: the value of a setting: roles/.../vars/main.yml, defaults/main.yml when the settings have no such line
setting() {
  if grep -q "^$1:" "$DOCTOR_VARS" 2> /dev/null; then
    setting_of "$DOCTOR_VARS" "$1"
  else
    setting_of defaults/main.yml "$1"
  fi
}

# probe <netcheck.py arguments...>: a network probe of patch/netcheck.py
probe() {
  python3 patch/netcheck.py "$@" 2>&1
}

# first_address <host>: the first IPv4 address of the host, nothing when it is not resolved
first_address() {
  probe resolve "$1" 2> /dev/null | head -n 1 | grep -E '^[0-9.]+$'
}

# is_local_container <name>: 0 when the name is a container of this host (e.g. mcloud-grid of mcloud on the same host)
is_local_container() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && docker inspect --type container "$1" > /dev/null 2>&1
}

# check_endpoint <description> <host> <port> <fix>: the host is resolved and its port accepts connections
check_endpoint() {
  local description="$1"
  local host="$2"
  local port="$3"
  local fix="$4"
  local output
  if [[ -z "$host" || -z "$port" ]]; then
    doctor_fail "${description}: no host or port" "$fix"
  elif is_local_container "$host"; then
    doctor_ok "${description}: ${host}:${port} is a container of this host"
  elif [[ -z "$(first_address "$host")" ]]; then
    doctor_fail "${description}: ${host} is not resolved" "a DNS name or the address of the MCloud server, or the line of the name in /etc/hosts"
  elif output="$(probe tcp "$host" "$port" 5)"; then
    doctor_ok "${description}: ${host}:${port} ($(first_address "$host")) accepts connections"
  else
    doctor_fail "${description}: ${host}:${port} ($(first_address "$host")) does not accept connections: ${output}" "$fix"
  fi
}

#### Checks

# doctor_host: the tools of the agent
doctor_host() {
  doctor_section "Host"
  if [[ -z "$ZEBRUNNER_MCLOUD_AGENT_DIR" ]]; then
    doctor_fail "ZEBRUNNER_MCLOUD_AGENT_DIR is not set" "./zebrunner.sh setup, then open a new terminal"
  elif [[ "$ZEBRUNNER_MCLOUD_AGENT_DIR" != "$MCLOUD_AGENT_DIR_VALUE" ]]; then
    doctor_warn "ZEBRUNNER_MCLOUD_AGENT_DIR is ${ZEBRUNNER_MCLOUD_AGENT_DIR}, not this folder ${MCLOUD_AGENT_DIR_VALUE}" \
      "./zebrunner.sh setup in the folder of the agent, then open a new terminal"
  else
    doctor_ok "ZEBRUNNER_MCLOUD_AGENT_DIR is this folder"
  fi
  if ! command -v docker > /dev/null 2>&1; then
    doctor_fail "docker is not installed" "install Docker (README.md#software-prerequisites)"
  elif ! docker info > /dev/null 2>&1; then
    doctor_fail "docker does not answer to $(whoami)" "start Docker; Linux: sudo usermod -aG docker $(whoami) and log in again"
  else
    doctor_ok "docker $(docker version --format '{{.Server.Version}}' 2> /dev/null) answers"
  fi
  if command -v ansible-playbook > /dev/null 2>&1; then
    doctor_ok "$(ansible-playbook --version 2> /dev/null | head -n 1)"
  else
    doctor_fail "ansible-playbook is not installed" "install Ansible (README.md#software-prerequisites)"
  fi
  if command -v python3 > /dev/null 2>&1; then
    doctor_ok "python3 (the CURVE key and the network checks)"
  else
    doctor_fail "python3 is not installed: the CURVE key and the network checks need it" "install Python 3"
  fi
  if [[ "$(uname)" == "Linux" ]] && ! command -v lsusb > /dev/null 2>&1; then
    doctor_warn "lsusb is not installed: zebrunner-farm does not find the USB devices" "sudo apt install usbutils"
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    case "$(rosetta_state)" in
    missing | docker-off) doctor_warn "Rosetta 2 is not used by Docker Desktop: appium runs under QEMU" "./zebrunner.sh setup prints the steps" ;;
    esac
  fi
}

# doctor_settings: the obligatory settings of roles/.../vars/main.yml and their format
doctor_settings() {
  doctor_section "Settings (${DOCTOR_VARS})"
  if [[ ! -f "$DOCTOR_VARS" ]]; then
    doctor_fail "${DOCTOR_VARS} does not exist" "./zebrunner.sh setup"
    return 1
  fi
  local name
  local value
  local missing=()
  for name in PUBLIC_IP PUBLIC_IP_PORT PUBLIC_IP_PROTOCOL STF_PROVIDER_HOST STF_PROVIDER_CONNECT_SUB STF_PROVIDER_CONNECT_PUSH \
    SELENIUM_HUB_HOST SELENIUM_HUB_PORT STF_STORAGE_TOKEN NODE_REGISTRATION_TOKEN STF_ZMQ_CURVE_SERVER_PUBLIC_KEY \
    STF_ZMQ_CURVE_SECRET_KEY; do
    [[ -n "$(setting "$name")" ]] || missing+=("$name")
  done
  if [[ "$(count_values "${missing[@]}")" -gt 0 ]]; then
    doctor_fail "empty: ${missing[*]}" "the values of variables.env and .env of mcloud (README.md#connect-to-mcloud)"
  else
    doctor_ok "the obligatory settings are set"
  fi
  value="$(setting STF_PROVIDER_HOST)"
  if [[ "$value" == "linux-agent.zebrunner.farm" || "$value" == "macos-agent.zebrunner.farm" ]]; then
    doctor_fail "STF_PROVIDER_HOST is the example ${value}" "the address of this host the MCloud server reaches (README.md#connect-to-mcloud)"
  fi
  value="$(setting STF_ZMQ_CURVE_SERVER_PUBLIC_KEY)"
  if [[ -n "$value" && ! "$value" =~ ^[0-9a-fA-F]{64}$ ]]; then
    doctor_fail "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY is not a key of 64 hex characters" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of variables.env of mcloud, in quotes"
  fi
  value="$(setting STF_ZMQ_CURVE_SECRET_KEY)"
  if [[ -n "$value" && ! "$value" =~ ^[0-9a-fA-F]{64}$ ]]; then
    doctor_fail "STF_ZMQ_CURVE_SECRET_KEY is not a key of 64 hex characters" "./zebrunner.sh curve-key after emptying it"
  elif [[ -n "$value" ]] && command -v python3 > /dev/null 2>&1; then
    doctor_info "the public CURVE key of this host is in variables.env of mcloud as $(curve_client_line "$(python3 patch/curve_keygen.py "$value" | sed -n 's/^public=//p')")"
  fi
  if grep -qE '^[[:space:]]*-[[:space:]]+id:' "$DOCTOR_VARS"; then
    doctor_ok "$(grep -cE '^[[:space:]]*-[[:space:]]+id:' "$DOCTOR_VARS") devices are declared"
  else
    doctor_warn "no device is declared" "the devices of ${DOCTOR_VARS} (README.md#run-ansible-playbook)"
  fi
}

# doctor_deployment: zebrunner-farm and the containers made with the current settings
doctor_deployment() {
  doctor_section "Deployment"
  if [[ ! -f "$DOCTOR_FARM" ]]; then
    doctor_warn "zebrunner-farm is not deployed" "./zebrunner.sh ansible"
    return 0
  fi
  # the variables of the containers and the settings they are rendered from
  local pair
  local env_name
  local value
  local changed=()
  for pair in STF_PROVIDER_HOST=STF_PROVIDER_HOST STF_PROVIDER_PUBLIC_IP=PUBLIC_IP SELENIUM_HOST=SELENIUM_HUB_HOST \
    SELENIUM_PORT=SELENIUM_HUB_PORT STF_PROVIDER_CONNECT_SUB=STF_PROVIDER_CONNECT_SUB \
    STF_PROVIDER_CONNECT_PUSH=STF_PROVIDER_CONNECT_PUSH NODE_REGISTRATION_TOKEN=NODE_REGISTRATION_TOKEN \
    STF_STORAGE_TOKEN=STF_STORAGE_TOKEN STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=STF_ZMQ_CURVE_SERVER_PUBLIC_KEY \
    STF_ZMQ_CURVE_SECRET_KEY=STF_ZMQ_CURVE_SECRET_KEY REMOTE_CONNECT_HOST=REMOTE_CONNECT_HOST; do
    env_name="${pair%%=*}"
    value="$(setting "${pair#*=}")"
    grep -qF -- "${env_name}=\"${value}\"" "$DOCTOR_FARM" || changed+=("${pair#*=}")
  done
  if [[ "$(count_values "${changed[@]}")" -gt 0 ]]; then
    doctor_warn "zebrunner-farm is deployed with other values of ${changed[*]}" \
      "./zebrunner.sh ansible, then zebrunner-farm restart recreates the containers with them"
  else
    doctor_ok "zebrunner-farm is deployed with the current settings"
  fi

  local container
  local host
  local stale=0
  local provider_host
  provider_host="$(setting STF_PROVIDER_HOST)"
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    host="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2> /dev/null | sed -n 's/^STF_PROVIDER_HOST=//p')"
    [[ "$host" == "$provider_host" ]] || stale=$((stale + 1))
  done <<< "$(docker ps -a --filter name=device- --format '{{.Names}}' 2> /dev/null | grep -- '-stf$')"
  if [[ "$stale" -gt 0 ]]; then
    doctor_warn "${stale} devices run with another STF_PROVIDER_HOST than ${provider_host}" "zebrunner-farm restart (after ./zebrunner.sh ansible)"
  fi
}

# doctor_network: the endpoints of the MCloud server and the address of this host it connects to
doctor_network() {
  doctor_section "Network"
  if ! command -v python3 > /dev/null 2>&1; then
    doctor_warn "the network is not checked without python3"
    return 0
  fi
  local public_ip
  local protocol
  local port
  local endpoint
  local name
  local code
  public_ip="$(setting PUBLIC_IP)"
  protocol="$(setting PUBLIC_IP_PROTOCOL)"
  port="$(setting PUBLIC_IP_PORT)"
  check_endpoint "MCloud (PUBLIC_IP)" "$public_ip" "$port" \
    "PUBLIC_IP, PUBLIC_IP_PORT: STF_URL of .env of mcloud; in the network of the server its address there (README.md#troubleshooting)"
  check_endpoint "mcloud-grid (SELENIUM_HUB_HOST)" "$(setting SELENIUM_HUB_HOST)" "$(setting SELENIUM_HUB_PORT)" \
    "the address of the MCloud server and the port of mcloud-grid (4446), see Firewall of mcloud"
  for name in STF_PROVIDER_CONNECT_SUB STF_PROVIDER_CONNECT_PUSH STF_PROVIDER_CONNECT_APP_DEALER STF_PROVIDER_CONNECT_DEV_DEALER; do
    endpoint="$(setting "$name")"
    [[ -n "$endpoint" ]] || continue
    endpoint="${endpoint#tcp://}"
    check_endpoint "STF ZeroMQ (${name})" "${endpoint%:*}" "${endpoint##*:}" "tcp://<MCloud server>:<port> of the triproxies, see Firewall of mcloud"
  done

  doctor_provider_host
  doctor_remote_connect

  # stf-proxy of mcloud serves the screens of the device hosts of AGENT_HOSTS only (403 for the other ones)
  local provider_host
  provider_host="$(setting STF_PROVIDER_HOST)"
  if [[ -n "$public_ip" && -n "$provider_host" ]] && command -v curl > /dev/null 2>&1; then
    code="$(curl -ks -m 10 -o /dev/null -w '%{http_code}' "${protocol:-http}://${public_ip}:${port:-80}/d/${provider_host}/doctor/7400/" 2> /dev/null)"
    case "$code" in
    403) doctor_fail "stf-proxy of mcloud refuses the screens of ${provider_host}: it is not in AGENT_HOSTS" \
      "AGENT_HOSTS of .env of mcloud with ${provider_host} (separated by commas), then ./zebrunner.sh restart there" ;;
    401 | 400 | 426 | 502 | 504) doctor_ok "stf-proxy of mcloud serves the screens of ${provider_host} (AGENT_HOSTS)" ;;
    000 | "") doctor_warn "stf-proxy of mcloud does not answer on ${protocol:-http}://${public_ip}:${port:-80}" ;;
    *) doctor_info "stf-proxy of mcloud answers ${code} for the screens of ${provider_host}" ;;
    esac
  fi
}

# doctor_provider_host: STF_PROVIDER_HOST leads to this host from the MCloud server: the hub registers the Appium nodes
# by it and stf-proxy takes the screens from it; a public address of a NAT often fails inside the same network (no hairpin)
doctor_provider_host() {
  local provider_host
  local provider_address
  local server
  local server_address
  local route_source
  provider_host="$(setting STF_PROVIDER_HOST)"
  [[ -n "$provider_host" ]] || return 0
  provider_address="$(first_address "$provider_host")"
  if [[ -z "$provider_address" ]]; then
    doctor_fail "STF_PROVIDER_HOST ${provider_host} is not resolved" "an address of this host, or a name the MCloud server resolves"
    return 0
  fi
  server="$(setting SELENIUM_HUB_HOST)"
  is_local_container "$server" && server="$(setting PUBLIC_IP)"
  server_address="$(first_address "$server")"
  [[ -n "$server_address" ]] && route_source="$(probe source "$server_address" 2> /dev/null)"

  if probe local "$provider_address" > /dev/null 2>&1; then
    doctor_ok "STF_PROVIDER_HOST ${provider_host} is an address of this host"
  elif [[ -n "$route_source" && "$(probe kind "$server_address")" != "public" && "$(probe kind "$provider_address")" == "public" ]]; then
    doctor_fail "the MCloud server ${server} (${server_address}) is in the network of this host (${route_source}), STF_PROVIDER_HOST ${provider_host} (${provider_address}) is a public address of a NAT: without the hairpin of the router the hub and stf-proxy cannot connect to it (registration 500 'not reachable from the hub', gray screens)" \
      "STF_PROVIDER_HOST: ${route_source} in ${DOCTOR_VARS} and in AGENT_HOSTS of .env of mcloud (README.md#device-hosts-in-a-private-network)"
  else
    doctor_info "STF_PROVIDER_HOST ${provider_host} (${provider_address}) is not an address of this host: it must lead to this host from the MCloud server (a NAT, a port forwarding)"
  fi
}

# connect_ports: the remote debug (adb connect) ports of the deployed Android devices, separated by spaces: connect_port,
# min_port + 1 without it (min_port is the screen)
connect_ports() {
  [[ -f "$DOCTOR_DEVICES" ]] || return 0
  # min_port is the 7th field and connect_port the 15th; min_port is the 9th of a list deployed before the proxy ports
  # were dropped (16 fields)
  awk -F '|' '$2 == "android" {
      if (NF >= 16) port = $9 + 1
      else if ($15 ~ /^[0-9]+$/) port = $15
      else if ($7 ~ /^[0-9]+$/) port = $7 + 1
      else next
      print port
    }' "$DOCTOR_DEVICES" | paste -s -d ' ' -
}

# doctor_remote_connect: `adb connect` of STF (the remote debug of the Android devices) reaches the devices:
# REMOTE_CONNECT_HOST through the adb relay of mcloud, which forwards their remote debug ports only
doctor_remote_connect() {
  local remote
  local provider_host
  local ports
  local port
  local entries=""
  local relay
  remote="$(setting REMOTE_CONNECT_HOST)"
  provider_host="$(setting STF_PROVIDER_HOST)"
  ports="$(connect_ports)"
  for port in $ports; do
    entries="${entries:+${entries},}${provider_host}:${port}"
  done
  relay="ADB_RELAY=true of .env of mcloud (the relay takes the ports of the devices from STF), or ADB_RELAY_HOSTS with ${entries:-<STF_PROVIDER_HOST>:<connect_port of every Android device>}; then ./zebrunner.sh restart there"
  if [[ -z "$remote" || "$remote" == "$provider_host" ]]; then
    if [[ "$(probe kind "$(first_address "$provider_host")" 2> /dev/null)" == "private" ]]; then
      doctor_info "adb connect of STF (the remote debug) reaches ${provider_host} from its network only; for the other users: REMOTE_CONNECT_HOST (the public name of MCloud) and ${relay}"
    fi
  elif [[ -z "$ports" ]]; then
    doctor_info "adb connect of STF goes to ${remote}: no Android device is deployed to check the relay with"
  else
    check_endpoint "adb relay of mcloud (REMOTE_CONNECT_HOST)" "$remote" "${ports%% *}" "$relay"
    doctor_info "the remote debug ports of this host (ADB_RELAY_PORTS of mcloud must have them): ${entries}"
  fi
}

# doctor_devices: the deployed devices, their containers and the errors of their logs
doctor_devices() {
  doctor_section "Devices"
  if [[ ! -f "$DOCTOR_DEVICES" ]]; then
    doctor_warn "no devices are deployed (${DOCTOR_DEVICES})" "./zebrunner.sh ansible"
    return 0
  fi
  local udid
  local name
  local connection
  local prefix
  local running
  local line
  local states
  states="$(docker ps -a --filter name=device- --format '{{.Names}} {{.State}}' 2> /dev/null)"
  local -a fields
  while IFS='|' read -r -a fields; do
    udid="${fields[0]}"
    [[ -n "$udid" ]] || continue
    name="${fields[2]}"
    # the connection is the 9th field, the 11th of a list deployed before the proxy ports were dropped (16 fields)
    if [[ "$(count_values "${fields[@]}")" -ge 16 ]]; then
      connection="${fields[10]}"
    else
      connection="${fields[8]}"
    fi
    prefix="device-${name}-${udid}"
    running="$(grep -cF -- "${prefix}-" <<< "$(grep ' running$' <<< "$states")")"
    if [[ "$running" -eq 0 ]]; then
      if [[ "${connection:-usb}" == "usb" && "$(uname)" == "Linux" && ! -L "/dev/${prefix}" ]]; then
        doctor_info "${name}: not plugged in"
      else
        doctor_warn "${name}: no running container" "zebrunner-farm start ${name}"
      fi
      continue
    fi
    doctor_ok "${name}: ${running} containers run"
    line="$(docker logs --since 30m --tail 300 "${prefix}-appium" 2>&1 | grep 'register with the grid' | tail -n 1)"
    if [[ -n "$line" ]]; then
      doctor_warn "${name}: the hub refuses the Appium node: ${line#*\[Appium\] }" \
        "the log of mcloud-grid tells why (e.g. 'is not reachable from the hub': STF_PROVIDER_HOST and appium_port must be reachable from the MCloud server)"
    fi
    if docker logs --since 30m --tail 300 "${prefix}-stf" 2>&1 | grep -q 'refused the CURVE key'; then
      doctor_fail "${name}: STF refuses the CURVE key of this host" "add $(curve_client_line '<public key of ./zebrunner.sh curve-key>') to variables.env of mcloud and restart it"
    fi
  done < "$DOCTOR_DEVICES"
}

# count_values <values...>: the number of the values
count_values() {
  echo "$#"
}

# doctor: all the checks; fails when one of them fails
doctor() {
  delimiter "MCloud Agent doctor"
  case "$(uname)" in
  Linux) DOCTOR_VARS="roles/devices/vars/main.yml" ;;
  Darwin) DOCTOR_VARS="roles/mac-devices/vars/main.yml" ;;
  *)
    echo_warning "Unknown OS. Supported OS are Linux and macOS."
    return 1
    ;;
  esac
  doctor_host
  if doctor_settings; then
    doctor_deployment
    doctor_network
    doctor_devices
  fi
  delimiter "*"
  if [[ "$DOCTOR_PROBLEMS" -gt 0 ]]; then
    failed "${DOCTOR_PROBLEMS} problems and ${DOCTOR_WARNINGS} warnings: fix the problems, then run ./zebrunner.sh doctor again"
    return 1
  elif [[ "$DOCTOR_WARNINGS" -gt 0 ]]; then
    warn "No problems, ${DOCTOR_WARNINGS} warnings"
  else
    succeed "No problems"
  fi
}
