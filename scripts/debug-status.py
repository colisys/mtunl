#!/usr/bin/env python3
"""Send a ping/start/status request over the mtunl control socket and print the raw response."""
import json
import socket
import sys
import struct

UID = 501
PATH = f"/tmp/mtunl-{UID}/ctl.sock"

def send(request: dict) -> dict:
    fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    fd.settimeout(5)
    fd.connect(PATH)
    payload = json.dumps(request).encode() + b"\n"
    fd.sendall(payload)
    data = b""
    while b"\n" not in data:
        chunk = fd.recv(65536)
        if not chunk:
            break
        data += chunk
    fd.close()
    return json.loads(data.split(b"\n")[0])

command = sys.argv[1] if len(sys.argv) > 1 else "ping"
target = sys.argv[2] if len(sys.argv) > 2 else None
request = {"command": command}
if target:
    request["target"] = target
response = send(request)
print("protocolVersion:", response.get("protocolVersion"))
for status in response.get("statuses") or []:
    print(f"- {status.get('name')}: state={status.get('state')} message={status.get('message')!r} passwordRequest={status.get('passwordRequestID') is not None} hostKey={status.get('hostKey') is not None}")
if "error" in response:
    print("error:", response["error"])
if "message" in response:
    print("message:", response["message"])
