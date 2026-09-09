#!/usr/bin/env python3
import os,sys,subprocess,tempfile,socket,time,json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
exe=root/'server-macos/build/SU Remote Server.app/Contents/MacOS/SURemoteServer'
with tempfile.TemporaryDirectory(prefix='su-remote-fixture-') as state:
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    with open(Path(state)/'server.log','w+') as log:
        server=subprocess.Popen([str(exe),'--fixture','--port',str(port),'--data-dir',state,'--password-stdin'],stdin=subprocess.PIPE,stdout=log,stderr=log,text=True)
        server.stdin.write('fixture-password\n');server.stdin.close()
        try:
            ready=False
            for _ in range(150):
                if server.poll() is not None:break
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1):pass
                    ready=True;break
                except OSError:time.sleep(.1)
            if not ready:raise RuntimeError('Fixture server did not listen')
            subprocess.run([sys.executable,str(root/'tests/protocol_e2e.py'),'--url',f'wss://127.0.0.1:{port}/remote'],check=True,timeout=45)
        except Exception:
            log.flush();log.seek(0);print(log.read());raise
        finally:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
