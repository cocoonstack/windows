#!/usr/bin/env python3
"""Probe a CH serial socket for a real Windows SAC console."""

from __future__ import annotations

import socket
import sys
import time
from pathlib import Path

TOKENS = (
    b"SAC>",
    b"Special Administration Console",
    b"EVENT:",
    b"Use any of the following commands",
    b"Channel",
    b"cmd",
)


def sanitize(buf: bytes) -> bytes:
    return buf.replace(b"\x00", b"")


def recv_for(sock: socket.socket, seconds: float) -> bytes:
    deadline = time.time() + seconds
    out = bytearray()
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            out.extend(chunk)
            continue
        time.sleep(0.1)
    return bytes(out)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <serial-socket>", file=sys.stderr)
        return 2

    sock_path = Path(sys.argv[1])
    if not sock_path.exists():
        print(f"socket not found: {sock_path}", file=sys.stderr)
        return 2

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(str(sock_path))
    sock.setblocking(False)

    transcript = bytearray()
    transcript.extend(recv_for(sock, 3))
    for payload in (b"\r\n", b"\r\n", b"?\r\n"):
        sock.sendall(payload)
        transcript.extend(recv_for(sock, 3))

    cleaned = sanitize(bytes(transcript))
    sys.stdout.buffer.write(cleaned)
    sys.stdout.flush()

    if any(token in cleaned for token in TOKENS):
        return 0

    print("\nSAC probe failed: expected SAC prompt/help tokens on the serial socket.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
