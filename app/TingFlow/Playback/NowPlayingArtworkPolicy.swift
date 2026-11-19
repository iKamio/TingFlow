import Foundation

// Completion identity is selection-scoped, including repeated selections of the same song.
// A decoded cover may outlive audio retirement after an error, but never a new selection.
struct NowPlayingArtworkIdentity: Equatable {
    let generation: UUID
    let songID: String
    let url: URL

    func accepts(generation: UUID, songID: String?, url: URL?) -> Bool {
        self.generation == generation && belongsTo(songID: songID, url: url)
    }

    func belongsTo(songID: String?, url: URL?) -> Bool {
        self.songID == songID && self.url == url
    }
}
