#!/bin/bash
# ./zebrunner.sh mdm of both OS (patch/mdm.sh, README.md#mdm) with stubbed curl, docker, lsusb/ioreg and launchctl:
# the requests to MCloud (the pinned TLS key, the node token on stdin), the one-shot containers of the connectors (their
# arguments and the script of their stdin), the containers of the device stopped and started again, the secrets never
# in the arguments of a process.
source "$(dirname "$0")/lib.sh"
require_cmd ansible

cat > "${WORK}/devices.txt" << 'EOF'
id=R28M1384YQY|os=android|name=Galaxy|location=loc|appium_port=7421|adb_port=7422|min_port=7425|max_port=7430|connection=usb|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=
id=192.168.1.50|os=android|name=WiFi|location=loc|appium_port=7431|adb_port=7432|min_port=7435|max_port=7440|connection=wireless|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=
id=00008020-0005308201DA002E|os=ios|name=iPhone_XR|location=loc|appium_port=7441|adb_port=7442|min_port=7445|max_port=7450|connection=usb|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=|wda_port=|mjpeg_port=|connect_port=
id=00008120-0010359E0240201E|os=ios|name=iPhone_15|location=loc|appium_port=7451|adb_port=7452|min_port=7455|max_port=7460|connection=usb|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=|wda_port=|mjpeg_port=|connect_port=
EOF
GALAXY="device-Galaxy-R28M1384YQY"
IPHONE="device-iPhone_XR-00008020-0005308201DA002E"
IPHONE15="device-iPhone_15-00008120-0010359E0240201E"
SECRET="agent-secret-0123456789"
TOKEN="node-token-abcdef"

# curl: the answers of the MDM by the path; the status of ${STUB_DIR}/curl_status (200 by default); its arguments go to
# calls.log, its stdin (the header with the node token) to ${STUB_DIR}/curl_stdin.log
cat > "${WORK}/bin/curl" << EOF
#!/bin/bash
(IFS='|'; echo "curl|\$*") >> "\${STUB_DIR}/calls.log"
cat >> "\${STUB_DIR}/curl_stdin.log"
out=""
prev=""
for arg in "\$@"; do
  [[ "\$prev" == "-o" ]] && out="\$arg"
  prev="\$arg"
done
url="\${*: -1}"
code="\$(cat "\${STUB_DIR}/curl_status" 2> /dev/null || echo 200)"
case "\$url" in
  */android/agent.apk) body="APK" ;;
  */mdm/enroll*) body="PROFILE" ;;
  */android/enroll*) body="content call --uri content://com.hmdm.launcher.mcloud --method setup --arg https://mcloud.example.com --extra deviceId:s:R28M1384YQY --extra secret:s:${SECRET} --extra token:s:${SECRET}" ;;
  */android/release*) body="content call --uri content://com.hmdm.launcher.mcloud --method release --extra token:s:${SECRET}" ;;
  */android/status*) body=\$'serial=R28M1384YQY\nknown=yes\ndevice_owner=yes' ;;
  */mdm/status*) body=\$'udid=00008020-0005308201DA002E\nknown=yes\nenrolled=yes' ;;
  */mdm/release*) body=\$'udid=00008020-0005308201DA002E\ncommand=CMD-1' ;;
esac
# staged=1 of a node with the staged form: the JSON and the command (an older MDM: the command only)
if [[ "\$url" == */android/enroll*staged=1* && ! -f "\${STUB_DIR}/old_mdm" ]]; then
  body=\$'staged={"baseUrl":"https://mcloud.example.com","deviceId":"R28M1384YQY","secret":"${SECRET}","token":"${SECRET}"}\ncommand='"\$body"
elif [[ "\$url" == */android/release*staged=1* && ! -f "\${STUB_DIR}/old_mdm" ]]; then
  body=\$'staged={"token":"${SECRET}"}\ncommand='"\$body"
fi
[[ "\$code" == 409 ]] && body=\$'udid=x\nerror=not an enrolled device'
[[ -f "\${STUB_DIR}/curl_body" ]] && body="\$(cat "\${STUB_DIR}/curl_body")"
if [[ -n "\$out" ]]; then
  printf '%s' "\$body" > "\$out"
  printf '\n%s' "\$code"
else
  printf '%s\n%s' "\$body" "\$code"
fi
EOF
chmod +x "${WORK}/bin/curl"
# docker: records its calls, `ps` lists ${STUB_DIR}/docker_ps (`stop` makes a container exited there), the stdin of
# `run -i` goes to ${STUB_DIR}/run_stdin.log and the copy of the files of /mdm to ${STUB_DIR}/mdm_files.log
cat > "${WORK}/bin/docker" << 'EOF'
#!/bin/bash
(IFS='|'; echo "docker|$*") >> "${STUB_DIR}/calls.log"
case "$1" in
  ps) cat "${STUB_DIR}/docker_ps" 2> /dev/null ;;
  stop)
    sed -i.bak "s|^${*: -1} running$|${*: -1} exited|" "${STUB_DIR}/docker_ps"
    ;;
  rm)
    sed -i.bak "\|^${*: -1} |d" "${STUB_DIR}/docker_ps"
    echo "${*: -1}"
    ;;
  run)
    if [[ " $* " == *" -i "* ]]; then
      cat >> "${STUB_DIR}/run_stdin.log"
      for arg in "$@"; do
        if [[ "$arg" == *:/mdm:ro ]]; then
          ls "${arg%:/mdm:ro}" >> "${STUB_DIR}/mdm_files.log"
          cat "${arg%:/mdm:ro}/wifi.mobileconfig" > "${STUB_DIR}/wifi.log" 2> /dev/null
        fi
      done
      # the exit statuses of the runs one by one (${STUB_DIR}/run_statuses), else DOCKER_RUN_STATUS
      if [[ -s "${STUB_DIR}/run_statuses" ]]; then
        code="$(head -n 1 "${STUB_DIR}/run_statuses")"
        sed -i.bak 1d "${STUB_DIR}/run_statuses"
        exit "$code"
      fi
      exit "${DOCKER_RUN_STATUS:-0}"
    fi
    echo "id"
    ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/docker"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs
stub lsusb 'cat "${STUB_DIR}/usb" 2> /dev/null'
# shellcheck disable=SC2016
stub ioreg 'cat "${STUB_DIR}/usb" 2> /dev/null'
stub readlink 'echo /dev/bus/usb/001/002'
record_stub launchctl

printf 'identity' > "${WORK}/supervision.p12"
settings="{\"MCLOUD_URL\": \"https://mcloud.example.com:443\", \"MCLOUD_TLS_PIN\": \"pin=\", \"MCLOUD_NODE_TOKEN\": \"${TOKEN}\",
  \"MDM_SUPERVISION_P12\": \"${WORK}/supervision.p12\", \"MDM_SUPERVISION_P12_PASSWORD\": \"p'w\$d\"}"
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "$settings" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  render_farm "$role" "${WORK}/farm-${role}-not-joined.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}-not-joined.env"
done

# farm <env file> <arguments...>: runs zebrunner-farm without the user's environment
farm() {
  local env="$1"
  shift
  env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    MCLOUD_LOCK_DIR="$WORK" DOCKER_RUN_STATUS="${DOCKER_RUN_STATUS:-0}" ZEBRUNNER_FARM_ENV="$env" /bin/bash "$FARM_SCRIPT" "$@" 2>&1
}

# mdm <env file> <arguments...>: runs ./zebrunner.sh mdm with the settings of zebrunner-farm of the env file (unwrap:
# the messages of patch/ui.sh on one line)
mdm() {
  local env="$1"
  shift
  env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" MDM_WDA_TRIES=1 MDM_USB_WAIT=0 \
    MCLOUD_LOCK_DIR="$WORK" DOCKER_RUN_STATUS="${DOCKER_RUN_STATUS:-0}" ZEBRUNNER_FARM_ENV="$env" \
    /bin/bash "${REPO}/zebrunner.sh" mdm "$@" 2>&1 | unwrap
  return "${PIPESTATUS[0]}"
}

setup_case() {
  reset_calls
  : > "${WORK}/docker_ps"
  : > "${WORK}/run_stdin.log"
  : > "${WORK}/curl_stdin.log"
  : > "${WORK}/mdm_files.log"
  rm -f "${WORK}/curl_status" "${WORK}/curl_body" "${WORK}/run_statuses" "${WORK}/wifi.log" "${WORK}/old_mdm"
  # lsusb and ioreg show the serial number of an iPhone without the dash of its udid
  printf '%s\n' R28M1384YQY 000080200005308201DA002E 000081200010359E0240201E > "${WORK}/usb"
}

# no_secret_in_args: none of the secrets is an argument of curl or docker
no_secret_in_args() {
  local args
  args="$(
    calls curl
    calls docker
  )"
  check_not_contains "$1: the node token is no argument" "$TOKEN" "$args"
  check_not_contains "$1: the secret of the agent is no argument" "$SECRET" "$args"
  check_not_contains "$1: the password of the identity is no argument" "p'w" "$args"
}

LINUX="${WORK}/farm-devices.env"
MACOS="${WORK}/farm-mac-devices.env"

section "usage"
setup_case
output="$(mdm "$LINUX" enroll)"
check "mdm enroll without a device fails" "1" "$?"
check_contains "the devices are asked for" "FAIL mdm enroll needs the devices: udids, names, groups" "$output"
check_contains "the command with the devices is the fix" "\`- fix ./zebrunner.sh mdm enroll <devices>" "$output"
check_contains "an unknown device is reported" "device not found: NO_SUCH" "$(mdm "$LINUX" status NO_SUCH)"
output="$(mdm "$LINUX" other Galaxy)"
check "an unknown action fails" "1" "$?"
check_contains "an unknown action is an error" "Unknown action 'other' of mdm." "$output"
check_contains "an unknown action shows the usage" "> ./zebrunner.sh mdm <status|enroll|release|supervise>" "$output"
check_not_contains "mdm without an action is no error" "Unknown action" "$(mdm "$LINUX")"
check_contains "--force is an option of supervise only" "--force is an option of supervise only" "$(mdm "$LINUX" enroll Galaxy --force)"
check_contains "--uninstall is an option of release only" "--uninstall is an option of release only" "$(mdm "$LINUX" enroll Galaxy --uninstall)"
check_contains "a host that did not join is reported" "FAIL This host is not enrolled in MCloud, empty: MCLOUD_URL MCLOUD_TLS_PIN MCLOUD_NODE_TOKEN" \
  "$(mdm "${WORK}/farm-devices-not-joined.env" status Galaxy)"
check_contains "a wireless device is refused" "The MDM takes the USB devices only" "$(mdm "$LINUX" enroll WiFi)"
check "the help of zebrunner.sh lists mdm" "yes" "$(env -i PATH=/usr/bin:/bin TERM=dumb /bin/bash "${REPO}/zebrunner.sh" help | grep -q 'mdm <status|enroll|release|supervise>' && echo yes)"
check "zebrunner-farm has no mdm" "no" "$(farm "$LINUX" --help | grep -q 'mdm' && echo yes || echo no)"
setup_case
mdm "$LINUX" status > /dev/null
check "status without devices: every device" "4" "$(calls curl | grep -c '/status?')"

section "status"
setup_case
output="$(mdm "$LINUX" status Galaxy)"
check_contains "the status of the MDM" "  device_owner=yes" "$output"
check_contains "the section of the device with its counter" "[ MDM STATUS ] ---" "$output"
check_contains "the counter of the devices" " 1/1"$'\n' "$output"
check_contains "the device under the title" "  Galaxy (R28M1384YQY, android, usb)" "$output"
check "an Android device: the status of Headwind MDM, over the pinned key" \
  "-sS|-k|--pinnedpubkey|sha256//pin=|--max-time|120|-H|@-|-X|GET|-w|\n%{http_code}|https://mcloud.example.com:443/android/status?serial=R28M1384YQY&format=shell" \
  "$(calls curl)"
check "the node token goes on the stdin of curl" "Authorization: Bearer ${TOKEN}" "$(cat "${WORK}/curl_stdin.log")"
check "status does not touch the device" "" "$(calls docker)"
check "every device has its section" "4/4" "$(mdm "$LINUX" status | grep -o '[0-9]/4$' | tail -n 1)"
setup_case
mdm "$LINUX" status iPhone_XR > /dev/null
check_contains "an iOS device: the status of the webhook" "/mdm/status?udid=00008020-0005308201DA002E&format=shell" "$(calls curl)"
setup_case
echo 403 > "${WORK}/curl_status"
output="$(mdm "$LINUX" status Galaxy)"
check "a refused address fails" "1" "$?"
check_contains "a refused address is explained" "not in MDM_SITE_ADDRESSES of MCloud" "$output"
setup_case
echo 403 > "${WORK}/curl_status"
printf 'forbidden\n' > "${WORK}/curl_body"
output="$(mdm "$LINUX" status Galaxy)"
check "a device of another node fails" "1" "$?"
check_contains "a device of another node is explained" "STF binds it to another node" "$output"
setup_case
echo 503 > "${WORK}/curl_status"
printf '%s\n' "${IPHONE}-connector running" > "${WORK}/docker_ps"
output="$(mdm "$LINUX" enroll iPhone_XR 2>&1)"
check "an error of the MDM fails" "1" "$?"
check_contains "the error of the MDM shows its body" "MCloud answers 503: PROFILE" "$output"

section "status: a certificate of a public CA (MCLOUD_TLS_PUBLIC of the deploy)"
# the CAs of the system and the name PUBLIC_IP on the address of MCLOUD_URL, no pin: a renewal with a new key works
render_farm devices "${WORK}/farm-public.env" --extra-vars "$settings" \
  --extra-vars '{"MCLOUD_URL": "https://192.168.50.2:8443", "PUBLIC_IP": "mcloud.example.com", "PUBLIC_IP_PORT": "443", "common_farm_tls_public": true}' ||
  exit 1
sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-public.env"
check "the deploy decided a certificate of a public CA" "MCLOUD_TLS_PUBLIC=true" "$(grep '^MCLOUD_TLS_PUBLIC=' "${WORK}/farm-public.env")"
setup_case
mdm "${WORK}/farm-public.env" status Galaxy > /dev/null
check "a public CA: the name of the certificate on the address of MCLOUD_URL, verified with the CAs of the system" \
  "-sS|--connect-to|mcloud.example.com:443:192.168.50.2:8443|--max-time|120|-H|@-|-X|GET|-w|\n%{http_code}|https://mcloud.example.com:443/android/status?serial=R28M1384YQY&format=shell" \
  "$(calls curl)"
check_not_contains "a public CA: no pin" "pinnedpubkey" "$(calls curl)"
check_not_contains "a public CA: never without a verification" "|-k|" "$(calls curl)"
check "the deploy decided no public CA by default: the pin" "MCLOUD_TLS_PUBLIC=false" "$(grep '^MCLOUD_TLS_PUBLIC=' "$LINUX")"
no_secret_in_args "a public CA"

section "Android enroll on Linux"
setup_case
printf '%s\n' "${GALAXY}-connector running" "${GALAXY}-stf running" "${GALAXY}-appium running" > "${WORK}/docker_ps"
output="$(mdm "$LINUX" enroll Galaxy)"
check "enroll succeeds" "0" "$?"
check_contains "the agent APK and the setup of the agent from the MDM, also in the staged form" \
  "https://mcloud.example.com:443/android/enroll?serial=R28M1384YQY&name=Galaxy&format=shell&staged=1" "$(calls curl)"
check_contains "the agent is downloaded into the folder of the container" "agent.apk" "$(cat "${WORK}/mdm_files.log")"
run="$(calls docker | grep '^run|')"
check_contains "a one-shot Android connector with the USB device and the adb key of the farm" \
  "run|--rm|-i|--name|${GALAXY}-mdm|--device=/dev/${GALAXY}:/dev/bus/usb/001/002|-v|mcloud-key-volume:/root/.android|-v|" "$run"
check_contains "its image and the script of its stdin" "|--entrypoint|sh|public.ecr.aws/zebrunner/mcloud-android-connector:" "$run"
script="$(cat "${WORK}/run_stdin.log")"
check_contains "the script sets the device owner" "dpm set-device-owner com.hmdm.launcher/.AdminReceiver" "$script"
check_contains "the script has the setup of the argument form" "command='content call --uri content://com.hmdm.launcher.mcloud --method setup" "$script"
check_contains "and of the staged form" "staged='{\"baseUrl\":\"https://mcloud.example.com\",\"deviceId\":\"R28M1384YQY\",\"secret\":" "$script"
check_contains "the staged form goes on the stdin of content write" \
  "printf '%s' \"\$staged\" | adb -s \"\$s\" shell content write --uri content://com.hmdm.launcher.mcloud/setup" "$script"
check_contains "the argument form for an agent without the staged form" "result=\"\$(adb -s \"\$s\" shell \"\$command\")\"" "$script"
check_contains "the adb server of the container" "adb start-server" "$script"
check_contains "the containers of the device are stopped first" "stop" "$(calls docker | grep -m1 -E '^(stop|run)')"
check_contains "and started again" "start|${GALAXY}-connector" "$(calls docker | grep '^start|')"
no_secret_in_args "Android enroll"
setup_case
output="$(mdm "$LINUX" enroll Galaxy)"
check "a new device without containers" "" "$(calls docker | grep -E '^(stop|start)\|')"
setup_case
DOCKER_RUN_STATUS=1 mdm "$LINUX" enroll Galaxy > /dev/null
check "a failure of the device fails enroll" "1" "$?"
setup_case
: > "${WORK}/usb"
check_contains "a device that is not plugged in" "Not connected over USB" "$(mdm "$LINUX" enroll Galaxy)"

section "Android release"
setup_case
mdm "$LINUX" release Galaxy --uninstall > /dev/null
check_contains "the release command of the MDM, for the serial of the device" "https://mcloud.example.com:443/android/release?serial=R28M1384YQY&staged=1" "$(calls curl)"
script="$(cat "${WORK}/run_stdin.log")"
check_contains "the script releases the device" "command='content call --uri content://com.hmdm.launcher.mcloud --method release" "$script"
check_contains "in the staged form for an agent with it" "content write --uri content://com.hmdm.launcher.mcloud/release" "$script"
check_contains "--uninstall removes the agent" "uninstall com.hmdm.launcher" "$script"
no_secret_in_args "Android release"
setup_case
mdm "$LINUX" release Galaxy > /dev/null
check_not_contains "the agent stays without --uninstall" "uninstall com.hmdm.launcher" "$(cat "${WORK}/run_stdin.log")"

section "Android: the staged form and the argument form on the device"
# run_script <script> <sdk> <features>: the script of the connector with a fake adb (its calls in adb.log, the stdin of
# content write in adb_stdin.log), without its waits
run_script() {
  mkdir -p "${WORK}/fakeadb"
  cat > "${WORK}/fakeadb/adb" << 'EOF'
#!/bin/sh
echo "adb $*" >> "${STUB_DIR}/adb.log"
case "$*" in
*get-state*) echo device ;;
*getprop*) echo "${FAKE_SDK}" ;;
*"content write"*) cat >> "${STUB_DIR}/adb_stdin.log" ;;
*"--method status"*) echo "Result: Bundle[{deviceOwner=true${FAKE_FEATURES:+, features=${FAKE_FEATURES}}}]" ;;
*"--method setup"* | *"--method release"*) echo "${FAKE_RESULT:-Result: Bundle[{configured=true}]}" ;;
esac
exit 0
EOF
  chmod +x "${WORK}/fakeadb/adb"
  : > "${WORK}/adb.log"
  : > "${WORK}/adb_stdin.log"
  sed -e 's/^sleep [0-9]*$/:/' <<< "$1" | env -i PATH="${WORK}/fakeadb:/usr/bin:/bin" STUB_DIR="$WORK" FAKE_SDK="$2" \
    FAKE_FEATURES="$3" FAKE_RESULT="${FAKE_RESULT:-}" sh -s 2>&1
}
for action in enroll release; do
  setup_case
  mdm "$LINUX" "$action" Galaxy > /dev/null
  script="$(cat "${WORK}/run_stdin.log")"
  output="$(run_script "$script" 30 pin,staged)"
  check "${action}: the staged form succeeds" "0" "$?"
  check_contains "${action}: the parameters on the stdin of content write" "\"token\":\"${SECRET}\"}" "$(cat "${WORK}/adb_stdin.log")"
  check_not_contains "${action}: the secret in no command line of the device" "$SECRET" "$(cat "${WORK}/adb.log")"
  check_contains "${action}: the call has no argument" "--method $([[ "$action" == enroll ]] && echo setup || echo release)" \
    "$(grep -v 'method status' "${WORK}/adb.log" | grep -- '--method' | grep -v -- '--extra')"
  run_script "$script" 27 pin,staged > /dev/null
  check_contains "${action}: Android 8 gets the argument form" "token:s:${SECRET}" "$(cat "${WORK}/adb.log")"
  check "${action}: and no content write" "" "$(cat "${WORK}/adb_stdin.log")"
  run_script "$script" 30 "" > /dev/null
  check_contains "${action}: an agent without the staged form gets the argument form" "token:s:${SECRET}" "$(cat "${WORK}/adb.log")"
  output="$(FAKE_RESULT="Error while accessing provider:com.hmdm.launcher.mcloud" run_script "$script" 30 pin,staged)"
  check "${action}: a refused call fails" "1" "$?"
  check_contains "${action}: with the error of the agent" "of the agent failed: Error while accessing provider" "$output"
done
setup_case
touch "${WORK}/old_mdm"
mdm "$LINUX" enroll Galaxy > /dev/null
script="$(cat "${WORK}/run_stdin.log")"
check_contains "an older MDM: its single command" "command='content call --uri content://com.hmdm.launcher.mcloud --method setup" "$script"
check_contains "an older MDM: no staged form" "staged=''" "$script"
run_script "$script" 30 pin,staged > /dev/null
check_contains "an older MDM: the argument form also for a new agent" "token:s:${SECRET}" "$(cat "${WORK}/adb.log")"
setup_case
printf 'staged={"token":"x'"'"'y"}\n' > "${WORK}/curl_body"
check_contains "a quote in the staged form is refused" "An unexpected answer of the MDM" "$(mdm "$LINUX" release Galaxy)"
check "nothing runs then" "" "$(calls docker | grep '^run|')"
setup_case
printf 'staged={"token":"%s"}\n' "$SECRET" > "${WORK}/curl_body"
mdm "$LINUX" release Galaxy > /dev/null
script="$(cat "${WORK}/run_stdin.log")"
check "an MDM with the staged form only (MDM_ANDROID_LEGACY_SETUP=false): no command" "command=''" "$(grep '^command=' <<< "$script")"
output="$(run_script "$script" 30 "")"
check "an agent without the staged form then fails" "1" "$?"
check_contains "with the reason" "the agent has no staged release" "$output"
no_secret_in_args "the staged form"

section "Android on macOS"
setup_case
mdm "$MACOS" enroll Galaxy > /dev/null
run="$(calls docker | grep '^run|')"
check_not_contains "no USB device in the container" "--device" "$run"
check_contains "the adb server of the host" "-e|ADB_SERVER_SOCKET=tcp:host.docker.internal:5037" "$run"
check_not_contains "the adb server of the host is not started nor killed" "start-server" "$(cat "${WORK}/run_stdin.log")"
check "the listener of macOS (iOS) stays for an Android device" "" "$(calls launchctl)"

section "iOS"
setup_case
mdm "$LINUX" enroll iPhone_XR > /dev/null
check_contains "the enrollment profile of the MDM" "https://mcloud.example.com:443/mdm/enroll?udid=00008020-0005308201DA002E&name=iPhone_XR" "$(calls curl)"
check "the profile and the identity in the folder of the container" "enroll.mobileconfig
supervision.p12" "$(cat "${WORK}/mdm_files.log")"
run="$(calls docker | grep '^run|')"
check_contains "a one-shot iOS connector with the USB device and the pairing records of the device" \
  "|--device=/dev/${IPHONE}:/dev/bus/usb/001/002|-v|${IPHONE}-lockdown:/var/lib/lockdown|" "$run"
script="$(cat "${WORK}/run_stdin.log")"
check_contains "its usbmuxd" "usbmuxd -f" "$script"
check_contains "the password of the identity, quoted" "P12_PASSWORD='p'\\''w\$d'" "$script"
check_contains "the profile is installed with the identity" "ios profile add /mdm/enroll.mobileconfig --p12file=/mdm/supervision.p12" "$script"
no_secret_in_args "iOS enroll"
setup_case
mdm "$MACOS" enroll iPhone_XR > /dev/null
check_contains "macOS: usbmuxd of the host" "socat UNIX-LISTEN:/var/run/usbmuxd" "$(cat "${WORK}/run_stdin.log")"
check "the listener of macOS is paused and loaded again" "unload|${WORK}/Library/LaunchAgents/ZebrunnerDevicesListener.plist
load|${WORK}/Library/LaunchAgents/ZebrunnerDevicesListener.plist" "$(calls launchctl)"
check_not_contains "macOS: no pairing volume" "lockdown" "$(calls docker | grep '^run|')"
setup_case
mdm "$LINUX" release iPhone_XR > /dev/null
check "the release of an iOS device is a request to the MDM only" \
  "-sS|-k|--pinnedpubkey|sha256//pin=|--max-time|120|-H|@-|-X|POST|-w|\n%{http_code}|https://mcloud.example.com:443/mdm/release?udid=00008020-0005308201DA002E&format=shell" \
  "$(calls curl)"
check "the iOS release does not touch the device" "" "$(calls docker | grep -E '^(run|stop)\|')"
setup_case
echo 409 > "${WORK}/curl_status"
check_contains "the release of a device that is not enrolled" "not an enrolled device" "$(mdm "$LINUX" release iPhone_XR)"
setup_case
sed "s|^MDM_SUPERVISION_P12=.*|MDM_SUPERVISION_P12=|" "$LINUX" > "${WORK}/farm-no-p12.env"
check_contains "iOS enroll needs the supervision identity" "MDM_SUPERVISION_P12 of config/settings.yml is not a readable file" \
  "$(mdm "${WORK}/farm-no-p12.env" enroll iPhone_XR)"

section "iOS supervise"
# a supervision identity openssl reads (3DES), the Wi-Fi of the farm
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=supervision" -keyout "${WORK}/sup.key" -out "${WORK}/sup.pem" > /dev/null 2>&1
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -inkey "${WORK}/sup.key" -in "${WORK}/sup.pem" \
  -out "${WORK}/real.p12" -passout "pass:p'w\$d" 2> /dev/null
sed "s|^MDM_SUPERVISION_P12=.*|MDM_SUPERVISION_P12=${WORK}/real.p12|" "$LINUX" > "${WORK}/farm-sup.env"
printf '%s\n' "MDM_WIFI_SSID='Farm & Lab'" "MDM_WIFI_PASSWORD='wifi-secret-<1>'" >> "${WORK}/farm-sup.env"
SUP="${WORK}/farm-sup.env"
setup_case
check_contains "supervise is for iOS" "supervise is for iOS" "$(mdm "$SUP" supervise Galaxy --yes)"
check_contains "supervise asks for --yes without a terminal" "run it at a terminal or with --yes" "$(mdm "$SUP" supervise iPhone_XR)"
check "nothing is done without the confirmation" "" "$(calls docker | grep -E '^(run|stop)\|')"
check_contains "supervise needs the Wi-Fi of the farm" "MDM_WIFI_SSID of config/settings.yml is empty" "$(mdm "$LINUX" supervise iPhone_XR --yes)"
check_contains "an identity openssl cannot read" "MDM_SUPERVISION_P12 cannot be read" \
  "$(
    sed "s|^MDM_WIFI_SSID=.*|MDM_WIFI_SSID=x|" "$LINUX" > "${WORK}/farm-bad.env"
    echo "MDM_WIFI_SSID=x" >> "${WORK}/farm-bad.env"
    mdm "${WORK}/farm-bad.env" supervise iPhone_XR --yes
  )"
setup_case
printf '%s\n' "${IPHONE}-connector running" "${IPHONE}-stf running" "${IPHONE15}-connector running" > "${WORK}/docker_ps"
output="$(mdm "$SUP" supervise iPhone_XR --yes)"
check "supervise succeeds" "0" "$?"
check_contains "the other iPhone of the bus stops meanwhile" "The other iPhones of the USB bus /dev/bus/usb/001 stop meanwhile: 00008120-0010359E0240201E" "$output"
check_contains "the end of supervise" "ok   Supervised and enrolled: ./zebrunner.sh mdm status iPhone_XR shows it" "$output"
runs="$(calls docker | grep '^run|--rm|-i|')"
check "two one-shot containers: the supervision, then the enrollment" "2" "$(grep -c . <<< "$runs")"
check_contains "the container gets the USB bus and the pairing records" \
  "|--device-cgroup-rule=c 189:* rmw|-v|/dev/bus/usb/001:/dev/bus/usb/001|-v|${IPHONE}-lockdown:/var/lib/lockdown|" "$(head -n 1 <<< "$runs")"
script="$(cat "${WORK}/run_stdin.log")"
check_contains "the device is erased" "ios erase --force" "$script"
check_contains "Activation Lock is checked first" "fm-activation-locked" "$script"
check_contains "the supervision with the certificate of the identity" "--certfile=/mdm/supervision.der --orgname=\"\$ORG\"" "$script"
check_contains "the organization" "ORG='Zebrunner MCloud'" "$script"
check_contains "Developer Mode" "ios devmode enable --enable-post-restart" "$script"
check_contains "the enrollment is tried again while the Wi-Fi comes up" "MDM_PROFILE_TRIES='8'" "$script"
check_contains "--skip-all before iOS 26, OSShowcase from iOS 26" 'skip="--skip-all"' "$script"
check_contains "the files of the containers" "supervision.der" "$(cat "${WORK}/mdm_files.log")"
check_contains "the Wi-Fi profile, escaped" "<string>Farm &amp; Lab</string>" "$(cat "${WORK}/wifi.log")"
check_contains "the password of the Wi-Fi in the profile" "<key>Password</key><string>wifi-secret-&lt;1&gt;</string>" "$(cat "${WORK}/wifi.log")"
check_contains "the enrollment profile after the supervision" "/mdm/enroll?udid=00008020-0005308201DA002E&name=iPhone_XR" "$(calls curl)"
check_contains "the containers of the device are removed: it restarts with another USB device" "rm|-f|${IPHONE}-connector" "$(calls docker | grep '^rm|')"
check_contains "the containers of the neighbor start again" "start|${IPHONE15}-connector" "$(calls docker | grep '^start|')"
check_not_contains "the neighbor keeps its containers" "rm|${IPHONE15}" "$(calls docker | grep '^rm|')"
check_contains "the containers of the device are created again" "--name|${IPHONE}-connector|" "$(calls docker | grep '^run|')"
check_contains "WebDriverAgent of the connector is asked" "exec|${IPHONE}-connector" "$(calls docker | grep '^exec|')"
no_secret_in_args "iOS supervise"
check_not_contains "the password of the Wi-Fi is no argument" "wifi-secret" "$(
  calls docker
  calls curl
)"
setup_case
check_contains "a supervised device is not erased, its Developer Mode and Wi-Fi are checked" "supervised already: no erase" "$script"
setup_case
echo 10 > "${WORK}/run_statuses"
output="$(mdm "$SUP" supervise iPhone_XR --yes)"
check "Activation Lock fails" "1" "$?"
check "no enrollment then" "" "$(calls curl | grep '/mdm/enroll')"
setup_case
check_contains "--force erases a supervised device" "FORCE='1'" "$(
  mdm "$SUP" supervise iPhone_XR --yes --force > /dev/null
  cat "${WORK}/run_stdin.log"
)"

section "iOS finish of the Setup Assistant"
# the connector: WebDriverAgent shows "iPhone Partially Set Up" until the touch on its button, SetupDone (lockdown) then
FIN="${WORK}/finish"
mkdir -p "${FIN}/bin"
cat > "${FIN}/bin/curl" << 'EOF'
#!/bin/bash
echo "$*" >> "${FIN}/curl.log"
case "$*" in
  *"/session/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/actions"*) touch "${FIN}/touched" ;;
  *activeAppInfo*) echo '"bundleId" : "com.apple.purplebuddy"' ;;
  *"/element/E1/rect"*) echo '{"value":{"y":767.7,"x":24,"width":345,"height":50.3}}' ;;
  *"/window/size"*) echo '{"value":{"width":393,"height":852}}' ;;
  *"/element") if [[ "$*" == *"Partial Setup"* ]]; then echo '"ELEMENT" : "E1"'; fi ;;
  *"com.apple.Preferences"*) echo '"sessionId" : "11111111-2222-3333-4444-555555555555"' ;;
  *"/session") echo '"sessionId" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"' ;;
esac
EOF
cat > "${FIN}/bin/ios" << 'EOF'
#!/bin/bash
if [[ -f "${FIN}/touched" ]]; then echo '{"SetupDone":true}'; else echo '{}'; fi
EOF
# the connector is Linux: timeout of coreutils, which macOS has not
printf '%s\n' '#!/bin/bash' 'shift' 'exec "$@"' > "${FIN}/bin/timeout"
chmod +x "${FIN}/bin/curl" "${FIN}/bin/ios" "${FIN}/bin/timeout"
output="$(
  export FIN
  # shellcheck source=../patch/mdm.sh
  source "${REPO}/patch/mdm.sh"
  {
    echo "w=localhost:8100"
    echo "u=U1"
    mdm_finish_setup_script
  } | PATH="${FIN}/bin:${PATH}" sh
)"
check_contains "Continue with Partial Setup" "the Setup Assistant: Continue with Partial Setup" "$output"
check_contains "a touch on the center of the button, not an XCTest tap" '"x":196,"y":792' "$(cat "${FIN}/curl.log")"
check_not_contains "the Setup Assistant is finished" "WARNING" "$output"
check_contains "an app starts then" "the apps start" "$output"

finish
