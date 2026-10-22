"""The agent's half of the dev check's mail scenario, run in the VM.

An agent with a read/write key, over /mcp as any agent: it fires without a
key, asks for one, fires under it, fires again, fires a mission edited since
the key was made, and fires one whose application has an unsettled earlier
send. Plus the fake Gmail's spool (what went out, what came in) and the
domain pipe's signed endpoint. Each step prints one JSON line.

    python3 mail-check.py STEP KEY [ARGS...]
"""

import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

NODE = "http://127.0.0.1:4000"
SPOOL = "/var/lib/fake-gmail"


def mcp(key, tool, args, lease=None):
    """One MCP session: initialize, lease the application when given (an agent
    writes only under its lease), then the tool call; (is_error, text)."""
    def post(msg, sid=None):
        headers = {"content-type": "application/json", "accept": "application/json, text/event-stream",
                   "authorization": f"Bearer {key}"}
        if sid:
            headers["mcp-session-id"] = sid
        r = urllib.request.urlopen(urllib.request.Request(f"{NODE}/mcp", json.dumps(msg).encode(), headers), timeout=60)
        body = r.read().decode()
        return r.headers.get("mcp-session-id"), json.loads(body[body.index("{"):]) if "{" in body else None

    def call(sid, n, name, arguments):
        _, answer = post({"jsonrpc": "2.0", "id": n, "method": "tools/call", "params": {"name": name, "arguments": arguments}}, sid)
        result = answer["result"]
        return result.get("isError", False), "\n".join(c.get("text", "") for c in result["content"])

    sid, _ = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mail-check", "version": "1"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    try:
        if lease:
            err, text = call(sid, 2, "lease", {"ids": [int(lease)]})
            assert not err, text
        return call(sid, 3, tool, args)
    finally:
        # Release and end the session, so its lease ends with it.
        call(sid, 4, "release", {})
        urllib.request.urlopen(urllib.request.Request(f"{NODE}/mcp", None, {"authorization": f"Bearer {key}", "mcp-session-id": sid}, method="DELETE"), timeout=30)


def sent():
    """What the release sent through the fake's SMTP: one envelope per mail."""
    d = os.path.join(SPOOL, "sent")
    names = sorted(n for n in os.listdir(d) if n.endswith(".json")) if os.path.isdir(d) else []
    return [json.load(open(os.path.join(d, n))) for n in names]


def step(name, key, *args):
    if name == "fire":
        # fire MISSION APPLICATION [KEY_ID]: the agent's shot, under its lease
        # on the application; the answer and what went out.
        call = {"id": int(args[0])}
        if len(args) > 2:
            call["key"] = int(args[2])
        before = len(sent())
        err, text = mcp(key, "fire", call, lease=args[1])
        time.sleep(3)
        return {"is_error": err, "text": text, "sent": len(sent()) - before, "envelopes": sent()}
    if name == "request":
        # request MISSIONS APPLICATION: the predialed link (a write, so under the
        # lease), and that opening it creates nothing.
        err, text = mcp(key, "request_fire_key", {"missions": args[0], "reason": "the dev check"}, lease=args[1])
        link = next((w for w in text.split() if "/fire/" in w), "").strip(".,()<>`\"")
        path = link[link.index("/fire/"):] if "/fire/" in link else ""
        try:
            status = urllib.request.urlopen(f"{NODE}{path}", timeout=10).getcode()
        except urllib.error.HTTPError as e:
            status = e.code
        return {"is_error": err, "text": text, "link": link, "opened": status}
    if name == "edit":
        # edit MISSION APPLICATION: the agent rewrites a mission's draft after the key was made.
        err, text = mcp(key, "put", {"table": "missions", "id": int(args[0]), "set": {"draft": "A different text."}}, lease=args[1])
        return {"is_error": err, "text": text}
    if name == "reply":
        # reply MESSAGE_ID: a recruiter's answer lands in the fake Gmail's inbox.
        mid = "<" + args[0].strip("<>") + ">"
        raw = (f"From: Recruiter <jobs@acme.example>\r\nTo: check@gmail.com\r\nSubject: Re: Staff Engineer\r\n"
               f"Message-ID: <reply-{int(time.time())}@acme.example>\r\nIn-Reply-To: {mid}\r\nReferences: {mid}\r\n"
               f"Date: Thu, 22 Oct 2026 12:00:00 +0000\r\n\r\nThursday at 10 then.\r\n")
        os.makedirs(os.path.join(SPOOL, "inbox"), exist_ok=True)
        with open(os.path.join(SPOOL, "inbox", "reply.eml"), "w") as f:
            f.write(raw)
        return {"dropped": True}
    if name == "labels":
        # labels: every message the fake holds, with its Gmail labels.
        return json.load(open(os.path.join(SPOOL, "state.json")))
    if name == "pipe":
        # pipe PIPE_ID SECRET: the domain pipe, signed right, signed wrong, and replayed.
        pipe_id, secret = args
        raw = (b"From: Founder <cto@acme.example>\r\nTo: matei@anghel4d.com\r\nSubject: Staff Engineer at Acme\r\n"
               b"Message-ID: <pipe-1@acme.example>\r\nDate: Thu, 22 Oct 2026 12:05:00 +0000\r\n\r\nAre you free to talk?\r\n")

        def post(signature):
            ts = str(int(time.time()))
            sig = signature or "v1=" + hmac.new(secret.encode(), f"{ts}.{hashlib.sha256(raw).hexdigest()}".encode(), hashlib.sha256).hexdigest()
            req = urllib.request.Request(f"{NODE}/mail/inbound/{pipe_id}", raw, {
                "content-type": "message/rfc822", "x-hireme-timestamp": ts, "x-hireme-signature": sig,
                "x-hireme-envelope-from": "cto@acme.example", "x-hireme-envelope-to": "matei@anghel4d.com"})
            try:
                return urllib.request.urlopen(req, timeout=30).getcode()
            except urllib.error.HTTPError as e:
                return e.code

        return {"forged": post("v1=" + "0" * 64), "signed": post(None), "replayed": post(None)}
    raise SystemExit(f"unknown step {name}")


if __name__ == "__main__":
    print(json.dumps(step(sys.argv[1], sys.argv[2], *sys.argv[3:])))
