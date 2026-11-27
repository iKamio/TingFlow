#!/usr/bin/env python3
"""Offline source-contract checks and a policy oracle, NOT Swift/AVFoundation execution."""
from pathlib import Path
import itertools
import math

root = Path(__file__).resolve().parents[1]
store = (root / 'app/TingFlow/Playback/PlayerStore.swift').read_text()
policy = (root / 'app/TingFlow/Playback/PlaybackTransition.swift').read_text()
deck = (root / 'app/TingFlow/Playback/PlaybackTransitionDeck.swift').read_text()
checks = 0

def check(value, label):
    global checks
    assert value, label
    checks += 1

for text, label in [
    ('let id = UUID()', 'unique attempts'),
    ('incomingReady && incomingEligible && !incomingEnded', 'ready and eligible end gate'),
    ('if p == 1 { return (0, 1) }', 'exact equal-power endpoint'),
]:
    check(text in policy, label)
for text in ['preloadingTask = nil; resolvingTicket = nil',
             'transitionCancelledForCurrentItem = true',
             '!transitionCancelledForCurrentItem',
             'self.pendingTicket == ticket',
             'transitionSettings == PlaybackTransitionSettings.load()',
             'transitionStartDeadline = ProcessInfo.processInfo.systemUptime + 2',
             'finishListening(naturalEnd: naturalEnd)',
             'promoteIncoming(ticket, naturalEnd: true)',
             'cancelTransition(reason: "正常切歌 · 预加载音频已结束")']:
    check(text in store, text)
check('self.hasEnded = true' in deck and 'player.removeTimeObserver(clock)' in deck, 'deck end/clock cleanup')
tap = (root / 'app/TingFlow/Playback/PlaybackOnsetTap.swift').read_text()
check('let onsetCapture = PlaybackOnsetCapture()' in deck and
      'anchorOnsetCapture = PlaybackOnsetCapture()' in store, 'per-item anchor/deck ownership')
for text in ['private var installation: Task<Void, Never>?', 'result?.teardown(); return',
             'self.item === item', 'operation = nil', 'installation?.cancel()',
             'let evidence = discard ? [] : (onsetCapture.tap?.snapshot() ?? [])',
             'player.volume = 0', 'addBoundaryTimeObserver',
             'PlaybackTransitionPreparationPolicy.continueProbe', '20_000_000',
             'PlaybackTransitionPreparationPolicy.acceptsRewind', 'finishSeek(false)',
             'seekCompletion = nil', 'item.cancelPendingSeeks()']:
    check(text in deck, text)
probe = deck.split('    private func finishProbe(', 1)[1].split('    func attach(', 1)[0]
check(probe.index('snapshot()') < probe.index('resetWindow()') < probe.index('player.pause()'),
      'snapshot before disarm/pause')
dispose = deck.split('    func dispose() {', 1)[1].split('    deinit {', 1)[0]
check(dispose.index('onsetCapture.stop()') < dispose.index('replaceCurrentItem(with: nil)') < dispose.index('loader?.invalidate()'),
      'detach tap before item replacement/loader invalidation')
prepare = store.split('    private func prepareTransition(', 1)[1].split('    private func transitionTicketIsCurrent', 1)[0]
check(prepare.index('let sought = await deck.seek') < prepare.index('guard sought else') < prepare.index('pendingPrepared = true'),
      'prepared only after checked exact restore')
check('PlaybackTransitionPreparationPolicy.canPrepare(' in prepare and 'try Task.checkCancellation()' in prepare,
      'shared preparation deadline/current gates')
check('outgoing.url.isFileURL && resource.url.isFileURL' in prepare, 'remote never reaches local reader path')
check('onStarted' not in prepare + deck and 'sampleListening' not in deck, 'probe has no history/current-song callbacks')
check('activeOnsetCapture.stop()' in store and 'incoming.onsetCapture.resetWindow()' in store,
      'cancel/retire and promotion reset capture')
check('PlaybackTransitionPreparationPolicy.missedPlan' in store, 'runtime missed plan refused')
check('Task.checkCancellation()' in tap and 'item.asset as? AVURLAsset' in tap, 'same-asset cancelled installation')
process = tap.split('private func onsetTapProcess(', 1)[1].split('// Apple currently documents', 1)[0]
for forbidden in ['.allocate(', 'Task {', 'DispatchQueue', 'os_unfair_lock_lock(', 'URLSession', 'print(']:
    check(forbidden not in process, 'render callback excludes ' + forbidden)
check('OSAtomicIncrement32Barrier' in tap and 'OSAtomicAdd32Barrier' in tap, 'atomic lifecycle/drop fences retained')
retire = store.split('    private func retire() {', 1)[1].split('    private func fail(', 1)[0]
check('finishListening(naturalEnd: false)' in retire and 'naturalEnd: naturalEnd' not in retire,
      'retire uses non-natural listening completion')
check('func promoteIncoming(_ ticket: PlaybackTransitionTicket, naturalEnd: Bool = false)' in store,
      'promotion completion reason is explicit')
check('URLSession' not in store + deck + policy, 'no new downloader')
project = (root / 'project.yml').read_text()
check("- '**/PlaybackOnsetTap.swift'" not in project, 'sampler included in app/Release source set')
check('MediaToolbox.framework' in project and 'AudioToolbox.framework' in project, 'required tap frameworks')
native = (root / 'scripts/check_native.sh').read_text()
check('-target arm64-apple-ios16.0 -typecheck' in native and 'PlaybackOnsetTap.swift' in native,
      'actual tap iPhoneOS arm64 SDK typecheck gate')
for name in ['PlaybackTransitionChecks.swift', 'PlaybackOnsetTapChecks.swift']:
    check(native.count(name) == 1, 'single native integration: ' + name)
check('playback-transition-status' in (root / 'app/TingFlow/UI/NowPlayingView.swift').read_text(), 'status UI')

# Independent oracle: exercise policy inputs and both timer/end orderings.
for bits in itertools.product([False, True], repeat=6):
    playing, prepared, one, ready, eligible, ended = bits
    promote = playing and prepared and not one and ready and eligible and not ended
    check(promote == (bits == (True, True, False, True, True, False)), 'gate truth table')
for curve in ['linear', 'equalPower']:
    for n in range(101):
        p = n / 100
        a, b = (1-p, p) if curve == 'linear' else (math.cos(p*math.pi/2), math.sin(p*math.pi/2))
        check(0 <= a <= 1 and 0 <= b <= 1, 'bounded envelope')
        if curve == 'equalPower':
            check(abs(a*a+b*b-1) < 1e-12, 'power oracle')
for events in [('timer', 'end'), ('end', 'timer'), ('cancel', 'timer', 'end')]:
    pending, promoted = True, 0
    for event in events:
        if event == 'cancel':
            pending = False
        elif pending:
            promoted += 1
            pending = False
    check(promoted == (0 if events[0] == 'cancel' else 1), 'single handoff model')
# Independent preparation oracle; does not claim execution of the Swift policy.
for current, restored, ready, media_ok, wall_ok in itertools.product([False, True], repeat=5):
    accepted = current and restored and ready and media_ok and wall_ok
    check(accepted == all([current, restored, ready, media_ok, wall_ok]), 'preparation gate oracle')
for completed, stale, late, exact in itertools.product([False, True], repeat=4):
    accepted = completed and not stale and not late and exact
    check(accepted == (completed and not (stale or late) and exact), 'rewind identity/deadline oracle')
for media, elapsed, budget, expected in [(0, 3, 3, False), (3, 0.2, 3, False),
        (0, 1, 1, False), (2.9, 2.9, 3, True), (0, 0, 0, False), (math.nan, 0, 3, False)]:
    running = math.isfinite(media) and 0 <= media < 3 and 0 <= elapsed < min(3, budget)
    check(running == expected, 'media plus monotonic deadline oracle')
for name in ['continueProbe', 'acceptsRewind', 'canPrepare', 'acceptsPlan', 'missedPlan', 'isCurrent']:
    check(name in policy and name in (root / 'tests/PlaybackTransitionChecks.swift').read_text(),
          'shared Swift policy regression: ' + name)
print(f'PASS: {checks} transition source-contract / Python policy-oracle checks; Swift/native NOT executed')
