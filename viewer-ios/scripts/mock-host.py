#!/usr/bin/env python3
"""Scripted Portlight mock host for iPhone viewer integration tests.

Speaks Portlight v1 (secure WebSocket, JSON control messages, length-prefixed binary envelopes)
and mirrors the rules of server-macos/Sources/Server.swift, Display.swift and Capture.swift, while
adding behaviour the real `--fixture` host cannot produce: input acceptance bookkeeping, audio,
several display topologies and scripted failure scenarios. It never injects real input.

Loopback only (127.0.0.1). Prints exactly like the real host on stdout:
    TLS SHA256 AB:CD:...
    Listening on port N

Usage (see --help):
    mock-host.py [--port 0] [--data-dir DIR] [--password-stdin | --password PW]
                 [--topology fixture3|mixed|negative|vertical|many|single|subhd]
                 [--scenario NAME[=VALUE][@SESSIONS]]... [--fps 10] [--audio aac|mulaw]
                 [--inflight 32] [--ack-timeout 15] [--noise] [--transcript FILE] [--log]

Scenario suffix `@N` limits a per-session scenario to the first N authenticated sessions
(e.g. `drop-after=2@1` drops only the first session so a reconnect then stays up).

Transcript (--transcript FILE): one JSON object per line, flushed immediately.
    dir "in"    every client message: t (time.monotonic()), session, type, message (any
                `password` replaced by "<redacted>"), frameAck `sequence`/`known`/`revision`/`display`,
                input `accepted` (+ `reason` when false), `typeWarnings` for Swift-bridged values.
    dir "event" host-side events (connect, authenticated, busy, subscribed, rejected, released, closed...).
Treat anything with dir != "in" as diagnostics.
"""
import argparse
import asyncio
import base64
import collections
import concurrent.futures
import hmac
import io
import json
import math
import os
import random
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
import zlib
import hashlib
from pathlib import Path

try:
    import websockets
    from websockets.asyncio.server import serve
    from websockets.exceptions import ConnectionClosed
    from websockets.frames import Opcode
except ImportError:  # pragma: no cover
    sys.stderr.write("mock-host: the websockets package is required (use app/.test-venv/bin/python)\n")
    sys.exit(1)
try:
    from PIL import Image
except ImportError:  # pragma: no cover - JPEG needs Pillow; PNG output does not
    Image = None

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_AAC_FIXTURES = SCRIPT_DIR.parent.parent / "viewer-windows" / "tests" / "aac-fixtures.json"

MAX_CONTROL_BYTES = 65536
MAX_BINARY_BYTES = 32 * 1024 * 1024
MAX_IN_FLIGHT_BYTES = 2 * 1024 * 1024
MAX_PENDING_BYTES = 32 * 1024 * 1024
STOP_AND_WAIT_PENDING = 16 * 1024 * 1024
NETWORK_BUDGET = 64 * 1024
CONTROL_BUDGET = 1024 * 1024
TILE = 256

AUTH_ERROR = "Incorrect password or incompatible protocol"
BUSY_ERROR = "Another viewer is connected. Disconnect it before connecting here."
SUBSCRIPTION_ERROR = "Invalid displays, revision, resolution, color, quality, frame rate or bandwidth"
REGION_MAP_ERROR = "Invalid visible region map"
REGION_ERROR = "Invalid visible region"
AUDIO_QUALITY_ERROR = "Unsupported audio quality"
AAC_INIT_ERROR = "The host could not initialize compressed audio. Turn audio off or choose another quality."
TOPOLOGY_ERROR = "Displays changed. Select displays again."
TIMEOUT_ERROR = "Viewer stopped acknowledging image updates"
CAPTURE_DENIED = ("macOS denied screen capture. On the host Mac, open Portlight Host → Permissions, enable Screen & "
                  "System Audio Recording for this copy of the app, then choose Restart Host. If it still fails after "
                  "restarting, turn this app’s permission off and on to renew the grant for the updated copy.")
CAPTURE_GENERIC = ("Screen capture failed: The operation couldn’t be completed. (com.apple.ScreenCaptureKit.SCStreamErrorDomain "
                   "error -3805.) (com.apple.ScreenCaptureKit.SCStreamErrorDomain, -3805). Open Permissions on the host Mac "
                   "and choose Check Again to test capture.")

RESOLUTION_SIZES = {"hd": (1280, 720), "fhd": (1920, 1080), "qhd": (2560, 1440), "uhd": (3840, 2160)}
COLORS = ("full", "gray16", "color256", "rgb565")
QUALITIES = ("auto", "desktop", "motion")
AUDIO_BITRATES = (48000, 96000, 160000, 320000)


class InternalError(Exception):
    """A bug in the mock host itself (exit status 70)."""


# ---------------------------------------------------------------------------------------------
# JSON: output like Foundation's JSONSerialization; input bridged like Swift `as? Int/Double/Bool`.

def _swiftify(value):
    if isinstance(value, bool) or value is None or isinstance(value, (int, str)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise InternalError("non-finite number in outbound JSON")
        return int(value) if value.is_integer() and abs(value) < 2 ** 53 else value
    if isinstance(value, dict):
        return {str(k): _swiftify(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_swiftify(v) for v in value]
    raise InternalError(f"unexpected outbound JSON value {type(value).__name__}")


def encode_json(obj, sort_keys=False):
    """Compact UTF-8 JSON; integral doubles print without a fraction and '/' is escaped, as JSONSerialization does."""
    text = json.dumps(_swiftify(obj), separators=(",", ":"), ensure_ascii=False, sort_keys=sort_keys, allow_nan=False)
    return text.replace("/", "\\/").encode("utf-8")


def binary_message(header, payload):
    data = encode_json(header, sort_keys=True)  # host: JSONSerialization .sortedKeys
    return struct.pack(">I", len(data)) + data + payload


class _BadConstant(ValueError):
    pass


def _reject_constant(name):
    raise _BadConstant(name)


def _parse_float(text):
    value = float(text)
    if math.isinf(value):  # JSONSerialization refuses 1e999 (it reads -1e999 as -inf; refused here too)
        raise _BadConstant(text)
    return value


def _foundation_refuses(value):
    """What Python's json accepts but JSONSerialization refuses (measured on macOS 15): an object nested
    deeper than 512 levels, an array deeper than 513, or a lone surrogate escape in any key or string."""
    stack = [(value, 1)]
    while stack:
        item, depth = stack.pop()
        if isinstance(item, str):
            if not item.isascii():
                try:
                    item.encode("utf-8")
                except UnicodeEncodeError:
                    return True
        elif isinstance(item, dict):
            if depth > 512:
                return True
            stack.extend((key, depth) for key in item)
            stack.extend((v, depth + 1) for v in item.values())
        elif isinstance(item, list):
            if depth > 513:
                return True
            stack.extend((v, depth + 1) for v in item)
    return False


def parse_control(data):
    """Host rule: <= 65536 bytes and a JSON object JSONSerialization can read (text and binary opcodes alike).
    None when invalid. Stricter, never looser: an empty message, UTF-16/32 JSON and -1e999 are refused too,
    although the host skips or reads them."""
    raw = data.encode("utf-8") if isinstance(data, str) else bytes(data)
    if len(raw) > MAX_CONTROL_BYTES:
        return None
    try:
        value = json.loads(raw.decode("utf-8"), parse_constant=_reject_constant, parse_float=_parse_float)
    except (ValueError, RecursionError, UnicodeDecodeError):
        return None
    return value if isinstance(value, dict) and not _foundation_refuses(value) else None


class Bridge:
    """Reads fields the way the host's `as? Int` / `as? Double` / `as? Bool` casts do (NSNumber bridging),
    recording a warning whenever a value only passes through bridging (e.g. `true` as an Int)."""

    def __init__(self):
        self.warnings = []

    def _warn(self, key, what):
        self.warnings.append(f"{key}: {what}")

    def int_(self, obj, key):
        if not isinstance(obj, dict) or key not in obj:
            return None
        v = obj[key]
        if isinstance(v, bool):
            self._warn(key, "Boolean accepted as Int by NSNumber bridging")
            return int(v)
        if isinstance(v, int):
            return v if -2 ** 63 <= v < 2 ** 63 else None
        if isinstance(v, float) and math.isfinite(v) and v.is_integer() and -2 ** 63 <= v < 2 ** 63:
            self._warn(key, "integral Double accepted as Int by NSNumber bridging")
            return int(v)
        return None

    def double(self, obj, key):
        if not isinstance(obj, dict) or key not in obj:
            return None
        return self.as_double(obj[key], key)

    def as_double(self, v, key):
        if isinstance(v, bool):
            self._warn(key, "Boolean accepted as Double by NSNumber bridging")
            return float(v)
        if isinstance(v, int):  # `as? Double` takes any exactly representable Int (2**60 yes, 2**53 + 1 no)
            return float(v) if abs(v) < 2 ** 1000 and int(float(v)) == v else None
        if isinstance(v, float):
            return v
        return None

    def bool_(self, obj, key):
        if not isinstance(obj, dict) or key not in obj:
            return None
        v = obj[key]
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v in (0, 1):
            self._warn(key, "number accepted as Bool by NSNumber bridging")
            return bool(v)
        return None

    @staticmethod
    def str_(obj, key):
        v = obj.get(key) if isinstance(obj, dict) else None
        return v if isinstance(v, str) else None

    @staticmethod
    def str_list(obj, key):
        v = obj.get(key) if isinstance(obj, dict) else None
        if isinstance(v, list) and all(isinstance(x, str) for x in v):
            return list(v)
        return None


def redact(value):
    if isinstance(value, dict):
        return {k: ("<redacted>" if k == "password" else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


# ---------------------------------------------------------------------------------------------
# PNG writer (stdlib zlib) so bit depths and color types are exact.

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
HOST_PALETTE = bytes(v for i in range(256) for v in ((i >> 5) * 255 // 7, ((i >> 2) & 7) * 255 // 7, (i & 3) * 255 // 3))


def _chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def png_bytes(width, height, bit_depth, color_type, filtered_rows, palette=None):
    """filtered_rows: raw scanlines, each prefixed with filter byte 0."""
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, 0)
    level = 1 if len(filtered_rows) > 4 * 1024 * 1024 else 6
    parts = [PNG_SIGNATURE, _chunk(b"IHDR", ihdr)]
    if palette is not None:
        parts.append(_chunk(b"PLTE", palette))
    parts.append(_chunk(b"IDAT", zlib.compress(filtered_rows, level)))
    parts.append(_chunk(b"IEND", b""))
    return b"".join(parts)


# ---------------------------------------------------------------------------------------------
# Quantization exactly as TileEncoder does it (Capture.swift).

DITHER_THRESHOLDS = [0, 48, 12, 60, 3, 51, 15, 63, 32, 16, 44, 28, 35, 19, 47, 31, 8, 56, 4, 52, 11, 59, 7, 55, 40, 24, 36, 20,
                     43, 27, 39, 23, 2, 50, 14, 62, 1, 49, 13, 61, 34, 18, 46, 30, 33, 17, 45, 29, 10, 58, 6, 54, 9, 57, 5, 53,
                     42, 26, 38, 22, 41, 25, 37, 21]


def _trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def dither_level(value, levels, phase):
    t = DITHER_THRESHOLDS[phase]
    numerator = value * levels * 64 + (32 + _trunc_div(t - 32, 4)) * 255
    return min(levels, max(0, numerator // 16320))


def luminance(rgb):
    r, g, b = rgb
    return (77 * r + 150 * g + 29 * b + 128) >> 8


def quantize(rgb, color, dither=False, x=0, y=0):
    """Pixel bytes for one color: 3 bytes (full/rgb565), 1 palette index (color256) or 1 nibble (gray16)."""
    r, g, b = rgb
    if color == "full":
        return bytes((r, g, b))
    if color == "rgb565":
        return bytes(((r >> 3) * 255 // 31, (g >> 2) * 255 // 63, (b >> 3) * 255 // 31))
    phase = (y & 7) * 8 + (x & 7)
    if color == "color256":
        if dither:
            return bytes((dither_level(r, 7, phase) << 5 | dither_level(g, 7, phase) << 2 | dither_level(b, 3, phase),))
        return bytes(((r >> 5) << 5 | (g >> 5) << 2 | (b >> 6),))
    if color == "gray16":
        lum = luminance(rgb)
        return bytes((dither_level(lum, 15, phase) if dither else lum // 17,))
    raise InternalError(f"unknown color {color}")


_SHL4 = bytes(((v << 4) & 0xFF) for v in range(256))
_Q5 = bytes((v >> 3) * 255 // 31 for v in range(256))
_Q6 = bytes((v >> 2) * 255 // 63 for v in range(256))
_NIB = bytes(v & 15 for v in range(256))


def pack_nibbles(row):
    """Two 4-bit samples per byte, first pixel in the high nibble, rows padded to a byte."""
    if len(row) % 2:
        row += b"\x00"
    hi = row[0::2].translate(_SHL4)
    lo = row[1::2]
    if not hi:
        return b""
    return (int.from_bytes(hi, "big") | int.from_bytes(lo, "big")).to_bytes(len(hi), "big")


# ---------------------------------------------------------------------------------------------
# Synthetic scene: fixture-like picture (background, teal block, moving yellow square) plus a thin
# border and per-display index markers. Rendered from rectangles, so any crop is cheap and exact.

BACKGROUNDS = [(23, 41, 61), (33, 64, 41), (64, 33, 51), (61, 48, 23), (36, 36, 64), (20, 56, 56), (56, 20, 20), (48, 48, 48)]
TEAL = (51, 204, 166)
YELLOW = (255, 204, 64)
MARK = (235, 235, 235)
NOISE = "noise"


def square_rect(w, h, frame):
    """The fixture's moving square in top-left coordinates (CG draws from the bottom-left)."""
    sw, sh = max(8, w // 20), max(8, h // 20)
    x0 = (frame % 30) * max(1, w // 40)
    y0 = h - (h // 10 + sh)
    return clip_rect((x0, y0, x0 + sw, y0 + sh), w, h)


def clip_rect(r, w, h):
    x0, y0, x1, y1 = max(0, r[0]), max(0, r[1]), min(w, r[2]), min(h, r[3])
    return (x0, y0, x1, y1) if x1 > x0 and y1 > y0 else None


def scene_rects(index, w, h, frame, noise):
    """Paint-ordered (x0, y0, x1, y1, color) over the display background."""
    rects = []
    bw = max(1, min(w, h) // 360)
    for r in ((0, 0, w, bw), (0, h - bw, w, h), (0, 0, bw, h), (w - bw, 0, w, h)):
        rects.append(r + (MARK,))
    rects.append((w // 10, h - (h // 4 + h // 2), w // 10 + w * 4 // 5, h - h // 4, NOISE if noise else TEAL))
    m = max(4, min(w, h) // 45)
    for i in range(min(max(1, index), 8)):
        rects.append((m + i * 2 * m, m, 2 * m + i * 2 * m, 2 * m, MARK))
    sq = square_rect(w, h, frame)
    if sq:
        rects.append(sq + (YELLOW,))
    return [clip_rect(r[:4], w, h) + (r[4],) for r in rects if clip_rect(r[:4], w, h)]


class NoisePool:
    """Static, deterministic, incompressible pixels for --noise (97 distinct rows defeat deflate's window)."""

    def __init__(self):
        self.cache = {}

    def row(self, rect_width, color, y):
        key = (rect_width, color)
        pool = self.cache.get(key)
        if pool is None:
            rng = random.Random(0x5EED ^ rect_width)
            pool = []
            for _ in range(97):
                if color in ("full", "rgb565"):
                    data = bytearray(rng.randbytes(rect_width * 3))
                    if color == "rgb565":
                        data[0::3] = bytes(data[0::3]).translate(_Q5)
                        data[1::3] = bytes(data[1::3]).translate(_Q6)
                        data[2::3] = bytes(data[2::3]).translate(_Q5)
                    pool.append(bytes(data))
                elif color == "color256":
                    pool.append(rng.randbytes(rect_width))
                else:
                    pool.append(rng.randbytes(rect_width).translate(_NIB))
            self.cache[key] = pool
        return pool[(y * 31) % 97]


NOISE_POOL = NoisePool()


def render(index, w, h, frame, noise, crop, color, dither, fmt):
    """Encode crop (x0, y0, x1, y1) of the scene. fmt: 'png' or 'jpeg'. Returns (payload, width, height)."""
    x0, y0, x1, y1 = crop
    rects = scene_rects(index, w, h, frame, noise)
    bg = BACKGROUNDS[(index - 1) % len(BACKGROUNDS)]
    mode = "full" if fmt == "jpeg" else color
    bpp = 3 if mode in ("full", "rgb565") else 1
    use_dither = dither and mode in ("color256", "gray16")
    breaks = sorted({y0, y1} | {min(max(r[1], y0), y1) for r in rects} | {min(max(r[3], y0), y1) for r in rects})
    rows = []
    cache = {}
    for band_start, band_end in zip(breaks, breaks[1:]):
        if band_end <= band_start:
            continue
        active = [r for r in rects if r[1] <= band_start < r[3]]
        segments = [(x0, x1, bg)]
        for rx0, _, rx1, _, c in active:
            a, b = max(rx0, x0), min(rx1, x1)
            if a >= b:
                continue
            kept = []
            for s, e, sc in segments:
                if e <= a or s >= b:
                    kept.append((s, e, sc))
                    continue
                if s < a:
                    kept.append((s, a, sc))
                if e > b:
                    kept.append((b, e, sc))
            kept.append((a, b, c))
            segments = sorted(kept, key=lambda seg: seg[0])
        noise_rect = next((r for r in active if r[4] == NOISE), None)
        for y in range(band_start, band_end):
            key = (band_start, (y & 7) if use_dither else 0, ((y * 31) % 97) if noise_rect else 0)
            row = cache.get(key)
            if row is None:
                parts = []
                for s, e, c in segments:
                    n = e - s
                    if c == NOISE:
                        line = NOISE_POOL.row(noise_rect[2] - noise_rect[0], mode, y)
                        off = s - noise_rect[0]
                        parts.append(line[off * bpp:(off + n) * bpp])
                    elif use_dither:
                        pattern = b"".join(quantize(c, mode, True, s + k, y) for k in range(8))
                        parts.append((pattern * (n // 8 + 1))[:n * bpp])
                    else:
                        parts.append(quantize(c, mode) * n)
                row = b"".join(parts)
                if fmt == "png":
                    row = b"\x00" + (pack_nibbles(row) if mode == "gray16" else row)
                cache[key] = row
            rows.append(row)
    width, height = x1 - x0, y1 - y0
    data = b"".join(rows)
    if fmt == "jpeg":
        if Image is None:
            raise InternalError("JPEG output needs Pillow")
        return data, width, height  # caller compresses (needs the quality)
    if mode in ("full", "rgb565"):
        return png_bytes(width, height, 8, 2, data), width, height
    if mode == "color256":
        return png_bytes(width, height, 8, 3, data, HOST_PALETTE), width, height
    return png_bytes(width, height, 4, 0, data), width, height


_TILE_CACHE = collections.OrderedDict()
_TILE_CACHE_LOCK = threading.Lock()
_TILE_CACHE_LIMIT = 192 * 1024 * 1024
_tile_cache_bytes = 0


def encode_tile(index, w, h, frame, noise, crop, color, dither, codec, jpeg_quality):
    """Encoded payload for one crop. The scene depends on the frame only through frame % 30, so results
    are memoized exactly in a bounded LRU: steady-state streaming costs almost no CPU."""
    global _tile_cache_bytes
    key = (index, w, h, frame % 30, noise, tuple(crop), color, bool(dither), codec, jpeg_quality if codec == "jpeg" else 0)
    with _TILE_CACHE_LOCK:
        hit = _TILE_CACHE.get(key)
        if hit is not None:
            _TILE_CACHE.move_to_end(key)
            return hit
    payload, width, height = render(index, w, h, frame, noise, crop, color, dither, codec)
    if codec == "jpeg":
        out = io.BytesIO()
        Image.frombytes("RGB", (width, height), payload).save(out, "JPEG", quality=jpeg_quality)
        payload = out.getvalue()
    result = (payload, width, height)
    with _TILE_CACHE_LOCK:
        if key not in _TILE_CACHE:
            _TILE_CACHE[key] = result
            _tile_cache_bytes += len(payload)
        while _tile_cache_bytes > _TILE_CACHE_LIMIT and _TILE_CACHE:
            _, evicted = _TILE_CACHE.popitem(last=False)
            _tile_cache_bytes -= len(evicted[0])
    return result


def visible_rect(region, w, h):
    """CGRect(rx*w, ry*h, rw*w, rh*h) ∩ canvas, then .integral (floor origin, ceil max). None when empty."""
    rx, ry, rw, rh = region
    x, y, ww, hh = rx * w, ry * h, rw * w, rh * h
    ix0, iy0 = max(x, 0.0), max(y, 0.0)
    ix1, iy1 = min(x + ww, float(w)), min(y + hh, float(h))
    if not (ix1 > ix0 and iy1 > iy0):
        return None
    return (math.floor(ix0), math.floor(iy0), math.ceil(ix1), math.ceil(iy1))


def rect_intersection(a, b):
    x0, y0, x1, y1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    return (x0, y0, x1, y1) if x1 > x0 and y1 > y0 else None


class DisplayEncoder:
    """Mirror of TileEncoder's decision logic for the synthetic scene (which pixels changed is known
    exactly from the square's geometry, so no pixel diff is needed)."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.last_frame = None
        self.last_size = None
        self.previous_region = None
        self.needs_lossless = False
        self.last_change = float("-inf")

    def plan(self, w, h, region, frame, color, quality, now):
        visible = visible_rect(region, w, h)
        if visible is None:
            return [], False
        force = self.last_frame is None or self.last_size != (w, h) or self.previous_region != region
        old_sq = square_rect(w, h, self.last_frame) if self.last_frame is not None else None
        new_sq = square_rect(w, h, frame)
        rects = []
        if quality == "motion":
            if force or old_sq != new_sq:
                rects = [visible]
        else:
            if self.last_frame is not None and self.last_size == (w, h):
                ty = max(0, visible[1] // TILE * TILE)
                while ty < min(h, visible[3]):
                    tx = max(0, visible[0] // TILE * TILE)
                    while tx < min(w, visible[2]):
                        tile = (tx, ty, tx + min(TILE, w - tx), ty + min(TILE, h - ty))
                        changed = force
                        if not changed:
                            a = rect_intersection(tile, old_sq) if old_sq else None
                            b = rect_intersection(tile, new_sq) if new_sq else None
                            changed = a != b
                        if changed:
                            clipped = rect_intersection(tile, visible)
                            if clipped:
                                rects.append(clipped)
                        tx += TILE
                    ty += TILE
            if force and not rects:
                rects = [visible]
        use_jpeg = quality == "motion" and color == "full"
        if rects:
            self.last_change = now
        if quality == "auto" and color == "full" and not force:
            changed_area = sum((r[2] - r[0]) * (r[3] - r[1]) for r in rects)
            visible_area = (visible[2] - visible[0]) * (visible[3] - visible[1])
            if changed_area > visible_area * 0.35:
                use_jpeg, rects = True, [visible]
            elif self.needs_lossless and not rects and now - self.last_change >= 0.5:
                rects = [visible]
        if use_jpeg and rects:
            self.needs_lossless = True
        elif visible in rects:
            self.needs_lossless = False
        self.last_frame, self.last_size, self.previous_region = frame, (w, h), region
        return rects, use_jpeg


# ---------------------------------------------------------------------------------------------
# Displays and topologies (Display.swift geometry rules).

class Display:
    def __init__(self, id, name, index, width, height, x, y, logical_width, logical_height):
        self.id, self.name, self.index = id, name, index
        self.width, self.height = width, height
        self.x, self.y = x, y
        self.logical_width, self.logical_height = float(logical_width), float(logical_height)

    def json(self):
        return {"id": self.id, "name": self.name, "index": self.index, "width": self.width, "height": self.height,
                "x": int(self.x), "y": int(self.y), "logicalWidth": self.logical_width, "logicalHeight": self.logical_height,
                "scale": self.width / max(1.0, self.logical_width), "primary": self.index == 1}

    def signature(self):
        return f"{self.id}:{self.width}x{self.height}:{self.x},{self.y},{self.logical_width},{self.logical_height}"


def _uid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "portlight-mock-host:" + name)).upper()


def _make(rows):
    return [Display(id_, name, i + 1, w, h, x, y, lw, lh) for i, (id_, name, w, h, x, y, lw, lh) in enumerate(rows)]


def topology(name):
    if name == "fixture3":
        return _make([(f"fixture-{i}", f"Test Display {i}", 1920 if i == 2 else 3840, 1080 if i == 2 else 2160, (i - 1) * 1920, 0, 1920, 1080)
                      for i in (1, 2, 3)])
    if name == "mixed":
        return _make([(_uid("mixed-5k"), "Studio Display 5K", 5120, 2880, 0, 0, 1920, 1080),
                      (_uid("mixed-hd"), "HD Monitor", 1920, 1080, 1920, 0, 1920, 1080)])
    if name == "negative":
        return _make([(_uid("negative-retina"), "Built-in Retina Display", 2880, 1800, -1440, 0, 1440, 900),
                      (_uid("negative-portrait"), "Portrait Monitor", 1080, 1920, 0, -300, 1080, 1920)])
    if name == "vertical":
        return _make([(_uid("vertical-lower"), "Lower Display", 1920, 1080, 0, 0, 1920, 1080),
                      (_uid("vertical-upper"), "Upper Display", 1920, 1080, 0, -1080, 1920, 1080)])
    if name == "many":
        return _make([(_uid(f"many-{i}"), f"Wall Display {i + 1}", 1920, 1080, (i % 6) * 1920, (i // 6) * 1080, 1920, 1080) for i in range(17)])
    if name == "single":
        return _make([(_uid("single-retina"), "Built-in Retina Display", 3024, 1964, 0, 0, 1512, 982)])
    if name == "subhd":
        return _make([(_uid("subhd-projector"), "Legacy Projector", 1024, 768, 0, 0, 1024, 768),
                      (_uid("subhd-hd"), "HD Monitor", 1920, 1080, 1024, 0, 1920, 1080)])
    raise KeyError(name)


TOPOLOGIES = ("fixture3", "mixed", "negative", "vertical", "many", "single", "subhd")


def scaled_size(display, preset):
    if preset not in RESOLUTION_SIZES:
        return (display.width, display.height)
    w, h = RESOLUTION_SIZES[preset]
    cap = (h, w) if display.height > display.width else (w, h)
    scale = min(1.0, min(cap[0] / display.width, cap[1] / display.height))
    return (max(1, int(display.width * scale)), max(1, int(display.height * scale)))


def common_resolution(requested, displays):
    presets = ["native", "hd", "fhd", "qhd", "uhd"]
    max_index = presets.index(requested) if requested in presets else 2
    for candidate in reversed(presets[:max_index + 1]):
        if candidate not in RESOLUTION_SIZES:
            return "native"
        w, h = RESOLUTION_SIZES[candidate]
        if all(max(d.width, d.height) >= w and min(d.width, d.height) >= h for d in displays):
            return candidate
    return "native"


# ---------------------------------------------------------------------------------------------
# Audio sources.

class AacFixtures:
    """Pre-encoded raw AAC-LC access units (no ADTS) from viewer-windows/tests/aac-fixtures.json."""

    def __init__(self, path):
        with open(path, encoding="utf-8") as f:
            cases = json.load(f)
        self.cases = {}
        for case in cases:
            packets = [base64.b64decode(p, validate=True) for p in case["packets"]]
            cookie = base64.b64decode(case["cookie"], validate=True)
            if not packets or not (1 <= int(case["channels"]) <= 2) or len(cookie) > 4096:
                raise ValueError(f"invalid AAC fixture case {case.get('bitrate')}")
            self.cases[int(case["bitrate"])] = (int(case["channels"]), base64.b64encode(cookie).decode("ascii"), packets)
        missing = [b for b in AUDIO_BITRATES if b not in self.cases]
        if missing:
            raise ValueError(f"AAC fixtures lack bitrates {missing}")

    def stream(self, bitrate):
        return self.cases[bitrate]


def mu_law(sample):
    """Server.swift muLaw()."""
    sign = 0x80 if sample < 0 else 0
    if sample < 0:
        sample = -sample
    sample = min(32635, sample) + 0x84
    exponent, mask = 7, 0x4000
    while exponent > 0 and sample & mask == 0:
        exponent -= 1
        mask >>= 1
    mantissa = (sample >> (exponent + 3)) & 0x0F
    return (~(sign | exponent << 4 | mantissa)) & 0xFF


class MulawTone:
    """24 kHz mono 440 Hz tone, 480 samples (20 ms) per packet, continuous phase."""

    def __init__(self, frequency=440.0, amplitude=6000):
        self.n = 0
        self.frequency, self.amplitude = frequency, amplitude

    def packet(self):
        out = bytes(mu_law(int(round(self.amplitude * math.sin(2 * math.pi * self.frequency * (self.n + k) / 24000)))) for k in range(480))
        self.n += 480
        return out


# ---------------------------------------------------------------------------------------------
# Keysym mapping (Server.swift inputKeysym) — decides whether a key is held or typed as text.

SPECIAL_KEYSYMS = {0xff0d, 0xff1b, 0xff08, 0xff09, 0xff51, 0xff52, 0xff53, 0xff54, 0xffff, 0xff50, 0xff57, 0xff55, 0xff56, 0xff63,
                   0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe9, 0xffea, 0xffeb, 0xffec, 0xffe5}
MODIFIER_KEYSYMS = {0xffe1: "shift", 0xffe2: "shift", 0xffe3: "control", 0xffe4: "control", 0xffe9: "alt", 0xffea: "alt",
                    0xffeb: "meta", 0xffec: "meta"}
PUNCTUATION_KEYS = set(" -=[]\\;',./`")


def keysym_effect(key):
    """'key' when the host posts a key code (held until released), 'text' when it types the character on
    key-down, None when the keysym is not a valid Unicode scalar (ignored)."""
    if key in SPECIAL_KEYSYMS or 0xffbe <= key <= 0xffd1:
        return "key"
    scalar = key & 0x00FFFFFF if key & 0xFF000000 == 0x01000000 else key
    if scalar < 0 or scalar > 0x10FFFF or 0xD800 <= scalar <= 0xDFFF:
        return None
    char = chr(scalar)
    lower = char.lower()
    if len(lower) == 1 and "a" <= lower <= "z":
        return "key"
    if 48 <= scalar <= 57 or char in PUNCTUATION_KEYS:
        return "key"
    return "text"


# ---------------------------------------------------------------------------------------------
# Subscription state, scenarios and transcript.

class Subscription:
    def __init__(self, revision=-1, ids=None, preset="fhd", color="full", quality="auto", fps=15, bandwidth=4000, paused=False,
                 audio=False, audio_codec="mulaw", audio_bitrate=96000, dither=False, view_only=False, regions=None):
        self.revision, self.ids, self.preset = revision, list(ids or []), preset
        self.color, self.quality, self.fps, self.bandwidth = color, quality, fps, bandwidth
        self.paused, self.audio, self.audio_codec, self.audio_bitrate = paused, audio, audio_codec, audio_bitrate
        self.dither, self.view_only, self.regions = dither, view_only, dict(regions or {})

    def region_empty(self, display_id):
        r = self.regions.get(display_id)
        return r is not None and (r[2] == 0 or r[3] == 0)


FRAME_ANOMALIES = ("future-revision", "canvas-mismatch", "size-mismatch", "bad-codec")
WIRE_ANOMALIES = ("bad-json", "deep-json", "binary-short", "header-overflow", "invalid-utf8", "non-object", "bad-header-json")
SCENARIO_NAMES = {
    "normal": "flag", "auth-fail": "flag", "busy": "flag", "busy-first-N": "int", "no-welcome": "flag",
    "drop-after": "seconds", "stall-after": "seconds", "close-after-welcome": "flag",
    "topology-change-after": "seconds[:topology]", "capture-error-after": "seconds[:denied|generic][:retry=S]",
    "reject-subscriptions-from": "int", "stale-burst": "flag", "cursor": "flag",
    **{name: "anomaly" for name in FRAME_ANOMALIES + WIRE_ANOMALIES},
}
SCENARIO_ALIASES = {"busy-first": "busy-first-N", "busy-first-n": "busy-first-N"}


class Scenario:
    def __init__(self, spec):
        text = spec.strip()
        self.limit = None
        if "@" in text:
            text, limit = text.rsplit("@", 1)
            self.limit = int(limit)
            if self.limit < 1:
                raise ValueError("@N must be at least 1")
        name, _, value = text.partition("=")
        name = SCENARIO_ALIASES.get(name, name)
        if name not in SCENARIO_NAMES:
            raise ValueError(f"unknown scenario {name!r}")
        kind = SCENARIO_NAMES[name]
        self.name, self.raw = name, value
        self.seconds, self.number, self.options = None, None, []
        if kind == "flag":
            if value:
                raise ValueError(f"scenario {name} takes no value")
        elif kind == "int":
            self.number = int(value)
            if self.number < 0:
                raise ValueError(f"scenario {name} needs a non-negative integer")
        elif kind == "anomaly":
            self.seconds = float(value) if value else None
        else:
            head, *self.options = value.split(":")
            self.seconds = float(head)
            if not math.isfinite(self.seconds) or self.seconds < 0:
                raise ValueError(f"scenario {name} needs non-negative seconds")
            if name == "topology-change-after" and self.options and self.options[0] not in TOPOLOGIES:
                raise ValueError(f"unknown topology {self.options[0]!r}")
            if name == "capture-error-after":
                for opt in self.options:
                    if opt not in ("denied", "generic") and not opt.startswith("retry="):
                        raise ValueError(f"unknown capture-error option {opt!r}")
        if self.seconds is not None and (not math.isfinite(self.seconds) or self.seconds < 0):
            raise ValueError(f"scenario {name} needs non-negative seconds")

    def applies(self, auth_index):
        return self.limit is None or (auth_index > 0 and auth_index <= self.limit)


class Transcript:
    def __init__(self, path):
        self.file = open(path, "a", encoding="utf-8") if path else None

    def write(self, record):
        if self.file is None:
            return
        self.file.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
        self.file.flush()

    def close(self):
        if self.file is not None:
            self.file.close()
            self.file = None


class InFlight:
    __slots__ = ("size", "sent", "display", "revision")

    def __init__(self, size, sent, display, revision):
        self.size, self.sent, self.display, self.revision = size, sent, display, revision


# ---------------------------------------------------------------------------------------------
# One WebSocket connection (RemoteSession in Server.swift).

class Session:
    def __init__(self, host, ws, number):
        self.host, self.ws, self.number = host, ws, number
        self.loop = asyncio.get_running_loop()
        self.session_id = str(uuid.uuid4()).upper()
        self.connected_at = time.monotonic()
        self.authenticated = self.closed = self.closing = self.stalled = self.silent = False
        self.auth_index = 0
        self.sub = Subscription()
        self.canvases = {}
        self.encoders = {}
        self.processing = set()
        self.outbound = collections.deque()
        self.in_flight = {}
        self.display_sequences = {}
        self.sequence = 0
        self.pending_bytes = self.network_bytes = self.control_bytes = 0
        self.tokens = float(512 * 1024)
        self.last_token_time = time.monotonic()
        self.frame = 0
        self.last_frame_time = float("-inf")
        self.frame_counter = self.skipped = self.encoded_inputs = 0
        self.encode_ms = 0.0
        self.bytes_sent = 0
        self.last_stats = time.monotonic()
        self.capture_revision = None
        self.capture_failed = False
        self.audio_task = None
        self.audio_generation = 0
        self.audio_outbound = collections.deque()
        self.button_mask = 0
        self.held_keys = set()
        self.held_modifiers = set()
        self.wheel_rx = self.wheel_ry = 0.0
        self.cursor_key = ""
        self.last_cursor_time = float("-inf")
        self.writer_queue = asyncio.Queue()
        self.tasks = []
        self.handles = []
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix=f"encode-s{number}")
        self.first_subscribed_at = None
        self.anomalies_pending = []
        self.stale = None
        self.timeout_sent = False
        self._install_pong_gate()

    # -- plumbing ------------------------------------------------------------------------------

    def _install_pong_gate(self):
        """While stalled, drop the WebSocket library's automatic Pong replies too ("send nothing")."""
        protocol = getattr(self.ws, "protocol", None)
        original = getattr(protocol, "send_frame", None)
        if original is None:
            return

        def send_frame(frame):
            if self.stalled and frame.opcode is Opcode.PONG:
                return
            original(frame)
        protocol.send_frame = send_frame

    def event(self, event_name, /, **fields):
        self.host.record({"session": self.number, "dir": "event", "event": event_name, **fields})
        self.host.log(f"s{self.number} {event_name} " + " ".join(f"{k}={v}" for k, v in fields.items()))

    def later(self, delay, fn, *args):
        handle = self.loop.call_later(max(0.0, delay), self.host.guarded(fn), *args)
        self.handles.append(handle)
        return handle

    def applies(self, name):
        scenario = self.host.scenarios.get(name)
        return scenario is not None and scenario.applies(self.auth_index)

    async def run(self):
        self.host.sessions.add(self)
        peer = self.ws.remote_address
        path = getattr(getattr(self.ws, "request", None), "path", None)
        self.event("connect", peer=f"{peer[0]}:{peer[1]}" if peer else None, path=path)
        self.later(self.host.auth_timeout, self._auth_timeout)
        self.tasks = [asyncio.create_task(self.writer()), asyncio.create_task(self.ticker())]
        try:
            async for message in self.ws:
                self.host.guarded(self.on_message)(message)
        except ConnectionClosed:
            pass
        finally:
            self.close(style="none", reason="connection ended")
            for task in self.tasks:
                task.cancel()
            await asyncio.gather(*self.tasks, return_exceptions=True)

    def _auth_timeout(self):
        if not self.authenticated and not self.closed:
            self.close(reason="not authenticated within the auth timeout")

    def send_control(self, obj, then=None):
        if self.closed:
            return
        data = encode_json(obj)
        if self.control_bytes + len(data) > CONTROL_BUDGET:
            self.close(reason="control send budget exceeded")
            return
        self.control_bytes += len(data)
        self.writer_queue.put_nowait(("text", data, then, len(data)))

    def send_raw(self, data, text):
        if not self.closed:
            self.writer_queue.put_nowait(("raw_text" if text else "raw_binary", data, None, 0))

    def error(self, code, message, then=None):
        self.send_control({"type": "error", "code": code, "message": message}, then)

    async def writer(self):
        try:
            while True:
                kind, data, then, size = await self.writer_queue.get()
                if kind == "stop" or self.closed:
                    return
                if not self.stalled:
                    await self.ws.send(data, text=kind in ("text", "raw_text"))
                if kind == "binary":
                    self.network_bytes -= size
                elif kind == "text":
                    self.control_bytes -= size
                if self.stalled:
                    continue
                if then is not None:
                    self.host.guarded(then)()
                if kind == "binary":
                    self.host.guarded(self.drain)()
        except ConnectionClosed:
            self.close(style="none", reason="send failed: connection closed")
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - anything else is a mock-host bug
            self.host.internal_error(exc)

    async def ticker(self):
        try:
            while not self.closed:
                await asyncio.sleep(0.025)
                self.host.guarded(self.tick)()
        except asyncio.CancelledError:
            raise

    # -- inbound -------------------------------------------------------------------------------

    def record_in(self, type_, obj, raw, **extra):
        record = {"session": self.number, "dir": "in", "type": type_}
        if obj is not None:
            record["message"] = redact(obj)
        if isinstance(raw, (bytes, bytearray, memoryview)):
            record["binaryOpcode"] = True
        record.update({k: v for k, v in extra.items() if v is not None})
        self.host.record(record)

    def on_message(self, raw):
        obj = parse_control(raw)
        if obj is None:
            size = len(raw.encode("utf-8")) if isinstance(raw, str) else len(raw)
            self.record_in(None, None, raw, invalid=True, bytes=size)
            if not (self.closed or self.closing or self.silent):
                self.closing = True
                self.error("message", "Invalid control message", then=lambda: self.close(reason="invalid control message"))
            return
        type_ = obj["type"] if isinstance(obj.get("type"), str) else None
        if self.closed or self.closing or self.silent:
            self.record_in(type_, obj, raw, ignored=True)
            return
        bridge = Bridge()
        if type_ is None:
            self.record_in(None, obj, raw)
            self.error("message", "Missing message type")
            return
        if not self.authenticated:
            outcome = self.handle_hello(type_, obj, bridge)
            self.record_in(type_, obj, raw, outcome=outcome, typeWarnings=bridge.warnings or None)
            return
        extra = {}
        if type_ == "subscribe":
            extra = self.apply_subscription(obj, bridge)
        elif type_ == "frameAck":
            seq = bridge.int_(obj, "sequence")
            entry = self.in_flight.pop(seq, None) if seq is not None else None
            extra = {"sequence": seq, "known": entry is not None}
            if entry is not None:
                extra.update(revision=entry.revision, display=entry.display)
                self.pending_bytes -= entry.size
                for seqs in self.display_sequences.values():
                    seqs.discard(seq)
            self.drain()
        elif type_ == "ping":
            self.send_control({"type": "pong", "time": obj["time"] if "time" in obj else 0})
        elif type_ in ("pointer", "wheel", "key", "text"):
            accepted, reason, details = self.handle_input(type_, obj, bridge)
            extra = {"accepted": accepted, "reason": reason, **details}
        else:
            self.error("message", "Unknown message type")
            extra = {"unknownType": True}
        self.record_in(type_, obj, raw, typeWarnings=bridge.warnings or None, **extra)

    def handle_hello(self, type_, obj, bridge):
        host = self.host
        version = bridge.int_(obj, "version")
        password = Bridge.str_(obj, "password")
        valid = type_ == "hello" and version == 1 and password is not None and host.verify(password)
        if valid and self.applies_global("auth-fail"):
            valid = False
        if not valid:
            host.failed_attempts.append(time.monotonic())
            self.closing = True
            self.event("authenticationRejected")
            self.error("authentication", AUTH_ERROR, then=lambda: self.close(reason="authentication rejected"))
            return "rejected"
        busy = host.active is not None and not host.active.closed
        if not busy:
            host.password_ok_count += 1
            if "busy" in host.scenarios:
                busy = True
            elif "busy-first-N" in host.scenarios and host.password_ok_count <= host.scenarios["busy-first-N"].number:
                busy = True
        if busy:
            self.closing = True
            self.event("busy")
            self.send_control({"type": "error", "code": "busy", "message": BUSY_ERROR}, then=lambda: self.close(reason="busy"))
            return "busy"
        self.authenticated = True
        host.active = self
        host.auth_sessions += 1
        self.auth_index = host.auth_sessions
        self.anomalies_pending = [name for name in FRAME_ANOMALIES + WIRE_ANOMALIES if self.applies(name)]
        self.event("authenticated", authIndex=self.auth_index)
        if self.applies("no-welcome"):
            self.silent = True
            self.event("scenario", name="no-welcome")
            return "authenticated"
        if self.applies("close-after-welcome"):
            self.closing = True
            self.send_control(self.welcome_payload(), then=lambda: self.close(reason="close-after-welcome"))
            return "authenticated"
        self.send_control(self.welcome_payload())
        for name, fn in (("drop-after", self.scenario_drop), ("stall-after", self.scenario_stall),
                         ("topology-change-after", self.scenario_topology), ("capture-error-after", self.scenario_capture_error)):
            if self.applies(name):
                self.later(host.scenarios[name].seconds, fn)
        return "authenticated"

    def applies_global(self, name):
        return name in self.host.scenarios

    def welcome_payload(self, type_="welcome"):
        host = self.host
        return {"type": type_, "version": 1, "serverName": host.server_name, "sessionId": self.session_id,
                "displays": [d.json() for d in host.displays],
                "capabilities": {"codecs": ["png", "jpeg"], "audio": list(host.audio_caps),
                                 "colorModes": ["gray16", "color256", "rgb565", "full"], "maxViewers": 1}}

    # -- subscription (applySubscription) --------------------------------------------------------

    def reject(self, code, message):
        self.error(code, message)
        self.event("subscriptionRejected", code=code, message=message)
        return {"outcome": "rejected", "error": message}

    def apply_subscription(self, o, b):
        host = self.host
        revision = b.int_(o, "revision")
        ids = Bridge.str_list(o, "displays")
        w, h = b.int_(o, "maxWidth"), b.int_(o, "maxHeight")
        preset = next((k for k, size in RESOLUTION_SIZES.items() if size == (w, h)), None)
        color, quality = Bridge.str_(o, "color"), Bridge.str_(o, "quality")
        fps, bandwidth = b.int_(o, "fps"), b.int_(o, "bandwidthKbps")
        known = {d.id for d in host.displays}
        valid = (revision is not None and revision >= 0 and revision > self.sub.revision
                 and ids is not None and len(ids) <= 16 and len(set(ids)) == len(ids) and all(i in known for i in ids)
                 and preset is not None and color in COLORS and quality in QUALITIES
                 and fps is not None and 1 <= fps <= 60
                 and bandwidth is not None and (bandwidth == 0 or 100 <= bandwidth <= 100000))
        rejecting = host.scenarios.get("reject-subscriptions-from")
        if valid and rejecting is not None and rejecting.applies(self.auth_index) and revision >= rejecting.number:
            return self.reject("subscription", SUBSCRIPTION_ERROR)
        if not valid:
            return self.reject("subscription", SUBSCRIPTION_ERROR)
        regions = {}
        if "regions" in o:
            raw = o["regions"]
            well_typed = isinstance(raw, dict) and all(
                isinstance(v, dict) and all(b.as_double(x, f"regions.{k}.{kk}") is not None for kk, x in v.items())
                for k, v in raw.items())
            if not well_typed:
                return self.reject("subscription", REGION_MAP_ERROR)
            for key, v in raw.items():
                vals = [b.as_double(v[f], f"regions.{key}.{f}") if f in v else None for f in ("x", "y", "width", "height")]
                if key not in ids or any(x is None for x in vals):
                    return self.reject("subscription", REGION_ERROR)
                x, y, rw, rh = vals
                if not (all(math.isfinite(n) for n in vals) and x >= 0 and y >= 0 and rw >= 0 and rh >= 0
                        and (rw == 0) == (rh == 0) and x + rw <= 1.0001 and y + rh <= 1.0001):
                    return self.reject("subscription", REGION_ERROR)
                regions[key] = (x, y, rw, rh)
        selected = [next(d for d in host.displays if d.id == i) for i in ids]
        actual = common_resolution(preset, selected)
        audio_codec = o["audioCodec"] if isinstance(o.get("audioCodec"), str) else "mulaw"
        audio_bitrate = b.int_(o, "audioBitrate")
        audio_bitrate = 96000 if audio_bitrate is None else audio_bitrate
        if audio_codec not in ("mulaw", "aac") or audio_bitrate not in AUDIO_BITRATES:
            return self.reject("subscription", AUDIO_QUALITY_ERROR)
        paused = b.bool_(o, "paused") or False
        audio = (b.bool_(o, "audio") or False) and host.audio_enabled
        nxt = Subscription(revision, ids, actual, color, quality, fps, bandwidth, paused, audio, audio_codec, audio_bitrate,
                           b.bool_(o, "dither") or False, b.bool_(o, "viewOnly") or False, regions)
        cur = self.sub
        preserve = (nxt.audio and cur.audio and nxt.audio_codec == cur.audio_codec and nxt.audio_bitrate == cur.audio_bitrate
                    and self.audio_task is not None)
        if nxt.audio and nxt.audio_codec == "aac" and not preserve and not host.aac_available:
            return self.reject("capture", AAC_INIT_ERROR)
        now = time.monotonic()
        old_sub, old_canvases, old_encoders = cur, dict(self.canvases), self.encoders
        self.stop_capture(include_audio=not preserve)
        self.release_input("subscription")
        self.sub = nxt
        self.capture_failed = False
        self.cursor_key = ""
        self.outbound.clear()
        self.pending_bytes = sum(f.size for f in self.in_flight.values())
        self.encoders, self.processing, self.display_sequences = {}, set(), {}
        self.tokens = float(max(65536, bandwidth * 125))
        self.last_token_time = now
        self.canvases = {d.id: scaled_size(d, actual) for d in selected}
        response = {"type": "subscribed", "revision": revision,
                    "displays": [{"id": d.id, "width": self.canvases[d.id][0], "height": self.canvases[d.id][1]} for d in selected],
                    "paused": nxt.paused, "audio": nxt.audio, "audioCodec": nxt.audio_codec,
                    "audioBitrate": nxt.audio_bitrate if nxt.audio_codec == "aac" else 192000, "resolution": actual}
        if actual != preset:
            response["notice"] = f"Resolution limited to {actual.upper()} by the selected displays."
        self.send_control(response, then=lambda: self.start_capture(revision))
        self.event("subscribed", revision=revision, resolution=actual, audioPreserved=preserve,
                   canvases={k: f"{v[0]}x{v[1]}" for k, v in self.canvases.items()})
        if self.first_subscribed_at is None:
            self.first_subscribed_at = now
        self.stale = None
        if self.applies("stale-burst") and old_sub.revision >= 0 and old_sub.ids and not old_sub.paused:
            displays = [(d, old_canvases[d.id], old_sub.regions.get(d.id)) for d in host.displays
                        if d.id in old_sub.ids and d.id in old_canvases and not old_sub.region_empty(d.id)]
            if displays:
                self.stale = {"sub": old_sub, "displays": displays, "encoders": old_encoders, "until": now + 0.3,
                              "last": float("-inf"), "frame": self.frame}
                self.emit_stale(now)
        return {"outcome": "accepted", "revision": revision}

    # -- capture, frames and flow control ----------------------------------------------------------

    def start_capture(self, revision):
        s = self.sub
        if s.revision != revision or self.closed:
            return
        if not (s.ids or s.audio) or not (not s.paused or s.audio):
            return
        if s.audio and self.audio_task is None:
            self.audio_generation += 1
            self.audio_task = asyncio.create_task(self.audio_loop(self.audio_generation, s.audio_codec, s.audio_bitrate))
            self.event("audioStarted", codec=s.audio_codec, bitrate=s.audio_bitrate, revision=revision)
        self.capture_revision = revision

    def stop_capture(self, include_audio=True):
        self.capture_revision = None
        if include_audio:
            self.audio_generation += 1
            if self.audio_task is not None:
                self.audio_task.cancel()
                self.audio_task = None
                self.event("audioStopped")
            self.audio_outbound.clear()

    def tick(self):
        if self.closed or self.closing or self.stalled or not self.authenticated or self.silent:
            return
        now = time.monotonic()
        s = self.sub
        elapsed, self.last_token_time = now - self.last_token_time, now
        rate = float(s.bandwidth if s.bandwidth else 100000) * 125
        self.tokens = min(max(65536.0, rate), self.tokens + elapsed * rate)
        self.drain()
        if any(now - f.sent > self.host.ack_timeout for f in self.in_flight.values()):
            self.closing = True
            self.event("ackTimeout", inFlight=len(self.in_flight))
            self.error("timeout", TIMEOUT_ERROR, then=lambda: self.close(reason="ack timeout"))
            return
        fps = max(1, min(self.host.fps, s.fps))
        if (self.capture_revision == s.revision and not self.capture_failed and not s.paused and s.ids
                and now - self.last_frame_time >= 1.0 / fps):
            self.last_frame_time = now
            self.frame += 1
            for display_id in s.ids:
                d = self.host.display(display_id)
                if d is not None:
                    self.accept_image(d, self.frame, now)
        if self.stale is not None:
            if now >= self.stale["until"]:
                self.stale = None
            elif now - self.stale["last"] >= 1.0 / fps:
                self.emit_stale(now)
        if self.anomalies_pending and self.first_subscribed_at is not None:
            for name in list(self.anomalies_pending):
                scenario = self.host.scenarios[name]
                delay = scenario.seconds if scenario.seconds is not None else self.host.anomaly_delay
                if now >= self.first_subscribed_at + delay and self.fire_anomaly(name):
                    self.anomalies_pending.remove(name)
        if self.applies("cursor") and not s.paused and now - self.last_cursor_time >= 0.05:
            self.last_cursor_time = now
            self.send_cursor(now)
        if now - self.last_stats >= 1:
            mean = self.encode_ms / float(max(1, self.encoded_inputs))
            self.send_control({"type": "stats", "bytesSent": self.bytes_sent, "fps": self.frame_counter,
                               "streamingDisplays": [] if s.paused else list(s.ids), "audio": s.audio, "quality": s.quality,
                               "resolution": s.preset, "encodedInputs": self.encoded_inputs,
                               "framesSkippedBackpressure": self.skipped, "pendingImageBytes": self.pending_bytes,
                               "inFlightFrames": len(self.in_flight), "meanEncodeMs": mean, "meanRasterMs": 0.0,
                               "meanQuantizeMs": 0.0, "meanDiffMs": 0.0, "meanCodecMs": mean})
            self.frame_counter = self.skipped = self.encoded_inputs = 0
            self.encode_ms = 0.0
            self.last_stats = now

    def accept_image(self, d, frame, now):
        s = self.sub
        if self.closed or s.paused or d.id not in s.ids or s.region_empty(d.id) or d.id not in self.canvases:
            return
        if d.id in self.processing or self.display_sequences.get(d.id) or self.pending_bytes >= STOP_AND_WAIT_PENDING:
            self.skipped += 1
            return
        encoder = self.encoders.setdefault(d.id, DisplayEncoder())
        w, h = self.canvases[d.id]
        rects, use_jpeg = encoder.plan(w, h, s.regions.get(d.id, (0.0, 0.0, 1.0, 1.0)), frame, s.color, s.quality, now)
        self.processing.add(d.id)
        job = (d.index, w, h, frame, self.host.noise, rects, s.color, s.quality == "motion" and s.dither,
               "jpeg" if use_jpeg else "png", 40 if 0 < s.bandwidth < 1500 else 70)
        future = self.loop.run_in_executor(self.executor, Session.encode_job, *job)
        revision = s.revision
        future.add_done_callback(lambda f: self.host.guarded(self._encoded)(f, d, revision, w, h, encoder))

    @staticmethod
    def encode_job(index, w, h, frame, noise, rects, color, dither, codec, jpeg_quality):
        started = time.perf_counter()
        tiles = []
        for r in rects:
            payload, tw, th = encode_tile(index, w, h, frame, noise, r, color, dither, codec, jpeg_quality)
            tiles.append((r[0], r[1], tw, th, codec, payload))
        return tiles, (time.perf_counter() - started) * 1000.0

    def _encoded(self, future, d, revision, w, h, encoder):
        if future.cancelled():
            return
        if future.exception() is not None:
            raise future.exception()
        s = self.sub
        if self.closed or s.revision != revision or d.id not in s.ids or s.paused:
            return
        self.processing.discard(d.id)
        tiles, ms = future.result()
        self.encoded_inputs += 1
        self.encode_ms += ms
        if tiles:
            self.frame_counter += 1
        for x, y, tw, th, codec, payload in tiles:
            self.sequence += 1
            header = {"type": "frame", "revision": revision, "display": d.id, "x": x, "y": y, "width": tw, "height": th,
                      "canvasWidth": w, "canvasHeight": h, "codec": codec, "sequence": self.sequence}
            data = binary_message(header, payload)
            if len(data) > MAX_BINARY_BYTES or self.pending_bytes + len(data) > MAX_PENDING_BYTES or len(self.outbound) >= 256:
                encoder.reset()
                break
            self.outbound.append((data, self.sequence, d.id, revision))
            self.pending_bytes += len(data)
            self.display_sequences.setdefault(d.id, set()).add(self.sequence)
        self.drain()

    def drain(self):
        if self.closed or self.closing or self.stalled:
            return
        while self.audio_outbound and self.network_bytes < NETWORK_BUDGET:
            self.transmit(self.audio_outbound.popleft())
        now = time.monotonic()
        while (not self.audio_outbound and self.outbound and len(self.in_flight) < self.host.packet_window
               and self.network_bytes < NETWORK_BUDGET):
            data, seq, display_id, revision = self.outbound[0]
            in_flight_bytes = sum(f.size for f in self.in_flight.values())
            if self.in_flight and in_flight_bytes + len(data) > MAX_IN_FLIGHT_BYTES:
                break
            bw = self.sub.bandwidth
            if not (bw == 0 or self.tokens >= len(data) or (self.tokens > 0 and len(data) > max(65536, bw * 125))):
                break
            self.outbound.popleft()
            self.tokens -= len(data)
            self.in_flight[seq] = InFlight(len(data), now, display_id, revision)
            self.transmit(data)

    def transmit(self, data):
        self.network_bytes += len(data)
        self.bytes_sent += len(data)
        self.writer_queue.put_nowait(("binary", data, None, len(data)))

    def queue_audio(self, packet):
        self.audio_outbound.append(packet)
        while len(self.audio_outbound) > 12:
            self.audio_outbound.popleft()
        self.drain()

    async def audio_loop(self, generation, codec, bitrate):
        try:
            if codec == "aac":
                channels, cookie, packets = self.host.aac.stream(bitrate)
                duration = 1024 / 48000
            else:
                tone = MulawTone()
                duration = 480 / 24000
            index = 0
            deadline = time.monotonic()
            while not self.closed and self.audio_generation == generation:
                deadline += duration
                delay = deadline - time.monotonic()
                if delay > 0:
                    await asyncio.sleep(delay)
                elif delay < -0.25:
                    deadline = time.monotonic()
                if self.closed or self.audio_generation != generation:
                    return
                s = self.sub
                if self.stalled or self.closing or not s.audio:
                    continue
                self.sequence += 1
                if codec == "aac":
                    header = {"type": "audio", "revision": s.revision, "codec": "aac", "sampleRate": 48000, "channels": channels,
                              "sequence": self.sequence, "samples": 1024, "bitrate": bitrate, "cookie": cookie}
                    payload = packets[index % len(packets)]
                else:
                    header = {"type": "audio", "revision": s.revision, "codec": "mulaw", "sampleRate": 24000, "channels": 1,
                              "sequence": self.sequence, "samples": 480}
                    payload = tone.packet()
                index += 1
                self.queue_audio(binary_message(header, payload))
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            self.host.internal_error(exc)

    def emit_stale(self, now):
        """stale-burst: frames of the previous revision after the new `subscribed` (old canvas, old encoders)."""
        st = self.stale
        st["last"] = now
        st["frame"] += 1
        old = st["sub"]
        count = 0
        for d, (w, h), region in st["displays"]:
            encoder = st["encoders"].setdefault(d.id, DisplayEncoder())
            rgn = region or (0.0, 0.0, 1.0, 1.0)
            rects, use_jpeg = encoder.plan(w, h, rgn, st["frame"], old.color, old.quality, now)
            visible = visible_rect(rgn, w, h)
            if not rects and visible:
                sq = square_rect(w, h, st["frame"]) or (0, 0, 1, 1)
                tx, ty = sq[0] // TILE * TILE, sq[1] // TILE * TILE
                tile = rect_intersection((tx, ty, min(w, tx + TILE), min(h, ty + TILE)), visible)
                rects = [tile or (visible[0], visible[1], min(visible[2], visible[0] + 16), min(visible[3], visible[1] + 16))]
            for r in rects:
                codec = "jpeg" if use_jpeg else "png"
                payload, tw, th = encode_tile(d.index, w, h, st["frame"], self.host.noise, r, old.color,
                                              old.quality == "motion" and old.dither, codec, 70)
                self.sequence += 1
                header = {"type": "frame", "revision": old.revision, "display": d.id, "x": r[0], "y": r[1], "width": tw,
                          "height": th, "canvasWidth": w, "canvasHeight": h, "codec": codec, "sequence": self.sequence}
                data = binary_message(header, payload)
                self.outbound.append((data, self.sequence, d.id, old.revision))
                self.pending_bytes += len(data)
                count += 1
        if count:
            self.event("staleFrames", revision=old.revision, count=count)
        self.drain()

    def fire_anomaly(self, name):
        if name in WIRE_ANOMALIES:
            if name == "bad-json":
                self.send_raw(b'{"type":"stats","bytesSent":', text=True)
            elif name == "deep-json":
                self.send_raw(b'{"type":"stats","nested":' + b"[" * 100 + b"]" * 100 + b"}", text=True)
            elif name == "binary-short":
                self.send_raw(b"\x00\x00\x00", text=False)
            elif name == "header-overflow":
                body = b'{"type":"frame"}'
                self.send_raw(struct.pack(">I", len(body) + 200) + body, text=False)
            elif name == "invalid-utf8":
                self.send_raw(b'{"type":"stats","note":"\xff\xfe"}', text=True)
            elif name == "non-object":
                self.send_raw(b"[]", text=True)
            elif name == "bad-header-json":
                body = b'{"type":"frame","revision":'
                self.send_raw(struct.pack(">I", len(body)) + body + PNG_SIGNATURE, text=False)
            self.event("anomaly", name=name)
            return True
        s = self.sub
        if s.paused or s.revision < 0 or self.capture_revision != s.revision:
            return False
        target = next((i for i in s.ids if i in self.canvases and not s.region_empty(i)), None)
        if target is None:
            return False
        d = self.host.display(target)
        w, h = self.canvases[target]
        tw, th = min(16, w), min(16, h)
        pw = tw
        if name == "size-mismatch":
            pw = tw - 1 if tw > 1 else tw + 1
        payload, _, _ = encode_tile(d.index, w, h, self.frame, self.host.noise, (0, 0, pw, th), s.color, False, "png", 70)
        self.sequence += 1
        header = {"type": "frame", "revision": s.revision + 1 if name == "future-revision" else s.revision, "display": target,
                  "x": 0, "y": 0, "width": tw, "height": th, "canvasWidth": w + 16 if name == "canvas-mismatch" else w,
                  "canvasHeight": h, "codec": "h264" if name == "bad-codec" else "png", "sequence": self.sequence}
        data = binary_message(header, payload)
        self.outbound.append((data, self.sequence, target, header["revision"]))
        self.pending_bytes += len(data)
        self.event("anomaly", name=name, sequence=self.sequence, display=target)
        self.drain()
        return True

    def send_cursor(self, now):
        s = self.sub
        candidates = [i for i in s.ids if not s.region_empty(i) and self.host.display(i) is not None]
        if not candidates:
            return
        t = now - self.connected_at
        d = self.host.display(candidates[int(t // 3) % len(candidates)])
        x = min(0.999999, (t * 0.2) % 1.0)
        y = min(0.999999, max(0.0, 0.5 + 0.3 * math.sin(t * 1.7)))
        key = f"{d.id}:{int(d.x + x * d.logical_width)}:{int(d.y + y * d.logical_height)}"
        if key != self.cursor_key:
            self.cursor_key = key
            self.send_control({"type": "cursor", "display": d.id, "x": x, "y": y})

    # -- input (handleInput / inputKeysym bookkeeping; nothing is injected) ------------------------

    def handle_input(self, type_, o, b):
        s = self.sub
        if s.paused:
            return False, "paused", {}
        if s.view_only:
            return False, "viewOnly", {}
        if not s.ids:
            return False, "noDisplays", {}
        if type_ == "key":
            key, down = b.int_(o, "key"), b.bool_(o, "down")
            effect = keysym_effect(key) if key is not None else None
            if effect is None or down is None:  # not a Unicode scalar either: inputKeysym ignores it
                return False, "invalid", {}
            if key in MODIFIER_KEYSYMS:
                (self.held_modifiers.add if down else self.held_modifiers.discard)(MODIFIER_KEYSYMS[key])
            if effect == "key":
                (self.held_keys.add if down else self.held_keys.discard)(key)
            return True, None, {"effect": effect if effect == "key" or (effect == "text" and down) else "none"}
        if type_ == "text":
            text = Bridge.str_(o, "text")
            if text is None or len(text.encode("utf-8", "surrogatepass")) > 4096:
                return False, "invalid", {}
            return True, None, {}
        display_id = Bridge.str_(o, "display")
        if display_id is None or display_id not in s.ids or self.host.display(display_id) is None:
            return False, "invalid", {}
        x, y = b.double(o, "x"), b.double(o, "y")
        if x is None or y is None or not (math.isfinite(x) and math.isfinite(y)) or not (0 <= x <= 1 and 0 <= y <= 1):
            return False, "invalid", {}
        if type_ == "wheel":
            dx, dy = b.double(o, "dx"), b.double(o, "dy")
            if dx is None or dy is None or not (math.isfinite(dx) and math.isfinite(dy)):
                return False, "invalid", {}
            self.wheel_rx += max(-100.0, min(100.0, dx)) * 12
            self.wheel_ry += max(-100.0, min(100.0, dy)) * 12
            px, py = int(self.wheel_rx), int(self.wheel_ry)
            self.wheel_rx -= px
            self.wheel_ry -= py
            return True, None, {"pixels": [px, py]}
        mask = b.int_(o, "buttons")
        if mask is None or not 0 <= mask <= 7:
            return False, "invalid", {}
        names = ("left", "right", "middle")
        transitions = [f"{'down' if mask & (1 << i) else 'up'}:{names[i]}" for i in range(3)
                       if (mask & (1 << i)) != (self.button_mask & (1 << i))]
        self.button_mask = mask
        return True, None, ({"transitions": transitions} if transitions else {})

    def release_input(self, reason, reset_mask=True):
        """input.releaseAll() (+ buttonMask=0, heldModifiers=[] on subscription, as the host does)."""
        if self.button_mask or self.held_keys or self.held_modifiers:
            self.event("inputReleased", reason=reason, buttons=self.button_mask, keys=sorted(self.held_keys),
                       modifiers=sorted(self.held_modifiers))
        self.held_keys.clear()
        if reset_mask:
            self.button_mask = 0
            self.held_modifiers.clear()

    # -- scripted scenarios --------------------------------------------------------------------

    def topology_changed(self):
        if self.closed or not self.authenticated or self.silent:
            return
        self.stop_capture(include_audio=True)
        self.release_input("topology", reset_mask=False)
        self.sub.ids = []
        self.outbound.clear()
        self.pending_bytes = 0
        self.stale = None
        self.send_control(self.welcome_payload("displays"))
        self.error("topology", TOPOLOGY_ERROR)
        self.event("topologyChanged", displays=[d.id for d in self.host.displays])

    def scenario_drop(self):
        if not self.closed:
            self.event("scenario", name="drop-after")
            self.close(style="abort", reason="drop-after")

    def scenario_stall(self):
        if not self.closed:
            self.stalled = True
            self.event("scenario", name="stall-after")

    def scenario_topology(self):
        if not self.closed:
            scenario = self.host.scenarios["topology-change-after"]
            self.event("scenario", name="topology-change-after")
            self.host.change_topology(scenario.options[0] if scenario.options else None)

    def scenario_capture_error(self):
        if self.closed or self.closing:
            return
        if self.sub.revision < 0:
            self.later(0.25, self.scenario_capture_error)
            return
        scenario = self.host.scenarios["capture-error-after"]
        retry = next((float(o.split("=", 1)[1]) for o in scenario.options if o.startswith("retry=")), None)
        self.capture_failed = True
        self.stop_capture(include_audio=True)
        self.error("capture", CAPTURE_DENIED if "denied" in scenario.options else CAPTURE_GENERIC)
        self.event("scenario", name="capture-error-after", retry=retry)
        if retry is not None:
            self.later(retry, self.retry_capture)

    def retry_capture(self):
        if not self.capture_failed or self.closed:
            return
        self.stop_capture(include_audio=True)
        self.encoders = {}
        self.capture_failed = False
        self.event("captureRetried", revision=self.sub.revision)
        self.start_capture(self.sub.revision)

    def close(self, style=None, reason=""):
        """style: 'tls' (TLS close_notify + FIN, no WebSocket close frame — like NWConnection.cancel),
        'websocket' (close frame 1000), 'abort' (TCP RST, no close frame), 'none' (already closed)."""
        if self.closed:
            return
        self.closed = True
        for handle in self.handles:
            handle.cancel()
        self.stop_capture(include_audio=True)
        self.release_input("close")
        self.host.sessions.discard(self)
        if self.host.active is self:
            self.host.active = None
        self.executor.shutdown(wait=False, cancel_futures=True)
        style = style or self.host.close_style
        self.event("closed", reason=reason, style=style)
        self.writer_queue.put_nowait(("stop", None, None, 0))
        transport = getattr(self.ws, "transport", None)
        if style == "none" or transport is None or transport.is_closing():
            return
        if style == "abort":
            sock = transport.get_extra_info("socket")
            if sock is not None:
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                except OSError:
                    pass
            transport.abort()
        elif style == "tls":
            transport.close()
        else:
            asyncio.ensure_future(self.ws.close(1000))


# ---------------------------------------------------------------------------------------------
# The listening host (RemoteServer).

class StartupError(Exception):
    pass


class MockHost:
    def __init__(self, args, password, scenarios, cert_path, key_path):
        self.args = args
        self.password = password
        self.scenarios = scenarios
        self.displays = topology(args.topology)
        self.fps = args.fps
        self.packet_window = max(1, min(32, args.inflight))
        self.ack_timeout = args.ack_timeout
        self.auth_timeout = args.auth_timeout
        self.anomaly_delay = args.anomaly_delay
        self.noise = args.noise
        self.server_name = args.server_name
        self.close_style = args.close_style
        self.lockout = not args.no_lockout
        self.audio_caps = {"aac": ["mulaw", "aac"], "mulaw": ["mulaw"], None: []}[args.audio]
        self.audio_enabled = args.audio is not None
        self.aac_available = args.audio == "aac"
        self.aac = None
        if self.aac_available:
            try:
                self.aac = AacFixtures(args.aac_fixtures)
            except (OSError, ValueError, KeyError, TypeError) as exc:
                raise StartupError(f"Could not load AAC fixtures from {args.aac_fixtures}: {exc}") from exc
        self.cert_path, self.key_path = cert_path, key_path
        self.sessions = set()
        self.active = None
        self.failed_attempts = []
        self.auth_sessions = 0
        self.password_ok_count = 0
        self.connection_count = 0
        self.transcript = Transcript(args.transcript)
        self.started = time.monotonic()
        self.exit_code = 0
        self.stop_event = None

    def record(self, record):
        self.transcript.write({"t": round(time.monotonic(), 6), **record})

    def log(self, text):
        if self.args.log:
            sys.stderr.write(f"[mock-host +{time.monotonic() - self.started:8.3f}] {text}\n")
            sys.stderr.flush()

    def verify(self, password):
        data = password.encode("utf-8", "surrogatepass")
        return len(data) <= 1024 and hmac.compare_digest(data, self.password.encode("utf-8"))

    def display(self, display_id):
        return next((d for d in self.displays if d.id == display_id), None)

    def guarded(self, fn):
        def wrapper(*a, **k):
            try:
                return fn(*a, **k)
            except Exception as exc:  # noqa: BLE001 - a mock-host bug; fail loudly
                self.internal_error(exc)
        return wrapper

    def internal_error(self, exc):
        sys.stderr.write("mock-host: internal error\n" + "".join(traceback.format_exception(exc)))
        sys.stderr.flush()
        self.exit_code = 70
        self.record({"dir": "event", "event": "internalError", "error": repr(exc)})
        if self.stop_event is not None:
            self.stop_event.set()

    def change_topology(self, name):
        before = [d.signature() for d in self.displays]
        if name:
            new = topology(name)
        elif len(self.displays) > 1:
            new = self.displays[:-1]
        else:
            last = self.displays[-1]
            new = self.displays + [Display(_uid("hot-plugged"), "Hot-Plugged Display", len(self.displays) + 1, 1920, 1080,
                                           int(last.x + last.logical_width), 0, 1920, 1080)]
        self.displays = new
        self.record({"dir": "event", "event": "hostTopology", "displays": [d.id for d in new]})
        if [d.signature() for d in new] != before:
            for session in list(self.sessions):
                if session.authenticated:
                    session.topology_changed()

    def tls_gate(self, sslobj, server_name, context):
        """Refuse during the TLS handshake, like the host refuses before TLS completes (8 sessions or lockout)."""
        now = time.monotonic()
        self.failed_attempts = [t for t in self.failed_attempts if now - t <= 60]
        if len(self.sessions) >= 8 or (self.lockout and len(self.failed_attempts) >= 10):
            self.record({"dir": "event", "event": "refused", "sessions": len(self.sessions), "recentFailures": len(self.failed_attempts)})
            self.log("refused a connection during TLS (session limit or lockout)")
            return ssl.ALERT_DESCRIPTION_HANDSHAKE_FAILURE
        return None

    async def handler(self, ws):
        self.connection_count += 1
        await Session(self, ws, self.connection_count).run()

    def _loop_exception(self, loop, context):
        self.log(f"asyncio: {context.get('message')} {context.get('exception')!r}")

    async def run(self):
        loop = asyncio.get_running_loop()
        loop.set_exception_handler(self._loop_exception)
        self.stop_event = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, self.stop_event.set)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(self.cert_path), str(self.key_path))
        context.sni_callback = self.tls_gate
        import logging
        ws_logger = logging.getLogger("mock-host.websockets")
        ws_logger.propagate = False
        ws_logger.setLevel(logging.INFO if self.args.log else logging.CRITICAL)
        if self.args.log:
            ws_logger.addHandler(logging.StreamHandler(sys.stderr))
        # max_size as NWProtocolWebSocket.maximumMessageSize: a larger message gets close 1009 and no error message.
        server = await serve(self.handler, "127.0.0.1", self.args.port, ssl=context, compression=None,
                             ping_interval=None, ping_timeout=None, close_timeout=2, max_size=MAX_CONTROL_BYTES, max_queue=64,
                             server_header=None, logger=ws_logger)
        port = server.sockets[0].getsockname()[1]
        self.record({"dir": "event", "event": "listening", "port": port, "topology": self.args.topology,
                     "scenarios": sorted(self.scenarios), "audio": self.audio_caps,
                     "dataDir": getattr(self.args, "resolved_data_dir", None)})
        self.log(f"listening on 127.0.0.1:{port} topology={self.args.topology} scenarios={sorted(self.scenarios)}")
        print(f"Listening on port {port}", flush=True)
        await self.stop_event.wait()
        for session in list(self.sessions):
            session.close(reason="host stopped")
        server.close(close_connections=True)
        try:
            await asyncio.wait_for(server.wait_closed(), 3)
        except (asyncio.TimeoutError, Exception):  # noqa: BLE001 - shutdown is best effort
            pass
        self.record({"dir": "event", "event": "stopped", "exitCode": self.exit_code})
        print("Stopped", flush=True)


def load_identity(data_dir, regenerate):
    """Self-signed ECDSA P-256 like Security.swift (CN "Portlight Mock Host"); reused when present, as the host does."""
    cert, key = data_dir / "certificate.pem", data_dir / "identity.key"
    if regenerate or not (cert.is_file() and key.is_file()):
        for path in (cert, key):
            path.unlink(missing_ok=True)
        old_umask = os.umask(0o077)
        try:
            result = subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                                     "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-days", "3650",
                                     "-subj", "/CN=Portlight Mock Host", "-keyout", str(key), "-out", str(cert)],
                                    capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise StartupError(f"Could not generate the server's local TLS identity ({exc}).") from exc
        finally:
            os.umask(old_umask)
        if result.returncode != 0:
            raise StartupError("Could not generate the server's local TLS identity: " + result.stderr.strip())
        os.chmod(key, 0o600)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text(encoding="ascii"))
    return cert, key, ":".join(f"{b:02X}" for b in hashlib.sha256(der).digest())


def read_password(args):
    if args.password_stdin:
        line = sys.stdin.buffer.readline().decode("utf-8", "replace")
        password = line[:-1] if line.endswith("\n") else line
        password = password[:-1] if password.endswith("\r") else password
    elif args.password is not None:
        password = args.password
    else:
        password = "mock-password"
    if not 8 <= len(password.encode("utf-8")) <= 1024:
        raise StartupError("Choose a password between 8 and 1024 characters.")
    return password


def build_parser():
    p = argparse.ArgumentParser(
        prog="mock-host.py", description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=("scenarios: " + ", ".join(f"{n}" + {"flag": "", "anomaly": "[=<seconds>]"}.get(k, f"=<{k}>")
                                          for n, k in SCENARIO_NAMES.items())
                + "\n  anomaly scenarios fire once per session, --anomaly-delay (or =<seconds>) after the first subscribed."
                + "\n  topologies: " + ", ".join(TOPOLOGIES)))
    p.add_argument("--port", type=int, default=0, help="TCP port on 127.0.0.1 (0 = pick a free port; default 0)")
    p.add_argument("--data-dir", help="identity directory (default: a temporary directory removed at exit)")
    p.add_argument("--regenerate-identity", action="store_true", help="replace an existing certificate in --data-dir")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--password-stdin", action="store_true", help="read the password from the first stdin line")
    group.add_argument("--password", help='password (default "mock-password"); prefer --password-stdin')
    p.add_argument("--topology", choices=TOPOLOGIES, default="fixture3")
    p.add_argument("--scenario", action="append", default=[], metavar="NAME[=VALUE][@N]", help="repeatable")
    p.add_argument("--fps", type=int, default=10, help="synthetic capture rate cap, 1-60 (default 10)")
    p.add_argument("--audio", choices=("aac", "mulaw"), help='aac advertises ["mulaw","aac"]; mulaw advertises ["mulaw"]')
    p.add_argument("--aac-fixtures", default=str(DEFAULT_AAC_FIXTURES))
    p.add_argument("--inflight", type=int, default=32, help="in-flight packet window, clamped 1-32 (default 32)")
    p.add_argument("--ack-timeout", type=float, default=15.0, help="seconds before the timeout error (default 15)")
    p.add_argument("--auth-timeout", type=float, default=120.0, help="seconds an unauthenticated socket may stay open")
    p.add_argument("--anomaly-delay", type=float, default=0.5, help="seconds after the first subscribed (default 0.5)")
    p.add_argument("--noise", action="store_true", help="static incompressible block (large keyframes, 2 MiB rule)")
    p.add_argument("--server-name", default="Portlight Mock Host")
    p.add_argument("--close-style", choices=("tls", "websocket"), default="tls",
                   help="how the host ends sessions: tls = no WebSocket close frame, like NWConnection.cancel (default)")
    p.add_argument("--no-lockout", action="store_true", help="disable the 10-failures-per-60-s connection lockout")
    p.add_argument("--transcript", help="JSON-lines transcript file")
    p.add_argument("--log", action="store_true", help="human-readable log on stderr")
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not 1 <= args.fps <= 60:
        parser.error("--fps must be 1-60")
    if not 0 <= args.port <= 65535:
        parser.error("--port must be 0-65535")
    if args.port == 5920:  # live hosts listen on *:5920; a 127.0.0.1 bind there could shadow one
        parser.error("--port 5920 is the live Portlight Host port; use 0 for a free port")
    for name in ("ack_timeout", "auth_timeout", "anomaly_delay"):
        value = getattr(args, name)
        if not math.isfinite(value) or value < 0 or (name != "anomaly_delay" and value == 0):
            parser.error(f"--{name.replace('_', '-')} must be positive")
    scenarios = {}
    for spec in args.scenario:
        try:
            scenario = Scenario(spec)
        except ValueError as exc:
            parser.error(f"--scenario {spec}: {exc}")
        if scenario.name != "normal":
            scenarios[scenario.name] = scenario
    created_dir = None
    host = None
    try:
        password = read_password(args)
        if args.data_dir:
            data_dir = Path(args.data_dir).expanduser().resolve()
            data_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        else:
            data_dir = created_dir = Path(tempfile.mkdtemp(prefix="portlight-mock-host-"))
        cert, key, fingerprint = load_identity(data_dir, args.regenerate_identity)
        args.resolved_data_dir = str(data_dir)
        host = MockHost(args, password, scenarios, cert, key)
        print(f"TLS SHA256 {fingerprint}", flush=True)
        asyncio.run(host.run())
        return host.exit_code
    except StartupError as exc:
        sys.stderr.write(f"Portlight could not start: {exc}\n")
        return 1
    except OSError as exc:
        print(f"Server error: {exc}", flush=True)
        return 1
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        return 70
    finally:
        if host is not None:
            host.transcript.close()
        if created_dir is not None:
            shutil.rmtree(created_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
