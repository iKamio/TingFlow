import Foundation

/// A short-lived, in-memory challenge. Backgrounding never extends its deadline.
struct NeteaseQRWindow {
    let expiresAt: Date
    private(set) var attempts = 0
    private(set) var isPaused = false
    init(now: Date = Date()) { expiresAt = now.addingTimeInterval(180) }
    func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt || attempts >= 60 }
    mutating func pause() { isPaused = true }
    mutating func resume() { isPaused = false }
    mutating func beginCheck(at now: Date = Date()) -> Bool {
        guard !isPaused, !isExpired(at: now) else { return false }
        attempts += 1
        return true
    }
}
