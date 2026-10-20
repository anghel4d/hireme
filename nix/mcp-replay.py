"""The /mcp outage of 2026-10-20, replayed through the host's nginx.

One key on one address, every call sequential and unpaced, as the CV-load
worker ran: a burst of rule probes and explains, every run of its scripts
starting with initialize and never ending its session, then the initialize
that answered an empty 503 until the sessions idled out. Then what else
shuts a client out: a body over nginx's default, a browser on the same
address, event streams behind a buffering proxy, and probes with no key or
a wrong one. Every stage runs; the failures are listed together.

    python3 mcp-replay.py ADDRESS KEY
"""

import json
import socket
import sys
import urllib.error
import urllib.request

ADDRESS, KEY = sys.argv[1], sys.argv[2]
failures, sent = [], 0


def post(msg, key=KEY, sid=None, stream=False):
    """One request: (status, session id, answer); an open response for a stream."""
    global sent
    sent += 1
    headers = {"host": "localhost", "content-type": "application/json",
               "accept": "application/json, text/event-stream"}
    if key:
        headers["authorization"] = f"Bearer {key}"
    if sid:
        headers["mcp-session-id"] = sid
    request = urllib.request.Request(f"http://{ADDRESS}/mcp", json.dumps(msg).encode(), headers)
    try:
        r = urllib.request.urlopen(request, timeout=5 if stream else 120)
    except urllib.error.HTTPError as e:
        r = e
    status = r.getcode()
    if stream and status == 200:
        return r
    body = r.read()
    client = (msg.get("params") or {}).get("clientInfo", {}).get("name")
    what = f"request {sent}, {msg.get('method')}{f' {client}' if client else ''}: {status}"
    # Whatever is refused says why: 401 with its challenge, anything else with a body,
    # and a refusal to come back later with when.
    if status >= 300:
        assert body or (status == 401 and r.headers.get("www-authenticate")), f"{what} with an empty body"
        assert status not in (429, 503) or r.headers.get("retry-after"), f"{what} without Retry-After"
    answer = json.loads(body) if body and status == 200 else {}
    return status, r.headers.get("mcp-session-id"), answer


def hello(name):
    return {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": name, "version": "1"}}}


def initialize(name):
    status, sid, answer = post(hello(name))
    assert status == 200 and sid and "result" in answer, f"initialize {name}: {status} {answer}"
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid=sid)
    return sid


def call(sid, tool, args=None):
    status, _, answer = post({"jsonrpc": "2.0", "id": sent, "method": "tools/call",
                              "params": {"name": tool, "arguments": args or {}}}, sid=sid)
    result = answer.get("result") or {}
    assert status == 200 and result and not result.get("isError"), f"{tool} {args}: {status} {answer}"


def stage(name, run):
    try:
        run()
    except Exception as e:
        failures.append(f"{name}: {type(e).__name__}: {e}")


sids = []


def burst():
    # One run: the write channel, then probes and explains back to back.
    sids.append(initialize("replay-0"))
    call(sids[0], "lease")
    probes = [("find", {"table": "applications", "limit": 50}), ("cv", {}),
              ("cv", {"check": "country in [DE, AT]"}), ("cv", {"fields": True})]
    for i in range(430):
        call(sids[0], *probes[i % len(probes)])


def leak():
    # Every other run: a new session, a call, never a DELETE. Then the call that failed,
    # and the first run's session id, which a client that kept it may still send.
    for n in range(1, 100):
        sids.append(initialize(f"replay-{n}"))
        call(sids[-1], "find", {"table": "places", "limit": 1})
    call(initialize("replay-after"), "find", {"table": "places", "limit": 1})
    call(sids[0], "find", {"table": "places", "limit": 1})


def body():
    # A 10 MiB CV file, as cv_upload carries it (base64 in JSON), reaches the node.
    status, _, _ = post({"jsonrpc": "2.0", "id": 1, "method": "ping",
                         "params": {"pad": "A" * (14 << 20)}}, sid=sids[-1])
    assert status == 200, f"a 14 MiB body: {status}"


def browser():
    # The operator's desk on the address that holds the agent's sessions is let in:
    # past the per-address cap the node says so at once, before any HELLO.
    with socket.create_connection((ADDRESS, 80), timeout=2) as s:
        s.sendall(b"GET /wire HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                  b"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                  b"Sec-WebSocket-Key: cmVwbGF5LXJlcGxheS0wMQ==\r\n\r\n")
        seen = b""
        try:
            while chunk := s.recv(4096):
                seen += chunk
        except socket.timeout:
            pass
    assert seen.startswith(b"HTTP/1.1 101"), f"/wire upgrade: {seen[:80]!r}"
    assert b"too many sessions" not in seen, "/wire: told the address holds too many sessions"


def streams():
    # Event streams come through as they are sent (nginx buffers none), and a key whose
    # every session holds one may still start another, or is told why not and when.
    held = []
    try:
        for n in range(70):
            sid = initialize(f"stream-{n}")
            r = post({"jsonrpc": "2.0", "id": 1, "method": "subscriptions/listen",
                      "params": {"notifications": {"toolsListChanged": True}}}, sid=sid, stream=True)
            assert not isinstance(r, tuple), f"subscriptions/listen {n}: {r[0]}"
            held.append((sid, r))
            line = r.readline()
            assert line.startswith(b"event: message"), f"stream {n}'s first line: {line!r}"
        status, _, _ = post(hello("past-the-streams"))
        assert status in (200, 429, 503), f"initialize past 70 streams: {status}"
    finally:
        # Ended as a client should, so the stage after starts clean.
        for sid, r in held:
            r.close()
            try:
                urllib.request.urlopen(urllib.request.Request(f"http://{ADDRESS}/mcp", method="DELETE", headers={
                    "host": "localhost", "authorization": f"Bearer {KEY}", "mcp-session-id": sid}), timeout=30).close()
            except OSError:
                pass


def keys():
    # No key, a made-up one, a typo of the real one: told so, maybe slowed, never banned,
    # and the real key on the same address is served right after.
    typo = KEY[:-1] + ("A" if KEY[-1] != "A" else "B")
    for key in [None, "hm_not_a_key", typo] * 7:
        status, _, _ = post(hello("a-bad-key"), key=key)
        assert status in (401, 429), f"a bad key answered {status}"
    call(initialize("after-the-probes"), "find", {"table": "places", "limit": 1})
    with urllib.request.urlopen(urllib.request.Request(
            f"http://{ADDRESS}/sign-in", headers={"host": "localhost"}), timeout=30) as r:
        assert r.getcode() == 200, f"/sign-in: {r.getcode()}"


for name, run in [("burst", burst), ("leak", leak), ("body", body), ("browser", browser),
                  ("streams", streams), ("keys", keys)]:
    stage(name, run)

print(f"replay: {sent} requests, {len(failures)} stages failed")
for f in failures:
    print(f"  {f}")
sys.exit(1 if failures else 0)
