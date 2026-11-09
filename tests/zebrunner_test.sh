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
for command in setup ansible status backup restore shutdown version doctor join; do
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
check_contains "the invite is the next step" "2. The administrator of MCloud invites this host on its server: ./zebrunner.sh node-invite" "$output"
check_contains "the join is the next step" "3. Enroll this host: ./zebrunner.sh join and paste the join string" "$output"
check_contains "the devices are a step" "4. Declare the devices in 'devices:' of 'roles/devices/vars/main.yml'" "$output"
check_contains "the doctor is a step" "5. Check the settings, the enrollment and the network to MCloud: ./zebrunner.sh doctor" "$output"
check_contains "the deploy is a step" "6. Deploy the agent: ./zebrunner.sh ansible" "$output"
check_not_contains "no manual settings" "variables.env" "$output"
output="$(OS=Linux zbr "" setup)"
check "a second setup does not duplicate the variable" "1" "$(exports .bashrc)"
check_contains "a second setup backs up existing settings" "making a backup" "$output"
check "the backup of the settings exists" "yes" "$([[ -f "${AGENT}/roles/devices/vars/main.yml.bak" ]] && echo yes)"
OS=Darwin zbr "" setup > /dev/null
check "macOS settings are created from the example" "same" \
  "$(cmp -s "${AGENT}/roles/mac-devices/vars/main.yml" "${AGENT}/roles/mac-devices/vars/main.yml.original" && echo same)"
check_contains "unknown OS is rejected" "Unknown OS" "$(OS=FreeBSD zbr "" setup)"

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
vars="${AGENT}/roles/devices/vars/main.yml"
cp "$vars" "${WORK}/vars.before-join"
cp "${AGENT}/roles/devices/vars/main.yml.original" "$vars"
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
output="$(OS=Linux zbr "${join_string}\n" join)"
check "join enrolls the host" "0" "$?"
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
  "\"publicKey\": \"$(python3 "${REPO}/patch/curve_keygen.py" "$secret" | sed -n 's/^public=//p')\"" "$body"
check_not_contains "the secret key is not sent" "$secret" "$body"
check "the script makes the public key of RFC 7748" "public=8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" \
  "$(python3 "${REPO}/patch/curve_keygen.py" 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a | head -1)"
for line in 'MCLOUD_URL: "https://192.168.50.2:443"' "MCLOUD_TLS_PIN: \"${pin}\"" "MCLOUD_NODE_TOKEN: \"${node_token}\"" \
  "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY: \"${server_key}\"" 'PUBLIC_IP: "demo.zebrunner.farm"' 'PUBLIC_IP_PORT: "443"' \
  'PUBLIC_IP_PROTOCOL: "https"' 'STF_PROVIDER_CONNECT_SUB: "tcp://192.168.50.2:7250"' \
  'STF_PROVIDER_CONNECT_DEV_DEALER: "tcp://192.168.50.2:7260"' 'SELENIUM_HUB_HOST: "192.168.50.2"' \
  'SELENIUM_HUB_PORT: "4446"' 'STF_PROVIDER_HOST: "192.168.30.2"'; do
  check "join writes ${line%%:*}" "1" "$(grep -cxF -- "$line" "$vars")"
done
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
    FAKE_UNAME=Linux ZEBRUNNER_MCLOUD_AGENT_DIR="$AGENT" DOCTOR_FARM="${WORK}/farm" DOCTOR_DEVICES="${WORK}/devices.txt" \
    /bin/bash "${AGENT}/zebrunner.sh" doctor 2>&1
}
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
check_contains "the public address of a NAT in the network of the server is a problem" \
  "STF_PROVIDER_HOST 185.237.20.136 (185.237.20.136) is a public address of a NAT" "$output"
check_contains "a new invite with the address of this host in that network is the fix" \
  "a new invite of this host with the address 192.168.30.2 (./zebrunner.sh node-invite <label> 192.168.30.2 of mcloud)" "$output"
cp "${WORK}/vars.joined" "$vars"
chmod 600 "$vars"
self_answer 192.168.30.2 > "${WORK}/mcloud/self_answer"

# the remote debug through the adb relay of mcloud
printf '%s\n' "emu1|android|Emu|loc|7471|7472|7475|7480|android-sim|/dev/null|x|host:5557|||" > "${WORK}/devices.txt"
check_contains "the deployed devices are checked" "Emu: no running container" "$(doctor_run)"
check_contains "the remote debug of a private address is explained" \
  "adb connect of STF (the remote debug) reaches 192.168.30.2 from its network only" "$(doctor_run)"
sed -i.bak 's/^REMOTE_CONNECT_HOST:.*/REMOTE_CONNECT_HOST: demo.zebrunner.farm/' "$vars" && rm -f "${vars}.bak"
check_contains "the adb relay is checked on the remote debug port of the devices" \
  "adb relay of mcloud (REMOTE_CONNECT_HOST): demo.zebrunner.farm:7476 (192.168.50.2) accepts connections" "$(doctor_run)"
printf '%s\n' "emu1|android|Emu|loc|7471|7472|7475|7480|android-sim|/dev/null|x|host:5557|||7499" > "${WORK}/devices.txt"
check_contains "connect_port is the remote debug port" "the remote debug ports of this host (ADB_RELAY_PORTS of mcloud must have them): 192.168.30.2:7499" "$(doctor_run)"
echo "demo.zebrunner.farm:7499" > "${WORK}/net/closed"
check_contains "a missing relay tells the setting of mcloud" "ADB_RELAY=true of .env of mcloud" "$(doctor_run)"
: > "${WORK}/net/closed"
cp "${WORK}/vars.joined" "$vars"
chmod 600 "$vars"

# MCloud on this machine: the devices must not use its ports
echo "192.168.50.2" >> "${WORK}/net/local"
printf '%s\n' "emu1|android|Emu|loc|4446|7472|7475|7480|android-sim|/dev/null|x|host:5557||" > "${WORK}/devices.txt"
output="$(doctor_run)"
check_contains "MCloud on this machine is reported" "MCloud runs on this machine (192.168.50.2)" "$output"
check_contains "a port of MCloud used by a device is a problem" "the devices use the ports 4446 of MCloud on this machine" "$output"
printf '%s\n' "emu1|android|Emu|loc|7471|7472|7475|7480|android-sim|/dev/null|x|host:5557||" > "${WORK}/devices.txt"
check_contains "no port of MCloud used by the devices" "the devices use no port of MCloud on this machine" "$(doctor_run)"
echo "192.168.30.2" > "${WORK}/net/local"
rm -f "${WORK}/devices.txt"

# zebrunner-farm rendered with another STF_PROVIDER_HOST, then with the settings
if command -v ansible > /dev/null 2>&1; then
  render "${AGENT}/roles/devices/templates/zebrunner-farm" "${WORK}/farm" --extra-vars "@${AGENT}/defaults/main.yml" \
    --extra-vars "@${vars}" --extra-vars "STF_PROVIDER_HOST=185.237.20.136" || exit 1
  check_contains "a deployment with other settings is reported" "zebrunner-farm is deployed with other values of STF_PROVIDER_HOST" "$(doctor_run)"
  render "${AGENT}/roles/devices/templates/zebrunner-farm" "${WORK}/farm" --extra-vars "@${AGENT}/defaults/main.yml" \
    --extra-vars "@${vars}" || exit 1
  chmod 755 "${WORK}/farm"
  output="$(doctor_run)"
  check_contains "a deployment with the settings" "zebrunner-farm is deployed with the current settings" "$output"
  check_contains "a readable zebrunner-farm is reported" "zebrunner-farm has the secrets of the settings and is readable by every user" "$output"
  rm -f "${WORK}/farm"
else
  skip_check "the settings of the deployed zebrunner-farm" "no ansible"
fi

echo "192.168.50.2:4446" > "${WORK}/net/closed"
check_contains "a closed port is a problem" "192.168.50.2:4446 (192.168.50.2) does not accept connections: Connection refused" "$(doctor_run)"
: > "${WORK}/net/closed"
echo "mcloud.other.com 10.0.0.1" > "${WORK}/net/hosts"
check_contains "an unresolved server is a problem" "MCloud (PUBLIC_IP): demo.zebrunner.farm is not resolved" "$(doctor_run)"
echo "demo.zebrunner.farm 192.168.50.2" > "${WORK}/net/hosts"

sed -i.bak 's/^MCLOUD_NODE_TOKEN:.*/MCLOUD_NODE_TOKEN: "mcn1.x"/' "$vars" && rm -f "${vars}.bak"
check_contains "an invalid token is a problem" "MCLOUD_NODE_TOKEN is not a token of ./zebrunner.sh join" "$(doctor_run)"
chmod 644 "$vars"
check_contains "readable settings are reported" "have secrets and are readable by other users (mode 644)" "$(doctor_run)"
cp "${AGENT}/roles/devices/vars/main.yml.original" "$vars"
output="$(doctor_run)"
check_contains "a host without the enrollment is reported" "this host is not enrolled, empty: MCLOUD_URL MCLOUD_TLS_PIN MCLOUD_NODE_TOKEN" "$output"
check_contains "join is the fix" "./zebrunner.sh join with the join string of ./zebrunner.sh node-invite of mcloud" "$output"
rm -f "$vars"
check_contains "no settings" "roles/devices/vars/main.yml does not exist" "$(doctor_run)"
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
