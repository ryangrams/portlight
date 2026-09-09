#!/usr/bin/env python3
"""Exercise the native Windows viewer against a loopback-only encrypted fixture.

This is not a replacement for the real Mac server E2E test: it specifically checks
WinHTTP TLS/WebSockets, actual WIC frame decoding, and subscription switching.
"""
import argparse
import asyncio
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import ssl
import struct
import subprocess
import tempfile

from PIL import Image, ImageDraw
from websockets.asyncio.server import serve


def certificate(folder):
    openssl = shutil.which('openssl')
    if not openssl:
        candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/usr/bin/openssl.exe'
        if candidate.exists():
            openssl = str(candidate)
    if not openssl:
        raise RuntimeError('OpenSSL is required to generate the temporary fixture identity.')
    cert, key = folder / 'certificate.pem', folder / 'key.pem'
    subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '1',
                    '-subj', '/CN=localhost'], check=True, capture_output=True, timeout=20)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    fingerprint = ':'.join(f'{v:02X}' for v in hashlib.sha256(der).digest())
    return context, fingerprint


async def run(viewer):
    observed = {'connections': 0, 'authenticated': 0, 'subscriptions': [], 'framesSent': 0, 'acks': 0}
    displays = [dict(id=f'fixture-{i}', name=f'Test Monitor {i}', width=1920, height=1080,
                     primary=i == 1) for i in range(1, 4)]
    known = {d['id'] for d in displays}

    async def connection(ws):
        observed['connections'] += 1
        assert ws.request.path == '/remote'
        hello = json.loads(await asyncio.wait_for(ws.recv(), 10))
        assert hello.get('type') == 'hello' and hello.get('version') == 1
        assert hello.get('password') == 'temporary-fixture-password'
        observed['authenticated'] += 1
        await ws.send(json.dumps(dict(type='welcome', version=1, serverName='Synthetic test server',
                                     sessionId='windows-fixture-session', displays=displays,
                                     capabilities=dict(codecs=['png', 'jpeg'], audio=[],
                                                       colorModes=['gray16', 'color256', 'rgb565', 'full']))))
        sequence = 0
        async for packet in ws:
            assert isinstance(packet, str)
            message = json.loads(packet)
            kind = message.get('type')
            if kind == 'subscribe':
                ids = message['displays']
                assert set(ids) <= known and len(ids) == len(set(ids))
                revision = message['revision']
                observed['subscriptions'].append(dict(revision=revision, displays=ids))
                width = min(1920, message['maxWidth'])
                height = min(1080, message['maxHeight'])
                assert width > 0 and height > 0
                await ws.send(json.dumps(dict(type='subscribed', revision=revision,
                                             displays=[dict(id=id, width=width, height=height) for id in ids],
                                             paused=message.get('paused', False), audio=False)))
                if message.get('paused'):
                    continue
                for id in ids:
                    region = message.get('regions', {}).get(id, {})
                    if region.get('width', 1) == 0 or region.get('height', 1) == 0:
                        continue
                    image = Image.new('RGB', (width, height), '#162434')
                    draw = ImageDraw.Draw(image)
                    draw.rectangle((0, 0, width - 1, height // 2), fill='#a43e35')
                    draw.rectangle((0, height // 2, width - 1, height - 1), fill='#246ba7')
                    draw.text((24, 24), f'{id} - TOP - revision {revision}', fill='white')
                    encoded = io.BytesIO()
                    image.save(encoded, format='PNG')
                    sequence += 1
                    header = json.dumps(dict(type='frame', revision=revision, display=id, x=0, y=0,
                                             width=width, height=height, canvasWidth=width,
                                             canvasHeight=height, codec='png', sequence=sequence)).encode()
                    await ws.send(struct.pack('>I', len(header)) + header + encoded.getvalue())
                    observed['framesSent'] += 1
            elif kind == 'frameAck':
                assert 0 < message['sequence'] <= sequence
                observed['acks'] += 1
            elif kind == 'ping':
                await ws.send(json.dumps(dict(type='pong', time=message.get('time', 0))))
            elif kind in ('pointer', 'wheel', 'key', 'text'):
                raise AssertionError('A fixture integration test must not inject user input.')
            else:
                raise AssertionError(f'Unexpected message: {kind}')

    with tempfile.TemporaryDirectory(prefix='su-windows-fixture-') as temp:
        folder = Path(temp)
        context, fingerprint = certificate(folder)
        async with serve(connection, '127.0.0.1', 0, ssl=context, max_size=65536) as server:
            port = server.sockets[0].getsockname()[1]
            report = folder / 'viewer-report.json'
            env = dict(os.environ, SU_REMOTE_TEST_HOST=f'127.0.0.1:{port}',
                       SU_REMOTE_TEST_FINGERPRINT=fingerprint,
                       SU_REMOTE_TEST_PASSWORD='temporary-fixture-password',
                       SU_REMOTE_TEST_REPORT=str(report))
            # A log file avoids a Windows child/crash reporter inheriting a pipe
            # and keeping asyncio.communicate() alive after the viewer exits.
            log_path = folder / 'viewer.log'
            with log_path.open('wb') as log:
                process = await asyncio.create_subprocess_exec(str(viewer.resolve()), '--integration-test',
                                                              env=env, stdout=log,
                                                              stderr=asyncio.subprocess.STDOUT)
                try:
                    await asyncio.wait_for(process.wait(), 30)
                except asyncio.TimeoutError:
                    print('Viewer timed out. Protocol observations:', json.dumps(observed), flush=True)
                    process.kill()
                    await asyncio.wait_for(process.wait(), 5)
                    raise
            output = log_path.read_text(errors='replace')
            if output: print(output)
            native = json.loads(report.read_text()) if report.exists() else {}
            print('Native report:', json.dumps(native), flush=True)
            assert process.returncode == 0, f'Viewer integration exit code {process.returncode}'
            assert native.get('ok') is True and native.get('rejectedFrames') == 0, native
        assert observed['connections'] == 1 and observed['authenticated'] == 1, observed
        selections = [set(s['displays']) for s in observed['subscriptions']]
        assert {'fixture-1'} in selections and {'fixture-3'} in selections and {'fixture-1', 'fixture-3'} in selections, observed
        assert observed['acks'] >= 3, observed
        print(json.dumps(dict(ok=True, native=native, protocol=observed), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('viewer', type=Path)
    args = parser.parse_args()
    asyncio.run(run(args.viewer))
