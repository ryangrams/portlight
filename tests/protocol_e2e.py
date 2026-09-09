#!/usr/bin/env python3
"""Exercise a real secure SU Remote server using synthetic monitor fixture data."""
import argparse, asyncio, io, json, ssl, struct, time
from collections import defaultdict
import websockets
from PIL import Image

class Client:
    def __init__(self, ws): self.ws=ws; self.byte_counts=defaultdict(int); self.frames=defaultdict(int)
    async def send(self, **message): await self.ws.send(json.dumps(message))
    async def receive(self, timeout=5):
        packet=await asyncio.wait_for(self.ws.recv(),timeout)
        if isinstance(packet,str): return json.loads(packet),None
        assert len(packet)>=4
        n=struct.unpack('>I',packet[:4])[0];assert 0<n<=65536 and n+4<=len(packet)
        header=json.loads(packet[4:4+n]);payload=packet[4+n:]
        if header['type']=='frame':
            assert header['codec'] in ('png','jpeg')
            with Image.open(io.BytesIO(payload)) as image:
                assert image.size==(header['width'],header['height'])
                assert header['x']>=0 and header['y']>=0
                assert header['x']+image.width<=header['canvasWidth']
                assert header['y']+image.height<=header['canvasHeight']
                image.load()
            self.byte_counts[header['display']]+=len(packet);self.frames[header['display']]+=1
            await self.send(type='frameAck',sequence=header['sequence'])
        return header,payload
    async def subscription(self, revision, displays, **changes):
        state=dict(type='subscribe',revision=revision,displays=displays,maxWidth=1280,maxHeight=720,color='color256',quality='desktop',fps=5,bandwidthKbps=4000,paused=False,audio=False,viewOnly=True,regions={})
        state.update(changes);await self.send(**state)
        while True:
            m,_=await self.receive()
            if m['type']=='error':raise AssertionError(m)
            if m['type']=='subscribed' and m['revision']==revision:return m
    async def collect(self, revision, allowed, seconds=1.0, expect_frames=True):
        end=time.monotonic()+seconds;received=[]
        while time.monotonic()<end:
            try:m,payload=await self.receive(min(.3,max(.01,end-time.monotonic())))
            except asyncio.TimeoutError:continue
            assert m.get('type')!='error',m
            if m['type']=='frame':
                assert m['revision']==revision,('stale frame after subscription acknowledgement',m)
                assert m['display'] in allowed,('unselected monitor transmitted',m)
                received.append((m,payload))
        if expect_frames:assert received,'No image data received'
        else:assert not received,('Paused/out-of-viewport image data',len(received))
        return received

async def run(url,password):
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);tls.check_hostname=False;tls.verify_mode=ssl.CERT_NONE
    # Trust disabled only in this local fixture test. Native apps require fingerprint approval.
    async with websockets.connect(url,ssl=tls,max_size=32*1024*1024) as bad:
        await bad.send(json.dumps(dict(type='hello',version=1,password='incorrect-test-password')))
        reply=json.loads(await asyncio.wait_for(bad.recv(),5));assert reply['type']=='error' and reply['code']=='authentication',reply
    async with websockets.connect(url,ssl=tls,max_size=32*1024*1024) as ws:
        client=Client(ws);await client.send(type='hello',version=1,password=password,codecs=['png','jpeg'])
        welcome,_=await client.receive();assert welcome['type']=='welcome',welcome
        ids=[d['id'] for d in welcome['displays']];assert len(ids)>=3,welcome
        session=welcome['sessionId'];results=[]
        await client.subscription(1,[ids[2]])
        samples=await client.collect(1,{ids[2]},1.5)
        assert set(client.byte_counts)=={ids[2]}
        for header,payload in samples:
            with Image.open(io.BytesIO(payload)) as im:
                colors=im.convert('RGB').getcolors(im.width*im.height)
                assert colors is not None and len(colors)<=256,('256-color mode not quantized',len(colors or []))
        results.append('Only selected monitor 3 transmitted; 256-color quantization verified')
        await client.subscription(2,[ids[0]],color='gray16')
        samples=await client.collect(2,{ids[0]},1)
        for header,payload in samples:
            with Image.open(io.BytesIO(payload)) as im:
                colors=im.convert('RGB').getcolors(im.width*im.height)
                assert len(colors)<=16
                assert all(r==g==b for _,(r,g,b) in colors)
        results.append('Monitor switched within the same authenticated WebSocket; 16-shade grayscale verified')
        ack=await client.subscription(3,[ids[0],ids[2]])
        assert {d['id'] for d in ack['displays']}=={ids[0],ids[2]}
        for d in ack['displays']:assert d['width']<=1280 and d['height']<=720
        await client.collect(3,{ids[0],ids[2]},1)
        results.append('Multiple selected monitors receive server-scaled HD frames')
        await client.subscription(4,[ids[0],ids[2]],regions={ids[0]:dict(x=0,y=0,width=0,height=0),ids[2]:dict(x=0,y=0,width=0,height=0)})
        await client.collect(4,set(),.8,False)
        results.append('Fully offscreen selected monitors produce no image frames')
        await client.subscription(5,[ids[2]],paused=True)
        await client.collect(5,set(),.8,False)
        results.append('Paused viewing produces no image frames')
        await client.subscription(6,[ids[1]],color='rgb565',regions={ids[1]:dict(x=.25,y=.25,width=.25,height=.25)})
        samples=await client.collect(6,{ids[1]},1)
        red_blue={n*255//31 for n in range(32)};green={n*255//63 for n in range(64)}
        for h,payload in samples:
            assert h['x']>=h['canvasWidth']*.25 and h['y']>=h['canvasHeight']*.25
            assert h['x']+h['width']<=h['canvasWidth']*.5 and h['y']+h['height']<=h['canvasHeight']*.5
            with Image.open(io.BytesIO(payload)) as im:
                assert all(r in red_blue and g in green and b in red_blue for _,(r,g,b) in im.convert('RGB').getcolors(im.width*im.height))
        results.append('16-bit RGB565 quantization and server-side viewport crop verified')
        ack=await client.subscription(7,[ids[0],ids[1]],maxWidth=3840,maxHeight=2160)
        assert all(d['width']<=1920 and d['height']<=1080 for d in ack['displays'])
        await client.collect(7,{ids[0],ids[1]},.8)
        results.append('UHD request clamps all selected monitors to the smallest FHD source')
        await client.send(type='subscribe',revision=8,displays=['unknown-display'],maxWidth=1280,maxHeight=720,color='full',quality='auto',fps=15,bandwidthKbps=4000)
        rejected=False
        for _ in range(100):
            m,_=await client.receive()
            if m['type']=='error':assert m['code']=='subscription';rejected=True;break
        assert rejected
        results.append('Invalid monitor selection is rejected without closing the authenticated session')
        await client.send(type='ping',time=12345)
        pong=False
        for _ in range(100):
            m,_=await client.receive()
            if m['type']=='pong':assert m['time']==12345;pong=True;break
        assert pong
        results.append('Control remains responsive during frame streaming')
        print(json.dumps(dict(ok=True,sessionId=session,checks=results,encodedBytes=dict(client.byte_counts),frames=dict(client.frames)),indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--url',default='wss://127.0.0.1:15920/remote');parser.add_argument('--password',default='fixture-password');args=parser.parse_args()
    asyncio.run(run(args.url,args.password))
