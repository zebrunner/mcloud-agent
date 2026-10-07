#!/bin/bash
# usbmuxd_watch binary: universal macOS 13.0+ build, and its output for the device events of a fake usbmuxd
source "$(dirname "$0")/lib.sh"
require_os Darwin
require_cmd python3

BINARY="${REPO}/roles/mac-devices/files/usbmuxd_watch"

section "binary"
check "universal binary" "x86_64 arm64" "$(lipo -archs "$BINARY")"
for arch in arm64 x86_64; do
  check "${arch} slice runs on macOS 13.0+" "13.0" "$(otool -arch "$arch" -l "$BINARY" | grep -A4 LC_BUILD_VERSION | awk '/minos/ {print $2}')"
  check "${arch} slice depends on libSystem only" "/usr/lib/libSystem.B.dylib" "$(otool -arch "$arch" -L "$BINARY" | tail -n +2 | awk '{print $1}' | paste -s -d ' ' -)"
done

# watch <scenario>: usbmuxd_watch output for the events of a fake usbmuxd scenario
watch() {
  rm -f "${WORK}/port"
  python3 "${REPO}/tests/fake_usbmuxd.py" "$1" "${WORK}/port" &
  local server=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "${WORK}/port" ]] && break
    sleep 0.5
  done
  USBMUXD_SOCKET_ADDRESS="127.0.0.1:$(cat "${WORK}/port")" "$BINARY" > "${WORK}/watch.out" 2>&1 &
  local watcher=$!
  sleep 3
  kill "$watcher" "$server" 2> /dev/null
  wait "$watcher" "$server" 2> /dev/null
  cat "${WORK}/watch.out"
}

section "events"
check "USB devices are reported, a 24 chars udid with a dash" "ATTACH udid=00008030-001A35E83C38802E handle=5
ATTACH udid=d6afc6b3a65584ca0813eb8957c6479b9b6ebb11 handle=7
PAIRED udid=d6afc6b3a65584ca0813eb8957c6479b9b6ebb11
DETACH udid=00008030-001A35E83C38802E handle=5
DETACH udid=d6afc6b3a65584ca0813eb8957c6479b9b6ebb11 handle=7" "$(watch usb)"
check "devices over the network are skipped, also the Wi-Fi side of a USB device" "ATTACH udid=00008030-001A35E83C38802E handle=5
PAIRED udid=00008030-001A35E83C38802E
DETACH udid=00008030-001A35E83C38802E handle=5" "$(watch mixed)"

finish
