#!/usr/bin/env python3
"""Exercise native message buttons while checking the fixture picture stays live."""
import argparse
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=int, default=120)
args = parser.parse_args()
server_app = pathlib.Path(os.environ.get('PORTLIGHT_TEST_SERVER', str(root.parent / 'server-macos/build/Portlight Host.app/Contents/MacOS/SURemoteServer')))
binary = root / 'build/popup-stream-test'
binary.parent.mkdir(exist_ok=True)
sources = [str(path) for path in (root / 'Sources').glob('*.swift') if path.name != 'main.swift']
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', *sources, str(root.parent / 'shared/AAC.swift'), str(root / 'tests/stream/main.swift'), '-framework', 'AppKit', '-framework', 'Network', '-framework', 'AVFoundation', '-framework', 'CryptoKit', '-framework', 'Security', '-o', str(binary)], check=True)
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='portlight-native-popup-stream-') as folder:
    test_dir = pathlib.Path(folder)
    with (test_dir / 'server.log').open('w') as log:
        server = subprocess.Popen([str(server_app), '--fixture', '--port', str(port), '--data-dir', folder, '--password-stdin'], stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
        try:
            server.stdin.write('fixture-password\n'); server.stdin.close()
            for _ in range(200):
                if 'Listening' in (test_dir / 'server.log').read_text():
                    break
                if server.poll() is not None:
                    raise RuntimeError('Fixture Host exited during startup')
                time.sleep(0.1)
            else:
                raise RuntimeError('Fixture Host did not start')
            fingerprint = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(test_dir / 'certificate.pem'), '-noout', '-fingerprint', '-sha256'], text=True).strip().split('=', 1)[1]
            report = root / 'build/popup-stream-report.json'
            result = subprocess.run([str(binary), str(port), fingerprint, str(report), str(args.seconds), '--ui-check'], input='fixture-password\n', text=True, timeout=args.seconds + 25)
            print(report.read_text(), flush=True)
            result.check_returncode()
            assert json.loads(report.read_text())['passed']
        finally:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
