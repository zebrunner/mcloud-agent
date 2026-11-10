#!/bin/bash
# `./zebrunner.sh doctor` (README.md#doctor): checks the host, the settings of the agent, the deployment, the network to
# the MCloud server and the devices, and tells what to fix. Sourced by zebrunner.sh after patch/utility.sh; never prints
# the secrets of the settings. The network probes are the ones of patch/netcheck.py.

DOCTOR_PROBLEMS=0
DOCTOR_WARNINGS=0
DOCTOR_VARS=""
DOCTOR_DEVICE_LIST=""
DOCTOR_ROLE=""
# NAME=value of the settings: the values by default of the roles, versions.yml, config/settings.yml (patch/settings.py)
DOCTOR_SETTINGS=""
DOCTOR_FARM="${DOCTOR_FARM:-/usr/local/bin/zebrunner-farm}"
# the settings of zebrunner-farm, rendered by the deploy
DOCTOR_FARM_ENV="${DOCTOR_FARM_ENV:-/usr/local/etc/zebrunner-farm.env}"
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

# setting <name>: the value of a setting as the playbooks load it (DOCTOR_SETTINGS of doctor_settings)
setting() {
  sed -n "s/^$1=//p" <<< "$DOCTOR_SETTINGS" | head -n 1
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

# doctor_settings: the obligatory settings of config/settings.yml and their format, the checks of the devices of
# config/devices.yml of the deploy
doctor_settings() {
  doctor_section "Settings (${DOCTOR_VARS})"
  if [[ ! -f "$DOCTOR_VARS" ]]; then
    doctor_fail "${DOCTOR_VARS} does not exist" "./zebrunner.sh setup"
    return 1
  fi
  local python
  if ! python="$(yaml_python)"; then
    doctor_fail "no python3 with PyYAML: the settings are not checked" "install ansible (README.md#software-prerequisites), its python has PyYAML"
    return 1
  fi
  if ! DOCTOR_SETTINGS="$("$python" patch/settings.py dump roles/common/defaults/main.yml "roles/${DOCTOR_ROLE}/defaults/main.yml" \
    versions.yml "$DOCTOR_VARS" 2>&1)"; then
    doctor_fail "$DOCTOR_SETTINGS" "fix the YAML of ${DOCTOR_VARS} (e.g. the quotes of a value with ':' or '#')"
    DOCTOR_SETTINGS=""
    return 1
  fi
  local legacy
  legacy="$(legacy_settings_file)"
  if [[ -f "$legacy" ]]; then
    doctor_fail "${legacy} of an earlier version overrides ${DOCTOR_VARS}" \
      "./zebrunner.sh migrate moves its settings to ${DOCTOR_VARS} and its devices: to ${DOCTOR_DEVICE_LIST} (README.md#settings)"
  fi
  local name
  local value
  local missing=()
  # the settings of ./zebrunner.sh join
  for name in MCLOUD_URL MCLOUD_TLS_PIN MCLOUD_NODE_TOKEN STF_PROVIDER_HOST PUBLIC_IP PUBLIC_IP_PORT PUBLIC_IP_PROTOCOL \
    STF_PROVIDER_CONNECT_SUB STF_PROVIDER_CONNECT_PUSH SELENIUM_HUB_HOST SELENIUM_HUB_PORT STF_ZMQ_CURVE_SERVER_PUBLIC_KEY \
    STF_ZMQ_CURVE_SECRET_KEY; do
    [[ -n "$(setting "$name")" ]] || missing+=("$name")
  done
  if [[ "$(count_values "${missing[@]}")" -gt 0 ]]; then
    doctor_fail "this host is not enrolled, empty: ${missing[*]}" \
      "./zebrunner.sh join with the join string of ./zebrunner.sh node-invite of mcloud (README.md#node-enrollment)"
  fi
  doctor_private "$DOCTOR_VARS" "the settings" "chmod 600 ${DOCTOR_VARS}"
  value="$(setting MCLOUD_NODE_TOKEN)"
  if [[ -n "$value" && ! "$value" =~ ^mcn1\.([a-z0-9][a-z0-9-]{0,39})\.[A-Za-z0-9_-]{43}$ ]]; then
    doctor_fail "MCLOUD_NODE_TOKEN is not a token of ./zebrunner.sh join" "./zebrunner.sh join with a new join string of ./zebrunner.sh node-invite of mcloud"
  fi
  for name in STF_ZMQ_CURVE_SERVER_PUBLIC_KEY STF_ZMQ_CURVE_SECRET_KEY; do
    value="$(setting "$name")"
    if [[ -n "$value" && ! "$value" =~ ^[0-9a-fA-F]{64}$ ]]; then
      doctor_fail "${name} is not a key of 64 hex characters" "./zebrunner.sh join with a new join string (README.md#node-enrollment)"
    fi
  done
  # the checks of the deploy (roles/common/files/devices.py): the number of the devices or their problems
  local count
  local farm_os=linux
  [[ "$DOCTOR_ROLE" == "mac-devices" ]] && farm_os=macos
  if [[ ! -f "$DOCTOR_DEVICE_LIST" ]]; then
    doctor_fail "${DOCTOR_DEVICE_LIST} does not exist" "./zebrunner.sh setup"
  elif ! count="$("$python" roles/common/files/devices.py file "$farm_os" "$DOCTOR_DEVICE_LIST" 2>&1)"; then
    local problem
    while IFS= read -r problem; do
      doctor_fail "$problem" "fix the devices of ${DOCTOR_DEVICE_LIST} (README.md#run-ansible-playbook)"
    done <<< "$count"
  elif [[ "$count" -gt 0 ]]; then
    doctor_ok "${count} devices are declared, their settings are valid"
  else
    doctor_warn "no device is declared" "the devices of ${DOCTOR_DEVICE_LIST} (README.md#run-ansible-playbook)"
  fi
}

# doctor_enrollment: what MCloud knows about this host: GET /api/v1/nodes/self of MCLOUD_URL with the token of this host,
# over HTTPS to the pinned TLS key only (the token goes to curl on stdin, never in its arguments)
doctor_enrollment() {
  doctor_section "Enrollment (MCloud)"
  local url pin token answer code report
  url="$(setting MCLOUD_URL)"
  pin="$(setting MCLOUD_TLS_PIN)"
  token="$(setting MCLOUD_NODE_TOKEN)"
  if [[ -z "$url" || -z "$pin" || -z "$token" ]]; then
    doctor_fail "this host is not enrolled" "./zebrunner.sh join (README.md#node-enrollment)"
    return 0
  fi
  if ! command -v curl > /dev/null 2>&1 || ! command -v python3 > /dev/null 2>&1; then
    doctor_warn "the enrollment is not checked without curl and python3"
    return 0
  fi
  if ! answer="$(printf 'Authorization: Bearer %s\n' "$token" | curl -sS -k --max-time 15 --pinnedpubkey "sha256//${pin}" \
    -H @- "${url}/api/v1/nodes/self" -w '\n%{http_code}' 2>&1)"; then
    if [[ "$answer" == *"pinned public key"* || "$answer" == *"(90)"* ]]; then
      doctor_fail "the TLS key of MCloud ${url} is not the pinned one" "a wrong MCLOUD_URL or a man in the middle; a new TLS key of MCloud needs a new join string"
    else
      doctor_fail "MCloud ${url} does not answer: ${answer}" "the network to MCloud (MCLOUD_URL is the address of the join string)"
    fi
    return 0
  fi
  code="${answer##*$'\n'}"
  answer="${answer%$'\n'*}"
  case "$code" in
  200) ;;
  401)
    doctor_fail "MCloud does not know the token of this host" "./zebrunner.sh join with a new join string of ./zebrunner.sh node-invite of mcloud"
    return 0
    ;;
  403)
    doctor_fail "MCloud revoked this host" "the administrator of MCloud invites it again (./zebrunner.sh node-invite), then ./zebrunner.sh join"
    return 0
    ;;
  *)
    doctor_fail "MCloud answers ${code} to the check of this host" "MCloud with the node enrollment (README.md#node-enrollment)"
    return 0
    ;;
  esac
  report="$(python3 -c '
import json, sys
node = json.load(sys.stdin)
print("label=%s" % node.get("label", ""))
print("address=%s" % node.get("address", ""))
for device in node.get("devices") or []:
    print("device=%s|%s|%s|%s" % (device.get("serial", ""), device.get("platform", ""), str(bool(device.get("present"))).lower(), str(bool(device.get("bound"))).lower()))
' <<< "$answer" 2> /dev/null)" || {
    doctor_fail "MCloud answers no valid JSON to the check of this host"
    return 0
  }
  local label address line serial platform present bound devices=0 bound_count=0
  label="$(sed -n 's/^label=//p' <<< "$report")"
  address="$(sed -n 's/^address=//p' <<< "$report")"
  doctor_ok "this host is enrolled and active in MCloud as ${label}"
  if [[ "$(tr '[:upper:]' '[:lower:]' <<< "$address")" != "$(setting STF_PROVIDER_HOST | tr '[:upper:]' '[:lower:]')" ]]; then
    doctor_fail "STF_PROVIDER_HOST $(setting STF_PROVIDER_HOST) is not the address of this host in MCloud (${address}): STF refuses its devices" \
      "./zebrunner.sh join with a new join string (it writes the address of the invite)"
  fi
  while IFS='|' read -r line; do
    [[ "$line" == device=* ]] || continue
    IFS='|' read -r serial platform present bound <<< "${line#device=}"
    devices=$((devices + 1))
    if [[ "$bound" == "true" ]]; then
      bound_count=$((bound_count + 1))
    else
      doctor_warn "STF refuses the device ${serial} (${platform}) of this host: it is not bound to it" \
        "STF_PROVIDER_HOST must be the address of the invite, zebrunner-farm restart ${serial} after ./zebrunner.sh ansible"
    fi
    [[ "$present" == "true" ]] || doctor_info "STF knows the device ${serial} (${platform}), it is not connected now"
  done <<< "$report"
  if [[ "$devices" -eq 0 ]]; then
    doctor_info "STF knows no device of this host yet: zebrunner-farm start"
  else
    doctor_ok "STF knows ${devices} devices of this host, ${bound_count} bound to it"
  fi
}

# file_mode <file>: the permissions of the file in octal (e.g. 600)
file_mode() {
  stat -c '%a' "$1" 2> /dev/null || stat -f '%Lp' "$1" 2> /dev/null
}

# doctor_private <file> <description> <fix>: the file with secrets is not readable by the group and the others
doctor_private() {
  local mode
  mode="$(file_mode "$1")"
  [[ -n "$mode" ]] || return 0
  if [[ "${mode: -2}" != "00" ]]; then
    doctor_warn "${2} (${1}) have secrets and are readable by other users (mode ${mode})" "$3"
  fi
}

# doctor_deployment: zebrunner-farm and the containers made with the current settings
doctor_deployment() {
  doctor_section "Deployment"
  if [[ ! -f "$DOCTOR_FARM" ]]; then
    doctor_warn "zebrunner-farm is not deployed" "./zebrunner.sh ansible"
    return 0
  fi
  # the settings zebrunner-farm runs with: the env file of the deploy, sourced as zebrunner-farm does
  local deployed
  # $1 is expanded by the shell that sources the settings
  # shellcheck disable=SC2016
  if [[ ! -r "$DOCTOR_FARM_ENV" ]] || ! deployed="$(env -i PATH=/usr/bin:/bin /bin/bash -c 'set -a && source "$1" && env' _ "$DOCTOR_FARM_ENV" 2> /dev/null)"; then
    doctor_warn "the settings of zebrunner-farm (${DOCTOR_FARM_ENV}) are not readable by $(whoami)" "./zebrunner.sh ansible"
    return 0
  fi
  # zebrunner-farm runs the scripts and the ssh key of the folder of its deploy
  local farm_dir
  farm_dir="$(sed -n 's/^ZEBRUNNER_MCLOUD_AGENT_DIR=//p' <<< "$deployed")"
  if [[ "$farm_dir" != "$MCLOUD_AGENT_DIR_VALUE" ]]; then
    doctor_warn "zebrunner-farm is deployed from another folder: ${farm_dir}" "./zebrunner.sh ansible of this folder ${MCLOUD_AGENT_DIR_VALUE}"
  fi
  local line
  local name
  local changed=()
  while IFS= read -r line; do
    name="${line%%=*}"
    # the settings of config/: the deployed value of every setting the env file has
    grep -q "^${name}=" <<< "$DOCTOR_SETTINGS" || continue
    [[ "${line#*=}" == "$(setting "$name")" ]] || changed+=("$name")
  done <<< "$deployed"
  local mode
  mode="$(file_mode "$DOCTOR_FARM_ENV")"
  if [[ -n "$mode" && "${mode: -1}" != "0" ]]; then
    doctor_warn "the settings of zebrunner-farm have the secrets of the host and are readable by every user (mode ${mode})" "./zebrunner.sh ansible deploys them readable by this user only"
  fi
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
  local port
  local endpoint
  local name
  public_ip="$(setting PUBLIC_IP)"
  port="$(setting PUBLIC_IP_PORT)"
  check_endpoint "MCloud (PUBLIC_IP)" "$public_ip" "$port" \
    "the devices reach the public name of MCloud: resolve it to the address of the MCloud server in its network (e.g. /etc/hosts, README.md#device-hosts-in-a-private-network)"
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

  doctor_same_machine
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
      "a new invite of this host with the address ${route_source} (./zebrunner.sh node-invite <label> ${route_source} of mcloud), then ./zebrunner.sh join (README.md#device-hosts-in-a-private-network)"
  else
    doctor_info "STF_PROVIDER_HOST ${provider_host} (${provider_address}) is not an address of this host: it must lead to this host from the MCloud server (a NAT, a port forwarding)"
  fi
}

# device_list_fields <key>...: the values of the keys of every deployed device, separated by '|', one device per line:
# mcloud-devices.txt has the fields key=value separated by '|' in any order (README.md#devices-management)
device_list_fields() {
  [[ -f "$DOCTOR_DEVICES" ]] || return 0
  awk -F '|' -v keys="$*" '!/^#/ && /=/ {
      split("", value)
      for (i = 1; i <= NF; i++) {
        eq = index($i, "=")
        if (eq > 0) value[substr($i, 1, eq - 1)] = substr($i, eq + 1)
      }
      n = split(keys, key, " ")
      line = value[key[1]]
      for (j = 2; j <= n; j++) line = line "|" value[key[j]]
      print line
    }' "$DOCTOR_DEVICES"
}

# connect_ports: the remote debug (adb connect) ports of the deployed Android devices, separated by spaces: connect_port,
# min_port + 1 without it (min_port is the screen)
connect_ports() {
  device_list_fields os min_port connect_port | awk -F '|' '$1 == "android" {
      if ($3 ~ /^[0-9]+$/) port = $3
      else if ($2 ~ /^[0-9]+$/) port = $2 + 1
      else next
      print port
    }' | paste -s -d ' ' -
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
  relay="ADB_RELAY=true of .env of mcloud (the relay takes the remote debug ports of the devices from STF) with the ports ${entries:-of the devices} in ADB_RELAY_PORTS, then ./zebrunner.sh restart there"
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

# device_ports_of_list: the host ports of the deployed devices, one per line: appium_port, min_port-max_port, connect_port
device_ports_of_list() {
  device_list_fields appium_port min_port max_port connect_port | awk -F '|' '$1 ~ /^[0-9]+$/ { print $1 }
    $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { for (port = $2; port <= $3; port++) print port }
    $4 ~ /^[0-9]+$/ { print $4 }'
}

# doctor_same_machine: MCloud on this machine (README.md#devices-on-the-mcloud-server): the ports of the devices are not the
# ports of MCloud
doctor_same_machine() {
  local url host address reserved port used
  url="$(setting MCLOUD_URL)"
  host="${url#*://}"
  host="${host%%[:/]*}"
  [[ -n "$host" ]] || return 0
  address="$(first_address "$host")"
  [[ -n "$address" ]] && probe local "$address" > /dev/null 2>&1 || return 0
  doctor_info "MCloud runs on this machine (${host})"
  reserved="${url##*:} $(setting SELENIUM_HUB_PORT)"
  for name in STF_PROVIDER_CONNECT_SUB STF_PROVIDER_CONNECT_PUSH STF_PROVIDER_CONNECT_APP_DEALER STF_PROVIDER_CONNECT_DEV_DEALER; do
    port="$(setting "$name")"
    reserved="${reserved} ${port##*:}"
  done
  used=""
  for port in $reserved; do
    if grep -qx -- "$port" <<< "$(device_ports_of_list)"; then
      used="${used:+${used} }${port}"
    fi
  done
  if [[ -n "$used" ]]; then
    doctor_fail "the devices use the ports ${used} of MCloud on this machine" "other appium_port, min_port-max_port and connect_port of the devices (README.md#devices-on-the-mcloud-server)"
  else
    doctor_ok "the devices use no port of MCloud on this machine"
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
  while IFS='|' read -r udid name connection; do
    [[ -n "$udid" ]] || continue
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
      doctor_fail "${name}: STF refuses the CURVE key of this host: MCloud knows another key of it or revoked it" "./zebrunner.sh join with a new join string of ./zebrunner.sh node-invite of mcloud"
    fi
  done <<< "$(device_list_fields id name connection)"
}

# count_values <values...>: the number of the values
count_values() {
  echo "$#"
}

# doctor: all the checks; fails when one of them fails
doctor() {
  delimiter "MCloud Agent doctor"
  DOCTOR_VARS="$SETTINGS_FILE"
  DOCTOR_DEVICE_LIST="$DEVICES_FILE"
  case "$(uname)" in
  Linux) DOCTOR_ROLE=devices ;;
  Darwin) DOCTOR_ROLE=mac-devices ;;
  *)
    echo_warning "Unknown OS. Supported OS are Linux and macOS."
    return 1
    ;;
  esac
  doctor_host
  if doctor_settings; then
    doctor_enrollment
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
