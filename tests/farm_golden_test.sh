#!/bin/bash
# zebrunner-farm of both OS against the golden files tests/golden/farm-<os>.txt: the docker and launchctl calls and the
# output of the commands for every kind of device, so a change of the containers is a visible change of these files.
# After an intended change regenerate them and review the diff: UPDATE_GOLDEN=1 tests/farm_golden_test.sh
source "$(dirname "$0")/lib.sh"
require_cmd ansible

# the devices list of the deploy: the fields key=value separated by '|'
cat > "${WORK}/devices.txt" << 'EOF'
id=R28M1384YQY|os=android|name=Galaxy|location=loc|appium_port=7421|adb_port=7422|min_port=7425|max_port=7430|connection=usb|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=
id=192.168.1.50|os=android|name=WiFi|location=loc|appium_port=7431|adb_port=7432|min_port=7435|max_port=7440|connection=wireless|wda_file=/dev/null|wda_bundleid=x|address=|wda_port=|mjpeg_port=|connect_port=7499
id=d6afc6b3a65584ca0813eb8957c6479b9b6ebb11|os=ios|name=iPhone_8_Plus|location=loc|appium_port=7441|adb_port=7442|min_port=7445|max_port=7450|connection=usb|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=|wda_port=|mjpeg_port=|connect_port=
id=aaaa1111|os=ios|name=AppleTV|location=loc|appium_port=7451|adb_port=7452|min_port=7455|max_port=7460|connection=proxy|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=10.0.0.5|wda_port=8100|mjpeg_port=|connect_port=
id=bbbb2222|os=ios|name=iPhoneWiFi|location=loc|appium_port=7461|adb_port=7462|min_port=7465|max_port=7470|connection=wireless|wda_file=/dev/null|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=192.168.1.60|wda_port=|mjpeg_port=|connect_port=
id=emu1|os=android|name=Emu|location=loc|appium_port=7471|adb_port=7472|min_port=7475|max_port=7480|connection=android-sim|wda_file=/dev/null|wda_bundleid=x|address=host.docker.internal:5557|wda_port=|mjpeg_port=|connect_port=
id=B1B07E76|os=ios|name=Sim|location=loc|appium_port=7481|adb_port=7482|min_port=7485|max_port=7490|connection=ios-sim|wda_file=/tmp/wda-sim.zip|wda_bundleid=com.facebook.WebDriverAgentRunner.xctrunner|address=|wda_port=8110|mjpeg_port=|connect_port=
EOF

# the calls of docker and launchctl go to ${WORK}/calls.log; docker ps lists no container
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == run ]] && echo "id"
exit 0'
record_stub launchctl
# all the devices are plugged in: lsusb (Linux) and ioreg (macOS) list them
stub lsusb "cut -d'|' -f1 '${WORK}/devices.txt' | cut -d= -f2"
stub ioreg "cut -d'|' -f1 '${WORK}/devices.txt' | cut -d= -f2"
# the USB bus of the udev symlink: readlink -f of a missing file differs on Linux and macOS
stub readlink 'echo /dev/bus/usb/001/002'

# a secret with '$' is passed as it is
# shellcheck disable=SC2016
settings='{"MCLOUD_NODE_TOKEN": "token", "STF_PROVIDER_HOST": "10.1.1.1", "PUBLIC_IP": "mcloud.example.com",
  "PUBLIC_IP_PORT": "443", "PUBLIC_IP_PROTOCOL": "https", "STF_PROVIDER_CONNECT_SUB": "tcp://10.1.1.2:7250",
  "STF_PROVIDER_CONNECT_PUSH": "tcp://10.1.1.2:7270", "STF_PROVIDER_CONNECT_APP_DEALER": "tcp://10.1.1.2:7160",
  "STF_PROVIDER_CONNECT_DEV_DEALER": "tcp://10.1.1.2:7260", "SELENIUM_HUB_HOST": "10.1.1.2", "SELENIUM_HUB_PORT": "4446",
  "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY": "server-key", "STF_ZMQ_CURVE_SECRET_KEY": "secret-key", "S3_BUCKET": "bucket",
  "S3_TENANT": "tenant", "S3_SECRET": "s3 $ecret", "WDA_FILE": "/opt/wda.ipa", "REMOTE_CONNECT_HOST": "relay.example.com"}'

# golden <devices|mac-devices>: the calls and the output of the commands; the paths of the test replaced, without the
# colors and the indent of the status table (column -t of util-linux keeps its empty first column, the one of macOS not)
golden() {
  local role="$1"
  local args
  render_farm "$role" "${WORK}/farm.env" --extra-vars "$settings" || return 1
  # the user of the deploy is the one of the test
  sed -i.bak -e "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" -e "s|^HOST_SSH_USER=.*|HOST_SSH_USER=tester|" "${WORK}/farm.env"
  for args in "start R28M1384YQY" "start WiFi" "start iPhone_8_Plus" "start AppleTV" "start iPhoneWiFi" "start Emu" \
    "start Sim" "start" "stop" "restart android" "down ios" "status"; do
    reset_calls
    echo "### zebrunner-farm ${args}"
    # the arguments are words
    # shellcheck disable=SC2086
    env -i HOME="$WORK" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" MCLOUD_LOCK_DIR="$WORK" \
      ZEBRUNNER_FARM_ENV="${WORK}/farm.env" /bin/bash "$FARM_SCRIPT" $args < /dev/null 2>&1
    echo "### calls"
    cat "${WORK}/calls.log" 2> /dev/null
  done | sed -e "s|${WORK}|<work>|g" -e "s|${REPO}|<agent>|g" -e $'s/\033\\[[0-9;]*m//g' -e 's/^ *|/|/'
}

for role in devices mac-devices; do
  os=linux
  [[ "$role" == "mac-devices" ]] && os=macos
  file="${REPO}/tests/golden/farm-${os}.txt"
  section "golden calls of ${os}"
  actual="$(golden "$role")" || exit 1
  if [[ -n "${UPDATE_GOLDEN:-}" ]]; then
    printf '%s\n' "$actual" > "$file"
    skip_check "${os}: the calls" "written to tests/golden/farm-${os}.txt"
    continue
  fi
  if [[ "$actual" == "$(cat "$file" 2> /dev/null)" ]]; then
    pass "${os}: the calls are the golden ones"
  else
    fail "${os}: the calls are not the golden ones" "regenerate with UPDATE_GOLDEN=1 after an intended change" \
      "$(diff <(cat "$file" 2> /dev/null) <(printf '%s\n' "$actual") | head -n 40)"
  fi
done

finish
