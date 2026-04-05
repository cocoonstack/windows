#!/usr/bin/env python3
"""Click a point on the QEMU VM via QMP input-send-event (absolute coords).

Usage: qmp_click.py X Y
X,Y are pixel coordinates in the 1280x800 VNC frame.
Absolute axis range in QEMU is 0..32767 regardless of actual resolution.
"""
import json
import socket
import sys

HOST, PORT = "127.0.0.1", 4445
W, H = 1280, 800
MAX = 32767


def send(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def recv(sock):
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf.decode().strip()


def main(x_px, y_px):
    x_abs = int(x_px * MAX / W)
    y_abs = int(y_px * MAX / H)

    s = socket.create_connection((HOST, PORT))
    s.settimeout(5)

    # Greeting
    print("greet:", recv(s))

    # Negotiate caps
    send(s, {"execute": "qmp_capabilities"})
    print("caps :", recv(s))

    # Move + press + release
    send(s, {
        "execute": "input-send-event",
        "arguments": {
            "events": [
                {"type": "abs", "data": {"axis": "x", "value": x_abs}},
                {"type": "abs", "data": {"axis": "y", "value": y_abs}},
            ],
        },
    })
    print("move :", recv(s))

    send(s, {
        "execute": "input-send-event",
        "arguments": {
            "events": [
                {"type": "btn", "data": {"button": "left", "down": True}},
            ],
        },
    })
    print("down :", recv(s))

    send(s, {
        "execute": "input-send-event",
        "arguments": {
            "events": [
                {"type": "btn", "data": {"button": "left", "down": False}},
            ],
        },
    })
    print("up   :", recv(s))

    s.close()
    print(f"clicked ({x_px},{y_px}) = ({x_abs},{y_abs})")


if __name__ == "__main__":
    main(int(sys.argv[1]), int(sys.argv[2]))
