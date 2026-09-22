#!/usr/bin/env python3
"""Check popup messages over the real Host's encrypted fixture connection."""
import argparse
import asyncio
import json
import ssl
import time

import websockets


class PopupClient:
    def __init__(self, websocket):
        self.websocket = websocket

    async def send(self, **message):
        await self.websocket.send(json.dumps(message))

    async def receive(self, expected, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            packet = await asyncio.wait_for(
                self.websocket.recv(), max(0.01, deadline - time.monotonic()))
            assert isinstance(packet, str), 'A paused popup test received media'
            message = json.loads(packet)
            if message['type'] == expected:
                return message
            assert message['type'] in ('stats', 'cursor'), message
        raise AssertionError(f'No {expected} response')

    async def state(self):
        await self.send(type='getPopupMessageState')
        return await self.receive('popupMessageState')

    async def show(self, text='Ready', duration=0, runs=None):
        message = dict(type='popupMessage', text=text, durationSeconds=duration)
        if runs is not None:
            message['runs'] = runs
        await self.send(**message)
        return await self.receive('popupMessageState')

    async def clear(self):
        await self.send(type='clearPopupMessage')
        state = await self.receive('popupMessageState')
        assert state['active'] is False and state['expiresAt'] == 0, state
        assert state['durationSeconds'] == 0, state
        return state


def check_state(state, display_ids, active):
    assert state['type'] == 'popupMessageState' and state['active'] is active, state
    assert isinstance(state['displayIDs'], list) and state['displayIDs'], state
    assert set(state['displayIDs']) <= set(display_ids), state
    assert len(state['displayIDs']) == len(set(state['displayIDs'])), state
    assert 'text' not in state and 'runs' not in state, 'State must omit message contents'


async def authenticate(websocket, password):
    client = PopupClient(websocket)
    await client.send(type='hello', version=1, password=password, codecs=['png', 'jpeg'])
    welcome = await client.receive('welcome')
    assert welcome['version'] == 1, welcome
    assert welcome['capabilities']['popupMessages'] == dict(
        maxCharacters=250, maxDurationSeconds=10800, richText=True, targetDisplays=True), welcome
    return client, welcome, await client.receive('popupMessageState')


async def run(url, password):
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    # The test runner owns this loopback fixture and its temporary identity.
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE
    options = dict(ssl=tls, max_size=65536, open_timeout=5, close_timeout=2)
    checks = []

    for command in ('popupMessage', 'clearPopupMessage', 'getPopupMessageState', 'setPopupMessageDisplays'):
        async with websockets.connect(url, **options) as websocket:
            client = PopupClient(websocket)
            await client.send(type=command, text='Unauthenticated', durationSeconds=0)
            error = await client.receive('error')
            assert error['code'] == 'authentication', error
    checks.append('Show, clear, and state query require authentication')

    async with websockets.connect(url, **options) as websocket:
        client, welcome, initial = await authenticate(websocket, password)
        display_ids = [display['id'] for display in welcome['displays']]
        primary = next(display['id'] for display in welcome['displays'] if display['primary'])
        check_state(initial, display_ids, False)
        assert initial['displayIDs'] == [primary], initial
        assert [d['id'] for d in initial['availableDisplays']] == display_ids, initial
        assert all(d['name'] and d['index'] >= 1 for d in initial['availableDisplays']), initial
        checks.append('Protocol v1 advertises popup capability and initial primary-screen state')

        await client.send(type='subscribe', revision=1, displays=[display_ids[-1]],
                          maxWidth=1280, maxHeight=720, color='full', quality='auto',
                          fps=1, bandwidthKbps=100, paused=True, audio=False, viewOnly=True)
        await client.receive('subscribed')
        assert (await client.state())['displayIDs'] == [primary]
        checks.append('Popup targets remain independent of paused, view-only stream selection')

        active = await client.show('Move this message', 0)
        for selection in ([display_ids[1]], [display_ids[0], display_ids[1]], [display_ids[1], display_ids[0]]):
            await client.send(type='setPopupMessageDisplays', displayIDs=selection)
            updated = await client.receive('popupMessageState')
            assert set(updated['displayIDs']) == set(selection), updated
            assert updated['active'] and updated['expiresAt'] == active['expiresAt'], updated
        for selection in ([], [display_ids[0], display_ids[0]], ['unknown'], 'fixture-1', None, [1]):
            await client.send(type='setPopupMessageDisplays', displayIDs=selection)
            error = await client.receive('error')
            assert error['code'] == 'popupMessage', error
            unchanged = await client.state()
            assert unchanged['displayIDs'] == updated['displayIDs'] and unchanged['expiresAt'] == active['expiresAt'], unchanged
        await client.send(type='setPopupMessageDisplays', displayIDs=[primary])
        assert (await client.receive('popupMessageState'))['displayIDs'] == [primary]
        await client.clear()
        checks.append('Client screen selection moves active messages, keeps their deadline, and rejects invalid targets')

        rich = await client.show('Ready 🎬 Go\nCafé e\u0301', 20, [
            dict(start=0, length=5, color='#FFB000'),
            dict(start=6, length=2, color='#12abEF', underline=True),
            dict(start=9, length=2, underline=True),
        ])
        check_state(rich, display_ids, True)
        assert rich['durationSeconds'] == 20, rich
        assert 15 <= rich['expiresAt'] - time.time() <= 21, rich
        checks.append('Rich Unicode accepts scalar-aligned UTF-16 color and underline ranges')

        boundary = await client.show('🎬' * 250, 10800, [dict(start=0, length=500)])
        check_state(boundary, display_ids, True)
        assert boundary['durationSeconds'] == 10800, boundary
        assert 10795 <= boundary['expiresAt'] - time.time() <= 10801, boundary
        checks.append('250 Unicode scalars and the three-hour timed limit are accepted')

        valid = dict(type='popupMessage', text='A🎬BC', durationSeconds=0)
        invalid = [
            ('missing text', dict(type='popupMessage', durationSeconds=0)),
            ('non-string text', dict(valid, text=123)),
            ('blank text', dict(valid, text=' \t\n')),
            ('251 scalars', dict(valid, text='🎬' * 251)),
            ('oversized UTF-8', dict(valid, text='🎬' * 1001)),
            ('missing duration', dict(type='popupMessage', text='Ready')),
            ('negative duration', dict(valid, durationSeconds=-1)),
            ('duration over three hours', dict(valid, durationSeconds=10801)),
            ('fractional duration', dict(valid, durationSeconds=1.5)),
            ('boolean duration', dict(valid, durationSeconds=True)),
            ('string duration', dict(valid, durationSeconds='20')),
            ('null duration', dict(valid, durationSeconds=None)),
            ('non-array runs', dict(valid, runs={})),
            ('null runs', dict(valid, runs=None)),
            ('non-object run', dict(valid, runs=[True])),
            ('missing start', dict(valid, runs=[dict(length=1)])),
            ('missing length', dict(valid, runs=[dict(start=0)])),
            ('negative start', dict(valid, runs=[dict(start=-1, length=1)])),
            ('zero length', dict(valid, runs=[dict(start=0, length=0)])),
            ('out-of-bounds range', dict(valid, runs=[dict(start=4, length=2)])),
            ('boolean start', dict(valid, runs=[dict(start=True, length=1)])),
            ('fractional length', dict(valid, runs=[dict(start=0, length=1.5)])),
            ('surrogate start', dict(valid, runs=[dict(start=2, length=1)])),
            ('surrogate end', dict(valid, runs=[dict(start=1, length=1)])),
            ('overlapping runs', dict(valid, runs=[dict(start=0, length=3), dict(start=1, length=2)])),
            ('unordered runs', dict(valid, runs=[dict(start=3, length=1), dict(start=0, length=1)])),
            ('short color', dict(valid, runs=[dict(start=0, length=1, color='#FFF')])),
            ('invalid color', dict(valid, runs=[dict(start=0, length=1, color='#GG0000')])),
            ('non-string color', dict(valid, runs=[dict(start=0, length=1, color=123)])),
            ('non-boolean underline', dict(valid, runs=[dict(start=0, length=1, underline=1)])),
            ('too many runs', dict(valid, text='a' * 250, runs=[dict(start=0, length=1)] * 251)),
        ]
        controls = list(range(0, 9)) + list(range(11, 32)) + [127, 0x061C, 0x200E, 0x200F]
        controls += list(range(0x202A, 0x202F)) + list(range(0x2066, 0x206A))
        invalid.extend((f'control U+{code:04X}', dict(valid, text=f'A{chr(code)}B'))
                       for code in controls)
        for label, message in invalid:
            await client.send(**message)
            error = await client.receive('error')
            assert error['code'] == 'popupMessage', (label, error)
            unchanged = await client.state()
            assert unchanged == boundary, (label, 'Invalid input changed popup state', unchanged)
        checks.append(f'{len(invalid)} malformed payloads are rejected without changing the current message')

        await client.show('First', 1)
        replacement = await client.show('Replacement\tmessage', 0)
        check_state(replacement, display_ids, True)
        assert replacement['durationSeconds'] == 0, replacement
        assert 10795 <= replacement['expiresAt'] - time.time() <= 10801, replacement
        await asyncio.sleep(1.25)
        assert await client.state() == replacement, 'The replaced message timer cleared its replacement'
        checks.append('Persistent messages have a three-hour deadline and survive a replaced timer')

    await asyncio.sleep(0.1)
    async with websockets.connect(url, **options) as websocket:
        client, _, retained = await authenticate(websocket, password)
        assert retained == replacement, ('Disconnect cleared the popup', retained)
        checks.append('Disconnect and reconnect retain the active message and original deadline')
        await client.clear()
        await client.clear()
        check_state(await client.state(), display_ids, False)
        checks.append('Explicit clear is idempotent and query reports the cleared state')

        shown = await client.show('Short popup', 1)
        check_state(shown, display_ids, True)
        expired = await client.receive('popupMessageState', timeout=4)
        check_state(expired, display_ids, False)
        assert expired['expiresAt'] == 0 and expired['durationSeconds'] == 0, expired
        checks.append('Timed expiry broadcasts the cleared state')
        await client.send(type='ping', time=12345)
        assert (await client.receive('pong'))['time'] == 12345
        checks.append('The authenticated session remains responsive after all validation cases')

    print(json.dumps(dict(ok=True, checks=checks), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='wss://127.0.0.1:15920/remote')
    parser.add_argument('--password', default='fixture-password')
    arguments = parser.parse_args()
    asyncio.run(run(arguments.url, arguments.password))
