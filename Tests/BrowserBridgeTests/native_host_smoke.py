#!/usr/bin/env python3
"""Exercise the real debug helper's framed stdio <-> Unix-socket relay in isolation."""
import json
import os
import pathlib
import select
import socket
import struct
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOST = ROOT / ".build/debug/LimaBrowserBridgeHost"
EXTENSION = "lima-browser-bridge@liamhosfeld.com"

def frame(message):
    data = json.dumps(message).encode()
    return struct.pack("<I", len(data)) + data

def read_exact(fd, count):
    data = b""
    while len(data) < count:
        if not select.select([fd], [], [], 5)[0]:
            raise AssertionError("Relay read timed out")
        piece = os.read(fd, count - len(data))
        if not piece:
            raise AssertionError("Unexpected relay EOF")
        data += piece
    return data

def read_message(fd):
    count = struct.unpack("<I", read_exact(fd, 4))[0]
    assert 0 < count <= 1048576
    return json.loads(read_exact(fd, count))

def message(kind, command, **extra):
    return dict(version=1, id=str(uuid.uuid4()), kind=kind, command=command, arguments={}, **extra)

with tempfile.TemporaryDirectory(prefix="lima-relay-", dir="/private/tmp") as directory:
    path = str(pathlib.Path(directory) / "s")
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(1)
        server.settimeout(5)
        env = dict(os.environ, LIMA_TEST_MODE="1", LIMA_BROWSER_BRIDGE_TEST_SOCKET=path)
        process = subprocess.Popen([str(HOST), "fixture-manifest.json", EXTENSION],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            with server.accept()[0] as peer:
                hello = message("hello", "connect")
                hello["arguments"] = {"extensionID": EXTENSION}
                payload = frame(hello)
                # Deliberately split both header and body writes.
                for start, end in [(0, 1), (1, 3), (3, 9), (9, len(payload))]:
                    process.stdin.write(payload[start:end]); process.stdin.flush()
                assert read_message(peer.fileno()) == hello
                request = message("request", "browser.tabs")
                peer.sendall(frame(request))
                assert read_message(process.stdout.fileno()) == request
                response = dict(request, kind="response", result={"tabs": []})
                process.stdin.write(frame(response)); process.stdin.flush()
                assert read_message(peer.fileno()) == response
                cancel = dict(request, kind="cancel")
                peer.sendall(frame(cancel))
                assert read_message(process.stdout.fileno()) == cancel
                # The browser is never allowed to issue native requests.
                process.stdin.write(frame(request)); process.stdin.flush()
                assert process.wait(timeout=5) != 0
                assert b"unavailable or invalid" in process.stderr.read()
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)
        invalid = subprocess.run([str(HOST), "fixture-manifest.json", "wrong@example.com"],
                                 capture_output=True, timeout=5, env=env)
        assert invalid.returncode != 0 and not invalid.stdout
print("Native helper smoke test passed: split frames, duplex relay, cancellation, direction and identity validation.")
