#!/usr/bin/env python3
"""Minimal Source RCON client for driving the headless Factorio server.

Usage:
    python3 tools/rcon.py <port> <password> "command"
    python3 tools/rcon.py <port> <password> --file commands.txt

Each line of a command file is sent as a separate command and its reply is
printed prefixed with the command, so a test run produces a greppable log.
"""

import socket
import struct
import sys
import time

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2


class RconError(RuntimeError):
    pass


class Rcon:
    def __init__(self, host, port, password, timeout=15.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self._request_id = 0
        self._send(SERVERDATA_AUTH, password)
        packet_id, _, _ = self._recv()
        if packet_id == -1:
            raise RconError("RCON authentication failed")

    def _send(self, packet_type, body):
        self._request_id += 1
        payload = struct.pack("<ii", self._request_id, packet_type)
        payload += body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)
        return self._request_id

    def _recv_exactly(self, count):
        chunks = b""
        while len(chunks) < count:
            chunk = self.sock.recv(count - len(chunks))
            if not chunk:
                raise RconError("connection closed by server")
            chunks += chunk
        return chunks

    def _recv(self):
        size = struct.unpack("<i", self._recv_exactly(4))[0]
        payload = self._recv_exactly(size)
        packet_id, packet_type = struct.unpack("<ii", payload[:8])
        return packet_id, packet_type, payload[8:-2].decode("utf-8", "replace")

    def command(self, text):
        self._send(SERVERDATA_EXECCOMMAND, text)
        _, _, body = self._recv()
        return body

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def connect_with_retry(host, port, password, attempts=30, delay=2.0):
    last = None
    for _ in range(attempts):
        try:
            return Rcon(host, port, password)
        except (OSError, RconError) as error:
            last = error
            time.sleep(delay)
    raise RconError("could not reach RCON on %s:%s (%s)" % (host, port, last))


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2

    port, password = int(argv[1]), argv[2]
    rcon = connect_with_retry("127.0.0.1", port, password)
    try:
        if argv[3] == "--file":
            with open(argv[4], encoding="utf-8") as handle:
                lines = [line.rstrip("\n") for line in handle]
            for line in lines:
                stripped = line.strip()
                # "#sleep N" lets a command file wait for the game to do
                # something on its own, such as a train actually driving to the
                # station rather than being teleported there.
                if stripped.startswith("#sleep"):
                    parts = stripped.split()
                    seconds = float(parts[1]) if len(parts) > 1 else 1.0
                    print("### sleep %g" % seconds)
                    time.sleep(seconds)
                    continue
                if not stripped or stripped.startswith("#"):
                    continue
                print("### %s" % line)
                print(rcon.command(line))
        else:
            print(rcon.command(" ".join(argv[3:])))
    finally:
        rcon.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
