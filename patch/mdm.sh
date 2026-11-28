#!/bin/bash
# the dev_* fields of get_device_fields and the settings of zebrunner-farm
# shellcheck disable=SC2154
# ./zebrunner.sh mdm (README.md#mdm): the devices of this host in the MDM of its MCloud (zebrunner/mcloud-mdm behind
# stf-proxy), the preparation of a device for the farm. The host calls MCloud with its node token (MCLOUD_URL,
# MCLOUD_TLS_PIN, MCLOUD_NODE_TOKEN of `./zebrunner.sh join`): stf-proxy checks it and calls the MDM with its own
# enrollment token. enroll, release and supervise of a device run in one-shot containers of the image of its connector,
# with its USB device (Linux) or the adb server and usbmuxd of the host (macOS), while the containers of the device are
# stopped: a new device without containers is enrolled too. The secrets of the device (the setup of the Android agent,
# the password of the supervision identity) go to the container on its stdin, never in the arguments of docker. status
# asks the MDM only. Sourced by zebrunner.sh after zebrunner-farm (get_device_fields, select_devices, stop_containers,
# create_containers); keep it compatible with the macOS system bash 3.2.

MDM_AGENT_PACKAGE="com.hmdm.launcher"
MDM_AGENT_ADMIN="${MDM_AGENT_PACKAGE}/.AdminReceiver"

# mdm_ready: the settings of the enrollment of this host are there
mdm_ready() {
  local missing=""
  [[ -n "$MCLOUD_URL" ]] || missing+=" MCLOUD_URL"
  [[ -n "$MCLOUD_TLS_PIN" ]] || missing+=" MCLOUD_TLS_PIN"
  [[ -n "$MCLOUD_NODE_TOKEN" ]] || missing+=" MCLOUD_NODE_TOKEN"
  if [[ -n "$missing" ]]; then
    ui_fail "This host is not enrolled in MCloud, empty:${missing}" "./zebrunner.sh join (README.md#node-enrollment)"
    return 1
  fi
}

# mdm_call <method> <path> [<output file>]: a request to MCloud over HTTPS, with the node token on the stdin of curl:
# to the pinned TLS key, or for a certificate of a public CA (MCLOUD_TLS_PUBLIC of the deploy) to the name PUBLIC_IP
# with the CAs of the system (mcloud_tls of patch/utility.sh); MDM_STATUS is the HTTP status, the answer goes to stdout
# or to the file, a failure to stderr
MDM_STATUS=""
mdm_call() {
  local method="$1"
  local path="$2"
  local output="${3:-}"
  local answer
  local out_args=()
  [[ -n "$output" ]] && out_args=(-o "$output")
  MDM_STATUS=""
  mcloud_tls "$MCLOUD_URL" "$MCLOUD_TLS_PIN" "${MCLOUD_TLS_PUBLIC:-false}" "${PUBLIC_IP:-}" "${PUBLIC_IP_PORT:-}"
  if ! answer="$(printf 'Authorization: Bearer %s\n' "$MCLOUD_NODE_TOKEN" | curl -sS "${MCLOUD_TLS_ARGS[@]}" --max-time 120 \
    -H @- -X "$method" "${out_args[@]+"${out_args[@]}"}" -w '\n%{http_code}' "${MCLOUD_TLS_BASE}${path}" 2>&1)"; then
    ui_fail "MCloud ${MCLOUD_URL} does not answer: ${answer##*$'\n'}" >&2
    return 1
  fi
  MDM_STATUS="${answer##*$'\n'}"
  answer="${answer%$'\n'*}"
  # the body of an error went to the output file
  if [[ -n "$output" && "$MDM_STATUS" != 2?? && -f "$output" ]]; then
    answer="$(head -c 300 "$output")"
    rm -f "$output"
  fi
  case "$MDM_STATUS" in
  2??)
    [[ -n "$output" ]] || printf '%s\n' "$answer"
    return 0
    ;;
  401) ui_fail "MCloud refuses the node token of this host" "./zebrunner.sh doctor" >&2 ;;
  403)
    # mcloud-mdm answers "forbidden" for a device of another node (MDM_ENFORCE_NODE_BINDING), stf-proxy a page
    if [[ "$answer" == forbidden* ]]; then
      ui_fail "MCloud refuses the MDM of this device to this node: STF binds it to another node or does not know it yet (MDM_ENFORCE_NODE_BINDING of MCloud)" >&2
    else
      ui_fail "MCloud refuses this address: the public address of this site is not in MDM_SITE_ADDRESSES of MCloud" >&2
    fi
    ;;
  404) ui_fail "No MDM on MCloud (MDM_ENABLED of its .env) or no Android there (${path%%\?*})" >&2 ;;
  409) ui_fail "${answer##*error=}" >&2 ;;
  *) ui_fail "MCloud answers ${MDM_STATUS}: ${answer}" >&2 ;;
  esac
  return 1
}

# mdm_query <value>: the value as a query parameter of a URL
mdm_query() {
  local value="$1"
  local out=""
  local c
  local i
  for ((i = 0; i < ${#value}; i++)); do
    c="${value:i:1}"
    case "$c" in
    [A-Za-z0-9._~-]) out+="$c" ;;
    *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# mdm_status: what the MDM knows about the device of get_device_fields; the device is not touched
mdm_status() {
  local path
  if [[ "$dev_platform_name" == "android" ]]; then
    path="/android/status?serial=$(mdm_query "$dev_udid")&format=shell"
  else
    path="/mdm/status?udid=$(mdm_query "$dev_udid")&format=shell"
  fi
  local answer
  answer="$(mdm_call GET "$path")" || return 1
  sed 's/^/  /' <<< "$answer"
}

# MDM_ONE_SHOT_RUNNER: the shell of a one-shot container reads the whole script of its stdin first, then runs it with
# the stdin /dev/null: adb shell forwards its stdin to the device, under sh -s it took the rest of a long script
# (sh: syntax error: unterminated quoted string after the device owner); the secrets stay out of the arguments
# shellcheck disable=SC2016
MDM_ONE_SHOT_RUNNER='script="$(cat)" && eval "$script" < /dev/null'

# mdm_one_shot <image> <arguments of docker run...>: a one-shot container of the image that runs the script of its stdin
mdm_one_shot() {
  local image="$1"
  shift
  docker run --rm -i --name "${dev_container}-mdm" "$@" --entrypoint sh "$image" -c "$MDM_ONE_SHOT_RUNNER"
}

# mdm_usb_args: the USB device of the connector (Linux) into MDM_USB_ARGS; macOS reaches the device by the host
MDM_USB_ARGS=()
mdm_usb_args() {
  MDM_USB_ARGS=()
  if [[ "$FARM_OS" != "macos" ]]; then
    MDM_USB_ARGS=(--device="/dev/${dev_container}:$(readlink -f "/dev/${dev_container}")")
  fi
}

# mdm_with_device_free <command...>: the command with the containers of the device stopped, the ones that ran are
# started again; the connector holds the device (adb, usbmuxd)
mdm_with_device_free() {
  local had=""
  read_container_states
  if [[ "$(container_state "${dev_container}-connector")" == "running" ]]; then
    had=1
    ui_info "Stopping the containers of the device"
    stop_containers > /dev/null
  fi
  local status=0
  "$@" || status=$?
  if [[ -n "$had" ]]; then
    ui_info "Starting the containers of the device again"
    create_containers > /dev/null || status=1
  fi
  return "$status"
}

# mdm_android_script <adb setup|release command> <action> [<staged JSON>]: the script of the one-shot Android
# connector; with the JSON the staged form of an agent that has it (the secret on the stdin of content write, printf is
# a builtin), else the command (the argument form); both go to the container in the script on its stdin
mdm_android_script() {
  local command="$1"
  local action="$2"
  local staged="${3:-}"
  local serial="$dev_udid"
  local path="setup"
  [[ "$action" == "enroll" ]] || path="release"
  echo "set -e"
  echo "s='${serial}'"
  echo "staged='${staged}'"
  echo "command='${command}'"
  # Linux: the adb server of the container with the adb key of the farm; macOS: the adb server of the host
  if [[ "$FARM_OS" != "macos" ]]; then
    echo "adb start-server > /dev/null 2>&1"
  fi
  cat << 'EOF'
i=0
until test "$(adb -s "$s" get-state 2> /dev/null)" = device; do
  i=$((i + 1))
  if test "$i" -gt 30; then
    echo "  the device is not online for adb: plugged in and its USB debugging authorized?"
    exit 1
  fi
  sleep 1
done
EOF
  if [[ "$action" == "enroll" ]]; then
    cat << EOF
echo "  installing the agent"
adb -s "\$s" install -r /mdm/agent.apk > /dev/null
# a device owner set when the agent was a test-only app stays removable over adb: it is set again
if adb -s "\$s" shell dumpsys device_policy | grep -q 'testOnlyAdmin=true'; then
  adb -s "\$s" shell dpm remove-active-admin ${MDM_AGENT_ADMIN} > /dev/null
fi
if adb -s "\$s" shell dpm list-owners | grep -q '${MDM_AGENT_PACKAGE}/'; then
  echo "  the agent is the device owner already"
else
  echo "  the agent becomes the device owner (Android refuses it with an account or a second user on the device)"
  adb -s "\$s" shell dpm set-device-owner ${MDM_AGENT_ADMIN}
fi
EOF
    mdm_android_apply "$path"
    cat << EOF
adb -s "\$s" shell am start -n ${MDM_AGENT_PACKAGE}/.ui.MainActivity > /dev/null
sleep 10
adb -s "\$s" shell content call --uri content://${MDM_AGENT_PACKAGE}.mcloud --method status | sed 's/^/  /'
EOF
  else
    mdm_android_apply "$path"
    cat << EOF
if adb -s "\$s" shell dpm list-owners | grep -q '${MDM_AGENT_PACKAGE}/'; then
  echo "  the agent is still the device owner"
  exit 1
fi
echo "  the device has no device owner"
EOF
    if [[ "$MDM_UNINSTALL" == "1" ]]; then
      echo "adb -s \"\$s\" uninstall ${MDM_AGENT_PACKAGE} > /dev/null && echo '  the agent is uninstalled'"
    fi
  fi
  if [[ "$FARM_OS" != "macos" ]]; then
    echo "adb kill-server > /dev/null 2>&1 || true"
  fi
}

# mdm_android_apply <setup|release>: the part of the script that sets the agent up or releases it: the staged form when
# the MDM gave it, the agent lists the feature staged in its status and Android has content write (9+), else the
# argument form; the call must answer a Bundle (the provider prints its errors with the exit status 0)
mdm_android_apply() {
  local path="$1"
  cat << EOF
sdk="\$(adb -s "\$s" shell getprop ro.build.version.sdk | tr -dc '0-9')"
status="\$(adb -s "\$s" shell content call --uri content://${MDM_AGENT_PACKAGE}.mcloud --method status | tr -d '\r')"
if test -n "\$staged" && test "\${sdk:-0}" -ge 28 && printf '%s' "\$status" | grep -q 'features=[a-z,]*staged'; then
  printf '%s' "\$staged" | adb -s "\$s" shell content write --uri content://${MDM_AGENT_PACKAGE}.mcloud/${path}
  result="\$(adb -s "\$s" shell content call --uri content://${MDM_AGENT_PACKAGE}.mcloud --method ${path})"
elif test -n "\$command"; then
  echo "  the agent has no staged ${path} (a new agent, Android 9+): the secret goes in its arguments"
  result="\$(adb -s "\$s" shell "\$command")"
else
  echo "  the agent has no staged ${path} (a new agent, Android 9+) and the MDM gives no other (MDM_ANDROID_LEGACY_SETUP of mcloud-mdm)"
  exit 1
fi
case "\$result" in
*"Result: Bundle["*) ;;
*)
  echo "  the ${path} of the agent failed: \$(printf '%s' "\$result" | head -n 2 | tr -d '\r')"
  exit 1
  ;;
esac
EOF
}

# mdm_android_answer <answer of the MDM>: MDM_STAGED (the JSON of the staged form) and MDM_COMMAND (the adb shell
# command of the argument form) of an answer to staged=1 (staged=, command=), or the single command of an older MDM;
# anything else, or a quote (they go into single quotes of the script), is refused
MDM_STAGED=""
MDM_COMMAND=""
mdm_android_answer() {
  local answer="$1"
  MDM_STAGED="$(sed -n 's/^staged=//p' <<< "$answer" | head -n 1)"
  MDM_COMMAND="$(sed -n 's/^command=//p' <<< "$answer" | head -n 1)"
  if [[ -z "$MDM_STAGED" && -z "$MDM_COMMAND" ]]; then
    MDM_COMMAND="$(head -n 1 <<< "$answer")"
  fi
  if [[ -n "$MDM_COMMAND" && ("$MDM_COMMAND" != "content call "* || "$MDM_COMMAND" == *"'"*) ]] ||
    [[ -n "$MDM_STAGED" && ("$MDM_STAGED" != "{"*"}" || "$MDM_STAGED" == *"'"*) ]] ||
    [[ -z "$MDM_STAGED" && -z "$MDM_COMMAND" ]]; then
    ui_fail "An unexpected answer of the MDM"
    return 1
  fi
}

# mdm_android <enroll|release>: the agent of the MDM as the device owner of the Android device, or released
mdm_android() {
  local action="$1"
  local work="$MDM_WORK"
  local command
  if [[ "$action" == "enroll" ]]; then
    ui_info "Getting the agent and its setup from the MDM"
    mdm_call GET /android/agent.apk "${work}/agent.apk" || return 1
    # staged=1: the staged form too (an older MDM ignores it and answers the command only)
    command="$(mdm_call GET "/android/enroll?serial=$(mdm_query "$dev_udid")&name=$(mdm_query "$dev_device_name")&format=shell&staged=1")" || return 1
  else
    # the serial: an MCloud with MDM_ENFORCE_NODE_BINDING=true releases only a device of this node
    command="$(mdm_call GET "/android/release?serial=$(mdm_query "$dev_udid")&staged=1")" || return 1
  fi
  mdm_android_answer "$command" || return 1
  local env_args=()
  if [[ "$FARM_OS" == "macos" ]]; then
    env_args=(-e ADB_SERVER_SOCKET="tcp:${ADB_SERVER_SOCKET_ADDRESS:-host.docker.internal:5037}")
  fi
  mdm_usb_args
  mdm_android_script "$MDM_COMMAND" "$action" "$MDM_STAGED" | mdm_one_shot "${ANDROID_CONNECTOR_IMAGE}:${ANDROID_CONNECTOR_VERSION}" \
    "${MDM_USB_ARGS[@]+"${MDM_USB_ARGS[@]}"}" "${env_args[@]+"${env_args[@]}"}" \
    -v mcloud-key-volume:/root/.android -v "${work}:/mdm:ro"
}

# mdm_ios_enroll: the enrollment profile installed over USB with the supervision identity, no prompt on the device
mdm_ios_enroll() {
  if [[ -z "$MDM_SUPERVISION_P12" || ! -r "$MDM_SUPERVISION_P12" ]]; then
    ui_fail "MDM_SUPERVISION_P12 of config/settings.yml is not a readable file: the supervision identity of the farm (README.md#mdm)"
    return 1
  fi
  local work="$MDM_WORK"
  ui_info "Getting the enrollment profile from the MDM"
  mdm_call GET "/mdm/enroll?udid=$(mdm_query "$dev_udid")&name=$(mdm_query "$dev_device_name")" "${work}/enroll.mobileconfig" || return 1
  cp "$MDM_SUPERVISION_P12" "${work}/supervision.p12"
  chmod 644 "${work}/supervision.p12" "${work}/enroll.mobileconfig"
  local os_args=()
  mdm_usb_args
  if [[ "$FARM_OS" != "macos" ]]; then
    os_args=(-v "${dev_container}-lockdown:/var/lib/lockdown")
  fi
  mdm_ios_script | mdm_one_shot "${IOS_CONNECTOR_IMAGE}:${IOS_CONNECTOR_VERSION}" "${MDM_USB_ARGS[@]+"${MDM_USB_ARGS[@]}"}" \
    "${os_args[@]+"${os_args[@]}"}" -v "${work}:/mdm:ro"
}

# mdm_ios_script: the script of the one-shot iOS connector, with the password of the supervision identity: on the stdin
# of the container only
mdm_ios_script() {
  echo "set -e"
  echo "u='${dev_udid}'"
  echo "MDM_PROFILE_TRIES='${MDM_PROFILE_TRIES:-1}'"
  if [[ "$FARM_OS" == "macos" ]]; then
    # usbmuxd of the host, as the connector of a macOS host
    echo "socat UNIX-LISTEN:/var/run/usbmuxd,fork,reuseaddr,mode=777 TCP:'${USBMUXD_SOCKET_ADDRESS}' > /dev/null 2>&1 &"
  else
    echo "usbmuxd -f > /dev/null 2>&1 &"
  fi
  # the password of the identity: on stdin only, quoted for sh ('it'\''s')
  printf "P12_PASSWORD='%s'\n" "$(printf '%s' "$MDM_SUPERVISION_P12_PASSWORD" | sed "s/'/'\\\\''/g")"
  cat << 'EOF'
export P12_PASSWORD
i=0
until ios list 2> /dev/null | grep -q "$u"; do
  i=$((i + 1))
  if test "$i" -gt 30; then
    echo "  the device is not on usbmuxd"
    exit 1
  fi
  sleep 1
done
# a supervised device pairs with the supervision identity without a prompt; the log of go-ios only on a failure
if ! ios info --udid="$u" > /dev/null 2>&1; then
  echo "  pairing with the supervision identity"
  if ! out="$(ios pair --p12file=/mdm/supervision.p12 --udid="$u" 2>&1)"; then
    echo "$out" | tail -n 5
    exit 1
  fi
fi
echo "  installing the enrollment profile"
# a device just erased joins its Wi-Fi after a while: iOS refuses the profile without a network ("add failed")
i=0
until out="$(ios profile add /mdm/enroll.mobileconfig --p12file=/mdm/supervision.p12 --udid="$u" 2>&1)"; do
  i=$((i + 1))
  if test "$i" -ge "${MDM_PROFILE_TRIES:-1}"; then
    echo "$out" | tail -n 5
    exit 1
  fi
  sleep 20
done
echo "  the device enrolls in the MDM: ./zebrunner.sh mdm status shows it"
EOF
}

# mdm_ios_release: the MDM removes its enrollment profile (RemoveProfile over APNs): the device leaves the MDM with every
# profile of it; the device stays supervised and is not touched here
mdm_ios_release() {
  local answer
  answer="$(mdm_call POST "/mdm/release?udid=$(mdm_query "$dev_udid")&format=shell")" || return 1
  ui_ok "The MDM sent RemoveProfile (${answer##*command=}): the device leaves it once it is online"
}

# the number of the device of mdm_main and the number of its devices (1/3), in the title of the device
MDM_COUNTER=""

# mdm_device <status|enroll|release>: the command for the device of get_device_fields; MDM_WORK is a folder of the
# files of the one-shot container (the agent, the enrollment profile), removed at the end
MDM_WORK=""
mdm_device() {
  local action="$1"
  local status=0
  mdm_ready || return 1
  MDM_WORK="$(mktemp -d)"
  mdm_device_in "$action" || status=$?
  rm -rf "$MDM_WORK"
  return "$status"
}

mdm_device_in() {
  local action="$1"
  ui_section "mdm ${action}" "$MDM_COUNTER" "${dev_device_name} (${dev_udid}, ${dev_platform_name}, ${dev_connection})"
  if [[ "$action" == "status" ]]; then
    mdm_status
    return
  fi
  if [[ "$dev_connection" != "usb" ]]; then
    ui_fail "The MDM takes the USB devices only (the connection of this one is ${dev_connection})"
    return 1
  fi
  case "${dev_platform_name}:${action}" in
  ios:release)
    mdm_ios_release
    ;;
  ios:enroll)
    usb_connected > /dev/null || {
      ui_fail "Not connected over USB"
      return 1
    }
    mdm_with_device_free mdm_ios_enroll
    ;;
  ios:supervise)
    usb_connected > /dev/null || {
      ui_fail "Not connected over USB"
      return 1
    }
    mdm_ios_supervise
    ;;
  android:supervise)
    ui_fail "supervise is for iOS: an Android device needs no erase, enroll makes the agent its device owner" \
      "./zebrunner.sh mdm enroll ${dev_device_name}"
    return 1
    ;;
  android:*)
    usb_connected > /dev/null || {
      ui_fail "Not connected over USB"
      return 1
    }
    mdm_with_device_free mdm_android "$action"
    ;;
  *)
    ui_fail "The MDM takes Android and iOS devices only"
    return 1
    ;;
  esac
}

# mdm_xml <text>: the text escaped for a plist
mdm_xml() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# mdm_wifi_profile: the profile of the Wi-Fi of the farm (MDM_WIFI_SSID, MDM_WIFI_PASSWORD, MDM_WIFI_ENCRYPTION) a
# device joins after its erase: the MDM reaches it over this network
mdm_wifi_profile() {
  local password=""
  if [[ -n "$MDM_WIFI_PASSWORD" ]]; then
    password="<key>Password</key><string>$(mdm_xml "$MDM_WIFI_PASSWORD")</string>"
  fi
  cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadType</key><string>Configuration</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>com.zebrunner.mcloud.wifi</string>
<key>PayloadUUID</key><string>6F0E5B1C-3D8A-4B6E-9F2A-6D4C1B7E0A11</string>
<key>PayloadDisplayName</key><string>Wi-Fi $(mdm_xml "$MDM_WIFI_SSID")</string>
<key>PayloadContent</key><array><dict>
<key>PayloadType</key><string>com.apple.wifi.managed</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>com.zebrunner.mcloud.wifi.farm</string>
<key>PayloadUUID</key><string>0B7E4F3A-9C21-4D58-8E6B-2F1A5C9D3E22</string>
<key>PayloadDisplayName</key><string>$(mdm_xml "$MDM_WIFI_SSID")</string>
<key>SSID_STR</key><string>$(mdm_xml "$MDM_WIFI_SSID")</string>
<key>EncryptionType</key><string>$(mdm_xml "${MDM_WIFI_ENCRYPTION:-Any}")</string>
${password}<key>AutoJoin</key><true/><key>HIDDEN_NETWORK</key><false/>
</dict></array></dict></plist>
EOF
}

# mdm_supervision_der <file>: the certificate of the supervision identity (DER) for `ios prepare`
mdm_supervision_der() {
  local out="$1"
  local pem
  # 3DES and AES identities with OpenSSL 3 or LibreSSL, RC2 ones with -legacy of OpenSSL 3
  pem="$(MDM_P12_PASSWORD="$MDM_SUPERVISION_P12_PASSWORD" openssl pkcs12 -in "$MDM_SUPERVISION_P12" -clcerts -nokeys \
    -passin env:MDM_P12_PASSWORD 2> /dev/null ||
    MDM_P12_PASSWORD="$MDM_SUPERVISION_P12_PASSWORD" openssl pkcs12 -legacy -in "$MDM_SUPERVISION_P12" -clcerts -nokeys \
      -passin env:MDM_P12_PASSWORD 2> /dev/null)"
  if [[ "$pem" != *"BEGIN CERTIFICATE"* ]] || ! printf '%s\n' "$pem" | openssl x509 -outform DER -out "$out" 2> /dev/null; then
    ui_fail "MDM_SUPERVISION_P12 cannot be read with MDM_SUPERVISION_P12_PASSWORD (openssl pkcs12)"
    return 1
  fi
}

# mdm_bus: the USB bus folder of the device of get_device_fields (/dev/bus/usb/001); the device restarts during its
# supervision, its number on the bus changes: the container gets the whole bus
mdm_bus() {
  local node
  node="$(readlink -f "/dev/${dev_container}" 2> /dev/null)"
  [[ "$node" == /dev/bus/usb/* ]] && dirname "$node"
}

# mdm_neighbors <bus>: the other iOS devices of the bus (Linux): the usbmuxd of the one-shot container takes every
# iPhone of its bus, so their containers are stopped meanwhile; the udids, one per line
mdm_neighbors() {
  local bus="$1"
  local self="$dev_udid"
  local line
  local id
  while IFS= read -r line; do
    [[ "|${line}|" =~ \|id=([^|]*)\| && "|${line}|" == *"|os=ios|"* && "|${line}|" == *"|connection=usb|"* ]] || continue
    id="${BASH_REMATCH[1]}"
    [[ "$id" != "$self" ]] || continue
    get_device_fields "$id" > /dev/null 2>&1 || continue
    if [[ "$(mdm_bus)" == "$bus" ]]; then
      echo "$id"
    fi
  done < "$MCLOUD_DEVICES"
  get_device_fields "$self" > /dev/null
}

# mdm_neighbors_lock <udid...>: the locks of zebrunner-farm of the neighbors, held until the end of the process (fds from
# 20 up): udev and a restart of the farm wait meanwhile instead of starting their containers
mdm_neighbors_lock() {
  local fd=20
  local id
  local lock
  for id in "$@"; do
    lock="${MCLOUD_LOCK_DIR:-/run/lock}/mcloud-device-${id//[^A-Za-z0-9._-]/_}.lock"
    [[ -e "$lock" ]] || (set -C && umask 022 && : > "$lock") 2> /dev/null
    if [[ ! -r "$lock" ]] || ! command -v flock > /dev/null 2>&1; then
      continue
    fi
    eval "exec ${fd}< \"\$lock\""
    flock -w "${MCLOUD_LOCK_TIMEOUT:-1800}" "$fd" || {
      ui_fail "Another zebrunner-farm keeps the device ${id} for too long"
      return 1
    }
    fd=$((fd + 1))
  done
}

# mdm_neighbors_unlock: releases the locks of mdm_neighbors_lock
mdm_neighbors_unlock() {
  local fd
  for fd in 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39; do
    eval "exec ${fd}<&-" 2> /dev/null
  done
}

# mdm_containers <stop|remove|start> <udid...>: the containers of the devices (stop: of the running ones only, their
# udids on stdout; remove: the containers of a device that restarts, they keep its USB device of their creation);
# the fields of the device of get_device_fields are kept
mdm_containers() {
  local action="$1"
  shift
  local self="$dev_udid"
  local id
  read_container_states
  for id in "$@"; do
    get_device_fields "$id" > /dev/null 2>&1 || continue
    if [[ "$action" == "stop" ]]; then
      if [[ "$(container_state "${dev_container}-connector")" == "running" ]]; then
        stop_containers > /dev/null
        echo "$id"
      fi
    elif [[ "$action" == "remove" ]]; then
      if [[ -n "$(container_state "${dev_container}-connector")" ]]; then
        remove_containers > /dev/null
        echo "$id"
      fi
    else
      create_containers > /dev/null ||
        ui_warn "The containers of ${dev_device_name} did not start" "zebrunner-farm start ${dev_device_name}"
    fi
  done
  get_device_fields "$self" > /dev/null
}

# mdm_supervise_mux: the function mux of the scripts of supervise: the usbmuxd of the container (Linux: started again, it
# misses a device that comes back on the bus without udev) or the one of the host (macOS)
mdm_supervise_mux() {
  if [[ "$FARM_OS" == "macos" ]]; then
    echo "mux() { pkill -f 'socat UNIX-LISTEN:/var/run/usbmuxd' 2> /dev/null; rm -f /var/run/usbmuxd; socat UNIX-LISTEN:/var/run/usbmuxd,fork,reuseaddr,mode=777 TCP:'${USBMUXD_SOCKET_ADDRESS}' > /dev/null 2>&1 & sleep 2; }"
  else
    # shellcheck disable=SC2016 # the function of the script of the container
    echo 'mux() { kill -9 $(pidof usbmuxd) 2> /dev/null; sleep 1; usbmuxd -f > /dev/null 2>&1 & sleep 3; }'
  fi
}

# mdm_supervise_helpers: the functions of the scripts of supervise (the device on the bus, the checks of its state)
mdm_supervise_helpers() {
  cat << 'EOF'
export P12_PASSWORD
listed() { (timeout 15 ios list 2> /dev/null) 2> /dev/null | grep -q "$u"; }
# the long commands of go-ios (devmode, prepare) wait for the device themselves: a watchdog starts usbmuxd again when the
# device is away for 30 s, it finds the device back on the bus then
watchdog() {
  miss=0
  while true; do
    sleep 10
    if listed; then
      miss=0
    else
      miss=$((miss + 1))
      if test "$miss" -ge 3; then
        mux
        miss=0
      fi
    fi
  done
}
wait_on() {
  i=0
  until listed; do
    i=$((i + 1))
    if test $((i % 15)) -eq 0; then mux; fi
    if test "$i" -gt "$1"; then
      echo "  the device did not come back on USB"
      exit 1
    fi
    sleep 2
  done
}
wait_off() { i=0; while listed; do i=$((i + 1)); if test "$i" -gt "$1"; then return 1; fi; sleep 2; done; }
step() { echo "  $*"; }
last() { grep -v "go-ios agent is not running" | tail -n 3 | cut -c1-240 | sed 's/^/    /'; }
activated() { timeout 30 ios info --udid="$u" 2> /dev/null | grep -q '"ActivationState":"Activated"'; }
devmode_on() { timeout 30 ios devmode get --udid="$u" 2> /dev/null | grep -q '"DeveloperModeEnabled":true'; }
supervised() { timeout 30 ios prepare cloudconfig --udid="$u" 2> /dev/null | grep -q '"IsSupervised":true'; }
EOF
}

# mdm_supervise_script: the script of the one-shot iOS connector that erases, activates and supervises the device, turns
# Developer Mode on and joins the Wi-Fi of the farm; a device supervised already is not erased (without --force), its
# Developer Mode and Wi-Fi are made sure of; its exit: 0 done, 10 Activation Lock (Find My), 11 a passcode, other: a
# failure. Checked on iOS 18.3 and 26.2.1 (Linux).
mdm_supervise_script() {
  echo "u='${dev_udid}'"
  printf "ORG='%s'\n" "$(printf '%s' "${MDM_SUPERVISION_ORG:-Zebrunner MCloud}" | sed "s/'/'\\\\''/g")"
  echo "FORCE='${MDM_FORCE}'"
  printf "P12_PASSWORD='%s'\n" "$(printf '%s' "$MDM_SUPERVISION_P12_PASSWORD" | sed "s/'/'\\\\''/g")"
  mdm_supervise_mux
  mdm_supervise_helpers
  cat << 'EOF'
mux
watchdog &
wait_on 30
info="$(timeout 30 ios info --udid="$u" 2> /dev/null || true)"
# fm-activation-locked of the NVRAM: YES (WUVT) with Find My on, the device would stay locked to its Apple Account
if echo "$info" | grep -q '"fm-activation-locked":"WUVT'; then
  echo "  Activation Lock (Find My) is on: sign out of the Apple Account on the device first, it is not erased"
  exit 10
fi
if echo "$info" | grep -q '"PasswordProtected":true'; then
  echo "  the device has a passcode: remove it first, it is not erased"
  exit 11
fi
# right after the boot the services of the device (the image mounter of devmode) may not answer yet
developer_mode() {
  step "turning Developer Mode on"
  for i in 1 2 3 4 5 6; do
    devmode_on && break
    if ! timeout 30 ios devmode get --udid="$u" > /dev/null 2>&1; then
      sleep 20
      wait_on 150
      continue
    fi
    timeout 300 ios devmode enable --enable-post-restart --udid="$u" > /tmp/out 2>&1 || true
    sleep 10
    wait_on 150
    sleep 10
  done
  if ! devmode_on; then
    last < /tmp/out
    echo "  Developer Mode is off"
    exit 1
  fi
}
erase_and_supervise() {
  step "erasing the device"
  timeout 120 ios erase --force --udid="$u" > /tmp/out 2>&1 || true
  if ! grep -q '"ok"\|rebooting' /tmp/out; then
    last < /tmp/out
    exit 1
  fi
  wait_off 150 || true
  step "waiting for the device after the erase"
  sleep 30
  wait_on 450
  sleep 30
  rm -f "/var/lib/lockdown/${u}.plist"
  for i in 1 2 3 4 5; do
    timeout 60 ios pair --udid="$u" > /tmp/out 2>&1 && grep -q "Successfully paired" /tmp/out && break
    sleep 15
  done
  # the first activation right after the boot may fail (CreateTunnel1SessionInfoRequest): it is tried again
  step "activating it"
  for i in 1 2 3 4 5 6; do
    timeout 120 ios activate --udid="$u" > /tmp/out 2>&1 || true
    activated && break
    sleep 30
  done
  if ! activated; then
    last < /tmp/out
    echo "  the device is not activated"
    exit 1
  fi
  step "supervising it (${ORG})"
  # every skip key of go-ios (--skip-all); iOS 26: with OSShowcase, misspelled OSShowCase in go-ios (go-ios #852)
  skip="--skip-all"
  major="$(timeout 30 ios info --udid="$u" 2> /dev/null | grep -oE '"ProductVersion":"[0-9]+' | grep -oE '[0-9]+$')"
  if test "${major:-0}" -ge 26; then
    skip="$(timeout 20 ios prepare printskip 2> /dev/null | grep -oE '"[A-Za-z]+"' | tr -d '"' | sed 's/^/--skip=/' | tr '\n' ' ') --skip=OSShowcase"
  fi
  # shellcheck disable=SC2086 # the skip options are words
  timeout 300 ios prepare $skip --certfile=/mdm/supervision.der --orgname="$ORG" --udid="$u" > /tmp/out 2>&1 || true
  sleep 20
  wait_on 150
  if ! supervised; then
    last < /tmp/out
    echo "  the device is not supervised"
    exit 1
  fi
}
if test -z "$FORCE" && supervised; then
  echo "  supervised already: no erase (--force erases it anyway), Developer Mode and the Wi-Fi are checked"
else
  erase_and_supervise
fi
timeout 30 ios info --udid="$u" > /dev/null 2>&1 || timeout 60 ios pair --p12file=/mdm/supervision.p12 --udid="$u" > /dev/null 2>&1 || true
# Developer Mode restarts the device: the Setup Assistant prepared by go-ios is "iPhone Partially Set Up" then, the
# finish step continues it with WebDriverAgent (WebDriverAgent does not start before this restart)
developer_mode
step "joining the Wi-Fi of the farm"
if ! timeout 60 ios profile add /mdm/wifi.mobileconfig --p12file=/mdm/supervision.p12 --udid="$u" > /tmp/out 2>&1; then
  last < /tmp/out
  exit 1
fi
EOF
}

# mdm_finish_setup: the Setup Assistant prepared by go-ios waits on Hello and, after the restart of Developer Mode, shows
# "iPhone Partially Set Up"; WebDriverAgent of the connector swipes Hello up and taps "Continue with Partial Setup" (the
# taps of XCTest elements do not continue it, the touch actions do) until SetupDone of the device (lockdown)
mdm_finish_setup() {
  local connector="${dev_container}-connector"
  local port="${dev_wda_port:-8100}"
  local i
  ui_info "Waiting for WebDriverAgent of the connector"
  local tries="${MDM_WDA_TRIES:-72}"
  for i in $(seq 1 "$tries"); do
    if docker exec "$connector" sh -c "curl -s -m 3 localhost:${port}/status" 2> /dev/null | grep -q '"ready" *: *true'; then
      break
    fi
    if [[ "$i" -eq "$tries" ]]; then
      ui_warn "WebDriverAgent is not ready: check the screen of the device (the Setup Assistant may wait for 'Continue with Partial Setup')"
      return 0
    fi
    sleep 5
  done
  {
    echo "w=localhost:${port}"
    echo "u='${dev_udid}'"
    mdm_finish_setup_script
  } | docker exec -i "$connector" sh -s
}

# mdm_finish_setup_script: the script of the finish step in the connector (WebDriverAgent at $w, the device $u)
mdm_finish_setup_script() {
  cat << 'EOF'
setup_done() { timeout 30 ios lockdown get --domain=com.apple.PurpleBuddy --udid="$u" 2> /dev/null | grep -q '"SetupDone":true'; }
post() { curl -s -m 60 -X POST -H Content-Type:application/json -d "$2" "$w$1"; }
number() { grep -m1 -oE "\"$1\" *: *[0-9.]+" | grep -oE '[0-9.]+$' | sed 's/\..*//'; }
touch_path() {
  post "/session/$S/actions" "{\"actions\":[{\"type\":\"pointer\",\"id\":\"finger\",\"parameters\":{\"pointerType\":\"touch\"},\"actions\":[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":120},{\"type\":\"pointerMove\",\"duration\":300,\"x\":$3,\"y\":$4},{\"type\":\"pointerUp\",\"button\":0}]}]}" > /dev/null
}
tap_button() {
  E=$(post "/session/$S/element" "{\"using\":\"predicate string\",\"value\":\"type == 'XCUIElementTypeButton' AND label == '$1'\"}" | grep -m1 -oE '"ELEMENT" : "[^"]+"' | cut -d'"' -f4)
  test -n "$E" || return 1
  R=$(curl -s -m 30 "$w/session/$S/element/$E/rect")
  x=$(($(echo "$R" | number x) + $(echo "$R" | number width) / 2))
  y=$(($(echo "$R" | number y) + $(echo "$R" | number height) / 2))
  touch_path "$x" "$y" "$x" "$y"
}
session() {
  S=$(post /session '{"capabilities":{"alwaysMatch":{"shouldWaitForQuiescence":false}}}' | grep -m1 -oE '[A-F0-9]{8}-[A-F0-9-]{27}')
  Z=$(curl -s -m 30 "$w/session/$S/window/size")
  W=$(echo "$Z" | number width)
  H=$(echo "$Z" | number height)
}
i=0
while ! setup_done; do
  i=$((i + 1))
  test "$i" -le 8 || break
  session
  post "/session/$S/wda/pressButton" '{"name":"home"}' > /dev/null
  sleep 1
  if curl -s -m 30 "$w/wda/activeAppInfo" | grep -q '"bundleId" : "com.apple.purplebuddy"'; then
    tap_button "Continue with Partial Setup" && echo "  the Setup Assistant: Continue with Partial Setup"
  else
    # Hello of the Setup Assistant: swipe up
    tap_button "OK" || touch_path "$((W / 2))" "$((H - 6))" "$((W / 2))" "$((H * 3 / 10))"
  fi
  sleep 8
done
session
# "No SIM Available" after the Setup Assistant
tap_button "OK" && sleep 2
post "/session/$S/wda/pressButton" '{"name":"home"}' > /dev/null
if ! setup_done; then
  echo "  WARNING: the Setup Assistant is not finished: check the screen of the device"
fi
# the device is ready when an app starts (the Setup Assistant in the way: FBSOpenApplicationServiceErrorDomain)
S=$(post /session '{"capabilities":{"alwaysMatch":{"bundleId":"com.apple.Preferences"}}}' | grep -m1 -oE '[A-F0-9]{8}-[A-F0-9-]{27}')
if test -n "$S"; then
  echo "  the apps start: the device is ready"
  post "/session/$S/wda/pressButton" '{"name":"home"}' > /dev/null
  curl -s -m 30 -X DELETE "$w/session/$S" > /dev/null
else
  echo "  WARNING: the apps do not start, the Setup Assistant may be in the way: check the screen of the device"
fi
EOF
}

# mdm_ios_supervise: erases the device, supervises it with the identity of the farm, turns Developer Mode on, joins it
# to the Wi-Fi of the farm and enrolls it; a device supervised already is only enrolled (--force erases it anyway)
mdm_ios_supervise() {
  if [[ -z "$MDM_SUPERVISION_P12" || ! -r "$MDM_SUPERVISION_P12" ]]; then
    ui_fail "MDM_SUPERVISION_P12 of config/settings.yml is not a readable file: the supervision identity of the farm (README.md#mdm)"
    return 1
  fi
  if [[ -z "$MDM_WIFI_SSID" ]]; then
    ui_fail "MDM_WIFI_SSID of config/settings.yml is empty: the Wi-Fi network of the farm the erased device joins (README.md#mdm)"
    return 1
  fi
  local work="$MDM_WORK"
  mdm_supervision_der "${work}/supervision.der" || return 1
  cp "$MDM_SUPERVISION_P12" "${work}/supervision.p12"
  (umask 077 && mdm_wifi_profile > "${work}/wifi.mobileconfig")
  chmod 644 "${work}/supervision.p12" "${work}/supervision.der" "${work}/wifi.mobileconfig"

  local usb_args=()
  local neighbors=()
  local stopped=()
  local id
  if [[ "$FARM_OS" != "macos" ]]; then
    local bus
    bus="$(mdm_bus)"
    if [[ -z "$bus" ]]; then
      ui_fail "/dev/${dev_container} is not a USB device: reconnect it"
      return 1
    fi
    usb_args=(--device-cgroup-rule='c 189:* rmw' -v "${bus}:${bus}" -v "${dev_container}-lockdown:/var/lib/lockdown")
    while IFS= read -r id; do
      [[ -n "$id" ]] && neighbors+=("$id")
    done < <(mdm_neighbors "$bus")
    if [[ "${#neighbors[@]}" -gt 0 ]]; then
      ui_info "The other iPhones of the USB bus ${bus} stop meanwhile: ${neighbors[*]}"
      mdm_neighbors_lock "${neighbors[@]}" || return 1
    fi
  fi
  # the device restarts on the bus with other numbers: its containers are created again at the end, the ones of the
  # neighbors only stop
  [[ -n "$(mdm_containers remove "$dev_udid")" ]] && ui_info "The containers of the device are removed"
  while IFS= read -r id; do
    [[ -n "$id" ]] && stopped+=("$id")
  done < <(mdm_containers stop "${neighbors[@]+"${neighbors[@]}"}")
  [[ "${#stopped[@]}" -gt 0 ]] && ui_info "The containers of the neighbors are stopped: ${#stopped[@]} device(s)"

  local status=0
  local image="${IOS_CONNECTOR_IMAGE}:${IOS_CONNECTOR_VERSION}"
  mdm_supervise_script | mdm_one_shot "$image" "${usb_args[@]+"${usb_args[@]}"}" -v "${work}:/mdm:ro" || status=$?
  if [[ "$status" -eq 0 ]]; then
    ui_info "Getting the enrollment profile from the MDM"
    if mdm_call GET "/mdm/enroll?udid=$(mdm_query "$dev_udid")&name=$(mdm_query "$dev_device_name")" "${work}/enroll.mobileconfig"; then
      chmod 644 "${work}/enroll.mobileconfig"
      MDM_PROFILE_TRIES=8 mdm_ios_script | mdm_one_shot "$image" "${usb_args[@]+"${usb_args[@]}"}" -v "${work}:/mdm:ro" || status=1
    else
      status=1
    fi
  fi

  [[ "${#stopped[@]}" -gt 0 ]] && ui_info "Starting the containers of the neighbors again"
  mdm_containers start "${stopped[@]+"${stopped[@]}"}"
  mdm_neighbors_unlock
  # the containers of the device, new (a new device gets them too) once it stays on the bus
  mdm_usb_settled
  ui_info "Creating the containers of the device"
  mdm_containers start "$dev_udid"
  if [[ "$status" -eq 0 ]]; then
    ui_ok "Supervised and enrolled: ./zebrunner.sh mdm status ${dev_device_name} shows it"
  fi
  return "$status"
}

# mdm_usb_settled: waits until the USB device of the device stays the same 20 s (Linux): a device that boots comes on the
# bus twice, the containers get the USB device of their creation
mdm_usb_settled() {
  [[ "$FARM_OS" == "macos" ]] && return 0
  local last=""
  local node
  local i
  for i in $(seq 1 "${MDM_USB_TRIES:-12}"); do
    node="$(readlink -f "/dev/${dev_container}" 2> /dev/null)"
    if [[ -n "$node" && -e "$node" && "$node" == "$last" ]]; then
      return 0
    fi
    last="$node"
    sleep "${MDM_USB_WAIT:-20}"
  done
}

# mdm_confirm_erase: supervise erases the devices: --yes, or the word erase typed at the terminal
mdm_confirm_erase() {
  local answer
  [[ -n "$MDM_YES" ]] && return 0
  if [[ ! -t 0 ]]; then
    ui_fail "supervise ERASES the devices: run it at a terminal or with --yes"
    return 1
  fi
  ui_callout warn "supervise ERASES these devices: all their data and apps go (Find My must be off, no passcode)."
  print_selection
  read -r -p "$(ui_prompt "Type erase to go on:")" answer || return 1
  [[ "$answer" == "erase" ]]
}

# mdm_main <status|enroll|release|supervise> [devices...] [-x <devices>] [-q|--yes] [--uninstall] [--force]: the command
# for the selected devices one by one (the devices of a USB bus share it), each with the lock of zebrunner-farm
mdm_main() {
  local action="$1"
  shift
  case "$action" in
  status | enroll | release | supervise) ;;
  *)
    if [[ -n "$action" ]]; then
      ui_callout error "Unknown action '${action}' of mdm."
    fi
    ui_usage "./zebrunner.sh mdm <status|enroll|release|supervise> [devices...] [options]"
    ui_muted "./zebrunner.sh help mdm, README.md#mdm"
    return 1
    ;;
  esac
  MDM_UNINSTALL=""
  MDM_FORCE=""
  MDM_YES=""
  local args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
    --uninstall)
      if [[ "$action" != "release" ]]; then
        ui_fail "--uninstall is an option of release only"
        return 1
      fi
      MDM_UNINSTALL=1
      ;;
    --force)
      if [[ "$action" != "supervise" ]]; then
        ui_fail "--force is an option of supervise only"
        return 1
      fi
      MDM_FORCE=1
      ;;
    -y | --yes | -q | --quiet)
      MDM_YES=1
      args+=("$arg")
      ;;
    --json | --batch | --rolling | --strategy*)
      ui_fail "Unknown option: ${arg}" "./zebrunner.sh help mdm"
      return 1
      ;;
    *)
      args+=("$arg")
      ;;
    esac
  done
  check_devices_list || return 1
  parse_selection "${args[@]+"${args[@]}"}" || return 1
  if [[ "$action" != "status" && "$(count "${SELECTORS[@]}")" -eq 0 ]]; then
    ui_fail "mdm ${action} needs the devices: udids, names, groups such as ios or android, patterns" \
      "./zebrunner.sh mdm ${action} <devices>"
    return 1
  fi
  select_devices || return 1
  mdm_ready || return 1
  if [[ "$action" != "status" ]] && ! confirm_selection "mdm ${action}"; then
    ui_info "Cancelled."
    return 0
  fi
  if [[ "$action" == "supervise" ]] && ! mdm_confirm_erase; then
    ui_info "Cancelled."
    return 1
  fi
  # the listener of macOS (the iOS devices) would start the containers of the devices meanwhile
  local listener=""
  local udid
  if [[ "$action" != "status" && "$FARM_OS" == "macos" ]]; then
    for udid in "${SELECTED[@]}"; do
      if [[ "|$(device_line "$udid")|" == *"|os=ios|"* ]]; then
        listener=1
      fi
    done
  fi
  if [[ -n "$listener" ]]; then
    launchctl unload "${HOME}/Library/LaunchAgents/ZebrunnerDevicesListener.plist" > /dev/null 2>&1
  fi
  local failures=()
  local total
  local number=0
  total="$(count "${SELECTED[@]}")"
  for udid in "${SELECTED[@]}"; do
    number=$((number + 1))
    # the counter of the section of the device
    MDM_COUNTER="${number}/${total}"
    get_device_fields "$udid" > /dev/null || continue
    if [[ "$action" == "status" ]]; then
      mdm_device status || failures+=("$dev_device_name")
    elif ! with_device_lock "$dev_udid" mdm_device "$action"; then
      failures+=("$dev_device_name")
    elif [[ "$action" == "supervise" ]]; then
      # out of the lock: the jobs of udev of the device (its USB device changed) run meanwhile
      mdm_finish_setup
    fi
  done
  if [[ -n "$listener" ]]; then
    launchctl load "${HOME}/Library/LaunchAgents/ZebrunnerDevicesListener.plist" > /dev/null 2>&1
  fi
  if [[ "${#failures[@]}" -gt 0 ]]; then
    if [[ "$total" -gt 1 ]]; then
      echo ""
      ui_fail "mdm ${action} failed for: ${failures[*]}"
    fi
    return 1
  fi
}
