import Foundation

/// Keep platform safety decisions separate from the optional, anonymous matching service.
enum NeteasePlaybackResolver {
    @MainActor static func resolve(
        native: () async throws -> PlaybackResource,
        prefersUserSource: Bool,
        userSource: (() async throws -> PlaybackResource)?,
        match: (() async throws -> PlaybackResource)?
    ) async throws -> PlaybackResource {
        let resource: PlaybackResource
        do { resource = try await native() }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            guard NeteasePlaybackSafety.allowsSourceFallback(after: error) else { throw error }
            return try await fallback(prefersUserSource: prefersUserSource, userSource: userSource, match: match, original: error)
        }
        try Task.checkCancellation()
        if prefersUserSource {
            guard let userSource else { throw MusicError.unsupported("所选音源当前不可用，请检查启用和授权状态。") }
            return try await userSource()
        }
        if resource.isPreview {
            do { return try await fallback(prefersUserSource: false, userSource: userSource, match: match, original: NeteaseError.unavailable) }
            catch {
                try checkSourceTermination(error)
                return resource
            }
        }
        return resource
    }

    @MainActor private static func fallback(
        prefersUserSource: Bool,
        userSource: (() async throws -> PlaybackResource)?,
        match: (() async throws -> PlaybackResource)?, original: Error
    ) async throws -> PlaybackResource {
        if prefersUserSource {
            guard let userSource else { throw MusicError.unsupported("所选音源当前不可用，请检查启用和授权状态。") }
            return try await userSource()
        }
        var failure = original
        if let userSource {
            do { return try await userSource() }
            catch {
                try checkSourceTermination(error)
                failure = error
            }
        }
        try Task.checkCancellation()
        if let match { return try await match() }
        throw failure
    }

    private static func checkSourceTermination(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? SourceFailure) == .cancelled { throw CancellationError() }
        if (error as? SourceFailure) == .busy { throw error }
    }
}
