#!/bin/bash
# zebrunner-farm mdm of both OS (patch/mdm.sh, README.md#mdm) with stubbed curl, docker, lsusb/ioreg and launchctl:
# the requests to MCloud (the pinned TLS key, the node token on stdin), the one-shot containers of the connectors (their
# arguments and the script of their stdin), the containers of the device stopped and started again, the secrets never
# in the arguments of a process.
source "$(dirname "$0")/lib.sh"
require_cmd ansible

cat > "${WORK}/devices.txt" << 'EOF'
id=R28M1384YQY|os=android|name=Galaxy|location=loc|appium_port=7421|adb_port=7422|min_port=7425|max_port=7430|connection=usb|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=
id=192.168.1.50|os=android|name=WiFi|location=loc|appium_port=7431|adb_port=7432|min_port=7435|max_port=7440|connection=wireless|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=
id=00008020-0005308201DA002E|os=ios|name=iPhone_XR|location=loc|appium_port=7441|adb_port=7442|min_port=7445|max_port=7450|connection=usb|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=|wda_port=|mjpeg_port=|connect_port=
EOF
GALAXY="device-Galaxy-R28M1384YQY"
IPHONE="device-iPhone_XR-00008020-0005308201DA002E"
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
[[ "\$code" == 409 ]] && body=\$'udid=x\nerror=not an enrolled device'
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
  run)
    if [[ " $* " == *" -i "* ]]; then
      cat >> "${STUB_DIR}/run_stdin.log"
      for arg in "$@"; do
        [[ "$arg" == *:/mdm:ro ]] && ls "${arg%:/mdm:ro}" >> "${STUB_DIR}/mdm_files.log"
      done
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

setup_case() {
  reset_calls
  : > "${WORK}/docker_ps"
  : > "${WORK}/run_stdin.log"
  : > "${WORK}/curl_stdin.log"
  : > "${WORK}/mdm_files.log"
  rm -f "${WORK}/curl_status"
  # lsusb and ioreg show the serial number of an iPhone without the dash of its udid
  printf '%s\n' R28M1384YQY 000080200005308201DA002E > "${WORK}/usb"
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
output="$(farm "$LINUX" mdm enroll)"
check "mdm enroll without a device fails" "1" "$?"
check_contains "one device is asked for" "zebrunner-farm mdm enroll <device>: one device" "$output"
check_contains "an unknown device is reported" "device not found: NO_SUCH" "$(farm "$LINUX" mdm status NO_SUCH)"
check_contains "an unknown action shows the help" "mdm status <device>" "$(farm "$LINUX" mdm other Galaxy)"
check_contains "--uninstall is an option of release only" "--uninstall of release only" "$(farm "$LINUX" mdm enroll Galaxy --uninstall)"
check_contains "a host that did not join is reported" "this host is not enrolled in MCloud, empty: MCLOUD_URL MCLOUD_TLS_PIN MCLOUD_NODE_TOKEN" \
  "$(farm "${WORK}/farm-devices-not-joined.env" mdm status Galaxy)"
check_contains "a wireless device is refused" "the MDM takes the USB devices only" "$(farm "$LINUX" mdm enroll WiFi)"
check "the help lists mdm" "yes" "$(farm "$LINUX" --help | grep -q 'mdm enroll <device>' && echo yes)"

section "status"
setup_case
output="$(farm "$LINUX" mdm status Galaxy)"
check_contains "the status of the MDM" "  device_owner=yes" "$output"
check "an Android device: the status of Headwind MDM, over the pinned key" \
  "-sS|-k|--max-time|120|--pinnedpubkey|sha256//pin=|-H|@-|-X|GET|-w|\n%{http_code}|https://mcloud.example.com:443/android/status?serial=R28M1384YQY&format=shell" \
  "$(calls curl)"
check "the node token goes on the stdin of curl" "Authorization: Bearer ${TOKEN}" "$(cat "${WORK}/curl_stdin.log")"
check "status does not touch the device" "" "$(calls docker)"
setup_case
farm "$LINUX" mdm status iPhone_XR > /dev/null
check_contains "an iOS device: the status of the webhook" "/mdm/status?udid=00008020-0005308201DA002E&format=shell" "$(calls curl)"
setup_case
echo 403 > "${WORK}/curl_status"
output="$(farm "$LINUX" mdm status Galaxy)"
check "a refused address fails" "1" "$?"
check_contains "a refused address is explained" "not in MDM_SITE_ADDRESSES of MCloud" "$output"
setup_case
echo 503 > "${WORK}/curl_status"
printf '%s\n' "${IPHONE}-connector running" > "${WORK}/docker_ps"
output="$(farm "$LINUX" mdm enroll iPhone_XR 2>&1)"
check "an error of the MDM fails" "1" "$?"
check_contains "the error of the MDM shows its body" "MCloud answers 503: PROFILE" "$output"

section "Android enroll on Linux"
setup_case
printf '%s\n' "${GALAXY}-connector running" "${GALAXY}-stf running" "${GALAXY}-appium running" > "${WORK}/docker_ps"
output="$(farm "$LINUX" mdm enroll Galaxy)"
check "enroll succeeds" "0" "$?"
check_contains "the agent APK and the setup of the agent from the MDM" \
  "https://mcloud.example.com:443/android/enroll?serial=R28M1384YQY&name=Galaxy&format=shell" "$(calls curl)"
check_contains "the agent is downloaded into the folder of the container" "agent.apk" "$(cat "${WORK}/mdm_files.log")"
run="$(calls docker | grep '^run|')"
check_contains "a one-shot Android connector with the USB device and the adb key of the farm" \
  "run|--rm|-i|--name|${GALAXY}-mdm|--device=/dev/${GALAXY}:/dev/bus/usb/001/002|-v|mcloud-key-volume:/root/.android|-v|" "$run"
check_contains "its image and the script of its stdin" "|--entrypoint|sh|public.ecr.aws/zebrunner/mcloud-android-connector:" "$run"
script="$(cat "${WORK}/run_stdin.log")"
check_contains "the script sets the device owner" "dpm set-device-owner com.hmdm.launcher/.AdminReceiver" "$script"
check_contains "the script sets the agent up with the answer of the MDM" "adb -s \"\$s\" shell 'content call --uri content://com.hmdm.launcher.mcloud --method setup" "$script"
check_contains "the adb server of the container" "adb start-server" "$script"
check_contains "the containers of the device are stopped first" "stop" "$(calls docker | grep -m1 -E '^(stop|run)')"
check_contains "and started again" "start|${GALAXY}-connector" "$(calls docker | grep '^start|')"
no_secret_in_args "Android enroll"
setup_case
output="$(farm "$LINUX" mdm enroll Galaxy)"
check "a new device without containers" "" "$(calls docker | grep -E '^(stop|start)\|')"
setup_case
DOCKER_RUN_STATUS=1 farm "$LINUX" mdm enroll Galaxy > /dev/null
check "a failure of the device fails enroll" "1" "$?"
setup_case
: > "${WORK}/usb"
check_contains "a device that is not plugged in" "not connected over USB" "$(farm "$LINUX" mdm enroll Galaxy)"

section "Android release"
setup_case
farm "$LINUX" mdm release Galaxy --uninstall > /dev/null
check_contains "the release command of the MDM" "https://mcloud.example.com:443/android/release" "$(calls curl)"
script="$(cat "${WORK}/run_stdin.log")"
check_contains "the script releases the device" "shell 'content call --uri content://com.hmdm.launcher.mcloud --method release" "$script"
check_contains "--uninstall removes the agent" "uninstall com.hmdm.launcher" "$script"
no_secret_in_args "Android release"
setup_case
farm "$LINUX" mdm release Galaxy > /dev/null
check_not_contains "the agent stays without --uninstall" "uninstall com.hmdm.launcher" "$(cat "${WORK}/run_stdin.log")"

section "Android on macOS"
setup_case
farm "$MACOS" mdm enroll Galaxy > /dev/null
run="$(calls docker | grep '^run|')"
check_not_contains "no USB device in the container" "--device" "$run"
check_contains "the adb server of the host" "-e|ADB_SERVER_SOCKET=tcp:host.docker.internal:5037" "$run"
check_not_contains "the adb server of the host is not started nor killed" "start-server" "$(cat "${WORK}/run_stdin.log")"
check "the listener of macOS is paused and loaded again" "unload|${WORK}/Library/LaunchAgents/ZebrunnerDevicesListener.plist
load|${WORK}/Library/LaunchAgents/ZebrunnerDevicesListener.plist" "$(calls launchctl)"

section "iOS"
setup_case
farm "$LINUX" mdm enroll iPhone_XR > /dev/null
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
farm "$MACOS" mdm enroll iPhone_XR > /dev/null
check_contains "macOS: usbmuxd of the host" "socat UNIX-LISTEN:/var/run/usbmuxd" "$(cat "${WORK}/run_stdin.log")"
check_not_contains "macOS: no pairing volume" "lockdown" "$(calls docker | grep '^run|')"
setup_case
farm "$LINUX" mdm release iPhone_XR > /dev/null
check "the release of an iOS device is a request to the MDM only" \
  "-sS|-k|--max-time|120|--pinnedpubkey|sha256//pin=|-H|@-|-X|POST|-w|\n%{http_code}|https://mcloud.example.com:443/mdm/release?udid=00008020-0005308201DA002E&format=shell" \
  "$(calls curl)"
check "the iOS release does not touch the device" "" "$(calls docker | grep -E '^(run|stop)\|')"
setup_case
echo 409 > "${WORK}/curl_status"
check_contains "the release of a device that is not enrolled" "not an enrolled device" "$(farm "$LINUX" mdm release iPhone_XR)"
setup_case
sed "s|^MDM_SUPERVISION_P12=.*|MDM_SUPERVISION_P12=|" "$LINUX" > "${WORK}/farm-no-p12.env"
check_contains "iOS enroll needs the supervision identity" "MDM_SUPERVISION_P12 of config/settings.yml is not a readable file" \
  "$(farm "${WORK}/farm-no-p12.env" mdm enroll iPhone_XR)"

finish
