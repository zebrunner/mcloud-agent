#!/bin/bash
# zebrunner-farm of both roles with stubbed docker, lsusb/ioreg and launchctl, run in a
# udev/launchd-like empty environment: device selection, container creation arguments,
# existing and failing containers, wireless devices, status, uptime and the listener handling.
source "$(dirname "$0")/lib.sh"
require_cmd ansible

# the devices list of the deploy: the fields key=value separated by '|'
cat > "${WORK}/devices.txt" << 'EOF'
id=R28M1384YQY|os=android|name=Galaxy|location=loc|appium_port=7421|adb_port=7422|min_port=7425|max_port=7430|connection=usb|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=
id=192.168.1.50|os=android|name=WiFi|location=loc|appium_port=7431|adb_port=7432|min_port=7435|max_port=7440|connection=wireless|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=
id=d6afc6b3a65584ca0813eb8957c6479b9b6ebb11|os=ios|name=iPhone_8_Plus|location=loc|appium_port=7441|adb_port=7442|min_port=7445|max_port=7450|connection=usb|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=|wda_port=|mjpeg_port=|connect_port=
id=aaaa1111|os=ios|name=AppleTV|location=loc|appium_port=7451|adb_port=7452|min_port=7455|max_port=7460|connection=proxy|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=10.0.0.5|wda_port=8100|mjpeg_port=|connect_port=
id=bbbb2222|os=ios|name=iPhoneWiFi|location=loc|appium_port=7461|adb_port=7462|min_port=7465|max_port=7470|connection=wireless|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=192.168.1.60|wda_port=|mjpeg_port=|connect_port=
id=emu1|os=android|name=Emu|location=loc|appium_port=7471|adb_port=7472|min_port=7475|max_port=7480|connection=android-sim|wda_file=/dev/null|wda_bundleid=x|address=host.docker.internal:5557|wda_port=|mjpeg_port=|connect_port=
id=B1B07E76|os=ios|name=Sim|location=loc|appium_port=7481|adb_port=7482|min_port=7485|max_port=7490|connection=ios-sim|wda_file=/tmp/wda-sim.zip|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=|wda_port=8110|mjpeg_port=|connect_port=
EOF
IPHONE="device-iPhone_8_Plus-d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"

# docker: records the calls, prints ${STUB_DIR}/docker_ps for `ps`, fails `run` of a container
# ending with $DOCKER_FAIL_RUN and `stop` of one ending with $DOCKER_FAIL_STOP, has no network with $DOCKER_NO_NETWORK
# and returns $DOCKER_STARTED_AT/$DOCKER_FINISHED_AT for `inspect`; the variables of
# `run -e NAME` (no value: docker takes it from its environment) as it sees them go to ${STUB_DIR}/run_env.log,
# `<container>|NAME=value|...|`, a NAME missing from its environment is not there
cat > "${WORK}/bin/docker" << 'EOF'
#!/bin/bash
(IFS='|'; echo "docker|$*") >> "${STUB_DIR}/calls.log"
case "$1" in
  ps) cat "${STUB_DIR}/docker_ps" 2> /dev/null ;;
  run)
    name=""
    prev=""
    env_line=""
    for arg in "$@"; do
      [[ "$prev" == "--name" ]] && name="$arg"
      if [[ "$prev" == "-e" && "$arg" != *=* ]] && value="$(printenv "$arg")"; then
        env_line+="${arg}=${value}|"
      fi
      prev="$arg"
    done
    echo "${name}|${env_line}" >> "${STUB_DIR}/run_env.log"
    if [[ -n "$DOCKER_FAIL_RUN" && "$name" == *"$DOCKER_FAIL_RUN" ]]; then
      echo "docker: simulated failure" >&2
      exit 125
    fi
    echo "id-${name}"
    ;;
  stop)
    if [[ -n "$DOCKER_FAIL_STOP" && "${*: -1}" == *"$DOCKER_FAIL_STOP" ]]; then
      echo "Error response from daemon: simulated stop failure" >&2
      exit 1
    fi
    ;;
  network)
    [[ "$2" != "inspect" || -z "$DOCKER_NO_NETWORK" ]] || exit 1
    ;;
  inspect)
    case "$*" in
      # status: the containers of docker_ps (<name> [<status>], running without it), healthy, started at
      # $DOCKER_STARTED_AT, $DOCKER_RESTARTS restarts, the exit code 1
      *'{{.Name}}|'*)
        for name in "${@:4}"; do
          line="$(awk -v name="$name" '$1 == name { print; exit }' "${STUB_DIR}/docker_ps" 2> /dev/null)"
          [[ -n "$line" ]] || continue
          status="$(cut -s -d ' ' -f 2 <<< "$line")"
          echo "/${name}|${status:-running}|healthy|${DOCKER_STARTED_AT}|${DOCKER_RESTARTS:-0}|1"
        done
        ;;
      # status --json: the state of a container of docker_ps (<name> <status>), healthy, started 100 seconds ago
      *'{{.State.Status}}|'*)
        status="$(grep "^${*: -1} " "${STUB_DIR}/docker_ps" 2> /dev/null | cut -d ' ' -f 2)"
        [[ -n "$status" ]] || exit 1
        echo "${status}|healthy|${DOCKER_STARTED_AT}|2"
        ;;
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
  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

# farm <devices|mac-devices> <arguments...>: runs zebrunner-farm without the user's environment
farm() {
  local role="$1"
  shift
  env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    DOCKER_FAIL_RUN="${DOCKER_FAIL_RUN:-}" DOCKER_STARTED_AT="${DOCKER_STARTED_AT:-}" DOCKER_FINISHED_AT="${DOCKER_FINISHED_AT:-}" \
    DOCKER_FAIL_STOP="${DOCKER_FAIL_STOP:-}" DOCKER_NO_NETWORK="${DOCKER_NO_NETWORK:-}" DOCKER_RESTARTS="${DOCKER_RESTARTS:-}" \
    MCLOUD_LOCK_DIR="$WORK" MCLOUD_LOCK_TIMEOUT="${MCLOUD_LOCK_TIMEOUT:-}" MCLOUD_FARM_INTERACTIVE="${MCLOUD_FARM_INTERACTIVE:-}" \
    ZEBRUNNER_FARM_ENV="${WORK}/farm-${role}.env" /bin/bash "$FARM_SCRIPT" "$@" 2>&1
}

# run_args <container>: arguments of the `docker run` of a container, joined by '|'
run_args() {
  calls docker | grep "^run|.*|--name|$1|"
}

# run_env <container>: the variables of the `docker run -e NAME` of a container as docker sees them, `|NAME=value|...|`
run_env() {
  grep "^$1|" "${WORK}/run_env.log" 2> /dev/null | cut -d '|' -f 2- | sed 's/^/|/'
}

# devices removed by `down`, in the order of the devices list
removed() {
  calls docker | grep '^volume|rm|' | sed 's/^volume|rm|device-//; s/-.*//' | paste -s -d ' ' -
}

setup_case() {
  reset_calls
  : > "${WORK}/run_env.log"
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
check_contains "appium relaxed security is off by the defaults" "|RELAXED_SECURITY=false|" "$appium"
check_contains "appium adb shell (mobile: shell) is on by the defaults" "|ADB_SHELL=true|" "$appium"
check_contains "appium chromedriver autodownload is on by the defaults" "|CHROMEDRIVER_AUTODOWNLOAD=true|" "$appium"
check_contains "appium app size check flag is lower case" "|APPIUM_APP_SIZE_DISABLE=false|" "$appium"
check_contains "appium links the stf container" "|--link|device-Galaxy-R28M1384YQY-stf:device|" "$appium"
check_not_contains "appium gets no proxy ports" "PROXY_PORT" "$appium"

setup_case
farm devices start WiFi > /dev/null
connector="$(run_args device-WiFi-192.168.1.50-connector)"
check_not_contains "wireless android connector gets no device" "--device=" "$connector"
check_not_contains "wireless android connector has no empty argument" "||" "$connector"
check_contains "wireless android is connected over adb tcp" "|ANDROID_DEVICE=192.168.1.50:5555|" "$connector"

setup_case
output="$(farm devices start Galaxy)"
check_contains "disconnected USB device is reported" "NOT connected over USB (lsusb): the containers are not created." "$output"
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
check "Android emulator gets the containers of a device, the farm does not create it" "connector stf appium" \
  "$(calls docker | grep '^run|' | grep -o -- '--name|device-Emu-emu1-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
connector="$(run_args device-Emu-emu1-connector)"
check_contains "Android emulator is connected by its adb address" "|ANDROID_DEVICE=host.docker.internal:5557|" "$connector"
check_not_contains "Android emulator connector gets no device" "--device=" "$connector"
check_contains "Android emulator is the device of STF" "|DEVICE_UDID=host.docker.internal:5557|" "$(run_args device-Emu-emu1-stf)"
check_contains "appium of an Android emulator knows the connection" "|DEVICE_CONNECTION=android-sim|" "$(run_args device-Emu-emu1-appium)"
setup_case
farm devices start WiFi > /dev/null
check_contains "appium of a wireless Android device knows the connection" "|DEVICE_CONNECTION=wireless|" \
  "$(run_args device-WiFi-192.168.1.50-appium)"

setup_case
output="$(farm devices start Sim)"
check_contains "iOS simulator on Linux is reported" "The iOS simulators run on a macOS host only" "$output"
check "iOS simulator on Linux gets no containers" "" "$(calls docker | grep '^run|')"

section "ZeroMQ security"
server_key="$(printf '%064d' 0 | tr 0 a)"
secret_key="$(printf '%064d' 0 | tr 0 b)"
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars \
    "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${server_key} STF_ZMQ_CURVE_SECRET_KEY=${secret_key}" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  # <name>:<container prefix> of an Android and an iOS device
  for device in WiFi:device-WiFi-192.168.1.50 AppleTV:device-AppleTV-aaaa1111; do
    setup_case
    farm "$role" start "${device%%:*}" > /dev/null
    stf="$(run_args "${device#*:}-stf")"
    check_contains "${role}: ${device%%:*}: the CURVE keys are passed, the secret one by its name" \
      "|STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${server_key}|-e|STF_ZMQ_CURVE_SECRET_KEY|" "$stf"
    check_not_contains "${role}: ${device%%:*}: the secret CURVE key is not an argument of docker" "$secret_key" "$stf"
    check_contains "${role}: ${device%%:*}: the secret CURVE key is in the environment of docker" \
      "|STF_ZMQ_CURVE_SECRET_KEY=${secret_key}|" "$(run_env "${device#*:}-stf")"
    check_not_contains "${role}: ${device%%:*}: no shared storage token" "STF_STORAGE_TOKEN" "$stf"
    check_not_contains "${role}: ${device%%:*}: no RethinkDB" "RETHINKDB" "$stf"
  done

  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

section "devices list"
cp "${WORK}/devices.txt" "${WORK}/devices.saved"
# the fields in another order, a comment, no wda_bundleid: WDA_BUNDLEID of the settings
printf '# a comment\nconnection=proxy|address=10.0.0.5|wda_port=8100|max_port=7460|min_port=7455|appium_port=7451|name=AppleTV|os=ios|id=aaaa1111\n' \
  > "${WORK}/devices.txt"
setup_case
render_farm mac-devices "${WORK}/farm-mac-devices.env" --extra-vars "WDA_BUNDLEID=my.global.wda" || exit 1
sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-mac-devices.env"
farm mac-devices start AppleTV > /dev/null
check_contains "the fields of a device in any order" "|-e|DEVICE_CONNECTION=proxy|-e|DEVICE_ADDRESS=10.0.0.5|" \
  "$(run_args "device-AppleTV-aaaa1111-connector")"
check_contains "WDA_BUNDLEID of the settings for a device without wda_bundleid" "|-e|WDA_BUNDLEID=my.global.wda|" \
  "$(run_args "device-AppleTV-aaaa1111-connector")"
# the empty WDA_FILE and WDA_BUNDLEID of the example settings: the defaults without quotes
for role in devices mac-devices; do
  setup_case
  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  farm "$role" start AppleTV > /dev/null
  connector="$(run_args "device-AppleTV-aaaa1111-connector")"
  check_contains "${role}: the default WDA_BUNDLEID without wda_bundleid and WDA_BUNDLEID" \
    "|-e|WDA_BUNDLEID=com.facebook.WebDriverAgentRunner.xctrunner|" "$connector"
  check_contains "${role}: /dev/null is mounted without wda_file and WDA_FILE" "|-v|/dev/null:/tmp/zebrunner/WebDriverAgent.ipa|" "$connector"
done
printf 'R28M1384YQY|android|Galaxy|loc|7421|7422|7425|7430|usb|/dev/null|x|||\n' > "${WORK}/devices.txt"
check_contains "a devices list of an earlier version asks for the deploy" \
  "The devices list ${WORK}/devices.txt is of an earlier version: deploy it with ./zebrunner.sh ansible" "$(farm devices status)"
mv "${WORK}/devices.saved" "${WORK}/devices.txt"
render_farm mac-devices "${WORK}/farm-mac-devices.env" || exit 1
sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-mac-devices.env"

section "macOS container creation"
setup_case
echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' > "${WORK}/usb"
output="$(farm mac-devices start iPhone_8_Plus)"
check "USB iPhone gets all containers" "connector stf appium" \
  "$(calls docker | grep '^run|' | grep -o -- "--name|${IPHONE}-[a-z]*" | sed 's/.*-//' | paste -s -d ' ' -)"
check_contains "appium links the stf container" "|--link|${IPHONE}-stf:device|" "$(run_args "${IPHONE}-appium")"
check_contains "appium links the connector" "|--link|${IPHONE}-connector:connector|" "$(run_args "${IPHONE}-appium")"
check_not_contains "nothing is reported as already created" "already created" "$output"

setup_case
echo "${IPHONE}-stf" > "${WORK}/docker_ps"
echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' > "${WORK}/usb"
farm mac-devices start iPhone_8_Plus > /dev/null
check "existing container is not created again" "connector appium" \
  "$(calls docker | grep '^run|' | grep -o -- "--name|${IPHONE}-[a-z]*" | sed 's/.*-//' | paste -s -d ' ' -)"

setup_case
echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' > "${WORK}/usb"
output="$(DOCKER_FAIL_RUN=-appium farm mac-devices start iPhone_8_Plus)"
check_contains "failed container creation is reported with the error of docker" \
  "NOT created  ${IPHONE}-appium: docker: simulated failure" "$output"
check "the containers after a failed one are not created" "connector stf appium" \
  "$(calls docker | grep '^run|' | grep -o -- "--name|${IPHONE}-[a-z]*" | sed 's/.*-//' | paste -s -d ' ' -)"

setup_case
farm mac-devices start AppleTV > /dev/null
check "proxied device gets a connector too" "connector stf appium" \
  "$(calls docker | grep '^run|' | grep -o -- '--name|device-AppleTV-aaaa1111-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
check_contains "proxied WDA is relayed by the connector on macOS" \
  "|DEVICE_CONNECTION=proxy|-e|DEVICE_ADDRESS=10.0.0.5|-e|DEVICE_WDA_PORT=8100|-e|DEVICE_MJPEG_PORT=8101|" \
  "$(run_args device-AppleTV-aaaa1111-connector)"
appium="$(run_args device-AppleTV-aaaa1111-appium)"
check_contains "proxied device reaches WDA through the connector" "|WDA_HOST=connector|-e|WDA_PORT=8100|-e|WIRELESS=true|" "$appium"
check_contains "proxied device links the connector" "|--link|device-AppleTV-aaaa1111-connector:connector|" "$appium"
# the images run on the platform of the Mac (arm64 on Apple Silicon), but appium: it is linux/amd64 only
check_contains "macOS: appium is linux/amd64" "|--name|device-AppleTV-aaaa1111-appium|--platform|linux/amd64|" \
  "$(run_args device-AppleTV-aaaa1111-appium)"
for container in connector stf uploader; do
  check_not_contains "macOS: the ${container} runs on the platform of the host" "--platform" \
    "$(run_args "device-AppleTV-aaaa1111-${container}")"
done
check_not_contains "macOS: no default platform" "DOCKER_DEFAULT_PLATFORM=" "$(grep -v '^ *#' "$FARM_SCRIPT")"
output="$(env -i PATH=/usr/bin:/bin ZEBRUNNER_FARM_ENV="${WORK}/missing.env" /bin/bash "$FARM_SCRIPT" status 2>&1)"
check_contains "zebrunner-farm without its settings asks for the deploy" "the settings ${WORK}/missing.env are not readable: deploy them with ./zebrunner.sh ansible" "$output"
output="$(farm devices version)"
check_contains "zebrunner-farm runs zebrunner.sh of the agent of its settings" "DEVICE_VERSION:" "$output"
check_not_contains "zebrunner.sh gets the agent dir from zebrunner-farm" "is not set" "$output"

setup_case
farm mac-devices stop AppleTV > /dev/null
check "proxied device stop includes the connector" "appium uploader stf connector" \
  "$(calls docker | grep '^stop|' | sed 's/.*-//' | paste -s -d ' ' -)"
setup_case
farm mac-devices stop iPhone_8_Plus > /dev/null
check "USB device stop includes the connector" "appium uploader stf connector" \
  "$(calls docker | grep '^stop|' | sed 's/.*-//' | paste -s -d ' ' -)"

setup_case
output="$(farm mac-devices start iPhoneWiFi)"
check_not_contains "wireless iPhone skips the USB check" "connected over USB" "$output"
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
check "Android emulator of macOS gets the containers of a device" "connector stf appium" \
  "$(calls docker | grep '^run|' | grep -o -- '--name|device-Emu-emu1-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
check_contains "Android emulator of macOS is connected by its adb address" "|ANDROID_DEVICE=host.docker.internal:5557|" \
  "$(run_args device-Emu-emu1-connector)"
check_contains "appium of an Android emulator of macOS knows the connection" "|DEVICE_CONNECTION=android-sim|" \
  "$(run_args device-Emu-emu1-appium)"

section "grid registration"
for role in devices mac-devices; do
  # the token of this host of ./zebrunner.sh join
  node_token="mcn1.build-ua.$(printf '%043d' 0 | tr 0 n)"
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "MCLOUD_NODE_TOKEN=${node_token}" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  setup_case
  farm "$role" start WiFi > /dev/null
  farm "$role" start AppleTV > /dev/null
  for device in device-WiFi-192.168.1.50 device-AppleTV-aaaa1111; do
    appium="$(run_args "${device}-appium")"
    check_contains "${role}: ${device}: appium registers with the token of the host" "|-e|NODE_REGISTRATION_TOKEN|" "$appium"
    check_contains "${role}: ${device}: the token of appium is in the environment of docker" \
      "|NODE_REGISTRATION_TOKEN=${node_token}|" "$(run_env "${device}-appium")"
    check_not_contains "${role}: ${device}: the token of appium is not an argument of docker" "$node_token" "$appium"
    stf="$(run_args "${device}-stf")"
    check_contains "${role}: ${device}: STF proves the devices and uses the storage with the token of the host" "|-e|STF_NODE_TOKEN|" "$stf"
    check_contains "${role}: ${device}: the token of STF is in the environment of docker" "|STF_NODE_TOKEN=${node_token}|" \
      "$(run_env "${device}-stf")"
    check_not_contains "${role}: ${device}: the token of STF is not an argument of docker" "$node_token" "$stf"
    check_not_contains "${role}: ${device}: no shared storage token" "STF_STORAGE_TOKEN" "$stf"
  done

  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

section "the network of a device"
# render <role> [ansible arguments...]: the settings of zebrunner-farm with the devices of the test
render_settings() {
  local role="$1"
  shift
  render_farm "$role" "${WORK}/farm-${role}.env" "$@" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
}
cp "${WORK}/devices.txt" "${WORK}/devices.txt.orig"
echo "id=dummy1|os=android|name=Dummy|location=loc|appium_port=7491|adb_port=7492|min_port=7495|max_port=7500|connection=android-sim|wda_file=/dev/null|wda_bundleid=x|address=mcloud-dummy:15555|wda_port=|mjpeg_port=|connect_port=" \
  >> "${WORK}/devices.txt"
network="device-WiFi-192.168.1.50"
for role in devices mac-devices; do
  setup_case
  DOCKER_NO_NETWORK=1 farm "$role" start WiFi > /dev/null
  check_contains "${role}: start creates the network of the device with the first /28 of DEVICE_NETWORK_SUBNETS" \
    "network|create|--driver|bridge|--subnet|10.233.0.0/28|--label|com.zebrunner.mcloud.device=${network}|${network}" \
    "$(calls docker)"
  for container in connector stf appium; do
    check_contains "${role}: the ${container} is on the network of the device only" "|--net=${network}|" \
      "$(run_args "${network}-${container}")"
  done
  check_not_contains "${role}: no shared network" "infra" "$(calls docker)"
  setup_case
  farm "$role" start WiFi > /dev/null
  check_not_contains "${role}: an existing network is kept" "network|create" "$(calls docker)"
  setup_case
  farm "$role" down WiFi > /dev/null
  check_contains "${role}: down removes the network of the device" "network|rm|${network}" "$(calls docker)"
  setup_case
  DOCKER_NO_NETWORK=1 farm "$role" start Dummy > /dev/null
  check_contains "${role}: the container of the emulator joins the network of the device" \
    "network|connect|device-Dummy-dummy1|mcloud-dummy" "$(calls docker)"
  setup_case
  DOCKER_NO_NETWORK=1 farm "$role" start Emu > /dev/null
  check_not_contains "${role}: host.docker.internal is not a container" "network|connect" "$(calls docker)"

  render_settings "$role" --extra-vars "DEVICE_NETWORK_SUBNETS=10.233.0.0/30"
  setup_case
  output="$(DOCKER_NO_NETWORK=1 farm "$role" start WiFi 2>&1)"
  check_contains "${role}: no free subnet: the device is not started" "no free /28 subnet in DEVICE_NETWORK_SUBNETS 10.233.0.0/30" "$output"
  check "${role}: no free subnet: no container" "" "$(calls docker | grep '^run|')"

  render_settings "$role" --extra-vars "DEVICE_NETWORK_ISOLATION=false"
  setup_case
  DOCKER_NO_NETWORK=1 farm "$role" start WiFi > /dev/null
  check_contains "${role}: DEVICE_NETWORK_ISOLATION=false: the shared network is created" "network|create|infra" "$(calls docker)"
  check_contains "${role}: DEVICE_NETWORK_ISOLATION=false: the containers share it" "|--net=infra|" \
    "$(run_args "${network}-connector")"
  setup_case
  farm "$role" down WiFi > /dev/null
  check_not_contains "${role}: DEVICE_NETWORK_ISOLATION=false: down keeps the shared network" "network|rm" "$(calls docker)"
  render_settings "$role"
done
mv "${WORK}/devices.txt.orig" "${WORK}/devices.txt"

section "the environment of the containers"
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "STF_API_URL=https://mcloud.example.com/api/v1" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  # <name>:<container prefix> of an Android and an iOS device
  for device in WiFi:device-WiFi-192.168.1.50 AppleTV:device-AppleTV-aaaa1111; do
    setup_case
    farm "$role" start "${device%%:*}" > /dev/null
    appium="$(run_args "${device#*:}-appium")"
    check_contains "${role}: ${device%%:*}: appium reports the errors of the device to STF" \
      "|STF_API_URL=https://mcloud.example.com/api/v1|" "$appium"
    check_not_contains "${role}: ${device%%:*}: appium gets no access token of an admin of STF" "STF_AUTH_TOKEN" "$appium"
    check_contains "${role}: ${device%%:*}: appium knows the location for the recording card" "|DEVICE_LOCATION=loc|" "$appium"
    for env in RETAIN_TASK CUSTOM_NODE_CONFIG ANDROID_DEVICE=; do
      check_not_contains "${role}: ${device%%:*}: appium gets no ${env%=}, it does not read it" "|${env}" "$appium"
    done
  done
  setup_case
  farm "$role" start WiFi > /dev/null
  stf="$(run_args device-WiFi-192.168.1.50-stf)"
  check_not_contains "${role}: a public CA: STF gets no certificate of MCloud" "MCLOUD_CA_PEM" "$stf"
  check_not_contains "${role}: STF verifies the certificate of MCloud by default" "NODE_TLS_REJECT_UNAUTHORIZED" "$stf"
  pem=$'-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----'
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "{\"common_farm_tls\": {\"stdout\": \"${pem//$'\n'/\\n}\"}}" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  setup_case
  farm "$role" start WiFi > /dev/null
  check_contains "${role}: the pinned certificate of MCloud goes to STF" "|-e|MCLOUD_CA_PEM|" \
    "$(run_args device-WiFi-192.168.1.50-stf)"
  # the log of the environment has one line per call: the first line of the PEM
  check_contains "${role}: the certificate is in the environment of docker" "|MCLOUD_CA_PEM=-----BEGIN CERTIFICATE-----" \
    "$(run_env device-WiFi-192.168.1.50-stf)"
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "STF_TLS_INSECURE=true" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  setup_case
  farm "$role" start WiFi > /dev/null
  check_contains "${role}: STF_TLS_INSECURE: STF does not verify the certificate" "|-e|NODE_TLS_REJECT_UNAUTHORIZED=0|" \
    "$(run_args device-WiFi-192.168.1.50-stf)"
  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  setup_case
  farm "$role" start WiFi > /dev/null
  connector="$(run_args device-WiFi-192.168.1.50-connector)"
  check_contains "${role}: the Android connector is created" "|ANDROID_DEVICE=192.168.1.50:5555|" "$connector"
  for env in PLATFORM_NAME DEVICE_UDID; do
    check_not_contains "${role}: the Android connector gets no ${env}, it does not read it" "|${env}=" "$connector"
  done

  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done
setup_case
echo "iSerial d6afc6b3a65584ca0813eb8957c6479b9b6ebb11" > "${WORK}/usb"
farm devices start iPhone_8_Plus > /dev/null
connector="$(run_args "${IPHONE}-connector")"
check_contains "Linux: the USB iPhone is passed into the connector" "|--device=/dev/${IPHONE}:" "$connector"
check_not_contains "Linux: the iOS connector gets no DEVICE_BUS, it does not read it" "|DEVICE_BUS=" "$connector"
check_not_contains "Linux: appium of a USB iPhone takes usbmuxd from the connector, not the USB device" "--device=" \
  "$(run_args "${IPHONE}-appium")"

section "recordings"
# the example settings have no S3: appium records no video, the device has no uploader
for role in devices mac-devices; do
  setup_case
  farm "$role" start WiFi > /dev/null
  check "${role}: without S3 the device has no uploader" "connector stf appium" \
    "$(calls docker | grep '^run|' | grep -o -- '--name|device-WiFi-192.168.1.50-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
  check_contains "${role}: without S3 appium records no video" "|RECORD_ARTIFACTS=false|" "$(run_args device-WiFi-192.168.1.50-appium)"
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "S3_BUCKET=bucket S3_TENANT=tenant" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  setup_case
  farm "$role" start WiFi > /dev/null
  check_contains "${role}: with S3 appium records the sessions" "|RECORD_ARTIFACTS=true|" "$(run_args device-WiFi-192.168.1.50-appium)"
  check_contains "${role}: with S3 the uploader uploads them" "|S3_KEY_PATTERN=s3://bucket/tenant/artifacts/test-sessions|" \
    "$(run_args device-WiFi-192.168.1.50-uploader)"
  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

section "secrets"
# the secrets of the host with the characters a shell would change; the containers of every device get them in the
# environment of docker, none of them is an argument of a process (ps shows them to every local user)
host_token="node token \$HOME"
curve_key="curve key *"
s3_key_id="access key id"
s3_secret="s3 \$ecret 'x'"
# shellcheck disable=SC2016
secrets='{"MCLOUD_NODE_TOKEN": "node token $HOME", "STF_ZMQ_CURVE_SECRET_KEY": "curve key *",
  "S3_ACCESS_KEY_ID": "access key id", "S3_SECRET": "s3 $ecret '"'x'"'",
  "S3_BUCKET": "bucket"}'
# expected_env <container>: the secrets of the container as run_env gives them
expected_env() {
  case "$1" in
  *-stf) echo "|STF_NODE_TOKEN=${host_token}|STF_ZMQ_CURVE_SECRET_KEY=${curve_key}|" ;;
  *-appium) echo "|NODE_REGISTRATION_TOKEN=${host_token}|" ;;
  *-uploader) echo "|AWS_ACCESS_KEY_ID=${s3_key_id}|AWS_SECRET_ACCESS_KEY=${s3_secret}|" ;;
  *) echo "|" ;;
  esac
}
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "$secrets" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  setup_case
  # all the devices are plugged in, in the format of lsusb (Linux) and ioreg (macOS)
  awk -F '[=|]' '{ print "iSerial " $2; print "\"USB Serial Number\" = \"" $2 "\"" }' "${WORK}/devices.txt" > "${WORK}/usb"
  farm "$role" start > /dev/null
  containers="$(calls docker | grep '^run|' | grep -o -- '--name|[^|]*' | cut -d '|' -f 2)"
  check_contains "${role}: the devices get their uploaders" "-uploader" "$containers"
  wrong=""
  for name in $containers; do
    [[ "$(run_env "$name")" == "$(expected_env "$name")" ]] || wrong+=" ${name}: $(run_env "$name")"
  done
  check "${role}: every container gets its secrets in the environment of docker" "" "$wrong"
  for secret in "$host_token" "$curve_key" "$s3_key_id" "$s3_secret"; do
    check_not_contains "${role}: the secret '${secret}' is no argument of a process" "$secret" "$(cat "${WORK}/calls.log")"
  done

  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

section "macOS device listener"
# -x of a USB iOS device (the ones of the listener) keeps the listener as it is: it keeps working for that device
for command in start stop down; do
  for filter in "" ios android iPhone_8_Plus "-x iPhone_8_Plus" "ios -x AppleTV" "-x Galaxy" "ios -x=iPhone_8_Plus"; do
    setup_case
    # the words of the filter are the arguments
    # shellcheck disable=SC2086
    farm mac-devices "$command" $filter > /dev/null
    expected=""
    case "$filter" in
    "" | ios | "ios -x AppleTV" | "-x Galaxy")
      [[ "$command" == "start" ]] && expected="load" || expected="unload"
      ;;
    esac
    check "${command} '${filter}' handles the listener with '${expected}'" "$expected" "$(calls launchctl | cut -d '|' -f 1 | paste -s -d ' ' -)"
  done
done

section "selection of several devices"
for role in devices mac-devices; do
  while IFS='=' read -r query expected; do
    setup_case
    # the query words are the arguments, their patterns are not expanded by this shell
    set -f
    # shellcheck disable=SC2086
    farm "$role" down $query > /dev/null
    set +f
    check "${role}: down ${query} selects '${expected}'" "$expected" "$(removed)"
  done << 'EOF'
Galaxy WiFi=Galaxy WiFi
Galaxy,Sim=Galaxy Sim
wireless=WiFi iPhoneWiFi
android-sim ios-sim proxy=AppleTV Emu Sim
iPhone*=iPhone_8_Plus iPhoneWiFi
??=
lo?=Galaxy WiFi iPhone_8_Plus AppleTV iPhoneWiFi Emu Sim
android -x WiFi=Galaxy Emu
-x ios -x Emu=Galaxy WiFi
--exclude ios,android-sim=Galaxy WiFi
ios --exclude iPhone*=AppleTV Sim
EOF
done
setup_case
farm devices down --exclude=ios,android-sim,Galaxy > /dev/null
check "--exclude= takes the devices too" "WiFi" "$(removed)"
setup_case
farm devices down -e=ios,android-sim -e Galaxy > /dev/null
check "-e is -x (also -e=)" "WiFi" "$(removed)"
setup_case
farm devices down '*WiFi' > /dev/null
check "a pattern matches the names" "WiFi iPhoneWiFi" "$(removed)"
setup_case
output="$(farm devices stop ios -x ios)"
check "an empty selection fails" "1" "$?"
check_contains "an empty selection is reported" "No device matches: ios without ios" "$output"
check "an empty selection changes no container" "" "$(calls docker | grep -v '^network|')"
setup_case
output="$(farm devices stop android -x NO_SUCH)"
check "an excluded unknown device fails" "1" "$?"
check_contains "an excluded unknown device is reported" "device not found: NO_SUCH" "$output"
output="$(farm devices stop android --bad)"
check_contains "an unknown option is reported" "unknown option: --bad" "$output"
output="$(farm devices stop android -x)"
check_contains "the exclusion needs devices" "-x needs the devices to skip" "$output"

section "confirmation of the devices"
# ask <role> <answers> <arguments...>: zebrunner-farm as a person at a terminal answering the question
ask() {
  local role="$1"
  local answers="$2"
  shift 2
  printf '%b' "$answers" | MCLOUD_FARM_INTERACTIVE=true farm "$role" "$@"
}
for role in devices mac-devices; do
  setup_case
  printf '%s\n' "device-WiFi-192.168.1.50-stf running" "device-WiFi-192.168.1.50-appium exited" > "${WORK}/docker_ps"
  output="$(ask "$role" "\n" down android)"
  check "${role}: the devices are listed with their numbers" "1" "$(grep -cE '^ +2 +WiFi +192\.168\.1\.50 +android +wireless ' <<< "$output")"
  check_contains "${role}: the containers of a device are summarized" "1 of 2 running" "$output"
  check_contains "${role}: a device without containers" "Galaxy" "$output"
  check "${role}: Enter runs the command" "Galaxy WiFi Emu" "$(removed)"

  setup_case
  output="$(ask "$role" "n\n" down android)"
  check_contains "${role}: n cancels" "Cancelled." "$output"
  check "${role}: a cancelled command changes no container" "" "$(calls docker | grep -v '^ps|')"

  setup_case
  ask "$role" "x 2\ny\n" down android > /dev/null
  check "${role}: x excludes a device by its number" "Galaxy Emu" "$(removed)"
  setup_case
  ask "$role" "x\nEmu,1\n\n" down android > /dev/null
  check "${role}: x asks the devices to exclude" "WiFi" "$(removed)"
  setup_case
  ask "$role" "f ios\nf Sim 2\ny\n" down > /dev/null
  # the numbers are the ones of the list shown last: 2 is AppleTV of the iOS devices
  check "${role}: f filters the list, again and again" "AppleTV Sim" "$(removed)"
  setup_case
  output="$(ask "$role" "x android\n" down android)"
  check_contains "${role}: no device left cancels" "No device is left." "$output"
  check "${role}: no device left changes no container" "" "$(removed)"
  setup_case
  output="$(ask "$role" "what\ny\n" down Emu WiFi)"
  check_contains "${role}: a wrong answer is explained" "Answer y (run), n (cancel)" "$output"
  check "${role}: a wrong answer asks again" "WiFi Emu" "$(removed)"
  setup_case
  output="$(ask "$role" "" down android)"
  check "${role}: no answer (end of input) cancels" "" "$(removed)"

  setup_case
  output="$(ask "$role" "n\n" down android -q)"
  check_not_contains "${role}: -q asks nothing" "The devices to" "$output"
  check "${role}: -q runs the command" "Galaxy WiFi Emu" "$(removed)"
  setup_case
  output="$(ask "$role" "n\n" down WiFi)"
  check_not_contains "${role}: a device named exactly is not confirmed" "The devices to" "$output"
  check "${role}: a device named exactly runs at once" "WiFi" "$(removed)"
  setup_case
  output="$(ask "$role" "n\n" status android)"
  check_not_contains "${role}: status asks nothing" "The devices to" "$output"
  setup_case
  output="$(farm "$role" down android < /dev/null)"
  check_not_contains "${role}: without a terminal (udev, launchd, scripts) nothing is asked" "The devices to" "$output"
done

section "restart strategies"
# phases: the order of the removals and the creations of the containers, repeats collapsed
phases() {
  calls docker | grep -E '^(rm|run)\|' | cut -d '|' -f 1 | uniq | paste -s -d ' ' -
}
for role in devices mac-devices; do
  setup_case
  output="$(farm "$role" restart android -q)"
  check "${role}: batch is the default: all removed, then created" "rm run" "$(phases)"
  check_contains "${role}: the batch phases are reported" "Removing the containers of 3 devices (batch restart)" "$output"
  setup_case
  farm "$role" restart android -q --rolling > /dev/null
  check "${role}: rolling removes and creates device by device" "rm run rm run" "$(phases)"
  setup_case
  farm "$role" restart android -q --strategy=rolling > /dev/null
  check "${role}: --strategy=rolling" "rm run rm run" "$(phases)"
  setup_case
  farm "$role" restart android -q --strategy batch > /dev/null
  check "${role}: --strategy batch" "rm run" "$(phases)"
  check_contains "${role}: an unknown strategy fails" "--strategy is batch or rolling" "$(farm "$role" restart --strategy=fast)"
  setup_case
  output="$(printf 's\ny\n' | MCLOUD_FARM_INTERACTIVE=true farm "$role" restart android)"
  check_contains "${role}: the question shows the strategy" "Strategy: batch - the containers of all the devices are removed" "$output"
  check_contains "${role}: s switches the strategy" "Strategy: rolling - device by device" "$output"
  check "${role}: the switched strategy runs" "rm run rm run" "$(phases)"
  setup_case
  output="$(printf 'n\n' | MCLOUD_FARM_INTERACTIVE=true farm "$role" stop android)"
  check_not_contains "${role}: other commands have no strategy" "Strategy:" "$output"
done

section "allow_reboot"
cp "${WORK}/devices.txt" "${WORK}/devices.saved"
sed -e 's/^\(id=bbbb2222|.*\)$/\1|allow_reboot=true/' -e 's/^\(id=aaaa1111|.*\)$/\1|allow_reboot=false/' \
  -e 's/^\(id=192.168.1.50|.*\)$/\1|allow_reboot=true/' "${WORK}/devices.saved" > "${WORK}/devices.txt"
for role in devices mac-devices; do
  setup_case
  farm "$role" start iPhoneWiFi AppleTV WiFi Emu > /dev/null
  check_contains "${role}: allow_reboot lets the iOS connector reboot the device" "|-e|ALLOW_REBOOT=true|" \
    "$(run_args device-iPhoneWiFi-bbbb2222-connector)"
  check_contains "${role}: allow_reboot lets the Android connector reboot the device" "|-e|ALLOW_REBOOT=true|" \
    "$(run_args device-WiFi-192.168.1.50-connector)"
  check_not_contains "${role}: allow_reboot=false passes nothing" "ALLOW_REBOOT" "$(run_args device-AppleTV-aaaa1111-connector)"
  check_not_contains "${role}: an Android device without allow_reboot gets no ALLOW_REBOOT" "ALLOW_REBOOT" \
    "$(run_args device-Emu-emu1-connector)"
done
mv "${WORK}/devices.saved" "${WORK}/devices.txt"
setup_case
farm devices start iPhoneWiFi WiFi > /dev/null
check_not_contains "without allow_reboot the connector gets no ALLOW_REBOOT" "ALLOW_REBOOT" \
  "$(run_args device-iPhoneWiFi-bbbb2222-connector)$(run_args device-WiFi-192.168.1.50-connector)"

section "remote debug port"
cp "${WORK}/devices.txt" "${WORK}/devices.saved"
# WiFi: the port in the range, Emu: the port out of it
sed -e 's/^\(id=192.168.1.50|.*\)connect_port=$/\1connect_port=7436/' -e 's/^\(id=emu1|.*\)connect_port=$/\1connect_port=7999/' \
  "${WORK}/devices.saved" > "${WORK}/devices.txt"
for role in devices mac-devices; do
  setup_case
  farm "$role" start WiFi Emu -q > /dev/null
  stf="$(run_args device-WiFi-192.168.1.50-stf)"
  check_contains "${role}: connect_port goes to STF" "|STF_PROVIDER_CONNECT_PORT=7436|" "$stf"
  check_not_contains "${role}: connect_port in the range is not published twice" "|7436:7436|" "$stf"
  check_contains "${role}: connect_port out of the range is published" "|-p|7999:7999|" "$(run_args device-Emu-emu1-stf)"
  check_contains "${role}: appium knows the remote debug port" "|ADB_PORT=7999|" "$(run_args device-Emu-emu1-appium)"
done
mv "${WORK}/devices.saved" "${WORK}/devices.txt"

for role in devices mac-devices; do
  setup_case
  farm "$role" start WiFi > /dev/null
  check_not_contains "${role}: STF picks the remote debug port without connect_port" "STF_PROVIDER_CONNECT_PORT" "$(run_args device-WiFi-192.168.1.50-stf)"
  check_contains "${role}: the remote debug port is the second one of the range by default" "|ADB_PORT=7436|" \
    "$(run_args device-WiFi-192.168.1.50-appium)"
  farm "$role" start AppleTV > /dev/null
  check_contains "${role}: an iOS appium keeps adb_port" "|ADB_PORT=7452|" "$(run_args device-AppleTV-aaaa1111-appium)"
done

section "remote connect host"
for role in devices mac-devices; do
  setup_case
  farm "$role" start WiFi > /dev/null
  check_contains "${role}: STF_PROVIDER_HOST is the connect host by default" "|REMOTE_CONNECT_HOST=|" "$(run_args device-WiFi-192.168.1.50-stf)"
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "REMOTE_CONNECT_HOST=mcloud.example.com" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  for device in WiFi:device-WiFi-192.168.1.50 AppleTV:device-AppleTV-aaaa1111; do
    setup_case
    farm "$role" start "${device%%:*}" > /dev/null
    check_contains "${role}: ${device%%:*}: the connect host goes to STF" "|REMOTE_CONNECT_HOST=mcloud.example.com|" "$(run_args "${device#*:}-stf")"
  done
  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

section "containers of a device"
for role in devices mac-devices; do
  setup_case
  printf '%s\n' "device-WiFi-192.168.1.50-connector running" "device-WiFi-192.168.1.50-stf exited" > "${WORK}/docker_ps"
  # without the colors of the states
  output="$(farm "$role" start WiFi | sed "s/$(printf '\033')\[[0-9;]*m//g")"
  check_contains "${role}: a running container is kept" "running  device-WiFi-192.168.1.50-connector" "$output"
  check_contains "${role}: a stopped container is started" "started  device-WiFi-192.168.1.50-stf" "$output"
  check_contains "${role}: a missing container is created" "created  device-WiFi-192.168.1.50-appium" "$output"
  check "${role}: only the stopped container is started" "start|device-WiFi-192.168.1.50-stf" "$(calls docker | grep '^start|')"
  check "${role}: only the missing containers are created" "appium" \
    "$(calls docker | grep '^run|' | grep -o -- '--name|device-WiFi-192.168.1.50-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
  setup_case
  output="$(farm "$role" down WiFi)"
  # the docker stub removes no container
  check_contains "${role}: down reports every container" "no container  device-WiFi-192.168.1.50-uploader" "$output"
  check_contains "${role}: down reports the volume of the logs" "removed  device-WiFi-192.168.1.50  volume of the logs" "$output"
  # appium shares the recordings, the uploader uploads them, the volume of the logs is removed after them
  check "${role}: down stops every container before its removal, appium and the uploader first, the volume last" \
    "stop|-t|40|appium rm|-f|appium stop|-t|130|uploader rm|-f|uploader stop|-t|30|stf rm|-f|stf stop|-t|10|connector rm|-f|connector volume|rm|device-WiFi-192.168.1.50" \
    "$(calls docker | grep -E '^(stop|rm|volume)\|' | sed 's/device-WiFi-192.168.1.50-//' | paste -s -d ' ' -)"
  setup_case
  output="$(farm "$role" stop WiFi)"
  check_contains "${role}: stop reports every container" "stopped  device-WiFi-192.168.1.50-appium" "$output"
  check_contains "${role}: the device is the title of its lines" "  > WiFi  android - wireless - 192.168.1.50 ---" "$output"
  check "${role}: stop waits for the recordings and their upload" \
    "stop|-t|40|appium stop|-t|130|uploader stop|-t|30|stf stop|-t|10|connector" \
    "$(calls docker | grep '^stop|' | sed 's/device-WiFi-192.168.1.50-//' | paste -s -d ' ' -)"
done

section "status"
setup_case
check_contains "Linux: wireless device shows its containers" "no container  device-WiFi-192.168.1.50-connector" \
  "$(farm devices status WiFi)"
check_contains "Linux: USB device without symlink is disconnected" "disconnected: the USB device is not plugged in" \
  "$(farm devices status Galaxy)"
check_contains "macOS: wireless device shows its containers" "no container  device-AppleTV-aaaa1111-connector" \
  "$(farm mac-devices status AppleTV)"
check_contains "macOS: not connected USB device is disconnected" "disconnected: the USB device is not plugged in" \
  "$(farm mac-devices status iPhone_8_Plus)"

# status --json: the JSON array on stdout only, checked by python
OS_ROLE=devices
[[ "$(uname)" == "Darwin" ]] && OS_ROLE=mac-devices
setup_case
printf '%s\n' "device-WiFi-192.168.1.50-connector running" "device-WiFi-192.168.1.50-stf exited" > "${WORK}/docker_ps"
for role in devices mac-devices; do
  started="$(date -u -v-100S +%Y-%m-%dT%H:%M:%S 2> /dev/null || date -u -d '100 seconds ago' +%Y-%m-%dT%H:%M:%S).123456789Z"
  output="$(DOCKER_STARTED_AT="$started" farm "$role" status --json WiFi Galaxy 2> /dev/null)"
  report="$(python3 -c '
import json, sys
devices = json.loads(sys.argv[1])
wifi, galaxy = [next(device for device in devices if device["name"] == name) for name in ("WiFi", "Galaxy")]
connector = wifi["containers"]["connector"]
print(len(devices), wifi["name"], wifi["os"], wifi["connection"], wifi["plugged_in"], galaxy["plugged_in"])
print(connector["status"], connector["health"], connector["restarts"])
print(95 <= (connector["uptime_seconds"] or 0) <= 130)
print(wifi["containers"]["stf"]["status"], wifi["containers"]["stf"]["uptime_seconds"], wifi["containers"]["appium"])
' "$output" 2>&1)"
  check "${role}: status --json is the devices of the selection" "2 WiFi android wireless None False" "$(sed -n 1p <<< "$report")"
  check "${role}: status --json has the state of a running container" "running healthy 2" "$(sed -n 2p <<< "$report")"
  check "${role}: status --json has a stopped and a missing container" "exited None {'exists': False}" "$(sed -n 4p <<< "$report")"
  # the date of the OS of the role: GNU date of Linux, BSD date of macOS
  if [[ "$role" == "$OS_ROLE" ]]; then
    check "${role}: status --json has the uptime of a running container" "True" "$(sed -n 3p <<< "$report")"
  fi
done
# farm_streams <stdout|stderr> <arguments...>: one output stream of zebrunner-farm of Linux
farm_streams() {
  local stream="$1"
  shift
  if [[ "$stream" == stdout ]]; then
    env -i PATH="${WORK}/bin:/usr/bin:/bin" STUB_DIR="$WORK" ZEBRUNNER_FARM_ENV="${WORK}/farm-devices.env" \
      /bin/bash "$FARM_SCRIPT" "$@" 2> /dev/null
  else
    env -i PATH="${WORK}/bin:/usr/bin:/bin" STUB_DIR="$WORK" ZEBRUNNER_FARM_ENV="${WORK}/farm-devices.env" \
      /bin/bash "$FARM_SCRIPT" "$@" 3>&1 1> /dev/null 2>&3
  fi
}
check_contains "status --json of an unknown device: the message on stderr" "device not found: Nope" \
  "$(farm_streams stderr status --json Nope)"
check "status --json of an unknown device: nothing on stdout" "" "$(farm_streams stdout status --json Nope)"
check_contains "status --json: the JSON on stdout" '"name": "WiFi"' "$(farm_streams stdout status --json WiFi)"
check_contains "--json is for status only" "--json is an option of status only" "$(farm devices stop --json WiFi 2>&1)"
check "a name with a quote is a JSON string" '"a\"b\\c"' "$(eval "$(sed -n '/^json_string() {/,/^}/p' "$FARM_SCRIPT")" && json_string 'a"b\c')"

section "device lock"
if command -v flock > /dev/null 2>&1; then
  lock="${WORK}/mcloud-device-R28M1384YQY.lock"
  : > "$lock"
  # another zebrunner-farm (e.g. the restart of udev) keeps the device
  flock "$lock" sleep 8 &
  holder=$!
  sleep 0.5
  setup_case
  output="$(MCLOUD_LOCK_TIMEOUT=1 farm devices restart Galaxy)"
  check "a command of a kept device fails (the unit of udev fails)" "1" "$?"
  check_contains "a command of a kept device (called by its name, locked by its id) waits, then gives up" \
    "another zebrunner-farm keeps the device Galaxy for too long" "$output"
  check "a command of a kept device changes no container" "" "$(calls docker | grep -v '^network|')"
  setup_case
  output="$(MCLOUD_LOCK_TIMEOUT=1 farm devices stop android)"
  check_contains "a group waits for its kept device, then gives up" "another zebrunner-farm keeps the device Galaxy for too long" "$output"
  check "a group does not change the containers of its kept device" "" "$(calls docker | grep 'device-Galaxy-')"
  check_contains "a group runs the command for its other devices" "stop|-t|40|device-WiFi-192.168.1.50-appium" "$(calls docker)"
  setup_case
  MCLOUD_LOCK_TIMEOUT=1 farm devices restart android -q > /dev/null
  check "the batch restart of a group does not change the containers of its kept device" "" "$(calls docker | grep 'device-Galaxy-')"
  check_contains "the batch restart of a group restarts its other devices" "--name|device-WiFi-192.168.1.50-appium|" "$(calls docker)"
  wait "$holder"
  setup_case
  echo "iSerial R28M1384YQY" > "${WORK}/usb"
  farm devices restart R28M1384YQY > /dev/null
  check_contains "the device runs its command when it is free" "rm|-f|device-Galaxy-R28M1384YQY-appium" "$(calls docker)"
  check_contains "the device runs its command when it is free (the containers)" "--name|device-Galaxy-R28M1384YQY-appium|" \
    "$(calls docker)"
else
  skip_check "the lock of a device" "no flock (util-linux)"
fi

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
# the uptime of the stf container in the status of a wireless device (date parsing is OS specific)
if [[ "$(uname)" == "Darwin" ]]; then
  uptime_of() { farm mac-devices status AppleTV | grep -- '-stf$' | sed 's/^ *[A-Za-z]* *[a-z]* *[a-z-]* *//; s/ *device-.*//'; }
else
  uptime_of() { farm devices status WiFi | grep -- '-stf$' | sed 's/^ *[A-Za-z]* *[a-z]* *[a-z-]* *//; s/ *device-.*//'; }
fi
setup_case
printf '%s\n' "device-AppleTV-aaaa1111-stf running" "device-WiFi-192.168.1.50-stf running" > "${WORK}/docker_ps"
uptime="$(DOCKER_STARTED_AT="$(iso_ago 3661)" uptime_of)"
check "uptime below a day" "ok" "$([[ "$uptime" =~ ^up\ 1h\ 1m$ ]] && echo ok || echo "$uptime")"
uptime="$(DOCKER_STARTED_AT="$(iso_ago 93784)" uptime_of)"
check "uptime above a day shows days" "ok" "$([[ "$uptime" =~ ^up\ 1d\ 2h$ ]] && echo ok || echo "$uptime")"
uptime="$(DOCKER_STARTED_AT="$(iso_ago 45)" uptime_of)"
check "uptime below a minute shows seconds" "ok" "$([[ "$uptime" =~ ^up\ 4[5-9]s$ ]] && echo ok || echo "$uptime")"
printf '%s\n' "device-AppleTV-aaaa1111-stf exited" "device-WiFi-192.168.1.50-stf exited" > "${WORK}/docker_ps"
check "stopped container has its exit code, no uptime" "code 1" "$(DOCKER_STARTED_AT="$(iso_ago 7200)" uptime_of)"

section "Developer Disk Images"
# ddi_mount <role> <device> <container prefix>: the DDI mount of the connector of a started device, empty without it
ddi_mount() {
  setup_case
  echo "iSerial d6afc6b3a65584ca0813eb8957c6479b9b6ebb11" > "${WORK}/usb"
  echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' >> "${WORK}/usb"
  farm "$1" start "$2" > /dev/null
  run_args "${3}-connector" | tr '|' '\n' | grep ':/opt/zebrunner/ddi'
}
# a fake agent folder for the default DDI_DIR, with the scripts zebrunner-farm sources
mkdir -p "${WORK}/agent"
ln -s "${REPO}/patch" "${WORK}/agent/patch"
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  check_contains "${role}: the DDI are on by default" $'\n'"DDI_ENABLED=true"$'\n' $'\n'"$(cat "${WORK}/farm-${role}.env")"$'\n'
  check_contains "${role}: DDI_DIR is empty by default" "DDI_DIR=''" "$(cat "${WORK}/farm-${role}.env")"
  sed -i.bak -e "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" \
    -e "s|^ZEBRUNNER_MCLOUD_AGENT_DIR=.*|ZEBRUNNER_MCLOUD_AGENT_DIR=${WORK}/agent|" "${WORK}/farm-${role}.env"
  rm -rf "${WORK}/agent/DeveloperDiskImages"
  check "${role}: no folder, no mount" "" "$(ddi_mount "$role" iPhone_8_Plus "$IPHONE")"
  mkdir -p "${WORK}/agent/DeveloperDiskImages"
  check "${role}: the folder of the agent is mounted read-only" "${WORK}/agent/DeveloperDiskImages:/opt/zebrunner/ddi:ro" \
    "$(ddi_mount "$role" iPhone_8_Plus "$IPHONE")"
  check "${role}: the wireless iPhone gets it too" "${WORK}/agent/DeveloperDiskImages:/opt/zebrunner/ddi:ro" \
    "$(ddi_mount "$role" iPhoneWiFi device-iPhoneWiFi-bbbb2222)"
  check "${role}: the Android connector gets none" "" "$(ddi_mount "$role" WiFi device-WiFi-192.168.1.50)"
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars "DDI_DIR=${WORK}/ddi" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  mkdir -p "${WORK}/ddi"
  check "${role}: DDI_DIR is mounted" "${WORK}/ddi:/opt/zebrunner/ddi:ro" "$(ddi_mount "$role" iPhone_8_Plus "$IPHONE")"
  render_farm "$role" "${WORK}/farm-${role}.env" --extra-vars '{"DDI_ENABLED": false}' --extra-vars "DDI_DIR=${WORK}/ddi" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
  check_contains "${role}: DDI_ENABLED false is lower case" "DDI_ENABLED=false" "$(cat "${WORK}/farm-${role}.env")"
  check "${role}: DDI_ENABLED false mounts nothing" "" "$(ddi_mount "$role" iPhone_8_Plus "$IPHONE")"
done
render_farm mac-devices "${WORK}/farm-mac-devices.env" --extra-vars "DDI_DIR=${WORK}/ddi" || exit 1
sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-mac-devices.env"
check "a simulator gets none" "" "$(ddi_mount mac-devices Sim device-Sim-B1B07E76)"
check "the proxied device gets it" "${WORK}/ddi:/opt/zebrunner/ddi:ro" "$(ddi_mount mac-devices AppleTV device-AppleTV-aaaa1111)"

section "doctor"
# python3 of patch/usb_stats.py and patch/usb_map.py records its arguments, its status is the one of
# ${STUB_DIR}/usb-status
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub python3 '(IFS="|"; echo "python3|$*") >> "${STUB_DIR}/calls.log"
exit "$(cat "${STUB_DIR}/usb-status" 2> /dev/null || echo 0)"'
reset_calls
farm devices doctor usb-stats > /dev/null
check "doctor usb-stats: the report of every port of the devices list" "|--devices|${WORK}/devices.txt" \
  "$(calls python3 | sed 's/^[^|]*usb_stats\.py//')"
reset_calls
farm devices doctor usb-stats iPhone_8_Plus Galaxy --days 30 --threshold 5 --json > /dev/null
check "doctor usb-stats: the options and the devices of the selection" \
  "|--devices|${WORK}/devices.txt|--days|30|--threshold|5|--json|--device|R28M1384YQY|--device|d6afc6b3a65584ca0813eb8957c6479b9b6ebb11" \
  "$(calls python3 | sed 's/^[^|]*usb_stats\.py//')"
reset_calls
farm devices doctor usb-stats usb -x Galaxy --days=3 > /dev/null
check "doctor usb-stats: a group without a device" "|--devices|${WORK}/devices.txt|--days|3|--device|d6afc6b3a65584ca0813eb8957c6479b9b6ebb11" \
  "$(calls python3 | sed 's/^[^|]*usb_stats\.py//')"
echo 1 > "${WORK}/usb-status"
farm devices doctor usb-stats > /dev/null
check "doctor usb-stats: the status of a flapping port" "1" "$?"
rm -f "${WORK}/usb-status"
check_contains "doctor usb-stats: --days takes a number" "--days takes a number of 1 or more" "$(farm devices doctor usb-stats --days 0)"
check_contains "doctor usb-stats: an unknown option" "unknown option: --verbose" "$(farm devices doctor usb-stats --verbose)"
check_contains "doctor usb-stats: an unknown device" "device not found: Galxy" "$(farm devices doctor usb-stats Galxy)"
reset_calls
farm devices doctor usb-map > /dev/null
check "doctor usb-map: the tree of every device of the devices list" "|--devices|${WORK}/devices.txt" \
  "$(calls python3 | sed 's/^[^|]*usb_map\.py//')"
reset_calls
farm devices doctor usb-map Galaxy --days=7 --json > /dev/null
check "doctor usb-map: the options and the devices of the selection" \
  "|--devices|${WORK}/devices.txt|--days|7|--json|--device|R28M1384YQY" "$(calls python3 | sed 's/^[^|]*usb_map\.py//')"
echo 1 > "${WORK}/usb-status"
farm devices doctor usb-map > /dev/null
check "doctor usb-map: the status of a device not on USB" "1" "$?"
rm -f "${WORK}/usb-status"
check_contains "doctor usb-map: --days takes a number" "--days takes a number of 1 or more" "$(farm devices doctor usb-map --days x)"
check_contains "doctor usb-map: no --threshold" "unknown option: --threshold" "$(farm devices doctor usb-map --threshold 5)"
check_contains "doctor usb-map: an unknown device" "device not found: Galxy" "$(farm devices doctor usb-map Galxy)"
reset_calls
check_contains "doctor usb-stats: Linux only" "usb-stats reads the kernel log of Linux: not on macOS" "$(farm mac-devices doctor usb-stats)"
check_contains "doctor usb-map: Linux only" "usb-map reads the sysfs of Linux: not on macOS" "$(farm mac-devices doctor usb-map)"
check "doctor: nothing runs on macOS" "" "$(calls python3)"
output="$(farm devices doctor usb-mapp)"
check "doctor: an unknown check is a usage error" "2" "$?"
check_contains "doctor: an unknown check suggests the closest ones" "unknown check of doctor: usb-mapp (did you mean: usb-map" "$output"
check_contains "doctor: its help" "whether the port (different devices flapped on it" "$(farm devices help doctor | tr -s ' \n' '  ')"
check_contains "doctor: the help of usb-map" "the chips of one hub and its USB3 half as one hub" "$(farm devices doctor usb-map --help | tr -s ' \n' '  ')"
reset_calls
farm devices doctor usb-map -h > /dev/null
check "doctor: --help runs nothing" "" "$(calls python3)"
# complete_doctor <index> <words...>: the candidates of zebrunner-farm doctor on one line
complete_doctor() {
  env -i PATH="${WORK}/bin:/usr/bin:/bin" ZEBRUNNER_FARM_ENV="${WORK}/farm-devices.env" /bin/bash "$FARM_SCRIPT" __complete "$@" | paste -s -d ' ' -
}
check "doctor: the checks of the completion" "usb-stats usb-map" "$(complete_doctor 2 doctor "")"
check "doctor usb-stats: the options of the completion" "--days --threshold --json -x -e --exclude --help" "$(complete_doctor 3 doctor usb-stats -)"
check "doctor usb-map: the options of the completion" "--days --json -x -e --exclude --help" "$(complete_doctor 3 doctor usb-map -)"
check_contains "doctor usb-map: the devices of the completion" "R28M1384YQY Galaxy" "$(complete_doctor 3 doctor usb-map "")"
check "doctor: nothing after --days" "" "$(complete_doctor 4 doctor usb-map --days "")"
# doctor without a check: ./zebrunner.sh doctor of the agent folder of the settings, its status
mkdir -p "${WORK}/doctor-agent"
ln -s "${REPO}/patch" "${WORK}/doctor-agent/patch"
printf '#!/bin/bash\necho "zebrunner.sh $*"\nexit 3\n' > "${WORK}/doctor-agent/zebrunner.sh"
chmod +x "${WORK}/doctor-agent/zebrunner.sh"
sed "s|^ZEBRUNNER_MCLOUD_AGENT_DIR=.*|ZEBRUNNER_MCLOUD_AGENT_DIR=${WORK}/doctor-agent|" "${WORK}/farm-devices.env" > "${WORK}/farm-doctor.env"
output="$(farm doctor doctor)"
check "doctor: its status is the one of ./zebrunner.sh doctor" "3" "$?"
check "doctor: ./zebrunner.sh doctor of the agent folder" "zebrunner.sh doctor" "$output"
rm -f "${WORK}/bin/python3"

section "help"
output="$(farm devices | tr -s ' \n' '  ')"
check_contains "help describes the devices argument" "Devices: udid or name of a whitelisted device, a group: ios, android, usb" "$output"
check_contains "help describes the exclusion" "-x, -e, --exclude <devices>" "$output"

section "the output without a terminal"
# udev, systemd and launchd run zebrunner-farm without a terminal: plain text, a line per container
setup_case
output="$(farm devices stop WiFi)"
check_not_contains "no escape sequence (colors, spinner)" $'\033' "$output"
check "the title of the device: its name as it is, its platform, connection and udid" "1" \
  "$(grep -cE '^  > WiFi  android - wireless - 192\.168\.1\.50 -{3,}$' <<< "$output")"
check "a line per container: the action first and the full name" "4" \
  "$(grep -cE '^   ok   stopped  device-WiFi-192\.168\.1\.50-(appium|uploader|stf|connector)$' <<< "$output")"
check "a single device has no summary" "" "$(grep -E 'ok, .* fail' <<< "$output")"
setup_case
output="$(farm mac-devices start iPhone_8_Plus)"
check_contains "a long container name stays on the line of its action" \
  "   FAIL NOT connected over USB (ioreg): the containers are not created." "$output"
echo '"USB Serial Number" = "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"' > "${WORK}/usb"
output="$(farm mac-devices start iPhone_8_Plus)"
check_contains "the facts of the device under its title" "    WDA      /dev/null (com.facebook.WebDriverAgentRunner.xctrunner)" "$output"
check_contains "the line of a long container name is not wrapped in a log" \
  "   ok   created  ${IPHONE}-connector  id-${IPHONE:0:9}" "$output"

section "a group of devices"
for role in devices mac-devices; do
  setup_case
  output="$(farm "$role" stop android -q)"
  check "${role}: stop of a group succeeds" "0" "$?"
  check_contains "${role}: the title of the command and the number of the devices" "[ STOP ] ---" "$output"
  check_contains "${role}: the counter of a device" "--- 2/3" "$output"
  check_contains "${role}: the summary" "3 ok, 0 warn, 0 fail" "$output"
  check_contains "${role}: the summary has the time" "3 devices - done in " "$output"
  setup_case
  output="$(DOCKER_FAIL_RUN=Emu-emu1-appium farm "$role" start WiFi Emu -q)"
  check "${role}: a failed device fails the group" "1" "$?"
  check_contains "${role}: the summary counts the failed device" "1 ok, 0 warn, 1 fail" "$output"
  check_contains "${role}: the failed devices are listed" "failed: Emu - done in " "$output"
  check_contains "${role}: the command to retry them" "retry: zebrunner-farm start Emu" "$output"
  setup_case
  DOCKER_FAIL_RUN=Emu-emu1-appium farm "$role" start Emu > /dev/null
  check "${role}: a failed device fails (the unit of udev fails)" "1" "$?"
  setup_case
  farm "$role" start Emu > /dev/null
  check "${role}: a started device succeeds" "0" "$?"
  setup_case
  output="$(DOCKER_FAIL_STOP=WiFi-192.168.1.50-stf farm "$role" stop WiFi)"
  check "${role}: a container that does not stop fails the device" "1" "$?"
  check_contains "${role}: the container that does not stop is reported" \
    "FAIL NOT stopped  device-WiFi-192.168.1.50-stf: Error response from daemon: simulated stop failure" "$output"
  check "${role}: the other containers are stopped anyway" "4" "$(calls docker | grep -c '^stop|')"
  setup_case
  output="$(DOCKER_FAIL_STOP=WiFi-192.168.1.50-stf farm "$role" down WiFi)"
  check "${role}: down of a device whose container does not stop still removes it" "0" "$?"
done
setup_case
output="$(farm devices start android -q)"
check "Linux: a USB device that is not plugged in is skipped, the group succeeds" "0" "$?"
check_contains "Linux: the skipped device is a warning of the summary" "2 ok, 1 warn, 0 fail" "$output"
setup_case
output="$(farm devices restart android -q)"
check_contains "the batch restart has the strategy in its title" "3 devices - batch" "$output"
check "the batch restart counts every device once" "1" "$(grep -c '2 ok, 1 warn, 0 fail' <<< "$output")"

section "--dry-run"
for role in devices mac-devices; do
  for command in start stop restart down; do
    setup_case
    printf '%s\n' "device-WiFi-192.168.1.50-connector running" "device-WiFi-192.168.1.50-stf exited" > "${WORK}/docker_ps"
    output="$(DOCKER_NO_NETWORK=1 farm "$role" "$command" --dry-run)"
    check "${role}: ${command} --dry-run succeeds" "0" "$?"
    check "${role}: ${command} --dry-run changes no container" "" \
      "$(calls docker | grep -E '^(run|start|stop|rm|create|kill|exec)\||^(volume|network)\|(rm|create)\|')"
    check "${role}: ${command} --dry-run reads the containers once" "1" "$(calls docker | grep -c '^ps|')"
    check "${role}: ${command} --dry-run changes no launch agent" "" "$(calls launchctl)"
    check_contains "${role}: ${command} --dry-run says so" "--dry-run: nothing was changed" "$output"
  done
  setup_case
  printf '%s\n' "device-WiFi-192.168.1.50-connector running" "device-WiFi-192.168.1.50-stf exited" > "${WORK}/docker_ps"
  output="$(DOCKER_NO_NETWORK=1 farm "$role" start WiFi --dry-run)"
  check_contains "${role}: start --dry-run keeps a running container" "info running  device-WiFi-192.168.1.50-connector" "$output"
  check_contains "${role}: start --dry-run would start a stopped one" "info would start  device-WiFi-192.168.1.50-stf" "$output"
  check_contains "${role}: start --dry-run would create a missing one" "info would create  device-WiFi-192.168.1.50-appium" "$output"
  check_contains "${role}: start --dry-run would create the network of the device" \
    "would create  device-WiFi-192.168.1.50  network of the device" "$output"
  output="$(farm "$role" stop WiFi --dry-run)"
  check_contains "${role}: stop --dry-run would stop a running container" "would stop  device-WiFi-192.168.1.50-connector" "$output"
  output="$(farm "$role" restart WiFi --dry-run)"
  check_contains "${role}: restart --dry-run would remove a container" "would remove  device-WiFi-192.168.1.50-connector" "$output"
  check_contains "${role}: restart --dry-run would create it again" "would create  device-WiFi-192.168.1.50-connector" "$output"
  output="$(farm "$role" restart android --dry-run)"
  check_not_contains "${role}: --dry-run asks nothing" "The devices to" "$output"
done
output="$(farm devices status --dry-run)"
check "--dry-run is no option of status" "1" "$?"
check_contains "--dry-run of status is reported" "--dry-run is an option of start, stop, restart, down only" "$output"

section "logs, shell and exec"
for role in devices mac-devices; do
  setup_case
  printf '%s\n' "device-WiFi-192.168.1.50-appium running" "device-WiFi-192.168.1.50-stf running" \
    "device-WiFi-192.168.1.50-connector running" > "${WORK}/docker_ps"
  farm "$role" logs WiFi > /dev/null
  check "${role}: logs of the appium of a device by its name" "logs|--tail|200|device-WiFi-192.168.1.50-appium" \
    "$(calls docker | grep '^logs|')"
  reset_calls
  farm "$role" logs 192.168.1.50 stf -f --tail 20 > /dev/null
  check "${role}: logs of a role of a device by its udid, followed" "logs|--follow|--tail|20|device-WiFi-192.168.1.50-stf" \
    "$(calls docker | grep '^logs|')"
  reset_calls
  farm "$role" logs WiFi --tail=all --follow connector > /dev/null
  check "${role}: the options of logs in any place" "logs|--follow|--tail|all|device-WiFi-192.168.1.50-connector" \
    "$(calls docker | grep '^logs|')"
  reset_calls
  farm "$role" shell WiFi < /dev/null > /dev/null
  check "${role}: shell runs bash or sh in appium" \
    "exec|-i|device-WiFi-192.168.1.50-appium|sh|-c|if command -v bash > /dev/null 2>&1; then exec bash; fi; exec sh" \
    "$(calls docker | grep '^exec|')"
  reset_calls
  farm "$role" exec WiFi connector adb -s 'a b' devices < /dev/null > /dev/null
  check "${role}: exec runs the command in the container, no terminal without one" \
    "exec|-i|device-WiFi-192.168.1.50-connector|adb|-s|a b|devices" "$(calls docker | grep '^exec|')"
  reset_calls
  output="$(farm "$role" logs WiFi foo)"
  check "${role}: an unknown role is a usage error" "2" "$?"
  check_contains "${role}: an unknown role lists the roles" "unknown role: foo; the roles: connector stf appium uploader" "$output"
  output="$(farm "$role" logs WiFi stff)"
  check_contains "${role}: a mistyped role is suggested" "unknown role: stff (did you mean: stf?)" "$output"
  output="$(farm "$role" logs android)"
  check "${role}: a group is not one device" "1" "$?"
  check_contains "${role}: a group lists its devices" "android is 3 devices: Galaxy WiFi Emu" "$output"
  output="$(farm "$role" logs WiFi uploader)"
  check "${role}: a missing container fails" "1" "$?"
  check_contains "${role}: a missing container is reported" "no container device-WiFi-192.168.1.50-uploader" "$output"
  output="$(farm "$role" logs Wifi)"
  check_contains "${role}: an unknown device is suggested" "device not found: Wifi (did you mean: WiFi?)" "$output"
  output="$(farm "$role" exec WiFi connector)"
  check "${role}: exec needs a command" "2" "$?"
  check "${role}: the usage errors change nothing" "" "$(calls docker | grep -v '^ps|')"
done

section "did you mean"
output="$(farm devices statsu)"
check "an unknown command is a usage error" "2" "$?"
check_contains "an unknown command suggests the closest one" "unknown command: statsu (did you mean: status?)" "$output"
check_contains "an unknown command shows the usage" "zebrunner-farm <command> [devices...] [options]" "$output"
check_not_contains "an unknown command prints no help" "[ OPTIONS ]" "$output"
check_contains "a prefix of a command is suggested" "(did you mean: restart?)" "$(farm devices rest)"
check_not_contains "a word far from every command suggests nothing" "did you mean" "$(farm devices xyzzy)"
farm devices > /dev/null
check "no command is the help" "0" "$?"
farm devices help > /dev/null
check "help is the help" "0" "$?"
output="$(farm devices stop Galxy)"
check_contains "an unknown device suggests the closest names" "device not found: Galxy (did you mean: Galaxy?)" "$output"
check_contains "an unknown device suggests a udid by its prefix" "(did you mean: R28M1384YQY?)" "$(farm devices stop R28)"
check_contains "an unknown device suggests a group" "(did you mean: android?)" "$(farm devices stop androd)"

section "help of a command"
for command in status start stop restart down logs shell exec doctor ansible version completion help; do
  output="$(farm devices help "$command")"
  check "help ${command} succeeds" "0" "$?"
  check_contains "help ${command} has its usage" "> zebrunner-farm ${command}" "$output"
done
check_contains "restart --help is the help of restart" "--rolling" "$(farm devices restart --help)"
check_contains "-h is --help" "--tail" "$(farm devices logs -h)"
check "--help changes nothing" "" "$(calls docker | grep -v '^ps|')"
output="$(farm devices help nope)"
check "help of an unknown command is a usage error" "2" "$?"
output="$(farm devices | tr -s ' \n' '  ')"
for command in status start stop restart down logs shell exec doctor ansible version completion help; do
  check_contains "help has ${command}" " ${command} " "$output"
done
for option in -x "-q," --quiet --batch --rolling --dry-run --json --watch -v; do
  check_contains "help has ${option}" " ${option} " "$output"
done
check_not_contains "help has no escape sequence without a terminal" $'\033' "$output"

section "status of a group"
for role in devices mac-devices; do
  setup_case
  printf '%s\n' "device-WiFi-192.168.1.50-connector running" "device-WiFi-192.168.1.50-stf exited" \
    "device-Emu-emu1-connector running" "device-Emu-emu1-stf running" "device-Emu-emu1-appium running" > "${WORK}/docker_ps"
  output="$(DOCKER_RESTARTS=2 farm "$role" status android)"
  check "${role}: status of a group succeeds" "0" "$?"
  check_contains "${role}: the header of the table" "DEVICE  PLATFORM  CONNECTION   C S A U  UPTIME    RESTARTS" "$output"
  check_contains "${role}: the letters of the states without colors" "WiFi    android   wireless     R X - -" "$output"
  check_contains "${role}: the first container that exited" "stf exited (1)" "$output"
  check_contains "${role}: the restarts and the containers with them" "6 connector,stf,appium" "$output"
  check_contains "${role}: the legend of the letters" "R running; S starting, unhealthy, restarting; X exited, dead; - no container" "$output"
  check_not_contains "${role}: no escape sequence without a terminal" $'\033' "$output"
  output="$(farm "$role" status android -v)"
  check_contains "${role}: -v shows the containers of every device" "running  healthy    " "$output"
  check_contains "${role}: -v has the full names" "device-Emu-emu1-appium" "$output"
  check_contains "${role}: an exited container fails with its fix" \
    "fix docker logs --tail 50 device-WiFi-192.168.1.50-stf, then: zebrunner-farm restart WiFi" "$output"
done
check_contains "Linux: a USB device that is not plugged in is disconnected" "Galaxy  android   usb          disconnected" \
  "$(farm devices status android)"
setup_case
printf '%s\n' "device-WiFi-192.168.1.50-connector running" > "${WORK}/docker_ps"
output="$(DOCKER_RESTARTS=3 farm devices status WiFi)"
check_contains "a container that restarted is a warning with the command of its log" \
  "warn running  healthy    " "$output"
check_contains "the restarts and the log of the container" "3 restarts: docker logs --tail 50 device-WiFi-192.168.1.50-connector" "$output"
output="$(farm devices status WiFi --watch)"
check "--watch needs a terminal" "1" "$?"
check_contains "--watch without a terminal is reported" "--watch needs a terminal" "$output"
check_contains "--watch is not with --json" "one of them" "$(farm devices status WiFi --watch --json 2>&1)"
check_contains "--watch is an option of status only" "--watch is an option of status only" "$(farm devices stop --watch)"
check_contains "-v is an option of status only" "-v is an option of status only" "$(farm devices start -v)"
setup_case
printf '%s\n' "device-Emu-emu1-connector exited" > "${WORK}/docker_ps"
check "status --json is the one of the earlier versions" \
  "$(printf '%s\n' '[' '{"id": "emu1", "name": "Emu", "os": "android", "connection": "android-sim", "location": "loc", "plugged_in": null, "containers": {"connector": {"exists": true, "status": "exited", "health": "healthy", "started_at": "", "uptime_seconds": null, "restarts": 2}, "stf": {"exists": false}, "appium": {"exists": false}, "uploader": {"exists": false}}}' ']')" \
  "$(farm_streams stdout status Emu --json)"

section "completion"
# __complete runs nothing: a docker that is called fails the check
mkdir -p "${WORK}/complete-bin"
printf '#!/bin/bash\ntouch "%s/docker-called"\nexit 1\n' "$WORK" > "${WORK}/complete-bin/docker"
chmod +x "${WORK}/complete-bin/docker"
# complete <env file> <index> <words...>: the candidates of zebrunner-farm on one line
complete() {
  local env_file="$1"
  shift
  env -i PATH="${WORK}/complete-bin:/usr/bin:/bin" HOME="$WORK" ZEBRUNNER_FARM_ENV="$env_file" \
    /bin/bash "$FARM_SCRIPT" __complete "$@" | paste -s -d ' ' -
}
ENV="${WORK}/farm-devices.env"
check "the commands" "status start stop restart down logs shell exec doctor ansible version completion help" "$(complete "$ENV" 1 "")"
devices="R28M1384YQY Galaxy 192.168.1.50 WiFi d6afc6b3a65584ca0813eb8957c6479b9b6ebb11 iPhone_8_Plus aaaa1111 AppleTV bbbb2222 iPhoneWiFi emu1 Emu B1B07E76 Sim"
groups="ios android usb wireless android-sim ios-sim proxy"
check "the devices and the groups of a command" "${devices} ${groups}" "$(complete "$ENV" 2 restart "")"
check "the devices after other devices" "${devices} ${groups}" "$(complete "$ENV" 3 restart Galaxy "")"
check "the devices after -x" "${devices} ${groups}" "$(complete "$ENV" 3 stop -x "")"
check "the options of restart" "-q --quiet --batch --rolling --strategy --dry-run --pick -x -e --exclude --help" \
  "$(complete "$ENV" 2 restart -)"
check "the options of status" "--json --watch -v --verbose --pick -x -e --exclude --help" "$(complete "$ENV" 3 status ios --)"
check "the strategies" "batch rolling" "$(complete "$ENV" 3 restart --strategy "")"
check "the devices of logs, without the groups" "$devices" "$(complete "$ENV" 2 logs "")"
check "the roles of logs" "connector stf appium uploader" "$(complete "$ENV" 3 logs WiFi "")"
check "the roles after an option" "connector stf appium uploader" "$(complete "$ENV" 5 logs --tail 20 WiFi "")"
check "nothing after --tail" "" "$(complete "$ENV" 3 logs --tail "")"
check "the options of logs" "--pick -f --follow --tail --help" "$(complete "$ENV" 3 logs WiFi -)"
check "the roles of exec" "connector stf appium uploader" "$(complete "$ENV" 3 exec WiFi "")"
check "nothing for the command of exec" "" "$(complete "$ENV" 4 exec WiFi stf "")"
check "the roles of shell" "connector stf appium uploader" "$(complete "$ENV" 3 shell Emu "")"
check "the commands of help" "status start stop restart down logs shell exec doctor ansible version completion help" \
  "$(complete "$ENV" 2 help "")"
check "the shells of completion" "bash zsh" "$(complete "$ENV" 2 completion "")"
check "nothing for version" "" "$(complete "$ENV" 2 version "")"
check "the commands without the settings" "status start stop restart down logs shell exec doctor ansible version completion help" \
  "$(complete "${WORK}/missing.env" 1 "")"
check "the options without the settings" "-q --quiet --dry-run --pick -x -e --exclude --help" "$(complete "${WORK}/missing.env" 2 start -)"
check "nothing on stderr without the settings" "" \
  "$(env -i PATH="${WORK}/complete-bin:/usr/bin:/bin" ZEBRUNNER_FARM_ENV="${WORK}/missing.env" /bin/bash "$FARM_SCRIPT" \
    __complete 2 start "" 2>&1 > /dev/null)"
check "a wrong index answers nothing" "" "$(complete "$ENV" x start)"
check "__complete calls no docker" "no" "$([[ -e "${WORK}/docker-called" ]] && echo yes || echo no)"
check "completion bash prints patch/completion.sh" "$(cat "${REPO}/patch/completion.sh")" "$(farm devices completion bash)"
check "completion zsh prints patch/completion.sh" "$(cat "${REPO}/patch/completion.sh")" "$(farm devices completion zsh)"
farm devices completion fish > /dev/null
check "completion of another shell is a usage error" "2" "$?"

section "the confirmation without fzf"
setup_case
output="$(printf 'p\nn\n' | MCLOUD_FARM_INTERACTIVE=true farm devices down android)"
check_contains "p without fzf and a terminal is explained" "p picks the devices with fzf at a terminal" "$output"
check "p without fzf changes nothing" "" "$(removed)"

section "a terminal"
# the spinner of a terminal runs docker in the background: the secrets of the containers are in its environment still
# tty_run <command...>: the command in a terminal of script(1): BSD (macOS) or util-linux
tty_run() {
  if [[ "$(uname)" == "Darwin" ]]; then
    script -q /dev/null "$@"
  else
    script -qec "$(printf '%q ' "$@")" /dev/null
  fi
}
if tty_run true > /dev/null 2>&1 < /dev/null; then
  render_farm devices "${WORK}/farm-devices.env" --extra-vars "MCLOUD_NODE_TOKEN=tty-token" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-devices.env"
  setup_case
  output="$(tty_run env -i HOME="$WORK" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm-256color \
    STUB_DIR="$WORK" MCLOUD_LOCK_DIR="$WORK" ZEBRUNNER_FARM_ENV="${WORK}/farm-devices.env" /bin/bash "$FARM_SCRIPT" \
    start WiFi < /dev/null 2>&1)"
  check_contains "a terminal has colors" $'\033[' "$output"
  check_contains "a terminal has the line of a created container" "created  device-WiFi-192.168.1.50-appium" "$output"
  check_contains "the secrets reach docker from the background" "|NODE_REGISTRATION_TOKEN=tty-token|" \
    "$(run_env device-WiFi-192.168.1.50-appium)"
  check_not_contains "the secrets are no argument of docker" "tty-token" "$(cat "${WORK}/calls.log")"
  setup_case
  printf '%s\n' "device-WiFi-192.168.1.50-connector running" > "${WORK}/docker_ps"
  # the code runs in the bash of the terminal: $1 and $2 are its arguments
  # shellcheck disable=SC2016
  tty_run env -i HOME="$WORK" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm-256color STUB_DIR="$WORK" \
    MCLOUD_LOCK_DIR="$WORK" ZEBRUNNER_FARM_ENV="${WORK}/farm-devices.env" /bin/bash -c \
    '/bin/bash "$1" exec WiFi connector adb devices > "$2"' _ "$FARM_SCRIPT" "${WORK}/exec.out" < /dev/null > /dev/null 2>&1
  check "exec with its output in a file: no pseudo-terminal, the stdin passed" \
    "exec|-i|device-WiFi-192.168.1.50-connector|adb|devices" "$(calls docker | grep '^exec|')"
  render_farm devices "${WORK}/farm-devices.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-devices.env"
else
  skip_check "a terminal" "no script(1)"
fi

section "--pick"
# fzf: the lines of the devices named by FZF_PICK (commas), Esc (130) for FZF_PICK=cancel; its arguments are logged;
# the body is the script of the stub, its variables expand there
# shellcheck disable=SC2016
stub fzf '
printf "%s\n" "$*" > "${STUB_DIR}/fzf.args"
input="$(cat)"
[[ "${FZF_PICK:-}" != "cancel" ]] || exit 130
while IFS= read -r line; do
  name="$(cut -f 2 <<< "$line")"
  [[ ",${FZF_PICK}," != *",${name},"* ]] || printf "%s\n" "$line"
done <<< "$input"'
for role in devices mac-devices; do
  setup_case
  output="$(farm "$role" start --pick < /dev/null)"
  check "${role}: --pick without a terminal fails" "1" "$?"
  check_contains "${role}: --pick without a terminal is explained" "--pick needs fzf at a terminal" "$output"
  check "${role}: --pick without a terminal runs for no device" "" "$(calls docker | grep -E '^(run|start|stop|rm)\|')"
  output="$(farm "$role" stop --pick --quiet < /dev/null)"
  check "${role}: --pick with --quiet fails" "1" "$?"
  check_contains "${role}: --pick with --quiet is explained" "--quiet asks nobody: one of them" "$output"
  output="$(farm "$role" status --pick --json < /dev/null 2>&1)"
  check_contains "${role}: --pick with --json is explained" "--json is for the monitoring: one of them" "$output"
  output="$(farm "$role" logs < /dev/null)"
  check "${role}: logs without a device and a terminal is a usage error" "2" "$?"
  check_contains "${role}: logs without a device asks for one" "logs needs a device: its name or udid" "$output"
  output="$(farm "$role" exec --pick connector adb devices < /dev/null)"
  check "${role}: exec --pick without a terminal fails" "1" "$?"
  check "${role}: exec --pick without a terminal runs nothing" "" "$(calls docker | grep '^exec|')"
  check_contains "${role}: the completion of --pick" "--pick" "$(farm "$role" __complete 2 start --p)"
  check "${role}: the roles after logs --pick" "connector stf appium uploader" \
    "$(farm "$role" __complete 3 logs --pick "" | paste -s -d ' ' -)"
done
# tty_farm <role> <stdin text> <arguments...>: zebrunner-farm in a terminal of script(1) with the answers of stdin
tty_farm() {
  local role="$1"
  local input="$2"
  shift 2
  printf '%b' "$input" | tty_run env -i HOME="$WORK" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm-256color \
    STUB_DIR="$WORK" MCLOUD_LOCK_DIR="$WORK" FZF_PICK="${FZF_PICK:-}" ZEBRUNNER_FARM_ENV="${WORK}/farm-${role}.env" \
    /bin/bash "$FARM_SCRIPT" "$@" 2>&1
}
if tty_run true > /dev/null 2>&1 < /dev/null; then
  setup_case
  # script(1) passes no answer: the question ends with the end of the input, nothing runs
  output="$(FZF_PICK=WiFi tty_farm devices '' start --pick)"
  check_contains "start --pick asks for the picked device" "Run 'start' for 1 devices?" "$output"
  check "start --pick without an answer runs nothing" "" "$(calls docker | grep '^run|')"
  check_contains "fzf picks several devices" "--multi" "$(cat "${WORK}/fzf.args")"
  setup_case
  output="$(FZF_PICK=WiFi tty_farm devices '' start --pick --dry-run)"
  check_contains "start --pick is for the picked device" "would create  device-WiFi-192.168.1.50-connector" "$output"
  check_not_contains "start --pick is for no other device" "device-Galaxy" "$output"
  setup_case
  output="$(FZF_PICK=cancel tty_farm devices '' down --pick)"
  check_contains "Esc of --pick cancels" "Cancelled." "$output"
  check "Esc of --pick removes nothing" "" "$(removed)"
  setup_case
  output="$(FZF_PICK=WiFi tty_farm devices '' status --pick)"
  check_contains "status --pick shows the picked device" "WiFi" "$output"
  check_not_contains "status --pick shows no other device" "Galaxy" "$output"
  setup_case
  printf '%s\n' "device-WiFi-192.168.1.50-appium running" "device-WiFi-192.168.1.50-stf running" \
    "device-WiFi-192.168.1.50-connector running" > "${WORK}/docker_ps"
  FZF_PICK=WiFi tty_farm devices '' logs > /dev/null
  check "logs without a device: the appium of the picked device" "logs|--tail|200|device-WiFi-192.168.1.50-appium" \
    "$(calls docker | grep '^logs|')"
  check_not_contains "logs picks one device" "--multi" "$(cat "${WORK}/fzf.args")"
  reset_calls
  FZF_PICK=WiFi tty_farm devices '' logs stf --pick > /dev/null
  check "logs <role> --pick: the role of the picked device" "logs|--tail|200|device-WiFi-192.168.1.50-stf" \
    "$(calls docker | grep '^logs|')"
  reset_calls
  FZF_PICK=WiFi tty_farm devices '' exec --pick connector adb devices > /dev/null
  check "exec --pick: the command in the picked device" "exec|-it|device-WiFi-192.168.1.50-connector|adb|devices" \
    "$(calls docker | grep '^exec|')"
  reset_calls
  FZF_PICK=cancel tty_farm devices '' shell > /dev/null
  check "Esc of the pick of shell runs nothing" "" "$(calls docker | grep '^exec|')"
  # macOS: some devices of the group picked or kept by a person: the devices listener stays for the other iOS devices
  setup_case
  check_not_contains "stop --pick without the USB iOS device keeps the devices listener" "would unload the devices listener" \
    "$(FZF_PICK=AppleTV tty_farm mac-devices '' stop ios --pick --dry-run)"
  check_contains "stop --pick with every USB iOS device unloads the devices listener" "would unload the devices listener" \
    "$(FZF_PICK=iPhone_8_Plus,AppleTV tty_farm mac-devices '' stop ios --pick --dry-run)"
  check_contains "stop of the iOS devices unloads the devices listener" "would unload the devices listener" \
    "$(tty_farm mac-devices '' stop ios --dry-run)"
else
  skip_check "--pick at a terminal" "no script(1)"
fi
rm -f "${WORK}/bin/fzf"
# f and x of the question narrow the group as --pick does: the listener stays (the functions, no answer of script(1));
# the code runs in the child bash: $1 is its argument
# shellcheck disable=SC2016
listener="$(env -i HOME="$WORK" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
  MCLOUD_LOCK_DIR="$WORK" ZEBRUNNER_FARM_ENV="${WORK}/farm-mac-devices.env" /bin/bash -c '
    source "$1"
    try() {
      parse_selection "$1"
      select_devices > /dev/null
      [[ -z "$2" ]] || refine_selection "$2" "$3"
      listener_applies && echo "$1 $2 $3: applies" || echo "$1 $2 $3: no"
    }
    try ios
    try ios keep iPhone_8_Plus
    try ios drop iPhone_8_Plus
    try "" drop Galaxy
    try "" keep WiFi
  ' _ "$FARM_SCRIPT" 2>&1)"
check "the listener: the group, a narrowed group without the USB iOS device only" "ios  : applies
ios keep iPhone_8_Plus: applies
ios drop iPhone_8_Plus: no
 drop Galaxy: applies
 keep WiFi: no" "$listener"

section "Ctrl-C"
# a device ended by Ctrl-C (130: the trap of docker_spin in the subshell of the lock) ends the whole run; the code runs
# in the child bash: $1 is its argument
# shellcheck disable=SC2016
output="$(env -i HOME="$WORK" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
  MCLOUD_LOCK_DIR="$WORK" ZEBRUNNER_FARM_ENV="${WORK}/farm-devices.env" /bin/bash -c '
    source "$1"
    with_device_lock() { echo "device $1"; return 130; }
    SELECTED=(R28M1384YQY 192.168.1.50)
    run_selected stop
    echo "the run went on"
  ' _ "$FARM_SCRIPT" 2>&1)"
status=$?
check "Ctrl-C of a device ends the run with 130" "130" "$status"
check_contains "the first device ran" "device R28M1384YQY" "$output"
check_not_contains "no other device after Ctrl-C" "device 192.168.1.50" "$output"
check_not_contains "nothing after the run" "the run went on" "$output"

section "the lock file of a device"
if command -v flock > /dev/null 2>&1; then
  lock="${WORK}/mcloud-device-192.168.1.50.lock"
  rm -f "$lock"
  setup_case
  farm devices stop WiFi > /dev/null
  check "the lock file is readable by the users of docker, writable by its owner only" "644" \
    "$(stat -c '%a' "$lock" 2> /dev/null || stat -f '%Lp' "$lock")"
  rm -f "$lock"
  # a symlink planted in the world-writable lock directory
  ln -s "${WORK}/planted" "$lock"
  setup_case
  farm devices stop WiFi > /dev/null
  check "the lock creates no file through a symlink" "no" "$([[ -e "${WORK}/planted" ]] && echo yes || echo no)"
  check_contains "the device runs its command without its lock file" "device-WiFi-192.168.1.50-appium" "$(calls docker | grep '^stop|')"
  rm -f "$lock"
else
  skip_check "the lock file of a device" "no flock (util-linux)"
fi

finish
