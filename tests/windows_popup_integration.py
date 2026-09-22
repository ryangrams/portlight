#!/usr/bin/env python3
"""Test the native Windows popup composer over a disposable loopback TLS session."""

from __future__ import annotations

import argparse
import asyncio
import copy
import io
import json
import math
import os
from pathlib import Path
import struct
import tempfile
import time


TEXT = "Ready🎬Go"
RUN = dict(start=5, length=2, color="#FFB000", underline=True)
PASSWORD = "temporary-popup-fixture-password"
REPORT_FLAGS = (
    "composerOpened", "controlWithComposerOpen", "stickyAcknowledged",
    "bothTargetsAcknowledged", "targetSelectionAcknowledged", "lastTargetProtected",
    "clearAcknowledged", "timedAcknowledged", "timedExpired", "draftRetained",
    "revisionUnchanged", "viewingSelectionUnchanged", "visibleCanvasStable",
)
OPERATIONS = ["sticky", "both-targets", "first-target", "clear", "timed", "expired"]


def validate(observed, native):
    """Require both native UI evidence and independently observed wire traffic."""
    assert native.get("ok") is True, native
    assert all(native.get(flag) is True for flag in REPORT_FLAGS), native
    assert native.get("rejectedFrames") == 0, native
    assert native.get("durationMs", 0) >= 120000, native
    assert native.get("framesDecodedAfterMessaging", 0) >= 240, native
    assert native.get("maxDecodedFrameGapMs", 1500) < 1500, native
    assert native.get("visibleCanvasSamples", 0) >= 1200, native
    assert native.get("visibleCanvasMismatches") == 0, native
    assert native.get("maxVisibleSampleGapMs", 1500) < 1500, native
    assert observed["connections"] == observed["authenticated"] == 1, observed
    assert not observed["errors"], observed["errors"]
    cycles = native.get("cycles", 0)
    assert isinstance(cycles, int) and cycles >= 2, native
    assert observed["operations"] == OPERATIONS * cycles, observed
    assert observed["frozenSubscription"]["displays"] == ["fixture-1"], observed
    assert observed["targetsAtFreeze"] == ["fixture-2"], observed
    assert observed["subscriptionChangesAfterFreeze"] == 0, observed
    assert observed["pointerDown"] >= cycles and observed["pointerUp"] >= cycles, observed
    assert observed["wheel"] >= cycles, observed
    assert observed["keyDown"] >= cycles and observed["keyUp"] >= cycles, observed
    assert observed["texts"] == ["Z"] * cycles, observed
    assert observed["acksWhileComposerActive"] >= 240, observed
    assert observed["maxAckGapSeconds"] < 1.5, observed


def self_test():
    native = dict.fromkeys(REPORT_FLAGS, True)
    native.update(ok=True, rejectedFrames=0, framesDecoded=482, durationMs=120100,
                  framesDecodedAfterMessaging=480, maxDecodedFrameGapMs=250, cycles=2,
                  visibleCanvasSamples=4000, visibleCanvasMismatches=0, maxVisibleSampleGapMs=25)
    observed = dict(connections=1, authenticated=1, errors=[], operations=OPERATIONS * 2,
                    frozenSubscription=dict(revision=2, displays=["fixture-1"]),
                    targetsAtFreeze=["fixture-2"], subscriptionChangesAfterFreeze=0,
                    pointerDown=2, pointerUp=2, wheel=2, keyDown=2, keyUp=2,
                    texts=["Z", "Z"], acksWhileComposerActive=480, maxAckGapSeconds=0.25)
    validate(observed, native)
    cases = [(field, 0) for field in ("pointerDown", "pointerUp", "wheel", "keyDown", "keyUp")]
    cases += [("texts", []), ("texts", [TEXT, "Z"]), ("acksWhileComposerActive", 0),
              ("maxAckGapSeconds", 2), ("subscriptionChangesAfterFreeze", 1),
              ("targetsAtFreeze", ["fixture-1"]), ("operations", OPERATIONS[:-1]),
              ("errors", ["bad packet"])]
    for field, value in cases:
        broken = copy.deepcopy(observed)
        broken[field] = value
        try:
            validate(broken, native)
        except AssertionError:
            continue
        raise AssertionError(f"Fixture accepted a missing or invalid check: {field}")
    for flag in REPORT_FLAGS:
        broken = dict(native, **{flag: False})
        try:
            validate(observed, broken)
        except AssertionError:
            continue
        raise AssertionError(f"Fixture accepted a missing native check: {flag}")
    native_cases = [("visibleCanvasSamples", 1199), ("visibleCanvasMismatches", 1),
                    ("maxVisibleSampleGapMs", 1500), ("framesDecodedAfterMessaging", 239),
                    ("maxDecodedFrameGapMs", 1500), ("durationMs", 119999)]
    for field, value in native_cases:
        broken = dict(native, **{field: value})
        try:
            validate(observed, broken)
        except AssertionError:
            continue
        raise AssertionError(f"Fixture accepted an invalid native measurement: {field}")
    print(f"PASS: fixture assertions reject {len(cases)} wire failures and "
          f"{len(REPORT_FLAGS) + len(native_cases)} native failures")


async def run(viewer: Path, report_path: Path):
    from PIL import Image
    from websockets.asyncio.server import serve
    from websockets.exceptions import ConnectionClosed
    from windows_integration import certificate

    displays = [dict(id=f"fixture-{i}", name=f"Test Monitor {i}", index=i,
                     width=1920, height=1080, primary=i == 1, x=(i - 1) * 1920, y=0,
                     logicalWidth=1920, logicalHeight=1080) for i in range(1, 4)]
    known = {display["id"] for display in displays}
    observed = dict(connections=0, authenticated=0, errors=[], operations=[], subscriptions=[],
                    frozenSubscription=None, targetsAtFreeze=None,
                    subscriptionChangesAfterFreeze=0, pointerDown=0, pointerUp=0,
                    wheel=0, keyDown=0, keyUp=0, texts=[], framesSent=0, acks=0,
                    acksWhileComposerActive=0, maxAckGapSeconds=0.0)

    async def connection(ws):
        observed["connections"] += 1
        stream = expiry = None
        subscription = None
        targets = ["fixture-2"]
        active, duration, expires_at = False, 0, 0.0
        sequence, epoch = 0, 0
        acknowledgements = set()
        last_ack_at = None
        frozen_at = None

        def freeze():
            nonlocal frozen_at
            if observed["frozenSubscription"] is None:
                assert subscription and subscription["displays"] == ["fixture-1"], subscription
                observed["frozenSubscription"] = copy.deepcopy(subscription)
                observed["targetsAtFreeze"] = list(targets)
                frozen_at = time.monotonic()

        async def send_state():
            await ws.send(json.dumps(dict(type="popupMessageState", active=active,
                                          durationSeconds=duration, expiresAt=expires_at,
                                          displayIDs=targets, availableDisplays=displays)))

        async def expire():
            nonlocal active, duration, expires_at
            await asyncio.sleep(1)
            active, duration, expires_at = False, 0, 0.0
            observed["operations"].append("expired")
            await send_state()

        async def frames():
            nonlocal sequence
            seen_epoch = -1
            while True:
                await asyncio.sleep(0.25)
                current = subscription
                if not current or current.get("paused"):
                    continue
                width, height = min(1920, current["maxWidth"]), min(1080, current["maxHeight"])
                full = seen_epoch != epoch
                seen_epoch = epoch
                for display_id in current["displays"]:
                    tile_width, tile_height = (width, height) if full else (min(64, width), min(64, height))
                    encoded = io.BytesIO()
                    Image.new("RGB", (tile_width, tile_height),
                              (22, 70 + sequence % 150, 130)).save(encoded, format="PNG")
                    sequence += 1
                    header = json.dumps(dict(type="frame", revision=current["revision"],
                                             display=display_id, x=0, y=0, width=tile_width,
                                             height=tile_height, canvasWidth=width, canvasHeight=height,
                                             codec="png", sequence=sequence)).encode()
                    await ws.send(struct.pack(">I", len(header)) + header + encoded.getvalue())
                    observed["framesSent"] += 1

        try:
            assert ws.request.path == "/remote", ws.request.path
            packet = await asyncio.wait_for(ws.recv(), 10)
            assert isinstance(packet, str), "Binary authentication packet"
            hello = json.loads(packet)
            assert hello.get("type") == "hello" and hello.get("version") == 1, "Invalid hello"
            assert hello.get("password") == PASSWORD, "Invalid fixture password"
            observed["authenticated"] += 1
            await ws.send(json.dumps(dict(type="welcome", version=1, serverName="Popup test Host",
                                         sessionId="windows-popup-fixture", displays=displays,
                                         capabilities=dict(codecs=["png", "jpeg"], audio=[],
                                             colorModes=["gray16", "color256", "rgb565", "full"],
                                             popupMessages=dict(maxCharacters=250, maxDurationSeconds=10800,
                                                                richText=True, targetDisplays=True)))))
            await send_state()
            stream = asyncio.create_task(frames())
            async for packet in ws:
                assert isinstance(packet, str), "Unexpected binary client packet"
                message = json.loads(packet)
                kind = message.get("type")
                if kind == "subscribe":
                    if frozen_at is not None:
                        observed["subscriptionChangesAfterFreeze"] += 1
                        raise AssertionError("Message UI changed the viewing subscription")
                    ids = message["displays"]
                    assert isinstance(ids, list) and set(ids) <= known and len(ids) == len(set(ids))
                    assert isinstance(message["revision"], int) and message["revision"] > 0
                    assert 0 < message["maxWidth"] <= 16384 and 0 < message["maxHeight"] <= 16384
                    assert message["fps"] == 60 and message["bandwidthKbps"] == 0
                    subscription = dict(message)
                    epoch += 1
                    observed["subscriptions"].append(dict(revision=message["revision"], displays=ids))
                    await ws.send(json.dumps(dict(type="subscribed", revision=message["revision"],
                                                 displays=[dict(id=id, width=min(1920, message["maxWidth"]),
                                                                height=min(1080, message["maxHeight"])) for id in ids],
                                                 paused=message.get("paused", False), audio=False)))
                elif kind == "frameAck":
                    number = message["sequence"]
                    assert isinstance(number, int) and 0 < number <= sequence and number not in acknowledgements
                    acknowledgements.add(number)
                    observed["acks"] += 1
                    if frozen_at is not None:
                        now = time.monotonic()
                        observed["acksWhileComposerActive"] += 1
                        observed["maxAckGapSeconds"] = max(observed["maxAckGapSeconds"], now - (last_ack_at or frozen_at))
                        last_ack_at = now
                elif kind == "ping":
                    await ws.send(json.dumps(dict(type="pong", time=message.get("time", 0))))
                elif kind == "getPopupMessageState":
                    await send_state()
                elif kind in ("pointer", "wheel", "key", "text"):
                    freeze()
                    if kind in ("pointer", "wheel"):
                        assert message["display"] == "fixture-1", message
                        assert all(isinstance(message[c], (int, float)) and math.isfinite(message[c])
                                   and 0 <= message[c] <= 1 for c in ("x", "y")), message
                    if kind == "pointer":
                        assert message["buttons"] in (0, 1), message
                        observed["pointerDown" if message["buttons"] == 1 else "pointerUp"] += 1
                    elif kind == "wheel":
                        assert message["dx"] == 0 and message["dy"] != 0, message
                        observed["wheel"] += 1
                    elif kind == "key":
                        assert message["key"] in (65, 97) and isinstance(message["down"], bool), message
                        observed["keyDown" if message["down"] else "keyUp"] += 1
                    else:
                        assert message["text"] == "Z", "Editor text escaped into remote input"
                        observed["texts"].append(message["text"])
                elif kind == "popupMessage":
                    freeze()
                    assert message["text"] == TEXT, message
                    assert message["runs"] == [RUN], message
                    phase = len(observed["operations"]) % len(OPERATIONS)
                    expected_duration = 0 if phase == 0 else 1
                    assert message["durationSeconds"] == expected_duration, message
                    assert phase in (0, 4), observed
                    active, duration = True, expected_duration
                    expires_at = time.time() + (duration or 10800)
                    observed["operations"].append("sticky" if duration == 0 else "timed")
                    await send_state()
                    if duration:
                        expiry = asyncio.create_task(expire())
                elif kind == "setPopupMessageDisplays":
                    freeze()
                    requested = message["displayIDs"]
                    assert active and isinstance(requested, list) and len(requested) == len(set(requested))
                    phase = len(observed["operations"]) % len(OPERATIONS)
                    if phase == 1:
                        assert set(requested) == {"fixture-1", "fixture-2"}, message
                        operation = "both-targets"
                    else:
                        assert phase == 2, observed
                        assert requested == ["fixture-1"], message
                        operation = "first-target"
                    targets = requested
                    observed["operations"].append(operation)
                    await send_state()
                elif kind == "clearPopupMessage":
                    freeze()
                    assert len(observed["operations"]) % len(OPERATIONS) == 3 and active, observed
                    active, duration, expires_at = False, 0, 0.0
                    observed["operations"].append("clear")
                    await send_state()
                else:
                    raise AssertionError(f"Unexpected packet type: {kind}")
        except ConnectionClosed as error:
            if not observed["operations"] or len(observed["operations"]) % len(OPERATIONS) != 0:
                observed["errors"].append(f"Connection closed before the test finished: {error}")
        except Exception as error:
            observed["errors"].append(f"{type(error).__name__}: {error}")
        finally:
            tasks = [task for task in (stream, expiry) if task is not None]
            for task in tasks:
                if not task.done():
                    task.cancel()
            results = await asyncio.gather(*tasks, return_exceptions=True)
            for result in results:
                if isinstance(result, Exception) and not isinstance(result, ConnectionClosed):
                    observed["errors"].append(f"Background task: {result}")

    with tempfile.TemporaryDirectory(prefix="portlight-windows-popup-") as temp:
        folder = Path(temp)
        context, fingerprint = certificate(folder)
        async with serve(connection, "127.0.0.1", 0, ssl=context, max_size=65536,
                         ping_interval=None, close_timeout=2) as server:
            report, log_path = folder / "viewer-report.json", folder / "viewer.log"
            port = server.sockets[0].getsockname()[1]
            env = dict(os.environ, SU_REMOTE_TEST_HOST=f"127.0.0.1:{port}",
                       SU_REMOTE_TEST_FINGERPRINT=fingerprint, SU_REMOTE_TEST_PASSWORD=PASSWORD,
                       SU_REMOTE_TEST_REPORT=str(report))
            with log_path.open("wb") as log:
                process = await asyncio.create_subprocess_exec(str(viewer.resolve()), "--popup-integration-test",
                                                              env=env, stdout=log, stderr=asyncio.subprocess.STDOUT)
                try:
                    await asyncio.wait_for(process.wait(), 180)
                except asyncio.TimeoutError:
                    process.kill()
                    await asyncio.wait_for(process.wait(), 5)
                    raise AssertionError(f"Native popup test timed out: {json.dumps(observed)}")
            output = log_path.read_text(errors="replace")
            if output:
                print(output)
            native = json.loads(report.read_text()) if report.exists() else {}
        result = json.dumps(dict(native=native, protocol=observed), indent=2)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(result + "\n")
        print(result, flush=True)
        assert process.returncode == 0, f"Native popup test exit code {process.returncode}"
        validate(observed, native)
        print("PASS: native popup UI, live remote input, message targets, clear, expiry, and stable subscription")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("viewer", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--report", type=Path, default=Path(__file__).with_name("windows-popup-report.json"))
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.viewer is None:
        parser.error("Provide the native Windows viewer executable or --self-test")
    else:
        asyncio.run(run(args.viewer, args.report))
