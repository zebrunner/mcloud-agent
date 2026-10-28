#!/bin/bash
# zebrunner-farm of both roles with stubbed docker, lsusb/ioreg and launchctl, run in a
# udev/launchd-like empty environment: device selection, container creation arguments,
# existing and failing containers, wireless devices, status, uptime and the listener handling.
source "$(dirname "$0")/lib.sh"
require_cmd ansible

# udid|platform|name|location|appium|adb|proxy|server proxy|min|max|connection|wda file|wda bundle id|address|wda port|
# mjpeg port
cat > "${WORK}/devices.txt" << 'EOF'
R28M1384YQY|android|Galaxy|loc|7421|7422|7423|7424|7425|7430|usb|/dev/null|x|||
192.168.1.50|android|WiFi|loc|7431|7432|7433|7434|7435|7440|wireless|/dev/null|x|||
d6afc6b3a65584ca0813eb8957c6479b9b6ebb11|ios|iPhone_8_Plus|loc|7441|7442|7443|7444|7445|7450|usb|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|||
aaaa1111|ios|AppleTV|loc|7451|7452|7453|7454|7455|7460|proxy|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|10.0.0.5|8100|
bbbb2222|ios|iPhoneWiFi|loc|7461|7462|7463|7464|7465|7470|wireless|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|192.168.1.60||
emu1|android|Emu|loc|7471|7472|7473|7474|7475|7480|android-sim|/dev/null|x|host.docker.internal:5557||
B1B07E76|ios|Sim|loc|7481|7482|7483|7484|7485|7490|ios-sim|/tmp/wda-sim.zip|com.facebook.WebDriverAgentRunner.xctrunner||8110|
EOF
IPHONE="device-iPhone_8_Plus-d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"

# docker: records the calls, prints ${STUB_DIR}/docker_ps for `ps`, fails `run` of a container
# ending with $DOCKER_FAIL_RUN and returns $DOCKER_STARTED_AT/$DOCKER_FINISHED_AT for `inspect`
cat > "${WORK}/bin/docker" << 'EOF'
#!/bin/bash
(IFS='|'; echo "docker|$*") >> "${STUB_DIR}/calls.log"
case "$1" in
  ps) cat "${STUB_DIR}/docker_ps" 2> /dev/null ;;
  run)
    name=""
    prev=""
    for arg in "$@"; do
      [[ "$prev" == "--name" ]] && name="$arg"
      prev="$arg"
    done
    if [[ -n "$DOCKER_FAIL_RUN" && "$name" == *"$DOCKER_FAIL_RUN" ]]; then
      echo "docker: simulated failure" >&2
      exit 125
    fi
    echo "id-${name}"
    ;;
  inspect)
    case "$*" in
      *StartedAt*) echo "$DOCKER_STARTED_AT" ;;
      *FinishedAt*) echo "${DOCKER_FINISHED_AT:-0001-01-01T00:00:00Z}" ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/docker"
# USB connected devices are listed in ${STUB_DIR}/usb
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub lsusb 'cat "${STUB_DIR}/usb" 2> /dev/null'
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub ioreg 'cat "${STUB_DIR}/usb" 2> /dev/null'
record_stub launchctl

for role in devices mac-devices; do
  render_farm "$role" "${WORK}/zebrunner-farm-${role}" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/zebrunner-farm-${role}"
done

# farm <devices|mac-devices> <arguments...>: runs zebrunner-farm without the user's environment
farm() {
  local role="$1"
  shift
  env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    DOCKER_FAIL_RUN="${DOCKER_FAIL_RUN:-}" DOCKER_STARTED_AT="${DOCKER_STARTED_AT:-}" DOCKER_FINISHED_AT="${DOCKER_FINISHED_AT:-}" \
    /bin/bash "${WORK}/zebrunner-farm-${role}" "$@" 2>&1
}

# run_args <container>: arguments of the `docker run` of a container, joined by '|'
run_args() {
  calls docker | grep "^run|.*|--name|$1|"
}

# devices removed by `down`, in the order of the devices list
removed() {
  calls docker | grep '^volume|rm|' | sed 's/^volume|rm|device-//; s/-.*//' | paste -s -d ' ' -
}

setup_case() {
  reset_calls
  : > "${WORK}/docker_ps"
  : > "${WORK}/usb"
}

section "device selection"
for role in devices mac-devices; do
  while IFS='=' read -r query expected; do
    setup_case
    farm "$role" down "$query" > /dev/null
    check "${role}: down '${query}' selects '${expected}'" "$expected" "$(removed)"
  done << 'EOF'
R28M1384YQY=Galaxy
Galaxy=Galaxy
iPhone_8_Plus=iPhone_8_Plus
R28=
7421=
ios=iPhone_8_Plus AppleTV iPhoneWiFi Sim
android=Galaxy WiFi Emu
=Galaxy WiFi iPhone_8_Plus AppleTV iPhoneWiFi Emu Sim
EOF
done

section "unknown device"
for role in devices mac-devices; do
  for command in start stop down status; do
    setup_case
    output="$(farm "$role" "$command" NO_SUCH)"
    check "${role}: ${command} of an unknown device fails" "1" "$?"
    check_contains "${role}: ${command} of an unknown device is reported" "device not found: NO_SUCH" "$output"
    check_not_contains "${role}: ${command} of an unknown device does not touch containers" "|device-" "|$(calls docker | tr '\n' '|')"
    check_not_contains "${role}: utility.sh is sourced without the user's environment" "command not found" "$output"
  done
done

section "Linux container creation"
setup_case
echo "iSerial R28M1384YQY" > "${WORK}/usb"
farm devices start Galaxy > /dev/null
connector="$(run_args device-Galaxy-R28M1384YQY-connector)"
check_contains "USB android connector gets the device" "|--device=/dev/device-Galaxy-R28M1384YQY:" "$connector"
check_not_contains "USB android connector has no empty argument" "||" "$connector"
appium="$(run_args device-Galaxy-R28M1384YQY-appium)"
check_contains "appium relaxed security comes from the defaults" "|RELAXED_SECURITY=true|" "$appium"
check_contains "appium app size check flag is lower case" "|APPIUM_APP_SIZE_DISABLE=false|" "$appium"
check_contains "appium links the stf container" "|--link|device-Galaxy-R28M1384YQY-stf:device|" "$appium"

setup_case
farm devices start WiFi > /dev/null
connector="$(run_args device-WiFi-192.168.1.50-connector)"
check_not_contains "wireless android connector gets no device" "--device=" "$connector"
check_not_contains "wireless android connector has no empty argument" "||" "$connector"
check_contains "wireless android is connected over adb tcp" "|ANDROID_DEVICE=192.168.1.50:5555|" "$connector"

setup_case
output="$(farm devices start Galaxy)"
check_contains "disconnected USB device is reported" "was NOT detected as connected" "$output"
check "disconnected USB device gets no containers" "" "$(calls docker | grep '^run|')"

setup_case
farm devices start > /dev/null
check "start of all devices creates the non-usb ones only without USB symlinks" \
  "WiFi AppleTV iPhoneWiFi Emu" "$(calls docker | grep '^run|' | grep -o -- '--name|device-[^|]*-stf' | sed 's/.*|device-//; s/-.*//' | paste -s -d ' ' -)"

setup_case
farm devices restart WiFi > /dev/null
check "restart removes the containers before creating them" "rm run" \
  "$(calls docker | grep -E '^(rm|run)\|' | cut -d '|' -f 1 | uniq | paste -s -d ' ' -)"

setup_case
farm devices start iPhoneWiFi > /dev/null
connector="$(run_args device-iPhoneWiFi-bbbb2222-connector)"
check_not_contains "wireless iPhone connector gets no device" "--device=/dev/device-" "$connector"
check_contains "wireless iPhone connector reaches the device by its address" "|DEVICE_CONNECTION=wireless|-e|DEVICE_ADDRESS=192.168.1.60|" "$connector"
stf="$(run_args device-iPhoneWiFi-bbbb2222-stf)"
check_contains "STF of an iPhone uses the shared tunnel of the connector" "|GO_IOS_AGENT_HOST=connector|" "$stf"
check_contains "STF of a wireless iPhone uses usbmuxd of the connector" "|WIRELESS=false|" "$stf"

setup_case
farm devices start AppleTV > /dev/null
connector="$(run_args device-AppleTV-aaaa1111-connector)"
check_contains "proxied WDA is relayed by the connector" "|DEVICE_CONNECTION=proxy|-e|DEVICE_ADDRESS=10.0.0.5|-e|DEVICE_WDA_PORT=8100|" "$connector"
check_contains "proxied WDA has no usbmuxd for appium" "|WIRELESS=true|" "$(run_args device-AppleTV-aaaa1111-appium)"

setup_case
farm devices start Emu > /dev/null
check "Android emulator gets the containers of a device, the farm does not create it" "connector stf appium uploader" \
  "$(calls docker | grep '^run|' | grep -o -- '--name|device-Emu-emu1-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
connector="$(run_args device-Emu-emu1-connector)"
check_contains "Android emulator is connected by its adb address" "|ANDROID_DEVICE=host.docker.internal:5557|" "$connector"
check_not_contains "Android emulator connector gets no device" "--device=" "$connector"
check_contains "Android emulator is the device of STF" "|DEVICE_UDID=host.docker.internal:5557|" "$(run_args device-Emu-emu1-stf)"

setup_case
output="$(farm devices start Sim)"
check_contains "iOS simulator on Linux is reported" "The iOS simulators run on a macOS host only" "$output"
check "iOS simulator on Linux gets no containers" "" "$(calls docker | grep '^run|')"

section "ZeroMQ security"
server_key="$(printf '%064d' 0 | tr 0 a)"
secret_key="$(printf '%064d' 0 | tr 0 b)"
for role in devices mac-devices; do
  setup_case
  farm "$role" start WiFi > /dev/null
  stf="$(run_args device-WiFi-192.168.1.50-stf)"
  check_contains "${role}: RethinkDB is passed without CURVE" "|RETHINKDB_PORT_28015_TCP=tcp://rethinkdb:28015|" "$stf"
  check_contains "${role}: no CURVE keys by default" \
    "|STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=|-e|STF_ZMQ_CURVE_SECRET_KEY=|" "$stf"

  render_farm "$role" "${WORK}/zebrunner-farm-${role}" \
    --extra-vars "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${server_key} STF_ZMQ_CURVE_SECRET_KEY=${secret_key}" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/zebrunner-farm-${role}"
  setup_case
  farm "$role" start WiFi > /dev/null
  stf="$(run_args device-WiFi-192.168.1.50-stf)"
  check_contains "${role}: the CURVE keys are passed" \
    "|STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${server_key}|-e|STF_ZMQ_CURVE_SECRET_KEY=${secret_key}|" "$stf"
  check_contains "${role}: no RethinkDB with CURVE" "|RETHINKDB_PORT_28015_TCP=|" "$stf"

  render_farm "$role" "${WORK}/zebrunner-farm-${role}" --extra-vars "STF_ZMQ_CURVE_SECRET_KEY=${secret_key}" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/zebrunner-farm-${role}"
  setup_case
  farm "$role" start WiFi > /dev/null
  check_contains "${role}: the key of the host is not passed without the key of the server" \
    "|STF_ZMQ_CURVE_SECRET_KEY=|" "$(run_args device-WiFi-192.168.1.50-stf)"

  render_farm "$role" "${WORK}/zebrunner-farm-${role}" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/zebrunner-farm-${role}"
done

section "macOS container creation"
setup_case
echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' > "${WORK}/usb"
output="$(farm mac-devices start iPhone_8_Plus)"
check "USB iPhone gets all containers" "connector stf appium uploader" \
  "$(calls docker | grep '^run|' | grep -o -- "--name|${IPHONE}-[a-z]*" | sed 's/.*-//' | paste -s -d ' ' -)"
check_contains "appium links the stf container" "|--link|${IPHONE}-stf:device|" "$(run_args "${IPHONE}-appium")"
check_contains "appium links the connector" "|--link|${IPHONE}-connector:connector|" "$(run_args "${IPHONE}-appium")"
check_not_contains "nothing is reported as already created" "already created" "$output"

setup_case
echo "${IPHONE}-stf" > "${WORK}/docker_ps"
echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' > "${WORK}/usb"
farm mac-devices start iPhone_8_Plus > /dev/null
check "existing container is not created again" "connector appium uploader" \
  "$(calls docker | grep '^run|' | grep -o -- "--name|${IPHONE}-[a-z]*" | sed 's/.*-//' | paste -s -d ' ' -)"

setup_case
echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' > "${WORK}/usb"
output="$(DOCKER_FAIL_RUN=-appium farm mac-devices start iPhone_8_Plus)"
check_contains "failed container creation is reported" "Error. Not created" "$output"

setup_case
farm mac-devices start AppleTV > /dev/null
check "proxied device gets a connector too" "connector stf appium uploader" \
  "$(calls docker | grep '^run|' | grep -o -- '--name|device-AppleTV-aaaa1111-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
check_contains "proxied WDA is relayed by the connector on macOS" \
  "|DEVICE_CONNECTION=proxy|-e|DEVICE_ADDRESS=10.0.0.5|-e|DEVICE_WDA_PORT=8100|-e|DEVICE_MJPEG_PORT=8101|" \
  "$(run_args device-AppleTV-aaaa1111-connector)"
appium="$(run_args device-AppleTV-aaaa1111-appium)"
check_contains "proxied device reaches WDA through the connector" "|WDA_HOST=connector|-e|WDA_PORT=8100|-e|WIRELESS=true|" "$appium"
check_contains "proxied device links the connector" "|--link|device-AppleTV-aaaa1111-connector:connector|" "$appium"

setup_case
farm mac-devices stop AppleTV > /dev/null
check "proxied device stop includes the connector" "connector appium stf uploader" \
  "$(calls docker | grep '^stop|' | sed 's/.*-//' | paste -s -d ' ' -)"
setup_case
farm mac-devices stop iPhone_8_Plus > /dev/null
check "USB device stop includes the connector" "connector appium stf uploader" \
  "$(calls docker | grep '^stop|' | sed 's/.*-//' | paste -s -d ' ' -)"

setup_case
output="$(farm mac-devices start iPhoneWiFi)"
check_contains "wireless iPhone skips the USB check" "is connected as 'wireless', skipping USB presence check." "$output"
connector="$(run_args device-iPhoneWiFi-bbbb2222-connector)"
check_contains "wireless iPhone uses usbmuxd of the host" "|USBMUXD_SOCKET_ADDRESS=host.docker.internal:2222|-e|DEVICE_CONNECTION=wireless|" "$connector"
check_contains "the connector of macOS starts WDA itself" "|HOST_OS=DARWIN|" "$connector"
check_contains "STF of macOS uses the shared tunnel of the connector" "|GO_IOS_AGENT_HOST=connector|" \
  "$(run_args device-iPhoneWiFi-bbbb2222-stf)"

setup_case
farm mac-devices start Sim > /dev/null
connector="$(run_args device-Sim-B1B07E76-connector)"
check_contains "simulator connector runs simctl of the host" "|DEVICE_CONNECTION=ios-sim|-e|HOST_SSH_USER=${USER}|-e|DEVICE_WDA_PORT=8110|-e|DEVICE_MJPEG_PORT=8111|" "$connector"
check_contains "simulator connector gets the ssh key of the agent" "/ssh/id_ed25519:/opt/zebrunner/ssh/id_ed25519:ro|" "$connector"
check_contains "simulator connector gets the simulator build of WDA" "|/tmp/wda-sim.zip:/tmp/zebrunner/wda-sim.zip|" "$connector"
check_contains "simulator connector gets the path of the build" "|WDA_FILE=/tmp/zebrunner/wda-sim.zip|" "$connector"
appium="$(run_args device-Sim-B1B07E76-appium)"
check_contains "simulator appium has no usbmuxd" "|WIRELESS=true|" "$appium"
check_contains "simulator appium runs xcrun of the host" "|DEVICE_CONNECTION=ios-sim|-e|HOST_SSH_USER=${USER}|" "$appium"

setup_case
echo '"USB Serial Number" = "R28M1384YQY"' > "${WORK}/usb"
farm mac-devices start Galaxy > /dev/null
connector="$(run_args device-Galaxy-R28M1384YQY-connector)"
check_contains "USB android of macOS stays on the adb server of the host" \
  "|ADB_TRANSPORT_SERVER=host.docker.internal:5037|-e|ADB_TRANSPORT_SERIAL=R28M1384YQY|-e|ADB_TRANSPORT_PORT=7422|" "$connector"
check_contains "USB android of macOS is the forwarded device of the connector" "|DEVICE_UDID=host.docker.internal:7422|" \
  "$(run_args device-Galaxy-R28M1384YQY-stf)"
check_contains "appium of macOS android uses the adb server of the connector" "|ADB_SERVER_SOCKET=tcp:connector:5037|" \
  "$(run_args device-Galaxy-R28M1384YQY-appium)"

setup_case
farm mac-devices start WiFi > /dev/null
check_contains "wireless android of macOS is connected over adb tcp" "|ANDROID_DEVICE=192.168.1.50:5555|" \
  "$(run_args device-WiFi-192.168.1.50-connector)"

setup_case
farm mac-devices start Emu > /dev/null
check "Android emulator of macOS gets the containers of a device" "connector stf appium uploader" \
  "$(calls docker | grep '^run|' | grep -o -- '--name|device-Emu-emu1-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
check_contains "Android emulator of macOS is connected by its adb address" "|ANDROID_DEVICE=host.docker.internal:5557|" \
  "$(run_args device-Emu-emu1-connector)"

section "macOS device listener"
for command in start stop down; do
  for filter in "" ios android iPhone_8_Plus; do
    setup_case
    farm mac-devices "$command" $filter > /dev/null
    expected=""
    if [[ -z "$filter" || "$filter" == "ios" ]]; then
      [[ "$command" == "start" ]] && expected="load" || expected="unload"
    fi
    check "${command} '${filter}' handles the listener with '${expected}'" "$expected" "$(calls launchctl | cut -d '|' -f 1 | paste -s -d ' ' -)"
  done
done

section "status"
setup_case
check_contains "Linux: wireless device shows its containers" "| Connector" "$(farm devices status WiFi)"
check_contains "Linux: USB device without symlink is disconnected" "DISCONNECTED" "$(farm devices status Galaxy)"
check_contains "macOS: wireless device shows its containers" "| Connector" "$(farm mac-devices status AppleTV)"
check_contains "macOS: not connected USB device is disconnected" "DISCONNECTED" "$(farm mac-devices status iPhone_8_Plus)"

section "uptime"
# iso_ago <seconds>: docker-like UTC timestamp of the given seconds ago
iso_ago() {
  local epoch=$(($(date +%s) - $1))
  if [[ "$(uname)" == "Darwin" ]]; then
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%S.123456789Z
  else
    date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%S.123456789Z
  fi
}
# uptime of the stf container from the status table of a wireless device (date parsing is OS specific)
if [[ "$(uname)" == "Darwin" ]]; then
  uptime_of() { farm mac-devices status AppleTV | grep '| STF' | awk -F '|' '{print $5}' | sed 's/^ *//; s/ *$//'; }
else
  uptime_of() { farm devices status WiFi | grep '| STF' | awk -F '|' '{print $5}' | sed 's/^ *//; s/ *$//'; }
fi
setup_case
printf '%s\n' device-AppleTV-aaaa1111-stf device-WiFi-192.168.1.50-stf > "${WORK}/docker_ps"
uptime="$(DOCKER_STARTED_AT="$(iso_ago 3661)" uptime_of)"
check "uptime below a day" "ok" "$([[ "$uptime" =~ ^01:01:0[12]$ ]] && echo ok || echo "$uptime")"
uptime="$(DOCKER_STARTED_AT="$(iso_ago 93784)" uptime_of)"
check "uptime above a day shows days" "ok" "$([[ "$uptime" =~ ^1d\ 02:03:0[45]$ ]] && echo ok || echo "$uptime")"
uptime="$(DOCKER_STARTED_AT="$(iso_ago 7200)" DOCKER_FINISHED_AT="$(iso_ago 60)" uptime_of)"
check "stopped container has unknown uptime" "UNKNOWN" "$uptime"

section "help"
check_contains "help describes the device argument" "Device: udid or name of a whitelisted device, or ios/android" "$(farm devices)"

finish
