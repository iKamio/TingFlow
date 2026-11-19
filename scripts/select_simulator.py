#!/usr/bin/env python3
"""Select an installed iPhone on iOS 26, without inventing a runtime name."""
import json, subprocess
info = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
choices = []
for runtime, devices in info['devices'].items():
    if '.iOS-26-' not in runtime:
        continue
    for d in devices:
        if d.get('isAvailable') and d.get('name', '').startswith('iPhone'):
            choices.append((runtime, d['name'] == 'iPhone 17 Pro', d['udid']))
if not choices:
    raise SystemExit('No installed iOS 26 iPhone simulator')
print(sorted(choices, reverse=True)[0][2])
