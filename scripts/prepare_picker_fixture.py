#!/usr/bin/env python3
"""Expose only simulator/debug test Documents to the real system file picker.
Release uses app/TingFlow/Info.plist unchanged; this file is outside app resources.
"""
from pathlib import Path
import plistlib
root = Path(__file__).resolve().parents[1]
source = root / 'app/TingFlow/Info.plist'
target = root / 'tests/SourcePicker-Debug-Info.plist'
info = plistlib.loads(source.read_bytes())
info['UIFileSharingEnabled'] = True
info['LSSupportsOpeningDocumentsInPlace'] = True
target.write_bytes(plistlib.dumps(info))
print('Prepared Debug-only Documents visibility for system picker UI tests')
