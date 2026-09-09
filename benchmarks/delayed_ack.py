#!/usr/bin/env python3
"""Real TLS/WebSocket fixture; intentionally delayed application acknowledgments."""
import asyncio, json, socket, ssl, struct, subprocess, tempfile, time
from pathlib import Path
import websockets

ROOT=Path(__file__).resolve().parent.parent
EXE=ROOT/'server-macos/build/Portlight Host.app/Contents/MacOS/SURemoteServer'

async def run_case(port,window,mode,seconds=5,delay=.020):
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);tls.check_hostname=False;tls.verify_mode=ssl.CERT_NONE
    # Test-only loopback identity; production viewers pin the certificate first.
    async with websockets.connect(f'wss://127.0.0.1:{port}/remote',ssl=tls,max_size=32*1024*1024) as ws:
        await ws.send(json.dumps(dict(type='hello',version=1,password='benchmark-password')))
        welcome=json.loads(await ws.recv());assert welcome['type']=='welcome',welcome
        monitor=welcome['displays'][0]['id']
        async def subscribe(revision,paused=False):
            await ws.send(json.dumps(dict(type='subscribe',revision=revision,displays=[monitor],maxWidth=1920,maxHeight=1080,color=mode,quality='desktop',fps=15,bandwidthKbps=4000,paused=paused,audio=False,viewOnly=True,regions={})))
        await subscribe(1)
        start=time.monotonic();frames=tiles=byte_count=0;area=0;stats=[];ping_rtt=[];acks=set();pause_acked=False
        async def ack(sequence):
            await asyncio.sleep(delay)
            try:await ws.send(json.dumps(dict(type='frameAck',sequence=sequence)))
            except websockets.ConnectionClosed:pass
        next_ping=start
        while time.monotonic()-start<seconds:
            if time.monotonic()>=next_ping:
                await ws.send(json.dumps(dict(type='ping',time=time.monotonic())))
                next_ping=time.monotonic()+.25
            message=await asyncio.wait_for(ws.recv(),2)
            if isinstance(message,str):
                obj=json.loads(message)
                assert obj['type']!='error',obj
                if obj['type']=='stats':stats.append(obj)
                if obj['type']=='pong':ping_rtt.append((time.monotonic()-obj['time'])*1000)
                continue
            n=struct.unpack('>I',message[:4])[0];h=json.loads(message[4:4+n])
            assert h['type']=='frame' and h['revision']==1
            tiles+=1;byte_count+=len(message);area+=h['width']*h['height']
            if area>=1920*1080:frames+=1;area=0
            task=asyncio.create_task(ack(h['sequence']));acks.add(task);task.add_done_callback(acks.discard)
        elapsed=time.monotonic()-start
        # Switch while ACKs/tiles may be pending. No old frame is legal after ack.
        await subscribe(2,True)
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            message=await asyncio.wait_for(ws.recv(),2)
            if isinstance(message,str):
                obj=json.loads(message)
                if obj['type']=='subscribed' and obj['revision']==2:pause_acked=True;break
            else:
                n=struct.unpack('>I',message[:4])[0];h=json.loads(message[4:4+n])
                await ws.send(json.dumps(dict(type='frameAck',sequence=h['sequence'])))
        assert pause_acked
        until=time.monotonic()+.2
        while time.monotonic()<until:
            try:message=await asyncio.wait_for(ws.recv(),until-time.monotonic())
            except asyncio.TimeoutError:break
            assert isinstance(message,str),'Image after paused subscription acknowledged'
        if acks:await asyncio.gather(*acks)
        return dict(packetWindow=window,mode=mode,elapsedSeconds=elapsed,completeImageUpdates=frames,updatesPerSecond=frames/elapsed,imagePackets=tiles,encodedProtocolBytes=byte_count,meanKbps=byte_count*8/elapsed/1000,
                    maximumPendingImageBytes=max((s.get('pendingImageBytes',0) for s in stats),default=0),maximumInFlightPackets=max((s.get('inFlightFrames',0) for s in stats),default=0),
                    medianPingMs=sorted(ping_rtt)[len(ping_rtt)//2] if ping_rtt else None,maximumPingMs=max(ping_rtt,default=None),pauseRetiredOldFrames=True,
                    meanHostEncodeMs=sum(s.get('meanEncodeMs',0) for s in stats)/max(1,len(stats)))

def main():
    rows=[]
    for window in [4,32]:
        with tempfile.TemporaryDirectory(prefix='portlight-ack-bench-') as state:
            with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
            with open(Path(state)/'server.log','w+') as log:
                proc=subprocess.Popen([str(EXE),'--fixture','--fixture-dense','--fixture-inflight',str(window),'--port',str(port),'--data-dir',state,'--password-stdin'],stdin=subprocess.PIPE,stdout=log,stderr=log,text=True)
                proc.stdin.write('benchmark-password\n');proc.stdin.close()
                try:
                    for attempt in range(100):
                        try:
                            with socket.create_connection(('127.0.0.1',port),.1):pass
                            break
                        except OSError:time.sleep(.1)
                    else:raise RuntimeError('Fixture did not listen')
                    for mode in ['gray16','color256','rgb565','full']:
                        row=asyncio.run(run_case(port,window,mode));rows.append(row);print(json.dumps(row),flush=True);time.sleep(.1)
                except Exception:
                    log.flush();log.seek(0);print(log.read());raise
                finally:
                    proc.terminate()
                    try:proc.wait(5)
                    except subprocess.TimeoutExpired:proc.kill();proc.wait()
    report=dict(schema=1,kind='real local TLS/WebSocket transport with deliberately delayed application ACKs',source='generated changing stripes; all40tiles change each1080p frame',width=1920,height=1080,inputFps=15,bandwidthKbps=4000,ackDelayMilliseconds=20,secondsPerCase=5,encoder='optimized in both cases; packetwindow is the only transport variable',limitations='Local loopback, generated image, no physical capture or remote viewer decode. Application ACK delay is intentional; it is not a physical WAN RTT or bandwidth shaper. All modes use the same source/fps/scale/app bandwidth cap.',results=rows)
    (ROOT/'benchmarks/results/delayed-ack-loopback.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
