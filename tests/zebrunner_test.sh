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
for command in setup ansible status backup restore shutdown version curve-key doctor join; do
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
check_contains "the enrollment is the next step" "2. Enroll this host (README.md#node-enrollment)" "$output"
check_contains "the join command is explained" "run ./zebrunner.sh join here and paste the join string" "$output"
check_contains "the manual settings are the alternative" "3. Without the enrollment set the settings of the MCloud server in 'roles/devices/vars/main.yml'" "$output"
check_contains "the address of the host is a step" "4. Set STF_PROVIDER_HOST" "$output"
check_contains "the key of the host is a step" "5. Make the key of this host: ./zebrunner.sh curve-key" "$output"
check_contains "the doctor is a step" "7. Check the settings and the network to the MCloud server: ./zebrunner.sh doctor" "$output"
check_contains "the deploy is a step" "8. Deploy the agent: ./zebrunner.sh ansible" "$output"
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
  check_contains "${os}: the line of variables.env of mcloud is printed" "STF_ZMQ_CURVE_CLIENT_KEY_$(hostname | sed 's/\..*//' | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')=${public}" "$output"
  check_not_contains "${os}: the secret key is not printed" "$secret" "$output"
  OS="$os" zbr "" curve-key > /dev/null
  check "${os}: the key is kept" "$secret" "$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY: "\(.*\)"$/\1/p' "$vars")"
done
vars="${AGENT}/roles/devices/vars/main.yml"
cp "$vars" "${WORK}/vars.saved"
grep -v '^STF_ZMQ_CURVE_SECRET_KEY:' "${WORK}/vars.saved" > "$vars"
check_contains "the settings need the line of the key" "has no STF_ZMQ_CURVE_SECRET_KEY line" "$(OS=Linux zbr "" curve-key)"
check "the settings without the line of the key are not changed" "same" \
  "$(grep -v '^STF_ZMQ_CURVE_SECRET_KEY:' "${WORK}/vars.saved" | cmp -s - "$vars" && echo same)"
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
# the running containers of the devices keep the old settings: the deploy offers to remove them first
cp "${WORK}/bin/docker" "${WORK}/docker"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "ps" ]] && printf "%s\n" device-Galaxy-R28-connector device-Galaxy-R28-stf device-Pixel-45-appium node_exporter
exit 0'
reset_calls
output="$(AGENT_DIR="$AGENT" OS=Linux zbr "\n" ansible)"
check_contains "running containers are reported" "3 containers of the devices are running" "$output"
check_contains "the devices of the running containers are listed" "device-Galaxy-R28" "$output"
check "the default answer removes them with zebrunner-farm" "down" "$(calls zebrunner-farm)"
check_contains "then the playbook runs" "${AGENT}/devices.yml" "$(calls ansible-playbook)"
reset_calls
output="$(AGENT_DIR="$AGENT" OS=Linux zbr "n\n" ansible)"
check "a declined removal keeps them" "" "$(calls zebrunner-farm)"
check_contains "a declined removal suggests the restart" "run 'zebrunner-farm restart' after the deploy" "$output"
check_contains "a declined removal deploys anyway" "${AGENT}/devices.yml" "$(calls ansible-playbook)"
reset_calls
AGENT_DIR="$AGENT" OS=Linux zbr "" ansible devices > /dev/null
check "the registration of the devices keeps the containers" "" "$(calls zebrunner-farm)"
mv "${WORK}/docker" "${WORK}/bin/docker"
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
check_contains "setup: Rosetta 2 not used by Docker Desktop is reported" "Docker Desktop runs the linux/amd64 image of appium under" "$(rosetta 1 1 setup)"
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
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub curl 'cat "${STUB_DIR}/net/curl_code"'
cp "${WORK}/bin/docker" "${WORK}/docker"
# docker of no container (inspect fails) and no device
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '[[ "$1" == "inspect" ]] && exit 1
exit 0'
echo "mcloud.example.com 192.168.50.2" > "${WORK}/net/hosts"
echo "192.168.30.2" > "${WORK}/net/local"
echo "192.168.30.2" > "${WORK}/net/source"
echo "403" > "${WORK}/net/curl_code"
: > "${WORK}/net/closed"
server_key="$(printf '%064d' 0 | tr 0 a)"
secret_key="77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
vars="${AGENT}/roles/devices/vars/main.yml"
cp "$vars" "${WORK}/vars.doctor"
# settings <STF_PROVIDER_HOST>: the settings of an agent in the network of the MCloud server mcloud.example.com
settings() {
  sed -e "s/^PUBLIC_IP: .*/PUBLIC_IP: mcloud.example.com/" -e "s/^PUBLIC_IP_PORT: .*/PUBLIC_IP_PORT: 443/" \
    -e "s|^STF_PROVIDER_CONNECT_\([A-Z_]*\): tcp://[^:]*:|STF_PROVIDER_CONNECT_\1: tcp://mcloud.example.com:|" \
    -e "s/^SELENIUM_HUB_HOST: .*/SELENIUM_HUB_HOST: mcloud.example.com/" -e "s/^SELENIUM_HUB_PORT: .*/SELENIUM_HUB_PORT: 4446/" \
    -e "s/^STF_PROVIDER_HOST: .*/STF_PROVIDER_HOST: $1/" -e 's/^NODE_REGISTRATION_TOKEN:.*/NODE_REGISTRATION_TOKEN: "grid-secret"/' \
    -e 's/^STF_STORAGE_TOKEN:.*/STF_STORAGE_TOKEN: "storage-secret"/' \
    -e "s/^STF_ZMQ_CURVE_SERVER_PUBLIC_KEY:.*/STF_ZMQ_CURVE_SERVER_PUBLIC_KEY: \"${server_key}\"/" \
    -e "s/^STF_ZMQ_CURVE_SECRET_KEY:.*/STF_ZMQ_CURVE_SECRET_KEY: \"${secret_key}\" # the key of this host/" \
    "${AGENT}/roles/devices/vars/main.yml.original" > "$vars"
  printf '%s\n' "  - id: R28M1384YQY" "    os: android" >> "$vars"
}
# doctor_run: ./zebrunner.sh doctor of a Linux host without the deployed files
doctor_run() {
  printf '' | env -i HOME="${WORK}/home" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    FAKE_UNAME=Linux ZEBRUNNER_MCLOUD_AGENT_DIR="$AGENT" DOCTOR_FARM="${WORK}/farm" DOCTOR_DEVICES="${WORK}/devices.txt" \
    /bin/bash "${AGENT}/zebrunner.sh" doctor 2>&1
}
rm -f "${WORK}/farm" "${WORK}/devices.txt"

settings 185.237.20.136
output="$(doctor_run)"
check "a broken agent fails" "1" "$?"
check_contains "the endpoints of the server are checked" "mcloud-grid (SELENIUM_HUB_HOST): mcloud.example.com:4446 (192.168.50.2) accepts connections" "$output"
check_contains "the public address of a NAT in the network of the server is a problem" \
  "STF_PROVIDER_HOST 185.237.20.136 (185.237.20.136) is a public address of a NAT" "$output"
check_contains "the address of this host in that network is the fix" "fix: STF_PROVIDER_HOST: 192.168.30.2 in roles/devices/vars/main.yml" "$output"
check_contains "a host out of AGENT_HOSTS is a problem" "stf-proxy of mcloud refuses the screens of 185.237.20.136: it is not in AGENT_HOSTS" "$output"
check_contains "the public key of the host is shown as the line of mcloud" "variables.env of mcloud as STF_ZMQ_CURVE_CLIENT_KEY_" "$output"
check_contains "the public key is the one of the secret key" "=8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" "$output"
for secret in grid-secret storage-secret "$secret_key"; do
  check_not_contains "a secret is not printed" "$secret" "$output"
done
check_contains "not deployed agent" "zebrunner-farm is not deployed" "$output"
check_contains "the problems are counted" "2 problems" "$output"

settings 192.168.30.2
echo "401" > "${WORK}/net/curl_code"
output="$(doctor_run)"
check "a working agent passes" "0" "$?"
check_contains "an address of this host" "STF_PROVIDER_HOST 192.168.30.2 is an address of this host" "$output"
check_contains "a host of AGENT_HOSTS" "stf-proxy of mcloud serves the screens of 192.168.30.2 (AGENT_HOSTS)" "$output"
check_contains "the devices are counted" "$(grep -cE '^ *- +id:' "$vars") devices are declared" "$output"
# the deployed devices: the list of now (14 fields) and the one deployed before the proxy ports were dropped (16 fields)
printf '%s\n' "emu1|android|Emu|loc|7471|7472|7475|7480|android-sim|/dev/null|x|host:5557||" > "${WORK}/devices.txt"
check_contains "the deployed devices are checked" "Emu: no running container" "$(doctor_run)"
printf '%s\n' "emu1|android|Emu|loc|7471|7472|7473|7474|7475|7480|android-sim|/dev/null|x|host:5557||" > "${WORK}/devices.txt"
check_contains "a list of the earlier format is read too" "Emu: no running container" "$(doctor_run)"
check_contains "the remote debug of a private address is explained" \
  "adb connect of STF (the remote debug) reaches 192.168.30.2 from its network only" "$(doctor_run)"
sed -i.bak "s/^REMOTE_CONNECT_HOST:.*/REMOTE_CONNECT_HOST: mcloud.example.com/" "$vars"
check_contains "the adb relay is checked on the port of the devices" \
  "adb relay of mcloud (REMOTE_CONNECT_HOST): mcloud.example.com:7476 (192.168.50.2) accepts connections" "$(doctor_run)"
echo "mcloud.example.com:7476" > "${WORK}/net/closed"
check_contains "the entries of the relay are the remote debug ports" "the remote debug ports of this host (ADB_RELAY_PORTS of mcloud must have them): 192.168.30.2:7476" "$(doctor_run)"
check_contains "a missing relay tells the entry of mcloud" "ADB_RELAY=true of .env of mcloud (the relay takes the ports of the devices from STF), or ADB_RELAY_HOSTS with 192.168.30.2:7476" "$(doctor_run)"
: > "${WORK}/net/closed"
rm -f "${WORK}/devices.txt"
settings 192.168.30.2

# zebrunner-farm rendered with another STF_PROVIDER_HOST, then with the settings
if command -v ansible > /dev/null 2>&1; then
  render "${AGENT}/roles/devices/templates/zebrunner-farm" "${WORK}/farm" --extra-vars "@${AGENT}/defaults/main.yml" \
    --extra-vars "@${vars}" --extra-vars "STF_PROVIDER_HOST=185.237.20.136" || exit 1
  check_contains "a deployment with other settings is reported" "zebrunner-farm is deployed with other values of STF_PROVIDER_HOST" "$(doctor_run)"
  render "${AGENT}/roles/devices/templates/zebrunner-farm" "${WORK}/farm" --extra-vars "@${AGENT}/defaults/main.yml" \
    --extra-vars "@${vars}" || exit 1
  check_contains "a deployment with the settings" "zebrunner-farm is deployed with the current settings" "$(doctor_run)"
  rm -f "${WORK}/farm"
else
  skip_check "the settings of the deployed zebrunner-farm" "no ansible"
fi

echo "mcloud.example.com:4446" > "${WORK}/net/closed"
check_contains "a closed port is a problem" "mcloud.example.com:4446 (192.168.50.2) does not accept connections: Connection refused" "$(doctor_run)"
: > "${WORK}/net/closed"
echo "mcloud.other.com 10.0.0.1" > "${WORK}/net/hosts"
check_contains "an unresolved server is a problem" "MCloud (PUBLIC_IP): mcloud.example.com is not resolved" "$(doctor_run)"

cp "${AGENT}/roles/devices/vars/main.yml.original" "$vars"
output="$(doctor_run)"
check_contains "the empty obligatory settings are listed" \
  "empty: STF_STORAGE_TOKEN NODE_REGISTRATION_TOKEN STF_ZMQ_CURVE_SERVER_PUBLIC_KEY STF_ZMQ_CURVE_SECRET_KEY" "$output"
check_contains "the example host is a problem" "STF_PROVIDER_HOST is the example linux-agent.zebrunner.farm" "$output"
rm -f "$vars"
check_contains "no settings" "roles/devices/vars/main.yml does not exist" "$(doctor_run)"
mv "${WORK}/docker" "${WORK}/bin/docker"
mv "${WORK}/netcheck.py" "${AGENT}/patch/netcheck.py"
mv "${WORK}/vars.doctor" "$vars"
rm -f "${WORK}/bin/curl"

section "join"
# a fake MCloud: curl records its arguments and its stdin (the body), answers ${WORK}/enroll/answer with the HTTP code of
# ${WORK}/enroll/code and exits with ${WORK}/enroll/exit
mkdir -p "${WORK}/enroll"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub curl '(IFS="|"; echo "curl|$*") >> "${STUB_DIR}/calls.log"
cat > "${STUB_DIR}/enroll/body"
exit_code="$(cat "${STUB_DIR}/enroll/exit" 2> /dev/null)"
[[ "${exit_code:-0}" == "0" ]] || { echo "curl: (${exit_code}) failed" >&2; exit "$exit_code"; }
printf "%s\n%s" "$(cat "${STUB_DIR}/enroll/answer")" "$(cat "${STUB_DIR}/enroll/code")"'
vars="${AGENT}/roles/devices/vars/main.yml"
cp "$vars" "${WORK}/vars.before-join"
cp "${AGENT}/roles/devices/vars/main.yml.original" "$vars"
sed -i.bak -e 's/^NODE_REGISTRATION_TOKEN:.*/NODE_REGISTRATION_TOKEN: "shared-grid-secret"/' \
  -e 's/^STF_STORAGE_TOKEN:.*/STF_STORAGE_TOKEN: "shared-storage-secret"/' "$vars" && rm -f "${vars}.bak"
pin="$(printf '%043d' 0 | tr 0 Q)="
invite="mci1.$(printf '%043d' 0 | tr 0 i)"
node_token="mcn1.build-ua.$(printf '%043d' 0 | tr 0 n)"
join_string="mcloud-join://192.168.50.2:443?label=build-ua&grid=192.168.50.2:4446&pin=${pin//=/%3D}&token=${invite}"
server_key="$(printf '%064d' 0 | tr 0 c)"
# answer <token> <address>: the answer of the enrollment
answer() {
  printf '{"nodeToken":"%s","label":"build-ua","address":"%s","serverPublicKey":"%s","stfUrl":"https://demo.zebrunner.farm",' "$1" "$2" "$server_key"
  printf '"endpoints":{"sub":"tcp://stf-triproxy-dev:7250","push":"tcp://stf-triproxy-dev:7270","appDealer":"tcp://stf-triproxy-app:7160","devDealer":"tcp://stf-triproxy-dev:7260"}}'
}
answer "$node_token" 192.168.30.2 > "${WORK}/enroll/answer"
echo 200 > "${WORK}/enroll/code"
echo 0 > "${WORK}/enroll/exit"
reset_calls
output="$(OS=Linux zbr "${join_string}\n" join)"
check "join enrolls the host" "0" "$?"
check_contains "join reports the label and the address" "enrolled in MCloud 192.168.50.2 as build-ua, its address is 192.168.30.2" "$output"
check_contains "the enrollment goes to MCloud over HTTPS with the pinned key only" \
  "--pinnedpubkey|sha256//${pin}|" "$(calls curl)"
check_contains "the enrollment URL" "https://192.168.50.2:443/api/v1/nodes/enroll" "$(calls curl)"
check_not_contains "the invite is not in the arguments of curl" "$invite" "$(calls curl)"
body="$(cat "${WORK}/enroll/body")"
check_contains "the body has the invite" "\"invite\": \"${invite}\"" "$body"
check_contains "the body has the label" "\"label\": \"build-ua\"" "$body"
secret="$(sed -n 's/^STF_ZMQ_CURVE_SECRET_KEY: "\(.*\)"$/\1/p' "$vars")"
check "join makes the CURVE key of the host" "64" "${#secret}"
check_contains "the body has the public key of the host" "\"publicKey\": \"$(python3 "${REPO}/patch/curve_keygen.py" "$secret" | sed -n 's/^public=//p')\"" "$body"
check_not_contains "the secret key is not sent" "$secret" "$body"
for line in "MCLOUD_NODE_TOKEN: \"${node_token}\"" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY: \"${server_key}\"" \
  'PUBLIC_IP: "demo.zebrunner.farm"' 'PUBLIC_IP_PORT: "443"' 'PUBLIC_IP_PROTOCOL: "https"' \
  'STF_PROVIDER_CONNECT_SUB: "tcp://192.168.50.2:7250"' 'STF_PROVIDER_CONNECT_DEV_DEALER: "tcp://192.168.50.2:7260"' \
  'SELENIUM_HUB_HOST: "192.168.50.2"' 'SELENIUM_HUB_PORT: "4446"' 'STF_PROVIDER_HOST: "192.168.30.2"' \
  'NODE_REGISTRATION_TOKEN:' 'STF_STORAGE_TOKEN:'; do
  check "join writes ${line%%:*}" "1" "$(grep -cxF -- "$line" "$vars")"
done
check_not_contains "the shared tokens are removed" "shared-" "$(cat "$vars")"
check "the settings are private" "600" "$(stat -c '%a' "$vars" 2> /dev/null || stat -f '%Lp' "$vars")"
backup="$(find "$(dirname "$vars")" -name 'main.yml.bak-join-*' | head -1)"
check "the previous settings are kept, private too" "600" "$(stat -c '%a' "$backup" 2> /dev/null || stat -f '%Lp' "$backup")"
check_not_contains "the token is not printed" "$node_token" "$output"
check_not_contains "the invite is not printed" "$invite" "$output"
check_contains "the next steps are printed" "./zebrunner.sh ansible deploys them" "$output"
rm -f "${vars}".bak-join-*

cp "$vars" "${WORK}/vars.joined"
check_contains "a wrong join string fails" "not a join string of ./zebrunner.sh node-invite" "$(OS=Linux zbr "https://example.com\n" join)"
check_contains "a join string without the pin fails" "the pin of the join string is not a sha256 in base64" \
  "$(OS=Linux zbr "${join_string/pin=/pinx=}\n" join)"
echo 90 > "${WORK}/enroll/exit"
check_contains "another TLS key of the server stops the enrollment" "the TLS key of the server is not the pinned one" \
  "$(OS=Linux zbr "${join_string}\n" join)"
echo 0 > "${WORK}/enroll/exit"
echo 403 > "${WORK}/enroll/code"
check_contains "a refused invite is explained" "MCloud refused the enrollment (HTTP 403)" "$(OS=Linux zbr "${join_string}\n" join)"
echo 200 > "${WORK}/enroll/code"
answer "mcn1.other-host.$(printf '%043d' 0 | tr 0 n)" 192.168.30.2 > "${WORK}/enroll/answer"
check_contains "a token of another label is refused" "MCloud answered no valid token of this label" "$(OS=Linux zbr "${join_string}\n" join)"
answer "$node_token" '192.168.30.2\nMCLOUD_NODE_TOKEN: x' > "${WORK}/enroll/answer"
output="$(OS=Linux zbr "${join_string}\n" join)"
check_contains "an answer cannot inject settings" "the address of this host is not a host name or address" "$output"
check "a failed enrollment changes no setting" "same" "$(cmp -s "$vars" "${WORK}/vars.joined" && echo same)"
rm -f "${vars}".bak-join-* "${WORK}/bin/curl"

section "doctor of an enrolled host"
# the settings of the join above, a working network of the fake netcheck.py
cp "${WORK}/vars.joined" "$vars"
cp "${AGENT}/patch/netcheck.py" "${WORK}/netcheck.py"
printf '%s\n' 'import sys' 'sys.exit(0 if sys.argv[1] != "local" else 1)' > "${AGENT}/patch/netcheck.py"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub curl 'echo 401'
cp "${WORK}/bin/docker" "${WORK}/docker"
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '[[ "$1" == "inspect" ]] && exit 1
exit 0'
output="$(doctor_run)"
check_contains "an enrolled host is reported" "this host is enrolled in MCloud as build-ua" "$output"
check_not_contains "the token is not printed by doctor" "$node_token" "$output"
check_not_contains "no warning about the shared tokens after join" "the shared tokens of the manual setup are still" "$output"
check_not_contains "the shared tokens are not obligatory with the token" "NODE_REGISTRATION_TOKEN STF" "$output"
sed -i.bak 's/^NODE_REGISTRATION_TOKEN:.*/NODE_REGISTRATION_TOKEN: "shared-grid-secret"/' "$vars" && rm -f "${vars}.bak"
check_contains "the shared tokens left are reported" "the shared tokens of the manual setup are still in the settings" "$(doctor_run)"
sed -i.bak 's/^MCLOUD_NODE_TOKEN:.*/MCLOUD_NODE_TOKEN: "mcn1.x"/' "$vars" && rm -f "${vars}.bak"
check_contains "an invalid token is a problem" "MCLOUD_NODE_TOKEN is not a token of ./zebrunner.sh join" "$(doctor_run)"
chmod 644 "$vars"
check_contains "readable settings are reported" "have secrets and are readable by other users (mode 644)" "$(doctor_run)"
sed -i.bak 's/^MCLOUD_NODE_TOKEN:.*/MCLOUD_NODE_TOKEN:/' "$vars" && rm -f "${vars}.bak"
check_contains "a host without the token is not enrolled" "this host is not enrolled" "$(doctor_run)"
mv "${WORK}/docker" "${WORK}/bin/docker"
mv "${WORK}/netcheck.py" "${AGENT}/patch/netcheck.py"
rm -f "${WORK}/bin/curl"
mv "${WORK}/vars.before-join" "$vars"

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
