#!/usr/bin/env python3
"""Offline source contracts only: never a substitute for native/device tests."""
from pathlib import Path
import json, plistlib
ROOT = Path(__file__).resolve().parents[1]
checks = 0

def text(path):
    return (ROOT / path).read_text()

def require(value, label):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1

content = text('app/TingFlow/ContentView.swift')
stores = {'emby': ('Emby/EmbyStore.swift', 'oldValue !== auth'),
          'subsonic': ('Subsonic/SubsonicStore.swift', 'oldValue !== auth'),
          'netease': ('Netease/NeteaseStore.swift', 'oldValue !== client'),
          'kugou': ('Kugou/KugouStore.swift', 'oldValue != credential')}
for name, (path, guard) in stores.items():
    source = text('app/TingFlow/' + path)
    require('@Published private(set) var playbackContextID = UUID()' in source,
            name + ': observable random epoch')
    require(guard + ' { playbackContextID = UUID() }' in source,
            name + ': replacement invalidates epoch')
    require('.onChange(of: ' + name + '.playbackContextID) { _ in player.transitionResolutionContextDidChange() }' in content,
            name + ': epoch reaches transition cancellation')
require('if player.queue.contains(where: { $0.platform == platform }) { player.stop() }' in content,
        'existing account-scope playback stop is preserved')
project = text('project.yml')
require('UIBackgroundModes:\n          - audio' in project, 'background audio declaration')
require('PRODUCT_BUNDLE_IDENTIFIER: com.ikamio.tingflow' in project, 'stable application identity')
player = text('app/TingFlow/Playback/PlayerStore.swift')
for marker in ('try audio.setCategory(.playback', 'try audio.setActive(true)',
               'MPNowPlayingInfoCenter.default().nowPlayingInfo = info',
               'MPRemoteCommandCenter.shared()', 'bind(center.playCommand)',
               'bind(center.pauseCommand)', 'bind(center.nextTrackCommand)'):
    require(marker in player, 'preserved media ownership contract: ' + marker)
nav = text('ui-tests/NavigationSmokeTests.swift')
require('testBackgroundReturnPreservesCurrentSongAndPlayerNavigation' in nav and
        'app.activate()' in nav and 'runningBackground' in nav,
        'native app re-entry regression exists (not proof of OS media-card tap)')
native = text('scripts/check_native.sh')
for filename in ('check_search_comments.py', 'SearchStoreChecks.swift', 'check_kugou.py --native',
                 'check_transitions.py', 'check_integration.py', 'PlaybackOnsetTap.swift',
                 'SongCommentTransportChecks.swift', 'SourceImportLifecycleChecks.swift'):
    require(filename in native, 'required native gate: ' + filename)
workflow = text('.github/workflows/ios.yml')
require('continue-on-error:' not in workflow, 'no weakened CI failure semantics')
for marker in ('id: native-checks', 'id: release-build', 'id: ui-tests',
               'if: always()', 'build/NativeUI.xcresult', 'VERIFICATION_STATUS.json'):
    require(marker in workflow, 'verification evidence contract: ' + marker)
require('TingFlow-unsigned-' in workflow and 'Unsigned IPA; UI test result is recorded separately.' in workflow,
        'packaged app is not mislabeled as full validation')
plist = ROOT / 'app/TingFlow/Info.plist'
if plist.exists():
    info = plistlib.loads(plist.read_bytes())
    require('audio' in info.get('UIBackgroundModes', []), 'generated app background mode')
    require(not info.get('UIFileSharingEnabled', False), 'Release file sharing remains disabled')
    require(not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False),
            'Release arbitrary network loads remain disabled')
print(f'PASS: {checks} offline integration source contracts')
print('No Swift compilation, simulator/device media-card tap, account request or audio validation was performed.')
