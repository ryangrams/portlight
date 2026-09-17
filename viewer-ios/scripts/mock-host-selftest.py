#!/usr/bin/env python3
"""Self-test for the scripted Portlight mock host (scripts/mock-host.py).

Starts the mock host as subprocesses on free loopback ports, connects with the websockets client
pinned to the printed certificate fingerprint (the leaf DER hash is verified before any password is
sent; CERT_NONE only disables CA/hostname validation, which a self-signed pin replaces), and asserts
the host's protocol behaviour. Prints a JSON summary like tests/protocol_e2e.py and exits nonzero on
any failure. Every password here is synthetic test data.

    app/.test-venv/bin/python viewer-ios/scripts/mock-host-selftest.py [--only GROUP ...] [--keep]
"""
import argparse
import asyncio
import base64
import hashlib
import io
import json
import math
import re
import shutil
import signal
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import traceback
import zlib
from pathlib import Path

import websockets
from websockets.exceptions import ConnectionClosed
from PIL import Image

SCRIPTS = Path(__file__).resolve().parent
MOCK = SCRIPTS / "mock-host.py"
AAC_FIXTURES = SCRIPTS.parent.parent / "viewer-windows" / "tests" / "aac-fixtures.json"
PASSWORD = "selftest-synthetic-password"
WRONG = "wrong-synthetic-password"
STARTUP_TIMEOUT = 60
GROUP_TIMEOUT = 240
PNG_SIG = b"\x89PNG\r\n\x1a\n"

AUTH_ERROR = "Incorrect password or incompatible protocol"
BUSY_ERROR = "Another viewer is connected. Disconnect it before connecting here."
SUB_ERROR = "Invalid displays, revision, resolution, color, quality, frame rate or bandwidth"
REGION_MAP_ERROR = "Invalid visible region map"
REGION_ERROR = "Invalid visible region"
AUDIO_QUALITY_ERROR = "Unsupported audio quality"
AAC_INIT_ERROR = "The host could not initialize compressed audio. Turn audio off or choose another quality."
TOPOLOGY_ERROR = "Displays changed. Select displays again."
TIMEOUT_ERROR = "Viewer stopped acknowledging image updates"
PALETTE = bytes(v for i in range(256) for v in ((i >> 5) * 255 // 7, ((i >> 2) & 7) * 255 // 7, (i & 3) * 255 // 3))
COLOR_MODES = ["gray16", "color256", "rgb565", "full"]
FIXTURE3 = [
    {"id": "fixture-1", "name": "Test Display 1", "index": 1, "width": 3840, "height": 2160, "x": 0, "y": 0,
     "logicalWidth": 1920, "logicalHeight": 1080, "scale": 2, "primary": True},
    {"id": "fixture-2", "name": "Test Display 2", "index": 2, "width": 1920, "height": 1080, "x": 1920, "y": 0,
     "logicalWidth": 1920, "logicalHeight": 1080, "scale": 1, "primary": False},
    {"id": "fixture-3", "name": "Test Display 3", "index": 3, "width": 3840, "height": 2160, "x": 3840, "y": 0,
     "logicalWidth": 1920, "logicalHeight": 1080, "scale": 2, "primary": False},
]
BASE = dict(maxWidth=1280, maxHeight=720, color="full", quality="desktop", fps=60, bandwidthKbps=0, paused=False,
            audio=False, viewOnly=False, regions={})


# ---------------------------------------------------------------------------------------------
# Result bookkeeping

class Results:
    def __init__(self):
        self.passed, self.failed, self.stops = [], [], []


R = Results()


def check(name, condition, detail=""):
    if condition:
        R.passed.append(name)
    else:
        R.failed.append({"check": name, "detail": str(detail)[:1500] or "assertion failed"})
    return bool(condition)


# ---------------------------------------------------------------------------------------------
# Independent expectations (re-derived from Display.swift / Capture.swift, not imported from the mock)

def scaled(width, height, box):
    bw, bh = box
    cap = (bh, bw) if height > width else (bw, bh)
    scale = min(1.0, min(cap[0] / width, cap[1] / height))
    return (max(1, int(width * scale)), max(1, int(height * scale)))


def expected_crop(region, w, h):
    rx, ry, rw, rh = region
    x0, y0 = max(rx * w, 0.0), max(ry * h, 0.0)
    x1, y1 = min(rx * w + rw * w, float(w)), min(ry * h + rh * h, float(h))
    return (math.floor(x0), math.floor(y0), math.ceil(x1) - math.floor(x0), math.ceil(y1) - math.floor(y0))


def png_info(data):
    if data[:8] != PNG_SIG:
        raise AssertionError("payload is not a PNG")
    pos, chunks = 8, {}
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        if struct.unpack(">I", data[pos + 8 + n:pos + 12 + n])[0] != zlib.crc32(kind + body) & 0xFFFFFFFF:
            raise AssertionError(f"bad CRC in {kind!r}")
        chunks.setdefault(kind, []).append(body)
        pos += 12 + n
    w, h, depth, ctype = struct.unpack(">IIBB", chunks[b"IHDR"][0][:10])
    return {"width": w, "height": h, "depth": depth, "ctype": ctype, "plte": (chunks.get(b"PLTE") or [None])[0]}


def decode(payload):
    with Image.open(io.BytesIO(payload)) as im:
        im.load()
        return im.copy()


def classify(packet):
    if isinstance(packet, str):
        try:
            obj = json.loads(packet)
        except ValueError:
            return {"kind": "badtext", "raw": packet}
        if not isinstance(obj, dict):
            return {"kind": "nonobject", "raw": packet}
        return {"kind": "text", "type": obj.get("type"), "obj": obj, "raw": packet}
    data = bytes(packet)
    if len(data) < 5:
        return {"kind": "short", "raw": data}
    n = struct.unpack(">I", data[:4])[0]
    if n == 0 or n > 65536 or 4 + n > len(data):
        return {"kind": "overflow", "raw": data, "n": n}
    try:
        header = json.loads(data[4:4 + n])
    except ValueError:
        return {"kind": "badheader", "raw": data}
    return {"kind": header.get("type"), "header": header, "payload": data[4 + n:], "raw": data}


def is_text(m, type_=None):
    return m["kind"] == "text" and (type_ is None or m["type"] == type_)


def frames(seen, revision=None):
    return [m for m in seen if m["kind"] == "frame" and (revision is None or m["header"]["revision"] == revision)]


# ---------------------------------------------------------------------------------------------
# Host process and pinned client

class Host:
    def __init__(self, *args, data_dir=None, transcript=False, password=PASSWORD):
        self.args, self.data_dir, self.password = list(args), data_dir, password
        self.tmp = Path(tempfile.mkdtemp(prefix="mock-host-selftest-"))
        self.transcript = self.tmp / "transcript.jsonl" if transcript else None
        self.stderr_path = self.tmp / "stderr.log"
        self.proc = None

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, *exc):
        await self.stop()

    async def start(self):
        cmd = [sys.executable, str(MOCK), "--password-stdin", *self.args]
        if self.data_dir:
            cmd += ["--data-dir", str(self.data_dir)]
        if self.transcript:
            cmd += ["--transcript", str(self.transcript)]
        self.stderr = open(self.stderr_path, "w")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, text=True)
        self.proc.stdin.write(self.password + "\n")
        self.proc.stdin.close()
        lines = []
        for _ in range(2):
            line = await asyncio.wait_for(asyncio.to_thread(self.proc.stdout.readline), STARTUP_TIMEOUT)
            lines.append(line.rstrip("\n"))
        self.lines = lines
        m1 = re.fullmatch(r"TLS SHA256 ((?:[0-9A-F]{2}:){31}[0-9A-F]{2})", lines[0])
        m2 = re.fullmatch(r"Listening on port (\d+)", lines[1])
        if not (m1 and m2):
            raise AssertionError(f"unexpected startup output {lines!r}; stderr: {self.stderr_path.read_text()[-1500:]}")
        self.fingerprint, self.port = m1.group(1), int(m2.group(1))

    async def stop(self, sig=signal.SIGTERM):
        if self.proc is None:
            return None
        if self.proc.poll() is None:
            self.proc.send_signal(sig)
        try:
            code = await asyncio.wait_for(asyncio.to_thread(self.proc.wait), 15)
        except asyncio.TimeoutError:
            self.proc.kill()
            code = await asyncio.to_thread(self.proc.wait)
            code = f"killed after SIGTERM timeout ({code})"
        rest = await asyncio.to_thread(self.proc.stdout.read)
        self.stderr.close()
        self.exit_code, self.tail = code, rest
        R.stops.append({"args": self.args, "code": code, "stopped": "Stopped" in rest,
                        "stderr": self.stderr_path.read_text()[-800:] if code != 0 else ""})
        self.proc = None
        return code

    def records(self):
        with open(self.transcript, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    async def connect(self):
        return await Client.connect(self)


class Client:
    def __init__(self, ws, host):
        self.ws, self.host = ws, host
        self.auto_ack = True
        self.seen = []

    @classmethod
    async def connect(cls, host):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        tls.check_hostname = False
        tls.verify_mode = ssl.CERT_NONE  # CA trust is replaced by the exact fingerprint pin checked below
        ws = await websockets.connect(f"wss://127.0.0.1:{host.port}/remote", ssl=tls, max_size=32 * 1024 * 1024,
                                      open_timeout=30, ping_interval=None, close_timeout=2, compression=None)
        der = ws.transport.get_extra_info("ssl_object").getpeercert(binary_form=True)
        fingerprint = ":".join(f"{b:02X}" for b in hashlib.sha256(der).digest())
        if fingerprint != host.fingerprint:
            await ws.close()
            raise AssertionError(f"certificate pin mismatch: {fingerprint} != {host.fingerprint}")
        client = cls(ws, host)
        client.der = der
        return client

    async def send(self, **obj):
        await self.ws.send(json.dumps(obj))

    async def next(self, timeout):
        packet = await asyncio.wait_for(self.ws.recv(), timeout)
        m = classify(packet)
        m["at"] = time.monotonic()
        self.seen.append(m)
        if m["kind"] == "frame" and self.auto_ack and isinstance(m["header"].get("sequence"), int):
            await self.send(type="frameAck", sequence=m["header"]["sequence"])
        return m

    async def until(self, predicate, timeout=10.0, what="message"):
        deadline = time.monotonic() + timeout
        seen = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for {what}; saw {summary(seen)}")
            try:
                m = await self.next(remaining)
            except asyncio.TimeoutError:
                continue
            seen.append(m)
            if predicate(m):
                return m, seen

    async def gather(self, seconds):
        deadline = time.monotonic() + seconds
        seen = []
        while (remaining := deadline - time.monotonic()) > 0:
            try:
                seen.append(await self.next(remaining))
            except asyncio.TimeoutError:
                break
        return seen

    async def hello(self, password=PASSWORD, **extra):
        await self.send(type="hello", version=1, password=password, codecs=["png", "jpeg"], **extra)
        m, _ = await self.until(lambda m: is_text(m, "welcome") or is_text(m, "error"), 15, "welcome or error")
        return m

    async def subscribe(self, revision, displays, **changes):
        msg = {"type": "subscribe", "revision": revision, "displays": displays, **BASE}
        for key, value in changes.items():
            if value is None:
                msg.pop(key, None)
            else:
                msg[key] = value
        await self.ws.send(json.dumps(msg))
        m, seen = await self.until(lambda m: is_text(m, "error") or (is_text(m, "subscribed") and m["obj"].get("revision") == revision),
                                   15, f"subscribed {revision}")
        return m["obj"], seen

    async def expect_closed(self, timeout=8.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                await self.next(deadline - time.monotonic())
            except ConnectionClosed as exc:
                return exc
            except asyncio.TimeoutError:
                break
        raise AssertionError("connection stayed open")

    async def close(self):
        try:
            await self.ws.close()
        except Exception:  # noqa: BLE001
            pass


def summary(seen):
    out = []
    for m in seen[-12:]:
        if m["kind"] == "text":
            out.append(m["type"] if m["type"] not in ("error",) else f"error:{m['obj'].get('message')}")
        elif m["kind"] in ("frame", "audio"):
            h = m["header"]
            out.append(f"{m['kind']}r{h.get('revision')}s{h.get('sequence')}")
        else:
            out.append(m["kind"])
    return out


def error_of(m):
    return (m["obj"].get("code"), m["obj"].get("message")) if m and is_text(m, "error") else None


HOSTS = []


def host(*args, **kwargs):
    h = Host(*args, **kwargs)
    HOSTS.append(h)
    return h


async def keyframes(client, revision, displays, extra=1.2, timeout=25):
    """Wait for the first frame of `revision` from every display, then keep collecting for `extra` seconds."""
    got = {}

    def first(m):
        if m["kind"] == "frame" and m["header"]["revision"] == revision:
            got.setdefault(m["header"]["display"], m)
        return all(d in got for d in displays)
    _, seen = await client.until(first, timeout, f"keyframes of revision {revision}")
    return got, seen + (await client.gather(extra) if extra else [])


def depth(value):
    if isinstance(value, dict):
        return 1 + max((depth(v) for v in value.values()), default=0)
    if isinstance(value, list):
        return 1 + max((depth(v) for v in value), default=0)
    return 0


ZERO = {"x": 0, "y": 0, "width": 0, "height": 0}


# ---------------------------------------------------------------------------------------------
# Groups

async def group_core(shared):
    h = host(data_dir=shared, transcript=True)
    await h.start()
    check("startup: prints 'TLS SHA256 <fp>' then 'Listening on port N' on a free port", 0 < h.port != 5920, h.lines)
    der = ssl.PEM_cert_to_DER_cert((shared / "certificate.pem").read_text())
    check("identity: printed fingerprint is SHA-256 of the leaf DER", ":".join(f"{b:02X}" for b in hashlib.sha256(der).digest()) == h.fingerprint)
    text = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-text", "-in", str(shared / "certificate.pem")],
                          capture_output=True, text=True).stdout
    check("identity: self-signed EC P-256 with CN Portlight Mock Host", "Portlight Mock Host" in text and ("prime256v1" in text or "P-256" in text), text[:400])
    main = await h.connect()
    check("pin: the client verified the served certificate's DER hash before sending a password", main.der == der)

    bad = await h.connect()
    m = await bad.hello(WRONG)
    check("auth: wrong password -> exact authentication error", error_of(m) == ("authentication", AUTH_ERROR), error_of(m))
    check("auth: host closes after the authentication error", await bad.expect_closed() is not None)
    c = await h.connect()
    await c.send(type="ping", time=1)
    m, _ = await c.until(lambda m: is_text(m, "error"), 10)
    check("auth: a first message other than hello -> authentication error", error_of(m) == ("authentication", AUTH_ERROR), error_of(m))
    await c.close()
    c = await h.connect()
    await c.send(type="hello", version=2, password=PASSWORD)
    m, _ = await c.until(lambda m: is_text(m, "error"), 10)
    check("auth: hello version 2 -> authentication error", error_of(m) == ("authentication", AUTH_ERROR), error_of(m))
    await c.close()

    await main.send(foo=1)
    m, _ = await main.until(lambda m: is_text(m, "error"), 10)
    check("control: no type before auth -> 'Missing message type', socket stays open", error_of(m) == ("message", "Missing message type"), error_of(m))
    m = await main.hello()
    w = m["obj"]
    check("welcome: fixture3 displays identical to the real fixture (ids, names, geometry, scale, primary)", w.get("displays") == FIXTURE3, w.get("displays"))
    check("welcome: capabilities {codecs, audio [], colorModes, maxViewers 1}",
          w.get("capabilities") == {"codecs": ["png", "jpeg"], "audio": [], "colorModes": COLOR_MODES, "maxViewers": 1}, w.get("capabilities"))
    check("welcome: version 1, serverName, uppercase UUID sessionId",
          w.get("version") == 1 and w.get("serverName") == "Portlight Mock Host"
          and re.fullmatch(r"[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}", w.get("sessionId", "")) is not None, w)
    check("welcome: numbers formatted like JSONSerialization (1920, not 1920.0)", '"logicalWidth":1920,' in m["raw"] and "1920.0" not in m["raw"], m["raw"][:200])

    other = await h.connect()
    m = await other.hello()
    check("busy: a second authenticated viewer gets the exact busy error", error_of(m) == ("busy", BUSY_ERROR), error_of(m))
    check("busy: host closes after busy", await other.expect_closed() is not None)
    junk = await h.connect()
    await junk.ws.send("not json")
    m, _ = await junk.until(lambda m: is_text(m, "error"), 10)
    check("control: invalid JSON -> 'Invalid control message' then close",
          error_of(m) == ("message", "Invalid control message") and await junk.expect_closed() is not None, error_of(m))
    refused = []
    for label, payload in (("1e999", '{"type":"ping","time":1e999}'), ("-1e999", '{"type":"ping","time":-1e999}'),
                           ("lone surrogate", '{"type":"hello","version":1,"password":"\\udc00"}'),
                           ("object at depth 513", '{"type":"ping","n":' + '{"n":' * 511 + "{}" + "}" * 511 + "}"),
                           ("array at depth 514", '{"type":"ping","n":' + "[" * 513 + "]" * 513 + "}"),
                           ("UTF-16", '{"type":"ping"}'.encode("utf-16-le")), ("empty", "")):
        junk = await h.connect()
        await junk.ws.send(payload)
        m, _ = await junk.until(lambda m: is_text(m, "error"), 10)
        if not (error_of(m) == ("message", "Invalid control message") and await junk.expect_closed() is not None):
            refused.append((label, error_of(m)))
    check("control: what JSONSerialization refuses (1e999, lone surrogates, objects deeper than 512, arrays deeper than 513) -> "
          "'Invalid control message' then close; so do -1e999, UTF-16 and empty messages (stricter than the host)", not refused, refused)
    template = '{"type":"ping","time":8,"n":' + "[" * 512 + "]" * 512 + ',"o":' + '{"o":' * 510 + "{}" + "}" * 510 + ',"pad":"%s"}'
    await main.ws.send(template % ("a" * (65536 - len(template % ""))))
    m, _ = await main.until(lambda m: is_text(m, "pong"), 6)
    check("control: exactly 65536 bytes with arrays to depth 513 and objects to 512 is accepted (the host's limits)", m["obj"].get("time") == 8, m["obj"])
    junk = await h.connect()
    await junk.ws.send(template % ("a" * (65537 - len(template % ""))))
    exc = await junk.expect_closed()
    check("control: 65537 bytes -> close frame 1009 and no error message (NWProtocolWebSocket's size limit)",
          exc.rcvd is not None and exc.rcvd.code == 1009 and not [x for x in junk.seen if is_text(x)], (repr(exc), summary(junk.seen)))

    m, _ = await main.until(lambda m: is_text(m, "stats"), 6, "stats")
    fields = {"bytesSent", "fps", "streamingDisplays", "audio", "quality", "resolution", "encodedInputs", "framesSkippedBackpressure",
              "pendingImageBytes", "inFlightFrames", "meanEncodeMs", "meanRasterMs", "meanQuantizeMs", "meanDiffMs", "meanCodecMs"}
    check("stats: every host field; resolution fhd and no streaming displays before the first subscribe",
          fields <= set(m["obj"]) and m["obj"]["resolution"] == "fhd" and m["obj"]["streamingDisplays"] == [], m["obj"])
    await main.send(type="ping", time=12345)
    m, _ = await main.until(lambda m: is_text(m, "pong"), 6)
    check("pong: echoes time", m["obj"].get("time") == 12345, m["obj"])
    await main.send(type="ping")
    m, _ = await main.until(lambda m: is_text(m, "pong"), 6)
    check("pong: time defaults to 0", m["obj"].get("time") == 0, m["obj"])
    await main.ws.send(json.dumps({"type": "ping", "time": 7}).encode())
    m, _ = await main.until(lambda m: is_text(m, "pong"), 6)
    check("control: JSON in a binary frame is parsed like text (host behaviour)", m["obj"].get("time") == 7)
    await main.send(type="teleport")
    m, _ = await main.until(lambda m: is_text(m, "error"), 6)
    check("control: unknown type after auth -> 'Unknown message type'", error_of(m) == ("message", "Unknown message type"), error_of(m))

    cases = [
        ("unknown display", dict(displays=["nope"]), SUB_ERROR), ("duplicate ids", dict(displays=["fixture-1", "fixture-1"]), SUB_ERROR),
        ("portrait box", dict(maxWidth=720, maxHeight=1280), SUB_ERROR), ("non-preset box", dict(maxWidth=1000, maxHeight=700), SUB_ERROR),
        ("color", dict(color="rgb888"), SUB_ERROR), ("quality", dict(quality="fast"), SUB_ERROR), ("fps 0", dict(fps=0), SUB_ERROR),
        ("fps 61", dict(fps=61), SUB_ERROR), ("bandwidth 50", dict(bandwidthKbps=50), SUB_ERROR),
        ("bandwidth 100001", dict(bandwidthKbps=100001), SUB_ERROR), ("missing fps", dict(fps=None), SUB_ERROR),
        ("negative revision", dict(revision=-1), SUB_ERROR), ("17th id", dict(displays=["fixture-1"] * 17), SUB_ERROR),
        ("regions not a map", dict(regions=[]), REGION_MAP_ERROR),
        ("region value not numeric", dict(regions={"fixture-1": {"x": "0", "y": 0, "width": 1, "height": 1}}), REGION_MAP_ERROR),
        ("region for an unselected display", dict(regions={"fixture-2": {"x": 0, "y": 0, "width": 1, "height": 1}}), REGION_ERROR),
        ("region past the edge", dict(regions={"fixture-1": {"x": 0.5, "y": 0, "width": 0.6, "height": 1}}), REGION_ERROR),
        ("region width without height", dict(regions={"fixture-1": {"x": 0, "y": 0, "width": 0.5, "height": 0}}), REGION_ERROR),
        ("region missing y", dict(regions={"fixture-1": {"x": 0, "width": 1, "height": 1}}), REGION_ERROR),
        ("region x 2^60 (an exact Double)", dict(regions={"fixture-1": {"x": 2 ** 60, "y": 0, "width": 0, "height": 0}}), REGION_ERROR),
        ("audio bitrate", dict(audioBitrate=64000), AUDIO_QUALITY_ERROR), ("audio codec", dict(audioCodec="opus"), AUDIO_QUALITY_ERROR),
    ]
    wrong = []
    for label, change, expected in cases:
        change = dict(change)
        reply, _ = await main.subscribe(change.pop("revision", 1), change.pop("displays", ["fixture-1"]), **change)
        if (reply.get("type"), reply.get("code"), reply.get("message")) != ("error", "subscription", expected):
            wrong.append((label, reply))
    check(f"subscription: {len(cases)} invalid requests rejected with the host's exact error texts", not wrong, wrong)

    reply, _ = await main.subscribe(1, ["fixture-1", "fixture-2"])
    check("subscription: rejections left revision 1 unconsumed", reply.get("type") == "subscribed", reply)
    check("subscribed: exact host shape (HD canvases, mulaw/192000 defaults, resolution, no notice)",
          reply == {"type": "subscribed", "revision": 1, "displays": [{"id": "fixture-1", "width": 1280, "height": 720},
                                                                        {"id": "fixture-2", "width": 1280, "height": 720}],
                    "paused": False, "audio": False, "audioCodec": "mulaw", "audioBitrate": 192000, "resolution": "hd"}, reply)
    reply, _ = await main.subscribe(1, ["fixture-1"])
    check("subscription: revisions must strictly increase", reply.get("type") == "error" and reply.get("message") == SUB_ERROR, reply)
    keys, seen = await keyframes(main, 1, ["fixture-1", "fixture-2"])
    ok = all((k["header"]["x"], k["header"]["y"], k["header"]["width"], k["header"]["height"], k["header"]["codec"]) == (0, 0, 1280, 720, "png")
             and (png_info(k["payload"])["depth"], png_info(k["payload"])["ctype"]) == (8, 2) for k in keys.values())
    check("frames: one full-canvas keyframe per selected display after subscribed (RGB PNG, IHDR 8/2)", ok,
          [k["header"] for k in keys.values()])
    im = decode(keys["fixture-1"]["payload"])
    check("frames: keyframe pixels are the synthetic scene", im.getpixel((640, 360)) == (51, 204, 166) and im.getpixel((5, 100)) == (23, 41, 61),
          (im.getpixel((640, 360)), im.getpixel((5, 100))))
    tiles = [m for m in frames(seen, 1) if all(m is not k for k in keys.values())]
    tiles_ok = bool(tiles) and all(hd["width"] <= 256 and hd["height"] <= 256 and hd["x"] % 256 == 0 and hd["y"] % 256 == 0
                                   and hd["x"] + hd["width"] <= 1280 and hd["y"] + hd["height"] <= 720
                                   and decode(m["payload"]).size == (hd["width"], hd["height"]) and png_info(m["payload"])["ctype"] == 2
                                   for m in tiles for hd in [m["header"]])
    check("frames: then small changing 256-grid tiles that decode to their header size", tiles_ok, [m["header"] for m in tiles[:4]])
    check("frames: canvasWidth/canvasHeight match the subscribed canvas", all((m["header"]["canvasWidth"], m["header"]["canvasHeight"]) == (1280, 720) for m in frames(seen)))

    await main.subscribe(2, ["fixture-1"], color="color256")
    keys, seen = await keyframes(main, 2, ["fixture-1"], 1.0)
    info, im = png_info(keys["fixture-1"]["payload"]), decode(keys["fixture-1"]["payload"])
    check("color256: indexed PNG, IHDR 8/3, PLTE = host palette", (info["depth"], info["ctype"]) == (8, 3) and info["plte"] == PALETTE, (info["depth"], info["ctype"]))
    check("color256: index = (r>>5)<<5 | (g>>5)<<2 | (b>>6)", im.mode == "P" and im.getpixel((640, 360)) == 58, (im.mode, im.getpixel((640, 360))))
    tile_info = [png_info(m["payload"]) for m in frames(seen, 2) if m is not keys["fixture-1"]]
    check("color256: tiles are 8-bit indexed PNG too", tile_info and all((i["depth"], i["ctype"]) == (8, 3) for i in tile_info), len(tile_info))
    await main.subscribe(3, ["fixture-1"], color="gray16")
    keys, seen = await keyframes(main, 3, ["fixture-1"], 1.0)
    info, im = png_info(keys["fixture-1"]["payload"]), decode(keys["fixture-1"]["payload"])
    check("gray16: 4-bit grayscale PNG, IHDR 4/0", (info["depth"], info["ctype"]) == (4, 0), (info["depth"], info["ctype"]))
    check("gray16: host luminance (77R+150G+29B+128)>>8 / 17, 16 shades",
          im.getpixel((640, 360)) == 153 and all(v % 17 == 0 for _, v in im.getcolors(4096)), (im.mode, im.getpixel((640, 360))))
    tile_info = [png_info(m["payload"]) for m in frames(seen, 3) if m is not keys["fixture-1"]]
    check("gray16: tiles are 4-bit grayscale PNG too", tile_info and all((i["depth"], i["ctype"]) == (4, 0) for i in tile_info), len(tile_info))
    await main.subscribe(4, ["fixture-1"], quality="motion")
    keys, seen = await keyframes(main, 4, ["fixture-1"], 1.0)
    later = frames(seen, 4)
    check("motion + full color: JPEG of the whole visible area every changed frame",
          len(later) >= 2 and all(m["header"]["codec"] == "jpeg" and m["payload"][:2] == b"\xff\xd8"
                                  and (m["header"]["x"], m["header"]["y"], m["header"]["width"], m["header"]["height"]) == (0, 0, 1280, 720) for m in later),
          [m["header"] for m in later[:3]])
    await main.subscribe(5, ["fixture-1"], color="rgb565")
    keys, seen = await keyframes(main, 5, ["fixture-1"], 0.3)
    im = decode(keys["fixture-1"]["payload"]).convert("RGB")
    rb, g6 = {n * 255 // 31 for n in range(32)}, {n * 255 // 63 for n in range(64)}
    check("rgb565: RGB PNG with 565-quantized values", all(r in rb and g in g6 and b in rb for _, (r, g, b) in im.getcolors(65536)))

    reply, _ = await main.subscribe(6, ["fixture-2"], regions={"fixture-2": {"x": .25, "y": .25, "width": .25, "height": .25}})
    keys, seen = await keyframes(main, 6, ["fixture-2"], 1.0)
    hd = keys["fixture-2"]["header"]
    check("region: keyframe is the visible rect in full-canvas coordinates, canvas unchanged",
          (hd["x"], hd["y"], hd["width"], hd["height"], hd["canvasWidth"], hd["canvasHeight"]) == (320, 180, 320, 180, 1280, 720)
          and reply["displays"] == [{"id": "fixture-2", "width": 1280, "height": 720}], hd)
    check("region: nothing more while changes stay outside the region", len(frames(seen, 6)) == 1, summary(seen))
    region = (0.1, 0.13, 0.3, 0.37)
    await main.subscribe(7, ["fixture-2"], regions={"fixture-2": dict(zip(("x", "y", "width", "height"), region))})
    keys, _ = await keyframes(main, 7, ["fixture-2"], 0)
    hd = keys["fixture-2"]["header"]
    check("region: non-integral edges crop to the integral rect (floor origin, ceil max)",
          (hd["x"], hd["y"], hd["width"], hd["height"]) == expected_crop(region, 1280, 720), (hd, expected_crop(region, 1280, 720)))
    reply, _ = await main.subscribe(8, ["fixture-1", "fixture-2"], regions={"fixture-1": ZERO, "fixture-2": ZERO})
    seen = await main.gather(1.3)
    check("zero regions: subscribed keeps full canvases but no image data is sent",
          [d["width"] for d in reply["displays"]] == [1280, 1280] and not frames(seen, 8), summary(seen))
    await main.subscribe(9, ["fixture-1"], paused=True)
    seen = await main.gather(1.4)
    stats = [m["obj"] for m in seen if is_text(m, "stats")]
    check("paused: no image data", not frames(seen, 9), summary(seen))
    check("paused: stats report no streaming displays", bool(stats) and all(s["streamingDisplays"] == [] for s in stats), stats)

    await main.send(type="pointer", display="fixture-1", x=0.5, y=0.5, buttons=1)
    await main.subscribe(10, ["fixture-1"], viewOnly=True)
    await main.send(type="key", key=0xff0d, down=True)
    await main.subscribe(11, ["fixture-1"], paused=0)
    await main.send(type="pointer", display="fixture-1", x=0.25, y=0.75, buttons=1)
    await main.send(type="key", key=0xffe3, down=True)
    await main.send(type="text", text="héllo")
    await main.send(type="wheel", display="fixture-1", x=0.5, y=0.5, dx=0, dy=-1.5)
    # Boundaries of the host's input rules (Server.swift handleInput/inputKeysym); the mask stays 1 for the release check.
    await main.send(type="text", text="a" * 4096)
    await main.send(type="text", text="é" * 2049)
    await main.send(type="pointer", display="fixture-1", x=1, y=0.75, buttons=1)
    await main.send(type="pointer", display="fixture-1", x=1.0001, y=0.75, buttons=1)
    await main.send(type="pointer", display="fixture-1", x=0.25, y=0.75, buttons=8)
    await main.send(type="key", key=0x61)
    await main.send(type="key", key=0x110000, down=True)
    await main.send(type="key", key=-1, down=True)
    await main.send(type="wheel", display="fixture-1", x=0.5, y=0.5, dx=0)
    await main.send(type="pointer", display="fixture-9", x=0.5, y=0.5, buttons=0)
    await main.subscribe(12, ["fixture-1"])
    await main.send(type="pointer", display="fixture-1", x=0.3, y=0.3, buttons=0)
    await main.subscribe(13, [])
    await main.send(type="text", text="x")
    reply, _ = await main.subscribe(14, ["fixture-1"], audio=True, audioCodec="aac")
    seen = await main.gather(0.6)
    check("no --audio: audio requests are acknowledged as off and no audio is sent (fixture behaviour)",
          reply.get("audio") is False and not [m for m in seen if m["kind"] == "audio"], reply)
    await main.send(type="ping", time=99)
    await main.until(lambda m: is_text(m, "pong") and m["obj"].get("time") == 99, 6)
    seqs = [m["header"]["sequence"] for m in main.seen if m["kind"] == "frame"]
    check("sequence: frame sequences are unique and increase within the session", seqs == sorted(set(seqs)), seqs[:20])
    await main.close()
    await h.stop()

    records = h.records()
    raw = h.transcript.read_text()
    inputs = [(r["type"], r.get("accepted"), r.get("reason")) for r in records if r.get("dir") == "in" and r.get("type") in ("pointer", "key", "text", "wheel")]
    expected = [("pointer", False, "paused"), ("key", False, "viewOnly"), ("pointer", True, None), ("key", True, None), ("text", True, None),
                ("wheel", True, None), ("text", True, None), ("text", False, "invalid"), ("pointer", True, None), ("pointer", False, "invalid"),
                ("pointer", False, "invalid"), ("key", False, "invalid"), ("key", False, "invalid"), ("key", False, "invalid"),
                ("wheel", False, "invalid"), ("pointer", False, "invalid"), ("pointer", True, None), ("text", False, "noDisplays")]
    check("transcript: input recorded with whether the host would accept it (paused/viewOnly/invalid/noDisplays), "
          "at the host's bounds (text 4096 UTF-8 bytes, x in [0,1], mask 0-7, required key/down/dy, keysyms that are Unicode scalars)",
          inputs == expected, inputs)
    pointer = next(r for r in records if r.get("type") == "pointer" and r.get("accepted"))
    wheel = next(r for r in records if r.get("type") == "wheel")
    check("transcript: pointer button transitions and wheel pixel accumulation", pointer.get("transitions") == ["down:left"] and wheel.get("pixels") == [0, -18], (pointer, wheel))
    released = [r for r in records if r.get("event") == "inputReleased"]
    check("transcript: an accepted subscription releases held input (host releaseAll)",
          any(r.get("buttons") == 1 and 0xffe3 in r.get("keys", []) for r in released), released)
    hellos = [r for r in records if r.get("type") == "hello"]
    check("transcript: hello passwords redacted; no password text anywhere in the file",
          len(hellos) >= 4 and all(r["message"].get("password") == "<redacted>" for r in hellos if "password" in r["message"])
          and PASSWORD not in raw and WRONG not in raw, len(hellos))
    acks = [r for r in records if r.get("type") == "frameAck"]
    check("transcript: frameAcks recorded with their sequence, revision and display", acks and all(isinstance(r.get("sequence"), int) and r.get("known") is True and "revision" in r for r in acks), acks[:2])
    check("transcript: monotonic timestamps", all(isinstance(r.get("t"), float) for r in records) and [r["t"] for r in records] == sorted(r["t"] for r in records))
    warn = next((r for r in records if r.get("type") == "subscribe" and r.get("message", {}).get("revision") == 11), {})
    check("transcript: values that pass only through Swift NSNumber bridging are flagged", any("paused" in w for w in warn.get("typeWarnings", [])), warn)


async def group_topologies(shared):
    async def one(name, verify):
        async with host("--topology", name, data_dir=shared) as h:
            c = await h.connect()
            m = await c.hello()
            ds = m["obj"]["displays"]
            ok = len({d["id"] for d in ds}) == len(ds) and all(
                isinstance(d["id"], str) and isinstance(d["name"], str) and d["index"] == i + 1 and all(isinstance(d[k], int) for k in ("width", "height", "x", "y"))
                and all(isinstance(d[k], (int, float)) for k in ("logicalWidth", "logicalHeight", "scale"))
                and abs(d["scale"] - d["width"] / d["logicalWidth"]) < 1e-9 and d["primary"] == (i == 0) for i, d in enumerate(ds))
            check(f"topology {name}: welcome display fields, types, index and primary", ok, ds)
            await verify(c, ds)
            await c.close()

    def geo(ds):
        return [(d["width"], d["height"], d["x"], d["y"], d["logicalWidth"], d["logicalHeight"]) for d in ds]

    async def fixture3(c, ds):
        check("topology fixture3: identical to the real fixture", ds == FIXTURE3)

    async def mixed(c, ds):
        check("topology mixed: 5K (logical 1920x1080) at x 0 and 1080p at x 1920", geo(ds) == [(5120, 2880, 0, 0, 1920, 1080), (1920, 1080, 1920, 0, 1920, 1080)], geo(ds))
        reply, _ = await c.subscribe(1, [d["id"] for d in ds], maxWidth=3840, maxHeight=2160)
        check("topology mixed: UHD request limited to FHD with the host notice; equal 1920x1080 canvases",
              reply.get("resolution") == "fhd" and reply.get("notice") == "Resolution limited to FHD by the selected displays."
              and [(d["width"], d["height"]) for d in reply["displays"]] == [(1920, 1080), (1920, 1080)], reply)

    async def negative(c, ds):
        check("topology negative: 1440x900@2x at x -1440 and portrait 1080x1920 at (0,-300)",
              geo(ds) == [(2880, 1800, -1440, 0, 1440, 900), (1080, 1920, 0, -300, 1080, 1920)] and ds[0]["scale"] == 2, geo(ds))
        reply, _ = await c.subscribe(1, [d["id"] for d in ds])
        sizes = [(d["width"], d["height"]) for d in reply["displays"]]
        check("topology negative: HD canvases follow scaledSize (portrait box swapped)", sizes == [scaled(2880, 1800, (1280, 720)), scaled(1080, 1920, (1280, 720))], sizes)
        keys, _ = await keyframes(c, 1, [ds[1]["id"]], 0)
        k = keys[ds[1]["id"]]
        check("topology negative: portrait keyframe decodes at the portrait canvas size", decode(k["payload"]).size == sizes[1], k["header"])

    async def vertical(c, ds):
        check("topology vertical: two 1080p displays stacked, one at y -1080", geo(ds) == [(1920, 1080, 0, 0, 1920, 1080), (1920, 1080, 0, -1080, 1920, 1080)], geo(ds))

    async def many(c, ds):
        check("topology many: 17 displays advertised", len(ds) == 17)
        reply, _ = await c.subscribe(1, [d["id"] for d in ds])
        check("topology many: a 17-display subscription is rejected", reply.get("type") == "error" and reply.get("message") == SUB_ERROR, reply)
        reply, _ = await c.subscribe(1, [d["id"] for d in ds[:16]])
        check("topology many: 16 displays are accepted", reply.get("type") == "subscribed" and len(reply["displays"]) == 16, reply.get("type"))

    async def single(c, ds):
        reply, _ = await c.subscribe(1, [ds[0]["id"]])
        check("topology single: one 3024x1964 display; HD canvas truncated like scaledSize",
              len(ds) == 1 and [(d["width"], d["height"]) for d in reply["displays"]] == [scaled(3024, 1964, (1280, 720))], reply)

    async def subhd(c, ds):
        reply, _ = await c.subscribe(1, [d["id"] for d in ds], maxWidth=1920, maxHeight=1080)
        check("topology subhd: a sub-HD display makes the host answer resolution native with native canvases",
              reply.get("resolution") == "native" and [(d["width"], d["height"]) for d in reply["displays"]] == [(1024, 768), (1920, 1080)]
              and reply.get("notice") == "Resolution limited to NATIVE by the selected displays.", reply)

    await asyncio.gather(*(one(n, f) for n, f in (("fixture3", fixture3), ("mixed", mixed), ("negative", negative), ("vertical", vertical),
                                                   ("many", many), ("single", single), ("subhd", subhd))))


from websockets.protocol import State  # noqa: E402


async def group_busy(shared):
    async with host("--scenario", "busy", data_dir=shared) as h:
        c = await h.connect()
        m = await c.hello()
        check("scenario busy: every correct-password viewer gets busy", error_of(m) == ("busy", BUSY_ERROR), error_of(m))
        c = await h.connect()
        m = await c.hello(WRONG)
        check("scenario busy: a wrong password still gets the authentication error", error_of(m) == ("authentication", AUTH_ERROR), error_of(m))
    async with host("--scenario", "busy-first-N=2", data_dir=shared) as h:
        outcomes = []
        for _ in range(3):
            c = await h.connect()
            m = await c.hello()
            outcomes.append("welcome" if is_text(m, "welcome") else m["obj"].get("code"))
            await c.close()
        check("scenario busy-first-N=2: busy, busy, then welcome", outcomes == ["busy", "busy", "welcome"], outcomes)
    async with host("--scenario", "auth-fail", data_dir=shared) as h:
        c = await h.connect()
        m = await c.hello()
        check("scenario auth-fail: even the correct password is rejected", error_of(m) == ("authentication", AUTH_ERROR), error_of(m))


async def group_flow(shared):
    async with host("--inflight", "2", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        c.auto_ack = False
        await c.subscribe(1, ["fixture-1", "fixture-2", "fixture-3"])
        await c.until(lambda m: len(frames(c.seen, 1)) >= 2, 25, "two frames")
        await c.gather(2.0)
        held = frames(c.seen, 1)
        check("frameAck window: with --inflight 2 only two packets fly without ACKs", len(held) == 2, summary(c.seen))
        m, _ = await c.until(lambda m: is_text(m, "stats"), 6)
        check("stats: inFlightFrames reports the unacknowledged packets", m["obj"]["inFlightFrames"] == 2, m["obj"])
        await c.send(type="frameAck", sequence=held[0]["header"]["sequence"])
        more = await c.gather(2.5)
        check("frameAck window: one ACK releases exactly one more packet", len(frames(more, 1)) == 1, summary(more))
    async with host("--noise", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        c.auto_ack = False
        await c.subscribe(1, ["fixture-1", "fixture-2", "fixture-3"])
        first, _ = await c.until(lambda m: m["kind"] == "frame", 40, "noise keyframe")
        m, seen = await c.until(lambda m: is_text(m, "stats") and m["obj"]["inFlightFrames"] == 1
                                and m["obj"]["pendingImageBytes"] > len(first["raw"]) + 1024 * 1024, 40, "a queued second keyframe")
        check("2 MiB rule: a >1 MiB keyframe travels alone while the next one waits queued",
              len(first["raw"]) > 1024 * 1024 and not frames(seen), (len(first["raw"]), m["obj"], summary(seen)))
        await c.send(type="frameAck", sequence=first["header"]["sequence"])
        m, _ = await c.until(lambda m: m["kind"] == "frame", 30, "next keyframe")
        check("2 MiB rule: acknowledging it releases the next large keyframe", len(m["raw"]) > 1024 * 1024, len(m["raw"]))
    async with host("--ack-timeout", "1.5", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        c.auto_ack = False
        await c.subscribe(1, ["fixture-1"])
        m, _ = await c.until(lambda m: is_text(m, "error"), 25)
        check("ack timeout: unacknowledged images -> exact timeout error", error_of(m) == ("timeout", TIMEOUT_ERROR), error_of(m))
        check("ack timeout: the host then closes the session", await c.expect_closed() is not None)


async def group_audio(shared):
    cases = {c["bitrate"]: (c["channels"], base64.b64decode(c["cookie"]), [base64.b64decode(p) for p in c["packets"]])
             for c in json.loads(AAC_FIXTURES.read_text())}
    header_keys = {"type", "revision", "codec", "sampleRate", "channels", "sequence", "samples", "bitrate", "cookie"}
    async with host("--audio", "aac", data_dir=shared) as h:
        c = await h.connect()
        m = await c.hello()
        check("audio aac: welcome advertises ['mulaw', 'aac'] like a real host", m["obj"]["capabilities"]["audio"] == ["mulaw", "aac"], m["obj"]["capabilities"])
        reply, _ = await c.subscribe(1, ["fixture-1"], audio=True, audioCodec="aac", audioBitrate=96000)
        check("audio: subscribed acknowledges aac at 96000", (reply.get("audio"), reply.get("audioCodec"), reply.get("audioBitrate")) == (True, "aac", 96000), reply)
        await c.until(lambda m: len([x for x in c.seen if x["kind"] == "audio"]) >= 20, 25, "20 audio packets")
        _, cookie, packets = cases[96000]
        audio = [m for m in c.seen if m["kind"] == "audio"]
        check("audio: exact AAC headers (revision, codec, 48 kHz, 2 ch, 1024 samples, bitrate, fixture cookie)",
              all(set(hd) == header_keys and (hd["revision"], hd["codec"], hd["sampleRate"], hd["channels"], hd["samples"], hd["bitrate"]) == (1, "aac", 48000, 2, 1024, 96000)
                  and base64.b64decode(hd["cookie"]) == cookie and isinstance(hd["sequence"], int) for m in audio for hd in [m["header"]]), audio[0]["header"])
        await c.subscribe(2, ["fixture-1"], color="gray16", audio=True, audioCodec="aac", audioBitrate=96000)
        await c.until(lambda m: len([x for x in c.seen if x["kind"] == "audio" and x["header"]["revision"] == 2]) >= 15, 25, "rev-2 audio")
        audio = [m for m in c.seen if m["kind"] == "audio"]
        payloads = [m["payload"] for m in audio]
        check("audio: raw access units loop the fixture's 12 packets in order, uninterrupted by a video-only revision",
              payloads == [packets[k % 12] for k in range(len(payloads))], [len(p) for p in payloads[:26]])
        revs = [m["header"]["revision"] for m in audio]
        sub2 = next(i for i, m in enumerate(c.seen) if is_text(m, "subscribed") and m["obj"]["revision"] == 2)
        first2 = next(i for i, m in enumerate(c.seen) if m["kind"] == "audio" and m["header"]["revision"] == 2)
        check("audio: the preserved stream is restamped with the current revision, only after its subscribed",
              revs == sorted(revs) and set(revs) == {1, 2} and first2 > sub2, revs)
        await c.subscribe(3, ["fixture-1"], audio=True, audioCodec="aac", audioBitrate=48000)
        m, _ = await c.until(lambda m: m["kind"] == "audio" and m["header"]["revision"] == 3, 25)
        _, cookie48, packets48 = cases[48000]
        check("audio: a bitrate change restarts the stream (mono, 48k cookie, first access unit)",
              (m["header"]["channels"], m["header"]["bitrate"]) == (1, 48000) and base64.b64decode(m["header"]["cookie"]) == cookie48
              and m["payload"] == packets48[0], m["header"])
        await c.subscribe(4, ["fixture-1"], paused=True, audio=True, audioCodec="aac", audioBitrate=48000)
        seen = await c.gather(1.0)
        check("audio: paused with audio true keeps audio and sends no images (host allows audio-only pause)",
              any(m["kind"] == "audio" and m["header"]["revision"] == 4 for m in seen) and not frames(seen, 4), summary(seen))
        await c.subscribe(5, ["fixture-1"], audio=False)
        seen = await c.gather(1.0)
        check("audio: audio off stops audio right after subscribed", not [m for m in seen if m["kind"] == "audio"], summary(seen))
        reply, _ = await c.subscribe(6, ["fixture-1"], audio=True, audioCodec="mulaw")
        await c.until(lambda m: len([x for x in c.seen if x["kind"] == "audio" and x["header"]["revision"] == 6]) >= 10, 25, "mulaw audio")
        mu = [m for m in c.seen if m["kind"] == "audio" and m["header"]["revision"] == 6]
        check("audio: μ-law packets are 24 kHz mono 480-byte tone packets; subscribed reports 192000",
              reply.get("audioBitrate") == 192000 and len(set(mu[0]["payload"])) > 16 and all(
                  set(hd) == header_keys - {"bitrate", "cookie"} and (hd["codec"], hd["sampleRate"], hd["channels"], hd["samples"]) == ("mulaw", 24000, 1, 480)
                  and len(m["payload"]) == 480 for m in mu for hd in [m["header"]]), mu[0]["header"])
        sa = [m["header"]["sequence"] for m in c.seen if m["kind"] == "audio"]
        sf = [m["header"]["sequence"] for m in c.seen if m["kind"] == "frame"]
        check("sequence: audio and images share one session-wide counter (unique, interleaved)",
              len(set(sa + sf)) == len(sa + sf) and sf and min(sa) < max(sf) and min(sf) < max(sa), (sa[:5], sf[:5]))
    async with host("--audio", "mulaw", data_dir=shared) as h:
        c = await h.connect()
        m = await c.hello()
        check("audio mulaw: welcome advertises only ['mulaw']", m["obj"]["capabilities"]["audio"] == ["mulaw"], m["obj"]["capabilities"])
        reply, _ = await c.subscribe(1, ["fixture-1"], audio=True, audioCodec="aac")
        check("audio mulaw-only host: an AAC request gets the host's compressed-audio capture error",
              (reply.get("type"), reply.get("code"), reply.get("message")) == ("error", "capture", AAC_INIT_ERROR), reply)
        reply, _ = await c.subscribe(1, ["fixture-1"], audio=True, audioCodec="mulaw")
        check("audio mulaw-only host: the rejected revision was not consumed", reply.get("type") == "subscribed" and reply.get("audio") is True, reply)


async def group_stale(shared):
    async with host("--scenario", "stale-burst", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        await c.subscribe(1, ["fixture-1"])
        await keyframes(c, 1, ["fixture-1"], 0.6)
        await c.subscribe(2, ["fixture-2"])
        sub_at = c.seen[-1]["at"]
        seen = await c.gather(2.0)
        stale = frames(seen, 1)
        check("stale-burst: previous-revision frames keep arriving after the new subscribed", bool(stale), summary(seen))
        check("stale-burst: they carry the previous display and canvas",
              bool(stale) and all(m["header"]["display"] == "fixture-1" and (m["header"]["canvasWidth"], m["header"]["canvasHeight"]) == (1280, 720) for m in stale))
        check("stale-burst: the burst ends (~300 ms) while the new revision streams",
              all(m["at"] - sub_at < 1.2 for m in stale) and bool(frames(seen, 2)), [round(m["at"] - sub_at, 3) for m in stale])


async def group_scenarios(shared):
    async with host("--scenario", "drop-after=1.5", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        await c.subscribe(1, ["fixture-1"])
        exc = await c.expect_closed(15)
        check("drop-after: the TCP connection drops without a WebSocket close frame", exc.rcvd is None, repr(exc))
    async with host("--scenario", "close-after-welcome", data_dir=shared) as h:
        c = await h.connect()
        m = await c.hello()
        exc = await c.expect_closed()
        check("close-after-welcome: welcome then a close without a close frame (NWConnection.cancel style)", is_text(m, "welcome") and exc.rcvd is None, repr(exc))
    async with host("--scenario", "close-after-welcome", "--close-style", "websocket", data_dir=shared) as h:
        c = await h.connect()
        m = await c.hello()
        exc = await c.expect_closed()
        check("--close-style websocket: the host sends close frame 1000", exc.rcvd is not None and exc.rcvd.code == 1000, repr(exc))
    async with host("--scenario", "stall-after=1", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        await c.subscribe(1, ["fixture-1"])
        await c.gather(2.0)
        await c.send(type="ping", time=5)
        waiter = await c.ws.ping()
        seen = await c.gather(2.5)
        check("stall-after: nothing is sent after the stall (no frames, stats or pong)", not seen, summary(seen))
        check("stall-after: WebSocket pings go unanswered while the socket stays open", not waiter.done() and c.ws.state is State.OPEN)
    async with host("--scenario", "no-welcome", data_dir=shared) as h:
        c = await h.connect()
        await c.send(type="hello", version=1, password=PASSWORD)
        seen = await c.gather(2.0)
        check("no-welcome: authenticated but silent, socket open", not seen and c.ws.state is State.OPEN, summary(seen))
    async with host("--scenario", "topology-change-after=1.5", data_dir=shared) as h:
        c = await h.connect()
        w = (await c.hello())["obj"]
        await c.subscribe(1, ["fixture-1", "fixture-2", "fixture-3"])
        m, _ = await c.until(lambda m: is_text(m, "displays"), 15, "displays message")
        err = await c.next(5)
        check("topology-change-after: a displays message shaped like welcome (same sessionId), then the topology error",
              set(m["obj"]) == set(w) and m["obj"]["sessionId"] == w["sessionId"] and [d["id"] for d in m["obj"]["displays"]] == ["fixture-1", "fixture-2"]
              and error_of(err) == ("topology", TOPOLOGY_ERROR), (m["obj"].get("displays"), error_of(err)))
        seen = await c.gather(1.0)
        check("topology-change-after: no image data until the viewer resubscribes", not frames(seen), summary(seen))
        reply, _ = await c.subscribe(1, ["fixture-1"])
        check("topology-change-after: the revision counter is not reset", reply.get("type") == "error", reply)
        reply, _ = await c.subscribe(2, ["fixture-3"])
        check("topology-change-after: removed display IDs are rejected", reply.get("type") == "error", reply)
        reply, _ = await c.subscribe(2, ["fixture-1", "fixture-2"])
        keys, _ = await keyframes(c, 2, ["fixture-1", "fixture-2"], 0)
        check("topology-change-after: a higher-revision resubscribe is accepted and streams", reply.get("type") == "subscribed" and len(keys) == 2, reply)
    async with host("--scenario", "capture-error-after=1:denied:retry=1.5", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        await c.subscribe(1, ["fixture-1"])
        m, _ = await c.until(lambda m: is_text(m, "error"), 15)
        check("capture-error-after: capture error with the host's permission-denied text",
              m["obj"].get("code") == "capture" and m["obj"].get("message", "").startswith("macOS denied screen capture.") and "Restart Host" in m["obj"]["message"], m["obj"])
        seen = await c.gather(0.9)
        check("capture-error-after: images stop after the capture error", not frames(seen), summary(seen))
        f, seen = await c.until(lambda m: m["kind"] == "frame", 15, "frames after retry")
        check("capture retry: capture restarts on the same revision with a fresh keyframe and no new subscribed",
              f["header"]["revision"] == 1 and (f["header"]["width"], f["header"]["height"]) == (1280, 720) and not any(is_text(x, "subscribed") for x in seen), f["header"])
    async with host("--scenario", "capture-error-after=0.5", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        await c.subscribe(1, ["fixture-1"])
        m, _ = await c.until(lambda m: is_text(m, "error"), 15)
        msg = m["obj"].get("message", "")
        check("capture-error-after: generic ScreenCaptureKit failure text", m["obj"].get("code") == "capture" and msg.startswith("Screen capture failed: ")
              and msg.endswith("Open Permissions on the host Mac and choose Check Again to test capture."), msg)
    async with host("--scenario", "reject-subscriptions-from=2", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        r1, _ = await c.subscribe(1, ["fixture-1"])
        r2, _ = await c.subscribe(2, ["fixture-1"])
        r3, _ = await c.subscribe(3, ["fixture-2"])
        check("reject-subscriptions-from=2: revision 1 accepted, later revisions get the subscription error",
              r1.get("type") == "subscribed" and all((r.get("type"), r.get("code"), r.get("message")) == ("error", "subscription", SUB_ERROR) for r in (r2, r3)), (r1, r2, r3))
    async with host(data_dir=shared) as h:
        for _ in range(10):
            c = await h.connect()
            await c.hello(WRONG)
            await c.close()
        try:
            c = await h.connect()
            refused = False
            await c.close()
        except AssertionError:
            raise
        except Exception:  # noqa: BLE001 - any TLS/connection failure is the expected refusal
            refused = True
        check("lockout: after 10 failures within 60 s the host refuses new connections during TLS", refused)


async def group_anomalies(shared):
    names = ["future-revision", "canvas-mismatch", "size-mismatch", "bad-codec", "bad-json", "deep-json", "binary-short",
             "header-overflow", "non-object", "bad-header-json", "cursor"]
    async with host(*[a for n in names for a in ("--scenario", n)], "--anomaly-delay", "0.3", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        await c.subscribe(1, ["fixture-1"])
        seen = await c.gather(3.0)
        fr = frames(seen)
        check("anomaly future-revision: exactly one frame stamped revision + 1", sum(m["header"]["revision"] == 2 for m in fr) == 1, summary(seen))
        check("anomaly canvas-mismatch: one frame whose canvasWidth differs from subscribed", sum(m["header"]["canvasWidth"] != 1280 for m in fr) == 1)
        check("anomaly size-mismatch: header width differs from the encoded PNG",
              sum(m["header"]["codec"] == "png" and png_info(m["payload"])["width"] != m["header"]["width"] for m in fr) == 1)
        check("anomaly bad-codec: one frame with an unsupported codec label", sum(m["header"]["codec"] not in ("png", "jpeg") for m in fr) == 1)
        check("anomaly bad-json: one malformed JSON text message", sum(m["kind"] == "badtext" for m in seen) == 1)
        check("anomaly deep-json: one text message nested 100 levels", sum(is_text(m) and depth(m["obj"]) > 64 for m in seen) == 1)
        check("anomaly binary-short: one binary message shorter than 5 bytes", sum(m["kind"] == "short" for m in seen) == 1)
        check("anomaly header-overflow: header length beyond the message", sum(m["kind"] == "overflow" for m in seen) == 1)
        check("anomaly non-object: one JSON text message that is not an object", sum(m["kind"] == "nonobject" for m in seen) == 1)
        check("anomaly bad-header-json: one binary envelope with an unparseable header", sum(m["kind"] == "badheader" for m in seen) == 1)
        cursors = [m["obj"] for m in seen if is_text(m, "cursor")]
        check("cursor: normalized cursor messages for a selected display, only on change",
              len(cursors) >= 5 and all(set(o) == {"type", "display", "x", "y"} and o["display"] == "fixture-1" and 0 <= o["x"] < 1 and 0 <= o["y"] < 1 for o in cursors)
              and all(a != b for a, b in zip(cursors, cursors[1:])), cursors[:3])
    async with host("--scenario", "invalid-utf8", data_dir=shared) as h:
        c = await h.connect()
        await c.hello()
        await c.subscribe(1, ["fixture-1"])
        exc = await c.expect_closed(15)
        check("anomaly invalid-utf8: a text frame with invalid UTF-8 (client fails the connection with 1007)",
              exc.sent is not None and exc.sent.code == 1007, repr(exc))


async def group_lifecycle(shared):
    h = host(transcript=True)
    await h.start()
    data_dir = next((r.get("dataDir") for r in h.records() if r.get("event") == "listening"), None)
    existed = bool(data_dir) and Path(data_dir, "certificate.pem").is_file()
    started = time.monotonic()
    code = await h.stop()
    elapsed = time.monotonic() - started
    check("SIGTERM: exit 0 promptly, prints Stopped, removes its temporary data dir",
          code == 0 and existed and not Path(data_dir).exists() and "Stopped" in h.tail and elapsed < 8, (code, data_dir, round(elapsed, 2)))
    h = host(data_dir=shared)
    await h.start()
    c = await h.connect()
    await c.hello()
    await c.subscribe(1, ["fixture-1"])
    code = await h.stop()
    exc = await c.expect_closed(8)
    check("SIGTERM with a live session: exit 0 and the session is closed", code == 0 and exc is not None, code)
    r = await asyncio.to_thread(subprocess.run, [sys.executable, str(MOCK), "--password-stdin"], input="short\n",
                                capture_output=True, text=True, timeout=90)
    check("startup: a password outside 8-1024 bytes fails like the host (exit 1)",
          r.returncode == 1 and "Choose a password between 8 and 1024 characters." in r.stderr, (r.returncode, r.stderr[-300:]))
    # Safe even if the guard regressed: the short password stops startup before anything binds (exit 1, not 2).
    r = await asyncio.to_thread(subprocess.run, [sys.executable, str(MOCK), "--port", "5920", "--password-stdin"], input="short\n",
                                capture_output=True, text=True, timeout=90)
    check("startup: --port 5920 (the live host port) is refused before anything binds (exit 2)",
          r.returncode == 2 and "5920" in r.stderr, (r.returncode, r.stderr[-300:]))
    r = await asyncio.to_thread(subprocess.run, [sys.executable, str(MOCK), "--scenario", "nonsense"], capture_output=True, text=True, timeout=90)
    check("startup: an unknown scenario is a usage error (exit 2)", r.returncode == 2, r.stderr[-200:])


GROUPS = [("core", group_core), ("topologies", group_topologies), ("busy", group_busy), ("flow", group_flow), ("audio", group_audio),
          ("stale", group_stale), ("scenarios", group_scenarios), ("anomalies", group_anomalies), ("lifecycle", group_lifecycle)]


async def run(args):
    shared = Path(tempfile.mkdtemp(prefix="mock-host-selftest-identity-"))
    timings = {}
    started = time.monotonic()
    try:
        selected = [(n, f) for n, f in GROUPS if not args.only or n in args.only]
        if selected and selected[0][0] != "core":
            bootstrap = host(data_dir=shared)  # create the shared identity once before parallel groups
            await bootstrap.start()
            await bootstrap.stop()
        for name, fn in selected:
            t = time.monotonic()
            try:
                await asyncio.wait_for(fn(shared), GROUP_TIMEOUT)
            except Exception as exc:  # noqa: BLE001
                R.failed.append({"check": f"{name}: group aborted", "detail": "".join(traceback.format_exception(exc))[-2000:]})
            timings[name] = round(time.monotonic() - t, 1)
    finally:
        for h in HOSTS:
            if h.proc is not None:
                await h.stop()
            if not args.keep:
                h.cleanup()
        shutil.rmtree(shared, ignore_errors=True)
    bad = [s for s in R.stops if s["code"] != 0 or not s["stopped"]]
    check(f"shutdown: every mock-host process ({len(R.stops)}) exited 0 on SIGTERM and printed Stopped", bool(R.stops) and not bad, bad)
    return timings, time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(description="Self-test for scripts/mock-host.py")
    parser.add_argument("--only", nargs="*", choices=[n for n, _ in GROUPS], help="run only these groups")
    parser.add_argument("--keep", action="store_true", help="keep per-host temp dirs (transcripts, stderr logs)")
    args = parser.parse_args()
    timings, seconds = asyncio.run(run(args))
    ok = not R.failed
    print(json.dumps({"ok": ok, "passed": len(R.passed), "failed": len(R.failed), "checks": R.passed, "failures": R.failed,
                      "hostProcesses": len(R.stops), "groupSeconds": timings, "seconds": round(seconds, 1)}, indent=2, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
