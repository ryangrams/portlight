#!/usr/bin/env python3
"""Capture bounded, synthetic native UI fixtures. No server, input, or ZeroTier activity."""
import argparse
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=pathlib.Path, default=root / 'build/design-review')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
app = root / 'build/Portlight.app/Contents/MacOS/su-remote-viewer'
shots = []
for stage in ('setup', 'session'):
    for appearance in ('light', 'dark'):
        for size in ('normal', 'minimum'):
            shots.append((stage, appearance, size, None))
for appearance in ('light', 'dark'):
    for popover in ('settings', 'displays'):
        shots.append(('session', appearance, 'normal', popover))
regression = args.output / 'ui-regression.json'
subprocess.run([str(app), '--ui-check', str(regression.resolve())], check=True, timeout=15)
regression_result = json.loads(regression.read_text())
if not regression_result.get('passed'):
    raise RuntimeError(f"Native UI regression failed: {regression_result}")
print(f"PASS {len(regression_result['checks'])} native UI regression checks", flush=True)
outputs = []
for stage, appearance, size, popover in shots:
    name = f'{stage}-{appearance}-{size}' + (f'-{popover}' if popover else '') + '.png'
    output = args.output / name
    command = [str(app), '--ui-snapshot', stage, '--appearance', appearance, '--size', size, '--snapshot', str(output.resolve())]
    if popover:
        command += ['--popover', popover]
    subprocess.run(command, check=True, timeout=15)
    if not output.exists() or output.stat().st_size < 1000:
        raise RuntimeError(f'Capture failed: {output}')
    outputs.append({'stage': stage, 'appearance': appearance, 'size': size, 'popover': popover, 'file': name})
    print(name, flush=True)
(args.output / 'index.json').write_text(json.dumps({'product': 'Portlight', 'version': '0.2.0', 'synthetic': True, 'screenshots': outputs}, indent=2) + '\n')
