#!/bin/bash
# the dev_* fields of get_device_fields and the settings of zebrunner-farm
# shellcheck disable=SC2154
# zebrunner-farm mdm (README.md#mdm): the device of this host in the MDM of its MCloud (zebrunner/mcloud-mdm behind
# stf-proxy). The host calls MCloud with its node token (MCLOUD_URL, MCLOUD_TLS_PIN, MCLOUD_NODE_TOKEN of `./zebrunner.sh
# join`): stf-proxy checks it and calls the MDM with its own enrollment token. enroll and release of a device run in a
# one-shot container of the image of its connector, with its USB device (Linux) or the adb server and usbmuxd of the
# host (macOS), while the containers of the device are stopped: a new device without containers is enrolled too. The
# secrets of the device (the setup of the Android agent, the password of the supervision identity) go to the container
# on its stdin, never in the arguments of docker. status asks the MDM only. Sourced by zebrunner-farm (get_device_fields,
# stop_containers, create_containers); keep it compatible with the macOS system bash 3.2.

MDM_AGENT_PACKAGE="com.hmdm.launcher"
MDM_AGENT_ADMIN="${MDM_AGENT_PACKAGE}/.AdminReceiver"

# mdm_ready: the settings of the enrollment of this host are there
mdm_ready() {
  local missing=""
  [[ -n "$MCLOUD_URL" ]] || missing+=" MCLOUD_URL"
  [[ -n "$MCLOUD_TLS_PIN" ]] || missing+=" MCLOUD_TLS_PIN"
  [[ -n "$MCLOUD_NODE_TOKEN" ]] || missing+=" MCLOUD_NODE_TOKEN"
  if [[ -n "$missing" ]]; then
    failed "this host is not enrolled in MCloud, empty:${missing}: ./zebrunner.sh join (README.md#node-enrollment)"
    return 1
  fi
}

# mdm_call <method> <path> [<output file>]: a request to MCloud over HTTPS to the pinned TLS key, with the node token
# on the stdin of curl; MDM_STATUS is the HTTP status, the answer goes to stdout or to the file, a failure to stderr
MDM_STATUS=""
mdm_call() {
  local method="$1"
  local path="$2"
  local output="${3:-}"
  local answer
  local out_args=()
  [[ -n "$output" ]] && out_args=(-o "$output")
  MDM_STATUS=""
  if ! answer="$(printf 'Authorization: Bearer %s\n' "$MCLOUD_NODE_TOKEN" | curl -sS -k --max-time 120 \
    --pinnedpubkey "sha256//${MCLOUD_TLS_PIN}" -H @- -X "$method" "${out_args[@]+"${out_args[@]}"}" \
    -w '\n%{http_code}' "${MCLOUD_URL%/}${path}" 2>&1)"; then
    failed "  MCloud ${MCLOUD_URL} does not answer: ${answer##*$'\n'}" >&2
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
  401) failed "  MCloud refuses the node token of this host: ./zebrunner.sh doctor" >&2 ;;
  403) failed "  MCloud refuses this address: the public address of this site is not in MDM_SITE_ADDRESSES of MCloud" >&2 ;;
  404) failed "  no MDM on MCloud (MDM_ENABLED of its .env) or no Android there (${path%%\?*})" >&2 ;;
  409) failed "  ${answer##*error=}" >&2 ;;
  *) failed "  MCloud answers ${MDM_STATUS}: ${answer}" >&2 ;;
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

# mdm_one_shot <image> <arguments of docker run...>: a one-shot container of the image that runs the script of its stdin
mdm_one_shot() {
  local image="$1"
  shift
  docker run --rm -i --name "${dev_container}-mdm" "$@" --entrypoint sh "$image" -s
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
    echo "  stopping the containers of the device"
    stop_containers > /dev/null
  fi
  local status=0
  "$@" || status=$?
  if [[ -n "$had" ]]; then
    echo "  starting the containers of the device again"
    create_containers > /dev/null || status=1
  fi
  return "$status"
}

# mdm_android_script <adb setup|release command> <action>: the script of the one-shot Android connector
mdm_android_script() {
  local command="$1"
  local action="$2"
  local serial="$dev_udid"
  echo "set -e"
  echo "s='${serial}'"
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
adb -s "\$s" shell '${command}' > /dev/null
adb -s "\$s" shell am start -n ${MDM_AGENT_PACKAGE}/.ui.MainActivity > /dev/null
sleep 10
adb -s "\$s" shell content call --uri content://${MDM_AGENT_PACKAGE}.mcloud --method status | sed 's/^/  /'
EOF
  else
    cat << EOF
adb -s "\$s" shell '${command}' > /dev/null
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

# mdm_android <enroll|release>: the agent of the MDM as the device owner of the Android device, or released
mdm_android() {
  local action="$1"
  local work="$MDM_WORK"
  local command
  if [[ "$action" == "enroll" ]]; then
    echo "  the setup of the agent from the MDM"
    mdm_call GET /android/agent.apk "${work}/agent.apk" || return 1
    command="$(mdm_call GET "/android/enroll?serial=$(mdm_query "$dev_udid")&name=$(mdm_query "$dev_device_name")&format=shell")" || return 1
  else
    command="$(mdm_call GET /android/release)" || return 1
  fi
  command="$(head -n 1 <<< "$command")"
  # the command goes into single quotes of the script: an answer with one is refused
  if [[ "$command" != "content call "* || "$command" == *"'"* ]]; then
    failed "  an unexpected answer of the MDM"
    return 1
  fi
  local env_args=()
  if [[ "$FARM_OS" == "macos" ]]; then
    env_args=(-e ADB_SERVER_SOCKET="tcp:${ADB_SERVER_SOCKET_ADDRESS:-host.docker.internal:5037}")
  fi
  mdm_usb_args
  mdm_android_script "$command" "$action" | mdm_one_shot "${ANDROID_CONNECTOR_IMAGE}:${ANDROID_CONNECTOR_VERSION}" \
    "${MDM_USB_ARGS[@]+"${MDM_USB_ARGS[@]}"}" "${env_args[@]+"${env_args[@]}"}" \
    -v mcloud-key-volume:/root/.android -v "${work}:/mdm:ro"
}

# mdm_ios_enroll: the enrollment profile installed over USB with the supervision identity, no prompt on the device
mdm_ios_enroll() {
  if [[ -z "$MDM_SUPERVISION_P12" || ! -r "$MDM_SUPERVISION_P12" ]]; then
    failed "  MDM_SUPERVISION_P12 of config/settings.yml is not a readable file: the supervision identity of the farm (README.md#mdm)"
    return 1
  fi
  local work="$MDM_WORK"
  echo "  the enrollment profile from the MDM"
  mdm_call GET "/mdm/enroll?udid=$(mdm_query "$dev_udid")" "${work}/enroll.mobileconfig" || return 1
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
if ! out="$(ios profile add /mdm/enroll.mobileconfig --p12file=/mdm/supervision.p12 --udid="$u" 2>&1)"; then
  echo "$out" | tail -n 5
  exit 1
fi
echo "  the device enrolls in the MDM: zebrunner-farm mdm status shows it"
EOF
}

# mdm_ios_release: the MDM removes its enrollment profile (RemoveProfile over APNs): the device leaves the MDM with every
# profile of it; the device stays supervised and is not touched here
mdm_ios_release() {
  local answer
  answer="$(mdm_call POST "/mdm/release?udid=$(mdm_query "$dev_udid")&format=shell")" || return 1
  echo "  the MDM sent RemoveProfile (${answer##*command=}): the device leaves it once it is online"
}

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
  echo "==> ${dev_device_name} (${dev_udid}, ${dev_platform_name}, ${dev_connection})"
  if [[ "$action" == "status" ]]; then
    mdm_status
    return
  fi
  if [[ "$dev_connection" != "usb" ]]; then
    failed "  the MDM takes the USB devices only (the connection of this one is ${dev_connection})"
    return 1
  fi
  case "${dev_platform_name}:${action}" in
  ios:release)
    mdm_ios_release
    ;;
  ios:enroll)
    usb_connected > /dev/null || {
      failed "  not connected over USB"
      return 1
    }
    mdm_with_device_free mdm_ios_enroll
    ;;
  android:*)
    usb_connected > /dev/null || {
      failed "  not connected over USB"
      return 1
    }
    mdm_with_device_free mdm_android "$action"
    ;;
  *)
    failed "  the MDM takes Android and iOS devices only"
    return 1
    ;;
  esac
}
