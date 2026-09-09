#!/usr/bin/env python3
"""Native viewer integration against an isolated loopback fixture server."""
import json
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent
SERVER = ROOT.parent / 'server-macos/build/SU Remote Server.app/Contents/MacOS/SURemoteServer'
VIEWER = ROOT / 'build/SU Remote Viewer.app/Contents/MacOS/su-remote-viewer'

with tempfile.TemporaryDirectory(prefix='su-native-viewer-test-') as folder:
    test_dir = pathlib.Path(folder)
    with (test_dir / 'server.log').open('w') as log:
        server = subprocess.Popen([str(SERVER), '--fixture', '--port', '15922', '--data-dir', folder, '--password-stdin'], stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
        try:
            server.stdin.write('fixture-password\n')
            server.stdin.close()
            for _ in range(200):
                if 'Listening' in (test_dir / 'server.log').read_text():
                    break
                if server.poll() is not None:
                    raise RuntimeError('Fixture server exited during startup.')
                time.sleep(0.1)
            else:
                raise RuntimeError('Fixture server did not start within 20 seconds.')
            fingerprint = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(test_dir / 'certificate.pem'), '-noout', '-fingerprint', '-sha256'], text=True).strip().split('=', 1)[1]
            report = ROOT / 'build/integration-report.json'
            snapshot = ROOT / 'build/integration-viewer.png'
            subprocess.run([str(VIEWER), '--integration-test', '15922', fingerprint, str(report), str(snapshot)], input='fixture-password\n', text=True, timeout=25, check=True)
            result = json.loads(report.read_text())
            assert result['connected'] and result['framesDecoded'] > 0 and result['framesRejected'] == 0, result
            assert len(result['selected']) == 3 and result['revision'] >= 2, result
            print(json.dumps(result, indent=2))
            print('PASS native TLS/WebSocket, monitor switching, and image decoding')
            print(snapshot)
        finally:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
