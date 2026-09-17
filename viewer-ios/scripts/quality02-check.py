#!/usr/bin/env python3
"""QUALITY-02 host-side evidence: "Smooth gradients" (host dither) changes nothing in Text mode and only
takes effect for Video with reduced color. The viewer side (dither is sent only for Video + reduced color,
off by default) is covered by PortlightKit unit tests.

Run against an ISOLATED fixture host only:
  eval "$(scripts/fixture-host start)"
  ../.test-venv/bin/python scripts/quality02-check.py
  scripts/fixture-host stop "$PORTLIGHT_FIXTURE_STATE"
Trust is pinned to PORTLIGHT_FIXTURE_FINGERPRINT (SHA-256 of the leaf DER), like the app."""
import asyncio, hashlib, io, json, os, ssl, struct, sys, time

import websockets
from PIL import Image


async def receive(ws, timeout=5.0):
    packet = await asyncio.wait_for(ws.recv(), timeout)
    if isinstance(packet, str):
        return json.loads(packet), None
    length = struct.unpack(">I", packet[:4])[0]
    return json.loads(packet[4:4 + length]), packet[4 + length:]


async def palette_after_subscribe(ws, revision, request, seconds):
    """Distinct RGB colors seen in this revision's frames (every frame is ACKed so the host keeps sending)."""
    await ws.send(json.dumps(dict(request, type="subscribe", revision=revision)))
    colors, frames, end = set(), 0, None
    while end is None or time.monotonic() < end:
        header, payload = await receive(ws)
        if header.get("type") == "error":
            raise SystemExit(f"host rejected revision {revision}: {header}")
        if header.get("type") == "subscribed" and header.get("revision") == revision:
            end = time.monotonic() + seconds
        if header.get("type") != "frame":
            continue
        await ws.send(json.dumps({"type": "frameAck", "sequence": header["sequence"]}))
        if header.get("revision") != revision:
            continue
        frames += 1
        with Image.open(io.BytesIO(payload)) as image:
            colors.update(color for _, color in image.convert("RGB").getcolors(image.width * image.height))
    return colors, frames


async def main():
    host = os.environ.get("PORTLIGHT_FIXTURE_HOST", "127.0.0.1")
    port = int(os.environ["PORTLIGHT_FIXTURE_PORT"])
    password = os.environ.get("PORTLIGHT_FIXTURE_PASSWORD", "fixture-password")
    pin = os.environ["PORTLIGHT_FIXTURE_FINGERPRINT"].upper()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE  # replaced by the exact fingerprint check below, before any data is sent
    async with websockets.connect(f"wss://{host}:{port}/remote", ssl=tls, max_size=32 * 1024 * 1024) as ws:
        der = ws.transport.get_extra_info("ssl_object").getpeercert(binary_form=True)
        shown = ":".join(f"{b:02X}" for b in hashlib.sha256(der).digest())
        if shown != pin:
            raise SystemExit(f"certificate {shown} does not match the pinned fixture fingerprint")
        await ws.send(json.dumps({"type": "hello", "version": 1, "password": password, "codecs": ["png", "jpeg"]}))
        while True:
            welcome, _ = await receive(ws)
            if welcome.get("type") == "welcome":
                break
        display = welcome["displays"][0]["id"]
        base = dict(displays=[display], maxWidth=1280, maxHeight=720, color="color256", fps=10, bandwidthKbps=0,
                    paused=False, audio=False, audioCodec="aac", audioBitrate=96000, viewOnly=True, regions={})
        results, revision = {}, 0
        for quality in ("desktop", "motion"):
            for dither in (False, True):
                revision += 1
                colors, frames = await palette_after_subscribe(ws, revision, dict(base, quality=quality, dither=dither), 1.5)
                results[(quality, dither)] = (colors, frames)

    text_off, text_on = results[("desktop", False)][0], results[("desktop", True)][0]
    video_off, video_on = results[("motion", False)][0], results[("motion", True)][0]
    checks = {
        "text mode: identical color set with smoothing on and off": text_off == text_on,
        "video + 256 colors: smoothing adds dithered colors": len(video_on) > len(video_off),
        "every case received frames": all(frames > 0 for _, frames in results.values()),
    }
    print(json.dumps({
        "ok": all(checks.values()),
        "checks": checks,
        "distinctColors": {f"{q}/dither={d}": len(c) for (q, d), (c, _) in results.items()},
        "frames": {f"{q}/dither={d}": f for (q, d), (_, f) in results.items()},
    }, indent=2))
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    asyncio.run(main())
