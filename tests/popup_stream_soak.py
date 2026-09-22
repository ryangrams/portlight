#!/usr/bin/env python3
"""Exercise message state while a v0.2 video subscription stays active."""
import argparse
import asyncio
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time

import websockets
from protocol_e2e import Client
from popup_messages_e2e import run as message_checks

ROOT = Path(__file__).resolve().parent.parent
HOST = ROOT / 'server-macos/build/Portlight Host.app/Contents/MacOS/SURemoteServer'


async def soak(url, seconds):
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE  # Only the isolated loopback fixture uses this context.
    # Native v0.2 viewers send JSON pings, so disable this library's binary pings.
    async with websockets.connect(url, ssl=tls, max_size=32 * 1024 * 1024, ping_interval=None) as ws:
        client = Client(ws)
        await client.send(type='hello', version=1, password='fixture-password')
        welcome, _ = await client.receive()
        assert welcome['type'] == 'welcome', welcome
        ids = [display['id'] for display in welcome['displays'][:2]]
        await client.subscription(1, ids, color='full', fps=10)
        start = time.monotonic()
        last_frame = {display: start for display in ids}
        largest_gap = {display: 0.0 for display in ids}
        sizes = {}
        changes = 0
        responses = 0
        next_change = start + 1
        next_ping = start + 2
        pings = set()
        pongs = 0
        while time.monotonic() - start < seconds:
            now = time.monotonic()
            if now >= next_change:
                operation = changes % 4
                if operation == 0:
                    await client.send(type='popupMessage', text='Live message ' + str(changes), durationSeconds=0,
                                      runs=[dict(start=0, length=4, color='#FFCC00', underline=True)])
                elif operation == 1:
                    await client.send(type='popupMessage', text='Timed message ' + str(changes), durationSeconds=1)
                elif operation == 2:
                    await client.send(type='clearPopupMessage')
                else:
                    await client.send(type='setPopupMessageDisplays', displayIDs=[welcome['displays'][2]['id']])
                changes += 1
                next_change = now + 3
            if now >= next_ping:
                stamp = int((now - start) * 1000)
                pings.add(stamp)
                await client.send(type='ping', time=stamp)
                next_ping = now + 2
            try:
                header, _ = await client.receive(.5)
            except asyncio.TimeoutError:
                assert all(time.monotonic() - last_frame[d] < 3 for d in ids), 'Video stalled'
                continue
            kind = header['type']
            assert kind not in ('error', 'welcome', 'displays', 'subscribed'), ('Stream reset during messaging', header)
            if kind == 'frame':
                display = header['display']
                assert display in ids and header['revision'] == 1, header
                size = (header['canvasWidth'], header['canvasHeight'])
                assert sizes.setdefault(display, size) == size, ('Canvas size changed', header)
                now = time.monotonic()
                largest_gap[display] = max(largest_gap[display], now - last_frame[display])
                last_frame[display] = now
            elif kind == 'popupMessageState':
                responses += 1
            elif kind == 'pong':
                assert header['time'] in pings, header
                pings.remove(header['time'])
                pongs += 1
        await client.send(type='clearPopupMessage')
        assert responses >= changes and pongs > seconds // 3, (responses, changes, pongs)
        assert all(client.frames[d] > seconds for d in ids), client.frames
        assert max(largest_gap.values()) < 3, largest_gap
        print(json.dumps(dict(ok=True, durationSeconds=seconds, messageChanges=changes,
                              messageStates=responses, frames=dict(client.frames),
                              largestFrameGapSeconds=largest_gap, subscriptionRevision=1,
                              unexpectedResubscriptions=0, responsivePings=pongs), indent=2))


def run(seconds):
    with tempfile.TemporaryDirectory(prefix='portlight-message-soak-') as temporary:
        folder = Path(temporary)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        with (folder / 'host.log').open('w+') as log:
            host = subprocess.Popen([str(HOST), '--fixture', '--port', str(port), '--data-dir', temporary,
                                     '--password-stdin'], stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
            try:
                host.stdin.write('fixture-password\n')
                host.stdin.close()
                for _ in range(150):
                    if host.poll() is not None:
                        raise RuntimeError('Fixture Host exited')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.1)
                else:
                    raise RuntimeError('Fixture Host did not listen')
                url = f'wss://127.0.0.1:{port}/remote'
                asyncio.run(message_checks(url, 'fixture-password'))
                asyncio.run(soak(url, seconds))
            except Exception:
                log.flush()
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=120)
    run(parser.parse_args().seconds)
