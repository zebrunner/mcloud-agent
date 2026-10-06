"""Minimal fake usbmuxd speaking the plist protocol over TCP, for usbmuxd_watch tests.

Usage: python3 fake_usbmuxd.py <scenario> <port file>
Listens on a free local port written into <port file> and replays the device events
of the scenario to every Listen client; libusbmuxd connects to it when
USBMUXD_SOCKET_ADDRESS=127.0.0.1:<port> is set.
"""
import plistlib
import socket
import struct
import sys
import threading
import time


def usb(device_id, serial):
    return {"MessageType": "Attached", "DeviceID": device_id, "Properties": {
        "ConnectionType": "USB", "DeviceID": device_id, "LocationID": device_id,
        "ProductID": 4776, "SerialNumber": serial}}


def network(device_id, serial, ip_last_byte):
    address = bytes([16, 2, 0, 0, 192, 168, 1, ip_last_byte] + [0] * 8)  # sockaddr_in
    return {"MessageType": "Attached", "DeviceID": device_id, "Properties": {
        "ConnectionType": "Network", "DeviceID": device_id, "SerialNumber": serial,
        "NetworkAddress": address}}


def event(kind, device_id):
    return {"MessageType": kind, "DeviceID": device_id}


SCENARIOS = {
    # USB devices with a new (24 chars, shown with a dash) and an old (40 chars) udid
    "usb": [
        usb(5, "00008030001A35E83C38802E"),
        usb(7, "d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"),
        event("Paired", 7),
        event("Detached", 5),
        event("Detached", 7),
    ],
    # an iPhone connected by USB and visible over Wi-Fi, and an Apple TV visible over the network only
    "mixed": [
        usb(5, "00008030001A35E83C38802E"),
        network(9, "00008030-001A35E83C38802E", 10),
        event("Paired", 9),
        network(11, "aabbccddeeff00112233445566778899aabbccdd", 20),
        event("Detached", 9),
        event("Detached", 11),
        event("Paired", 5),
        event("Detached", 5),
    ],
}


def receive(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise ConnectionError("client closed the connection")
        data += chunk
    return data


def send(conn, message, tag):
    payload = plistlib.dumps(message, fmt=plistlib.FMT_XML)
    # header: total length, version 1 (plist protocol), message 8 (plist), tag
    conn.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, tag) + payload)


def serve(conn, events):
    try:
        while True:
            length, _version, _message, tag = struct.unpack("<IIII", receive(conn, 16))
            request = plistlib.loads(receive(conn, length - 16))
            if request.get("MessageType") == "Listen":
                send(conn, {"MessageType": "Result", "Number": 0}, tag)
                for message in events:
                    time.sleep(0.2)
                    send(conn, message, 0)
            elif request.get("MessageType") == "ListDevices":
                send(conn, {"DeviceList": []}, tag)
            else:
                send(conn, {"MessageType": "Result", "Number": 0}, tag)
    except (ConnectionError, OSError):
        pass


def main():
    events = SCENARIOS[sys.argv[1]]
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(5)
    with open(sys.argv[2], "w") as port_file:
        port_file.write(str(server.getsockname()[1]))
    while True:
        client, _ = server.accept()
        threading.Thread(target=serve, args=(client, events), daemon=True).start()


if __name__ == "__main__":
    main()
