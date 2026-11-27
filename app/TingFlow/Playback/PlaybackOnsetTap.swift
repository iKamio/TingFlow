import AVFoundation
import AudioToolbox
import MediaToolbox
import os
import Darwin // Legacy OSAtomic generation fence supports the iOS 16 deployment target.

/// Main-actor control only. No new asset/loader/network request and never starts a player.
/// Call teardown explicitly before item/account replacement. Nil/empty means fixed-fade fallback.
@MainActor final class PlaybackOnsetTap {
    private weak var item: AVPlayerItem?
    private var tap: MTAudioProcessingTap?
    private let state: PlaybackOnsetTapState

    private init(item: AVPlayerItem, tap: MTAudioProcessingTap, state: PlaybackOnsetTapState) {
        self.item = item; self.tap = tap; self.state = state
    }
    static func install(on item: AVPlayerItem, enabled: Bool) async -> PlaybackOnsetTap? {
        guard enabled, !Task.isCancelled, item.audioMix == nil,
              let asset = item.asset as? AVURLAsset,
              !["m3u8", "m3u"].contains(asset.url.pathExtension.lowercased()) else { return nil }
        do {
            // Uses this item's existing credential-bound AVAsset, not a resolved remote URL.
            let protected = try await asset.load(.hasProtectedContent)
            try Task.checkCancellation()
            guard !protected else { return nil }
            let composable = try await asset.load(.isComposable)
            try Task.checkCancellation()
            guard composable else { return nil }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1, let track = tracks.first,
                  !Task.isCancelled, item.audioMix == nil, item.status != .failed else { return nil }
            let state = PlaybackOnsetTapState()
            // clientInfo is borrowed through synchronous Create. Init alone takes the callback retain.
            var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: Unmanaged.passUnretained(state).toOpaque(), init: onsetTapInit,
                finalize: onsetTapFinalize, prepare: onsetTapPrepare, unprepare: onsetTapUnprepare,
                process: onsetTapProcess)
            let created = withExtendedLifetime(state) {
                onsetCreateTap(MTAudioProcessingTapCreate, callbacks: &callbacks)
            }
            guard let tap = created else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            // Never mutate parameters after assigning them to a mix in use.
            item.audioMix = mix
            return PlaybackOnsetTap(item: item, tap: tap, state: state)
        } catch { return nil }
    }
    /// Explicit beat mode only; absolute asset seconds, <=12s. Re-arming always clears old evidence.
    @discardableResult func arm(start: Double, seconds: Double) -> Bool {
        guard ownsMix else { clear(); return false }
        os_unfair_lock_lock(state.lock)
        defer { os_unfair_lock_unlock(state.lock) }
        state.observedSkipped = OSAtomicIncrement32Barrier(state.skipped)
        state.resetHistory()
        return state.envelope.arm(start: start, seconds: seconds)
    }
    func clear() { state.clear() }
    /// Off-render-thread copy and attack detection. Bounded to 1,200 energies / 64 BeatOnsets.
    func snapshot() -> [BeatOnset] {
        guard ownsMix else { clear(); return [] }
        let copy = UnsafeMutablePointer<PlaybackOnsetEnergy>.allocate(capacity: PlaybackOnsetEnvelope.capacity)
        copy.initialize(repeating: PlaybackOnsetEnergy(), count: PlaybackOnsetEnvelope.capacity)
        defer { copy.deinitialize(count: PlaybackOnsetEnvelope.capacity); copy.deallocate() }
        os_unfair_lock_lock(state.lock)
        let generation = state.captureEpoch(), skipped = OSAtomicAdd32Barrier(0, state.skipped)
        var count = generation == state.preparedEpoch && state.valid && skipped == state.observedSkipped
            ? state.envelope.copy(into: copy) : 0
        // A lifecycle/drop callback can advance an atomic generation even while this reader owns the lock.
        if generation != state.captureEpoch() || skipped != OSAtomicAdd32Barrier(0, state.skipped) { count = 0 }
        os_unfair_lock_unlock(state.lock)
        return PlaybackOnsetEnvelope.onsets(Array(UnsafeBufferPointer(start: copy, count: count)))
    }
    func teardown() {
        clear()
        if ownsMix { item?.audioMix = nil }
        item = nil; tap = nil
    }
    private var ownsMix: Bool {
        guard let tap, let parameters = item?.audioMix?.inputParameters,
              parameters.count == 1 else { return false }
        return parameters[0].audioTapProcessor === tap
    }
    // Cannot touch AVPlayerItem from a nonisolated deinit. An omitted explicit teardown still disables
    // collection; the item's tap retains its context until MediaToolbox finalizes its last callback.
    deinit { state.clear() }
}

private final class PlaybackOnsetTapState {
    let lock: UnsafeMutablePointer<os_unfair_lock_s>
    let envelope = PlaybackOnsetEnvelope()
    // Only prepare/unprepare write format fields; per Apple, they never overlap process.
    // UI snapshots/control read only lock-protected fields and the atomic generation.
    let epoch: UnsafeMutablePointer<Int32>
    let skipped: UnsafeMutablePointer<Int32>
    var preparedEpoch: Int32 = -1, observedSkipped: Int32 = 0
    var valid = false, planar = false
    var channels = 0, maximumFrames = 0, windowFrames = 1
    var rate = 0.0, previous0 = 0.0, previous1 = 0.0
    init() {
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock_s())
        epoch = .allocate(capacity: 1); epoch.initialize(to: 0)
        skipped = .allocate(capacity: 1); skipped.initialize(to: 0)
    }
    deinit {
        skipped.deinitialize(count: 1); skipped.deallocate()
        epoch.deinitialize(count: 1); epoch.deallocate()
        lock.deinitialize(count: 1); lock.deallocate()
    }
    func captureEpoch() -> Int32 { OSAtomicAdd32Barrier(0, epoch) }
    func resetHistory() { previous0 = 0; previous1 = 0 }
    func clear() {
        os_unfair_lock_lock(lock)
        observedSkipped = OSAtomicIncrement32Barrier(skipped)
        envelope.clear(); resetHistory()
        os_unfair_lock_unlock(lock)
    }
    func invalidate() { envelope.resetContinuity(); resetHistory() }
    func prepare(_ description: AudioStreamBasicDescription, maximum: CMItemCount) {
        let generation = OSAtomicIncrement32Barrier(epoch)
        // If the UI is copying/resetting, fail closed until the next prepare. No callback waits.
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        preparedEpoch = generation
        invalidate()
        let flags = description.mFormatFlags
        planar = flags & kAudioFormatFlagIsNonInterleaved != 0
        channels = Int(description.mChannelsPerFrame); rate = description.mSampleRate
        let bytes = planar ? 4 : channels * 4
        valid = description.mFormatID == kAudioFormatLinearPCM && rate.isFinite
            && (8_000...192_000).contains(rate) && (1...2).contains(channels)
            && maximum > 0 && maximum <= 8_192 && description.mBitsPerChannel == 32
            && flags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
                == (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
            && flags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh) == 0
            && description.mFramesPerPacket == 1 && Int(description.mBytesPerFrame) == bytes
            && Int(description.mBytesPerPacket) == bytes
        maximumFrames = valid ? Int(maximum) : 0
        windowFrames = valid ? max(1, Int((rate * 0.01).rounded())) : 1
    }
    func unprepare() {
        _ = OSAtomicIncrement32Barrier(epoch)
        guard os_unfair_lock_trylock(lock) else { return }
        valid = false; invalidate()
        os_unfair_lock_unlock(lock)
    }
}

private func onsetTapInit(_ tap: MTAudioProcessingTap, _ client: UnsafeMutableRawPointer?,
                          _ storage: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    guard let client else { preconditionFailure("Missing tap context") }
    let state = Unmanaged<PlaybackOnsetTapState>.fromOpaque(client).takeUnretainedValue()
    storage.pointee = Unmanaged.passRetained(state).toOpaque()
}
private func onsetState(_ tap: MTAudioProcessingTap) -> PlaybackOnsetTapState {
    Unmanaged<PlaybackOnsetTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}
private func onsetTapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<PlaybackOnsetTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}
private func onsetTapPrepare(_ tap: MTAudioProcessingTap, _ maximum: CMItemCount,
                             _ description: UnsafePointer<AudioStreamBasicDescription>) {
    onsetState(tap).prepare(description.pointee, maximum: maximum)
}
private func onsetTapUnprepare(_ tap: MTAudioProcessingTap) { onsetState(tap).unprepare() }

private func onsetTapProcess(_ tap: MTAudioProcessingTap, _ requested: CMItemCount,
                             _ flags: MTAudioProcessingTapFlags,
                             _ buffers: UnsafeMutablePointer<AudioBufferList>,
                             _ framesOut: UnsafeMutablePointer<CMItemCount>,
                             _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    // Always fetch/pass through actual source audio, even disabled/unsupported/contended.
    let state = onsetState(tap)
    let beforeFetch = OSAtomicAdd32Barrier(0, state.skipped)
    framesOut.pointee = 0; flagsOut.pointee = 0
    var range = CMTimeRange(start: .invalid, duration: .invalid)
    let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flagsOut, &range, framesOut)
    if status != noErr { framesOut.pointee = 0 }
    // Separate generations distinguish an unsupported format rebuild from a dropped analysis block.
    let generation = state.captureEpoch()
    guard os_unfair_lock_trylock(state.lock) else {
        _ = OSAtomicIncrement32Barrier(state.skipped)
        return
    }
    defer { os_unfair_lock_unlock(state.lock) }
    if generation != state.preparedEpoch {
        state.invalidate(); state.preparedEpoch = generation
        // A prepare that missed its trylock must not reuse an old format.
        state.valid = false
    }
    let skipped = OSAtomicAdd32Barrier(0, state.skipped)
    if skipped != beforeFetch { return } // clear/rearm raced with GetSourceAudio; leave fresh evidence alone.
    if skipped != state.observedSkipped { state.invalidate(); state.observedSkipped = skipped }
    guard status == noErr, state.valid else { state.invalidate(); return }
    let frames = Int(framesOut.pointee)
    guard frames > 0 else { return }
    guard frames <= state.maximumFrames, frames <= 8_192,
          range.start.isNumeric, range.duration.isNumeric,
          range.start.epoch == 0, range.duration.epoch == 0 else {
        state.invalidate(); return
    }
    let start = range.start.seconds, duration = range.duration.seconds
    guard start.isFinite, start >= 0, duration.isFinite, duration > 0,
          abs(duration - Double(frames) / state.rate) <= max(0.002, 2 / state.rate) else {
        state.invalidate(); return
    }
    guard state.envelope.armed else { return }
    if !state.envelope.begin(start: start, duration: duration,
                            discontinuity: flagsOut.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0) {
        state.resetHistory()
    }
    guard state.envelope.intersects(start: start, end: start + duration) else { return }
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    let requiredBuffers = state.planar ? state.channels : 1
    guard list.count == requiredBuffers else { state.invalidate(); return }
    let stride = state.planar ? 1 : state.channels
    for index in 0..<requiredBuffers {
        let buffer = list[index]
        guard Int(buffer.mNumberChannels) == stride, let data = buffer.mData,
              Int(bitPattern: data) % MemoryLayout<Float>.alignment == 0,
              Int(buffer.mDataByteSize) >= frames * stride * MemoryLayout<Float>.size else {
            state.invalidate(); return
        }
    }
    let left = list[0].mData!.assumingMemoryBound(to: Float.self)
    let right = list[state.planar && state.channels == 2 ? 1 : 0].mData!.assumingMemoryBound(to: Float.self)
    let step = duration / Double(frames) // Authoritative asset time range, not wall clock/player elapsed.
    for frame in 0..<frames {
        let raw0 = Double(left[frame * stride])
        let value0 = raw0.isFinite ? min(1, max(-1, raw0)) : 0
        var value1 = value0
        if state.channels == 2 {
            let raw1 = Double(right[frame * stride + (state.planar ? 0 : 1)])
            value1 = raw1.isFinite ? min(1, max(-1, raw1)) : 0
        }
        let difference0 = value0 - state.previous0, difference1 = value1 - state.previous1
        state.previous0 = value0; state.previous1 = value1
        // Average channel powers, not signed samples: antiphase stereo must not cancel attacks.
        state.envelope.append(power: (value0 * value0 + value1 * value1) * 0.5,
            highPower: (difference0 * difference0 + difference1 * difference1) * 0.5,
            seconds: start + Double(frame) * step, windowFrames: state.windowFrames)
    }
}

// Apple currently documents a managed CF out parameter. Older SDKs import it as Unmanaged.
// Overload selection uses the SDK's actual declaration, preserving Create's +1 in either case.
private func onsetCreateTap(_ create: (CFAllocator?, UnsafePointer<MTAudioProcessingTapCallbacks>,
    MTAudioProcessingTapCreationFlags, UnsafeMutablePointer<MTAudioProcessingTap?>) -> OSStatus,
    callbacks: inout MTAudioProcessingTapCallbacks) -> MTAudioProcessingTap? {
    var tap: MTAudioProcessingTap?
    let status = create(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    return status == noErr ? tap : nil
}
private func onsetCreateTap(_ create: (CFAllocator?, UnsafePointer<MTAudioProcessingTapCallbacks>,
    MTAudioProcessingTapCreationFlags, UnsafeMutablePointer<Unmanaged<MTAudioProcessingTap>?>) -> OSStatus,
    callbacks: inout MTAudioProcessingTapCallbacks) -> MTAudioProcessingTap? {
    var tap: Unmanaged<MTAudioProcessingTap>?
    let status = create(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    let owned = tap?.takeRetainedValue()
    return status == noErr ? owned : nil
}
