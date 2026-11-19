#!/usr/bin/env python3
"""Generate an original opaque 1024px app icon; no external artwork."""
import json
from pathlib import Path
from PIL import Image, ImageDraw
root = Path(__file__).resolve().parents[1] / 'app/TingFlow/Assets.xcassets'
icons = root / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
im = Image.new('RGB', (1024, 1024), '#FAFAFB')
pixels = im.load()
for y in range(1024):
    for x in range(1024):
        f = max(0.0, 1.0 - ((x-530)**2 + (y-500)**2)**0.5/680) * 0.055
        pixels[x,y] = (250, int(250*(1-f)), int(251*(1-f/2)))
layer = Image.new('RGBA', (1024, 1024))
draw = ImageDraw.Draw(layer)
for left, top, bottom in [(290, 405, 665), (455, 250, 774), (620, 340, 700)]:
    draw.rounded_rectangle((left, top, left+110, bottom), radius=55, fill='#E93963')
layer = layer.rotate(-16, Image.Resampling.BICUBIC)
im.paste(layer, (0, 0), layer)
im.save(icons / 'AppIcon.png')
(root / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2)+'\n')
(icons / 'Contents.json').write_text(json.dumps({
    'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
    'info': {'author': 'xcode', 'version': 1}}, indent=2)+'\n')
print('Generated original opaque AppIcon.png')
