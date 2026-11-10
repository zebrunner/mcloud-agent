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
  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

# farm <devices|mac-devices> <arguments...>: runs zebrunner-farm without the user's environment
farm() {
  local role="$1"
  shift
  env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    DOCKER_FAIL_RUN="${DOCKER_FAIL_RUN:-}" DOCKER_STARTED_AT="${DOCKER_STARTED_AT:-}" DOCKER_FINISHED_AT="${DOCKER_FINISHED_AT:-}" \
    MCLOUD_LOCK_DIR="$WORK" MCLOUD_LOCK_TIMEOUT="${MCLOUD_LOCK_TIMEOUT:-}" MCLOUD_FARM_INTERACTIVE="${MCLOUD_FARM_INTERACTIVE:-}" \
    ZEBRUNNER_FARM_ENV="${WORK}/farm-${role}.env" /bin/bash "$FARM_SCRIPT" "$@" 2>&1
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
check "Android emulator gets the containers of a device, the farm does not create it" "connector stf appium uploader" \
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
    check_contains "${role}: ${device%%:*}: the CURVE keys are passed" \
      "|STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${server_key}|-e|STF_ZMQ_CURVE_SECRET_KEY=${secret_key}|" "$stf"
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
check_contains "failed container creation is reported with the error of docker" "NOT created: docker: simulated failure" "$output"
check "the containers after a failed one are not created" "connector stf appium" \
  "$(calls docker | grep '^run|' | grep -o -- "--name|${IPHONE}-[a-z]*" | sed 's/.*-//' | paste -s -d ' ' -)"

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
check "proxied device stop includes the connector" "connector appium stf uploader" \
  "$(calls docker | grep '^stop|' | sed 's/.*-//' | paste -s -d ' ' -)"
setup_case
farm mac-devices stop iPhone_8_Plus > /dev/null
check "USB device stop includes the connector" "connector appium stf uploader" \
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
check "Android emulator of macOS gets the containers of a device" "connector stf appium uploader" \
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
  check_contains "${role}: android appium registers with the token of the host" "|NODE_REGISTRATION_TOKEN=${node_token}|" \
    "$(run_args device-WiFi-192.168.1.50-appium)"
  farm "$role" start AppleTV > /dev/null
  check_contains "${role}: iOS appium registers with the token of the host" "|NODE_REGISTRATION_TOKEN=${node_token}|" \
    "$(run_args device-AppleTV-aaaa1111-appium)"
  for device in device-WiFi-192.168.1.50 device-AppleTV-aaaa1111; do
    stf="$(run_args "${device}-stf")"
    check_contains "${role}: ${device}: STF proves the devices and uses the storage with the token of the host" "|STF_NODE_TOKEN=${node_token}|" "$stf"
    check_not_contains "${role}: ${device}: no shared storage token" "STF_STORAGE_TOKEN" "$stf"
  done

  render_farm "$role" "${WORK}/farm-${role}.env" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" "${WORK}/farm-${role}.env"
done

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
  check_contains "${role}: a running container is kept" "connector  running" "$output"
  check_contains "${role}: a stopped container is started" "stf        started" "$output"
  check_contains "${role}: a missing container is created" "appium     created" "$output"
  check "${role}: only the stopped container is started" "start|device-WiFi-192.168.1.50-stf" "$(calls docker | grep '^start|')"
  check "${role}: only the missing containers are created" "appium uploader" \
    "$(calls docker | grep '^run|' | grep -o -- '--name|device-WiFi-192.168.1.50-[a-z]*' | sed 's/.*-//' | paste -s -d ' ' -)"
  setup_case
  output="$(farm "$role" down WiFi)"
  # the docker stub removes no container
  check_contains "${role}: down reports every container" "uploader   no container" "$output"
  check_contains "${role}: down reports the volume of the logs" "logs       volume removed" "$output"
  output="$(farm "$role" stop WiFi)"
  check_contains "${role}: stop reports every container" "appium     stopped" "$output"
  check_contains "${role}: the device is the header of its lines" "==> WiFi (192.168.1.50, android, wireless)" "$output"
done

section "status"
setup_case
check_contains "Linux: wireless device shows its containers" "| Connector" "$(farm devices status WiFi)"
check_contains "Linux: USB device without symlink is disconnected" "DISCONNECTED" "$(farm devices status Galaxy)"
check_contains "macOS: wireless device shows its containers" "| Connector" "$(farm mac-devices status AppleTV)"
check_contains "macOS: not connected USB device is disconnected" "DISCONNECTED" "$(farm mac-devices status iPhone_8_Plus)"

section "device lock"
if command -v flock > /dev/null 2>&1; then
  lock="${WORK}/mcloud-device-R28M1384YQY.lock"
  : > "$lock"
  # another zebrunner-farm (e.g. the restart of udev) keeps the device
  flock "$lock" sleep 4 &
  holder=$!
  sleep 0.5
  setup_case
  output="$(MCLOUD_LOCK_TIMEOUT=1 farm devices restart Galaxy)"
  check_contains "a command of a kept device (called by its name, locked by its id) waits, then gives up" \
    "another zebrunner-farm keeps the device Galaxy for too long" "$output"
  check "a command of a kept device changes no container" "" "$(calls docker)"
  setup_case
  farm devices stop android > /dev/null
  check_contains "the commands of a platform do not wait for a device" "stop|device-Galaxy-R28M1384YQY-appium" "$(calls docker)"
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
output="$(farm devices)"
check_contains "help describes the devices argument" "Devices: udid or name of a whitelisted device, a group: ios, android, usb" "$output"
check_contains "help describes the exclusion" "-x, -e, --exclude <devices>" "$output"

finish
