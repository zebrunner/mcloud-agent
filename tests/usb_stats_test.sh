#!/bin/bash
# Tests of patch/usb_stats.py (zebrunner-farm usb-stats, README.md#usb-stability): the kernel and docker logs, sysfs and
# the devices list are fixtures of the test, no journalctl and no USB device are needed.
source "$(dirname "$0")/lib.sh"
require_cmd python3

STATS="${REPO}/patch/usb_stats.py"
export USB_STATS_KERNEL_LOG="${WORK}/kernel.log"
export USB_STATS_DOCKER_LOG="${WORK}/docker.log"
export USB_STATS_SYSFS="${WORK}/sysfs"
cat > "${WORK}/devices.txt" << 'EOF'
# the devices list of the deploy
id=R58M1234|os=android|name=Galaxy|location=rack_1|connection=usb
id=00008110-000A1B2C3D4E0001|os=ios|name=iPhone_15|location=rack_2|connection=usb
id=PIXEL7|os=android|name=Pixel_7|location=|connection=usb
EOF
GALAXY=R58M1234
IPHONE=00008110000A1B2C3D4E0001
PIXEL=PIXEL7

# kernel_log: the kernel log of the lines of stdin, `<days ago> <port> <serial> <disconnects> [errors]`: the device is
# connected to the port that day, then disconnected and connected again <disconnects> times, with <errors> errors -71
kernel_log() {
  python3 -c '
import datetime, sys
today = datetime.date.today()
out = []
for number, line in enumerate(sys.stdin):
    fields = line.split()
    if not fields:
        continue
    ago, port, serial, disconnects = int(fields[0]), fields[1], fields[2], int(fields[3])
    errors = int(fields[4]) if len(fields) > 4 else 0
    day = today - datetime.timedelta(days=ago)
    stamp = lambda second: "%sT%02d:%02d:%02d+0100" % (day, number % 24, second // 60 % 60, second % 60)
    out.append("%s host kernel: usb %s: new high-speed USB device number 5 using xhci_hcd" % (stamp(0), port))
    out.append("%s host kernel: usb %s: SerialNumber: %s" % (stamp(1), port, serial))
    for i in range(disconnects):
        out.append("%s host kernel: usb %s: USB disconnect, device number 5" % (stamp(2 + 2 * i), port))
        out.append("%s host kernel: usb %s: SerialNumber: %s" % (stamp(3 + 2 * i), port, serial))
    for i in range(errors):
        out.append("%s host kernel: usb %s: can'"'"'t read configurations, error -71" % (stamp(3000 + i), port))
print("\n".join(out))
' > "$USB_STATS_KERNEL_LOG"
}

# stats <arguments...>: the report, its status in $STATUS
stats() {
  OUT="$(python3 "$STATS" --devices "${WORK}/devices.txt" "$@" 2>&1)"
  STATUS=$?
}

# json_field <python expression of r>: a value of the JSON report of $OUT
json_field() {
  python3 -c "import json, sys; r = json.loads(sys.stdin.read()); print($1)" <<< "$OUT"
}

: > "$USB_STATS_DOCKER_LOG"
mkdir -p "${USB_STATS_SYSFS}/1-13.4.2" "${USB_STATS_SYSFS}/1-6.4.2" "${USB_STATS_SYSFS}/1-6.4.2:1.0"
echo "$GALAXY" > "${USB_STATS_SYSFS}/1-13.4.2/serial"
echo "$IPHONE" > "${USB_STATS_SYSFS}/1-6.4.2/serial"

section "the port is to blame: the case of the issue"
# Galaxy flaps on 1-6.4.2 while iPhone_15 is stable on 1-13.4.2; they are swapped: iPhone_15 flaps on 1-6.4.2, Galaxy
# is stable on 1-13.4.2
kernel_log << EOF
6 1-6.4.2 ${GALAXY} 30 2
6 1-13.4.2 ${IPHONE} 0
5 1-6.4.2 ${GALAXY} 40
4 1-6.4.2 ${GALAXY} 25 1
3 1-13.4.2 ${GALAXY} 1
3 1-6.4.2 ${IPHONE} 50
2 1-6.4.2 ${IPHONE} 60
EOF
echo "2026-11-23T10:00:00+0100 host dockerd[1]: level=error msg=\"error gathering device information while adding custom device \\\"/dev/device-iPhone_15-00008110-000A1B2C3D4E0001\\\": not a device node\"" > "$USB_STATS_DOCKER_LOG"
stats
check "a flapping port: status 1" "1" "$STATUS"
check_contains "the header" "USB stability, 7 days" "$OUT"
check_contains "the threshold" "threshold 10 disconnects/day" "$OUT"
check_contains "the port, its device, the disconnects, the most of a day, the errors, the failed starts and the verdict" \
  "1-6.4.2      iPhone_15 (rack_2)                      205       60       3           1  port: different devices flapped here: Galaxy (rack_1), iPhone_15 (rack_2)" "$OUT"
check_contains "a stable port" "1-13.4.2     Galaxy (rack_1)                           1        1       0           0  ok" "$OUT"
check_contains "the devices of a port in the period" "1-6.4.2      Galaxy (rack_1) until" "$OUT"
check_contains "the current device of a port" "iPhone_15 (rack_2) since" "$OUT"
check_contains "the hint of the port" "port: replace the cable or use another port" "$OUT"
stats --summary
check "the summary for doctor: a line per flapping port" \
  "USB port 1-6.4.2 (iPhone_15 (rack_2)): 205 disconnects in 7 days, up to 60 a day; port: different devices flapped here: Galaxy (rack_1), iPhone_15 (rack_2)" "$OUT"
stats --json
check "the JSON report: flapping" "True" "$(json_field 'r["flapping"]')"
check "the JSON report: the ports" "1-6.4.2 1-13.4.2" "$(json_field '" ".join(p["port"] for p in r["ports"])')"
check "the JSON report: the verdict" "port" "$(json_field 'r["ports"][0]["verdict"]')"
check "the JSON report: the days of a port" "5" "$(json_field 'len(r["ports"][0]["per_day"])')"
check "the JSON report: the device of the port is connected to it now (sysfs)" "True" "$(json_field 'r["ports"][0]["connected_now"]')"
check "the JSON report: the id of the device" "00008110-000A1B2C3D4E0001" "$(json_field 'r["ports"][0]["id"]')"
check "the JSON report: the devices of the port" "2" "$(json_field 'len(r["ports"][0]["holders"])')"
stats --device Galaxy
check "a device: its ports only" "1-6.4.2 1-13.4.2" "$(python3 "$STATS" --devices "${WORK}/devices.txt" --device Galaxy --json |
  python3 -c 'import json, sys; print(" ".join(p["port"] for p in json.load(sys.stdin)["ports"]))')"
check "a device of no port: no port" "0" "$(python3 "$STATS" --devices "${WORK}/devices.txt" --device Pixel_7 --json |
  python3 -c 'import json, sys; print(len(json.load(sys.stdin)["ports"]))')"
stats --threshold 60
check "a higher threshold: no flapping port" "0" "$STATUS"
check_contains "a higher threshold: the port is ok" "205       60       3           1  ok" "$OUT"

section "the device is to blame"
# Pixel_7 flaps on two ports
kernel_log << EOF
5 1-2 ${PIXEL} 20
3 1-3 ${PIXEL} 15
EOF
: > "$USB_STATS_DOCKER_LOG"
stats
check_contains "a device that flaps on two ports" "device: Pixel_7 flaps on 1-3 too" "$OUT"
check_contains "the hint of the device" "device: check the connector and the cable of the device" "$OUT"
# Pixel_7 flaps on 1-2, where Galaxy was stable before
kernel_log << EOF
6 1-2 ${GALAXY} 2
4 1-2 ${PIXEL} 30
EOF
stats
check_contains "another device was stable on the port" "device: Pixel_7 flapped here, Galaxy (rack_1) stable on this port" "$OUT"

section "the port of a moved device"
# Galaxy is stable on 1-5, then moved to 1-2, where it flaps
kernel_log << EOF
6 1-5 ${GALAXY} 3
3 1-2 ${GALAXY} 40
EOF
stats
check_contains "a device that is stable on another port" "port: Galaxy (rack_1) flapped here, it is stable on 1-5" "$OUT"

section "unknown"
kernel_log << EOF
5 1-4 ${PIXEL} 12
4 1-4 ${PIXEL} 14
EOF
stats
check_contains "one device on one port" "unknown: one device on one port: Pixel_7" "$OUT"
check_contains "the hint of unknown" "swap the device with a stable device of another port" "$OUT"
kernel_log << EOF
3 1-7 UNKNOWNSERIAL 11
EOF
stats
check_contains "a device that is not in the devices list" "unknown device UNKNOWNSERIAL" "$OUT"

section "the kernel names of an iPhone"
# the kernel names an iPhone by its driver in the disconnection (apple-mfi-fastcharge) and gives its serial with or
# without the dash of the UDID
python3 -c '
import datetime
day = datetime.date.today() - datetime.timedelta(days=2)
lines = ["%sT08:00:00+0100 host kernel: usb 1-9: SerialNumber: 00008110-000A1B2C3D4E0001" % day]
lines += ["%sT08:%02d:00+0100 host kernel: apple-mfi-fastcharge 1-9: USB disconnect, device number %d" % (day, i + 1, i) for i in range(12)]
lines += ["%sT09:00:00+0100 host kernel: usb 1-9: SerialNumber: 00008110000A1B2C3D4E0001" % day]
lines += ["%sT09:01:00+0100 host kernel: apple-mfi-fastcharge 1-9: device not accepting address 7, error -71" % day]
print("\n".join(lines))' > "$USB_STATS_KERNEL_LOG"
stats
check_contains "the disconnects of the driver of an iPhone and its serial with a dash" \
  "1-9          iPhone_15 (rack_2)                       12       12       1           0  unknown: one device on one port" "$OUT"
check_not_contains "the serial with and without its dash is one device" "Ports held by more than one device" "$OUT"

section "the threshold and the noise"
kernel_log << EOF
3 1-4 ${PIXEL} 10
2 1-4 ${PIXEL} 2
EOF
stats
check "10 disconnects a day are not flapping" "0" "$STATUS"
check_contains "a port with disconnects is listed" "1-4          Pixel_7" "$OUT"
kernel_log << EOF
3 1-4 ${PIXEL} 11
EOF
stats
check "11 disconnects a day flap" "1" "$STATUS"
kernel_log << EOF
3 1-4 ${PIXEL} 0
EOF
stats
check "no disconnect: status 0" "0" "$STATUS"
check_contains "no disconnect is reported" "No disconnection of a USB device in the period." "$OUT"
check_contains "a log that starts after the period is reported" "The kernel log starts on" "$OUT"

section "the logs"
USB_STATS_KERNEL_LOG="${WORK}/missing.log" stats
check "unreadable logs: status 2" "2" "$STATUS"
check_contains "unreadable logs are explained" "The logs are not readable" "$OUT"
check_contains "the groups of the logs" "the groups adm or systemd-journal read them, or sudo" "$OUT"
stats --days 0
check "--days 0 is refused" "2" "$STATUS"
check_contains "--days 0 is explained" "--days and --threshold are 1 or more" "$OUT"

finish
