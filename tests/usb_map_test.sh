#!/bin/bash
# Tests of patch/usb_map.py (zebrunner-farm doctor usb-map, README.md#usb-map): sysfs, the kernel log and the devices
# list are fixtures of the test, no USB device is needed.
source "$(dirname "$0")/lib.sh"
require_cmd python3

MAP="${REPO}/patch/usb_map.py"
export USB_MAP_SYSFS="${WORK}/sysfs"
export USB_STATS_KERNEL_LOG="${WORK}/kernel.log"
SYSFS="$USB_MAP_SYSFS"
mkdir -p "$SYSFS"
# the name of the controller of the address
stub lspci 'echo "7f:1f.7 USB controller: Test xHCI Host Controller (rev 01)"'
export PATH="${WORK}/bin:${PATH}"
cat > "${WORK}/devices.txt" << 'EOF'
# the devices list of the deploy
id=R58M1234|os=android|name=Galaxy|location=rack_1|connection=usb
id=PIXEL7|os=android|name=Pixel_7|location=|connection=usb
id=00008110-000A1B2C3D4E0001|os=ios|name=iPhone_15|location=rack_2|connection=usb
id=TAB123|os=android|name=Galaxy_Tab|location=|connection=usb
id=MOTO1|os=android|name=Moto|location=|connection=usb
id=VIA1|os=android|name=Pixel_8|location=|connection=usb
id=R5CW722TWGY|os=android|name=Samsung_S22|location=S3_B2|connection=usb
id=192.168.1.50|os=android|name=WiFi|location=|connection=wireless
id=00008110-000A1B2C3D4E0009|os=ios|name=AppleTV|location=|connection=proxy
EOF

# dev <name> <vendor:product> <hub|-> <ports> <speed> <product> [serial] [removable]: a USB device of sysfs
dev() {
  local dir="${SYSFS}/$1"
  mkdir -p "$dir"
  echo "${2%%:*}" > "${dir}/idVendor"
  echo "${2##*:}" > "${dir}/idProduct"
  if [[ "$3" == "hub" ]]; then
    echo 09 > "${dir}/bDeviceClass"
    echo "$4" > "${dir}/maxchild"
  else
    echo 00 > "${dir}/bDeviceClass"
  fi
  echo "$5" > "${dir}/speed"
  echo "$6" > "${dir}/product"
  [[ -z "${7:-}" ]] || echo "$7" > "${dir}/serial"
  echo "${8:-unknown}" > "${dir}/removable"
}

# port_dir <hub> <port>: the folder of the port of the hub in sysfs
port_dir() {
  local interface="${1}:1.0"
  [[ "$1" != usb* ]] || interface="${1#usb}-0:1.0"
  echo "${SYSFS}/${1}/${interface}/${1}-port${2}"
}

# peers <hub> <hub of the other half> <ports>: the ports 1..<ports> of the hubs are the halves of each other
peers() {
  local port
  for port in $(seq 1 "$3"); do
    mkdir -p "$(port_dir "$1" "$port")" "$(port_dir "$2" "$port")"
    ln -s "$(port_dir "$2" "$port")" "$(port_dir "$1" "$port")/peer"
    ln -s "$(port_dir "$1" "$port")" "$(port_dir "$2" "$port")/peer"
  done
}

# the root hubs of the Intel controller (USB2, USB3) and of a PCIe card
dev usb1 1d6b:0002 hub 14 480 "xHCI Host Controller" 0000:7f:1f.7
dev usb2 1d6b:0003 hub 10 10000 "xHCI Host Controller" 0000:7f:1f.7
peers usb1 usb2 10
dev usb3 1d6b:0002 hub 4 480 "xHCI Host Controller" 0000:02:00.0
dev usb4 1d6b:0003 hub 4 5000 "xHCI Host Controller" 0000:02:00.0
peers usb3 usb4 4
# a 10-port hub of 3 chips on root port 6: 43f2:1211 -> 43f2:1211 -> 0bda:5411 on the last ports, with its USB3 half
dev 1-6 43f2:1211 hub 4 480 "USB2.1 Hub"
dev 1-6.4 43f2:1211 hub 4 480 "USB2.1 Hub"
dev 1-6.4.4 0bda:5411 hub 4 480 "4-Port USB 2.1 Hub"
dev 2-6 43f2:0211 hub 4 5000 "USB3.2 Hub"
dev 2-6.4 43f2:0211 hub 4 5000 "USB3.2 Hub"
dev 2-6.4.4 0bda:0411 hub 4 5000 "4-Port USB 3.2 Hub"
peers 1-6 2-6 4
peers 1-6.4 2-6.4 4
peers 1-6.4.4 2-6.4.4 4
dev 1-6.1 04e8:6860 - 0 480 SAMSUNG_Android R58M1234
# a USB3 device: on the USB3 half of its port
dev 2-6.4.2 18d1:4ee7 - 0 5000 "Pixel 7" PIXEL7
dev 1-6.4.4.1 046d:c31c - 0 1.5 "USB Keyboard"
# the kernel gives the UDID of an iPhone without its dash
dev 1-6.4.4.3 05ac:12a8 - 0 480 iPhone 00008110000A1B2C3D4E0001
# a USB2 hub on the last port of a chip with a USB3 half: plugged in, not a chip of the hub
dev 1-6.4.4.4 1a40:0101 hub 4 480 "USB 2.0 Hub"
# a plain 4-port USB2 hub
dev 1-9 05e3:0608 hub 4 480 "USB2.0 Hub" "" removable
# a hub behind a hub: on port 2 of a 4-port hub, not on its last ports
dev 1-11 05e3:0608 hub 4 480 "USB2.0 Hub" "" removable
dev 1-11.2 1a40:0101 hub 4 480 "USB 2.0 Hub"
dev 1-11.2.3 04e8:6860 - 0 480 SAMSUNG_Android TAB123
# a hub of the board
dev 1-13 05e3:0608 hub 4 480 "USB2.0 Hub" "" fixed
# the host ports
dev 1-2 0b05:19af - 0 12 "AURA LED Controller" 9876543210 fixed
dev 1-3 22b8:2e81 - 0 480 moto MOTO1 removable
# a 10-port hub of 3 chips on the PCIe card: two chips on the last two ports of the first one
dev 3-2 2109:2813 hub 4 480 "USB2.0 Hub"
dev 3-2.3 2109:2813 hub 4 480 "USB2.0 Hub"
dev 3-2.4 2109:2813 hub 4 480 "USB2.0 Hub"
dev 4-2 2109:0813 hub 4 5000 "USB3.0 Hub"
dev 4-2.3 2109:0813 hub 4 5000 "USB3.0 Hub"
dev 4-2.4 2109:0813 hub 4 5000 "USB3.0 Hub"
peers 3-2 4-2 4
peers 3-2.3 4-2.3 4
peers 3-2.4 4-2.4 4
dev 3-2.4.1 18d1:4ee7 - 0 480 "Pixel 8" VIA1
# an interface of a device is not a device
mkdir -p "${SYSFS}/1-6.1:1.0"

# the kernel log: Samsung_S22 was on 1-9.3 until its last disconnect, Galaxy flapped on 1-6.1, Pixel_7 on its USB3 port
today="$(date +%F)"
cat > "$USB_STATS_KERNEL_LOG" << EOF
${today}T04:00:00+0100 host kernel: usb 1-9.3: new high-speed USB device number 7 using xhci_hcd
${today}T04:00:01+0100 host kernel: usb 1-9.3: SerialNumber: R5CW722TWGY
${today}T05:03:19+0100 host kernel: usb 1-9.3: USB disconnect, device number 7
${today}T06:00:00+0100 host kernel: usb 1-6.1: SerialNumber: R58M1234
${today}T06:01:00+0100 host kernel: usb 1-6.1: USB disconnect, device number 8
${today}T06:01:01+0100 host kernel: usb 1-6.1: SerialNumber: R58M1234
${today}T06:02:00+0100 host kernel: usb 1-6.1: USB disconnect, device number 9
${today}T06:02:01+0100 host kernel: usb 1-6.1: SerialNumber: R58M1234
${today}T06:03:00+0100 host kernel: usb 1-6.1: USB disconnect, device number 10
${today}T06:03:01+0100 host kernel: usb 1-6.1: SerialNumber: R58M1234
${today}T07:00:00+0100 host kernel: usb 2-6.4.2: SerialNumber: PIXEL7
${today}T07:01:00+0100 host kernel: usb 2-6.4.2: USB disconnect, device number 11
${today}T07:01:01+0100 host kernel: usb 2-6.4.2: SerialNumber: PIXEL7
EOF

# map <arguments...>: the map, its status in $STATUS
map() {
  OUT="$(python3 "$MAP" --devices "${WORK}/devices.txt" "$@" 2>&1)"
  STATUS=$?
}

# json <python expression of r>: a value of the JSON map of $OUT
json() {
  python3 -c "import json, sys; r = json.loads(sys.stdin.read()); print($1)" <<< "$OUT"
}

section "the hubs"
map --json
check "a farm device not on USB: status 1" "1" "$STATUS"
check "every hub from the root ports down, by path" "1-6 1-6.4.4.4 1-9 1-11 1-11.2 1-13 3-2" \
  "$(json '" ".join(h["path"] for h in r["hubs"])')"
check "a 3-chip 10-port hub is one hub with ports 1-10" \
  "1-6.1 1-6.2 1-6.3 1-6.4.1 2-6.4.2 1-6.4.3 1-6.4.4.1 1-6.4.4.2 1-6.4.4.3 1-6.4.4.4" \
  "$(json '" ".join(s["path"] for s in r["hubs"][0]["slots"])')"
check "its port numbers" "1 2 3 4 5 6 7 8 9 10" "$(json '" ".join(str(s["port"]) for s in r["hubs"][0]["slots"])')"
check "its chips" "43f2:1211 43f2:1211 0bda:5411" "$(json '" ".join(r["hubs"][0]["chips"])')"
check "its USB3 half is merged" "2-6" "$(json 'r["hubs"][0]["usb3"]')"
check "the USB3 halves are no hubs of their own" "0" "$(json 'sum(h["path"].startswith(("2-", "4-")) for h in r["hubs"])')"
check "the states of its ports" "farm empty empty empty farm empty unknown empty farm hub" \
  "$(json '" ".join(s["state"] for s in r["hubs"][0]["slots"])')"
check "a farm device by its serial" "Galaxy rack_1 R58M1234" \
  "$(json '" ".join(str(r["hubs"][0]["slots"][0]["device"][k]) for k in ("name", "location", "id"))')"
check "a USB3 device on the port of the hub, its path and speed" "Pixel_7 2-6.4.2 5G" \
  "$(json '" ".join((r["hubs"][0]["slots"][4]["device"]["name"], r["hubs"][0]["slots"][4]["path"], r["hubs"][0]["slots"][4]["speed"]))')"
check "an iPhone by its UDID without the dash" "00008110-000A1B2C3D4E0001" "$(json 'r["hubs"][0]["slots"][8]["device"]["id"]')"
check "an unknown device" "USB Keyboard 046d:c31c 1.5M" \
  "$(json '" ".join((r["hubs"][0]["slots"][6]["product"], r["hubs"][0]["slots"][6]["usb_id"], r["hubs"][0]["slots"][6]["speed"]))')"
check "the controller of the hub" "0000:7f:1f.7 Test xHCI Host Controller (rev 01)" \
  "$(json 'r["hubs"][0]["controller"]["pci"] + " " + r["hubs"][0]["controller"]["name"]')"
check "a USB2 hub on the last port of a USB3 hub is plugged in, not a chip" "1-6 10 4 1a40:0101" \
  "$(json '" ".join((r["hubs"][1]["on"]["hub"], str(r["hubs"][1]["on"]["port"]), str(r["hubs"][1]["ports"]), r["hubs"][1]["chips"][0]))')"
check "a plain 4-port hub" "1-9.1 1-9.2 1-9.3 1-9.4 None" \
  "$(json '" ".join(s["path"] for s in r["hubs"][2]["slots"]) + " " + str(r["hubs"][2]["usb3"])')"
check "a hub behind a hub (not on the last ports) is a hub of its own" "hub 1-11 2 4" \
  "$(json '" ".join((r["hubs"][3]["slots"][1]["state"], r["hubs"][4]["on"]["hub"], str(r["hubs"][4]["on"]["port"]), str(r["hubs"][4]["ports"])))')"
check "the device behind the hub" "Galaxy_Tab" "$(json 'r["hubs"][4]["slots"][2]["device"]["name"]')"
check "a hub of the board is built in" "True False" "$(json 'str(r["hubs"][5]["built_in"]) + " " + str(r["hubs"][2]["built_in"])')"
check "two chips on the last two ports of the first one are one hub" \
  "3-2.1 3-2.2 3-2.3.1 3-2.3.2 3-2.3.3 3-2.3.4 3-2.4.1 3-2.4.2 3-2.4.3 3-2.4.4 4-2" \
  "$(json '" ".join(s["path"] for s in r["hubs"][6]["slots"]) + " " + r["hubs"][6]["usb3"]')"
check "the controller of the card" "0000:02:00.0" "$(json 'r["hubs"][6]["controller"]["pci"]')"
check "the devices of the host ports" "1-2 unknown 1-3 farm" \
  "$(json '" ".join(s["path"] + " " + s["state"] for s in r["host_ports"])')"
check "the free ports of the hubs, not of the built-in ones" \
  "1-6.2 1-6.3 1-6.4.1 1-6.4.3 1-6.4.4.2 1-6.4.4.4.1 1-6.4.4.4.2 1-6.4.4.4.3 1-6.4.4.4.4 1-9.1 1-9.2 1-9.3 1-9.4 1-11.1 1-11.3 1-11.4 1-11.2.1 1-11.2.2 1-11.2.4 3-2.1 3-2.2 3-2.3.1 3-2.3.2 3-2.3.3 3-2.3.4 3-2.4.2 3-2.4.3 3-2.4.4" \
  "$(json '" ".join(r["free_ports"])')"
check "the used ports" "8 of 36" "$(json 'str(r["used"]) + " of " + str(r["ports"])')"
check "the farm devices not on USB: the USB ones only, with their last port and time" \
  "Samsung_S22 S3_B2 1-9.3 ${today} 05:03:19" \
  "$(json '" ".join(str(d[k]) for d in r["not_on_usb"] for k in ("name", "location", "last_port", "last_seen"))')"
check "no disconnects without --days" "False" "$(json '"disconnects" in r["hubs"][0]["slots"][0]')"

section "the text"
map
check "status 1" "1" "$STATUS"
check_contains "the summary" ": 6 hubs (+1 built in), 8 of 36 ports used, 1 farm devices not on USB" "$OUT"
check_contains "the title of a hub: its USB3 half, ports, chips and controller" \
  "1-6 (USB3 2-6), 10 ports, 43f2:1211+43f2:1211+0bda:5411, 0000:7f:1f.7 Test xHCI Host Controller (rev 01)" "$OUT"
check_contains "a farm device on a port" "   1 1-6.1        480M  Galaxy (rack_1)                          R58M1234" "$OUT"
check_contains "a USB3 device" "   5 2-6.4.2      5G    Pixel_7                                  PIXEL7" "$OUT"
check_contains "an unknown device" "   7 1-6.4.4.1    1.5M  unknown USB Keyboard                     046d:c31c" "$OUT"
check_contains "a hub on a port" "  10 1-6.4.4.4    480M  hub 1-6.4.4.4                            1a40:0101" "$OUT"
check_contains "an empty port" "   2 1-6.2              -- empty --" "$OUT"
check_contains "a hub behind a port" "1-6.4.4.4, 4 ports, on port 10 of 1-6, 1a40:0101" "$OUT"
check_contains "a built-in hub" "1-13, 4 ports, built in, 05e3:0608" "$OUT"
check_contains "the host ports" "Host ports, 0000:7f:1f.7 Test xHCI Host Controller (rev 01)" "$OUT"
check_contains "a device of a host port" "     1-3          480M  Moto                                     MOTO1" "$OUT"
check_contains "the free ports" "Free ports: 1-6.2 1-6.3 1-6.4.1" "$OUT"
check_contains "a device not on USB" "Not on USB: Samsung_S22 (S3_B2) R5CW722TWGY (last seen ${today} 05:03:19 on 1-9.3)" "$OUT"

section "the options"
map --days 7 --json
check "--days: the disconnects of a port" "3" "$(json 'r["hubs"][0]["slots"][0]["disconnects"]')"
check "--days: of the USB3 half of a port" "1" "$(json 'r["hubs"][0]["slots"][4]["disconnects"]')"
check "--days: of an empty port of a gone device" "1" "$(json 'r["hubs"][2]["slots"][2]["disconnects"]')"
check "--days: the days" "7" "$(json 'r["days"]')"
map --days 7
check_contains "--days: next to the device" "R58M1234  disc7d=3" "$OUT"
map --summary
check "--summary: a line per device not on USB" \
  "Samsung_S22 (S3_B2) R5CW722TWGY is not on USB (last seen ${today} 05:03:19 on 1-9.3)" "$OUT"
check "--summary: status 1" "1" "$STATUS"
map --json --device Pixel_7
check "--device: the hubs of the device" "1-6" "$(json '" ".join(h["path"] for h in r["hubs"])')"
check "--device: no host port of other devices" "0" "$(json 'len(r["host_ports"])')"
check "--device: all its devices are on USB: status 0" "0" "$STATUS"
map --json --device MOTO1
check "--device of a host port: no hub" "0 1-3" "$(json 'str(len(r["hubs"])) + " " + r["host_ports"][0]["path"]')"
map --json --device Samsung_S22
check "--device not on USB: status 1" "1" "$STATUS"
check "--device not on USB: listed" "Samsung_S22" "$(json '" ".join(d["name"] for d in r["not_on_usb"])')"
grep -v Samsung_S22 "${WORK}/devices.txt" > "${WORK}/present.txt"
OUT="$(python3 "$MAP" --devices "${WORK}/present.txt" 2>&1)"
check "every farm device on USB: status 0" "0" "$?"
check_contains "every farm device on USB" ", 0 farm devices not on USB" "$OUT"

section "the kernel log"
USB_STATS_KERNEL_LOG="${WORK}/missing.log" map
check "an unreadable kernel log: still the map" "1" "$STATUS"
check_contains "an unreadable kernel log: the device without its last port" "Not on USB: Samsung_S22 (S3_B2) R5CW722TWGY"$'\n' "${OUT}"$'\n'
check_contains "an unreadable kernel log is explained" "The kernel log is not readable" "$OUT"
USB_MAP_SYSFS="${WORK}/nothing" map
check "no sysfs: status 2" "2" "$STATUS"
check_contains "no sysfs is explained" "No USB devices in sysfs" "$OUT"

finish
