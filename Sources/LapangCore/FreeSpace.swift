import Foundation

/// The startup volume's space. Two "free" numbers, because macOS keeps two:
/// Finder counts space the system can purge on demand (old snapshots, caches
/// it owns), `df` does not. They differed by 19 GB on 2026-11-21.
public struct VolumeSpace: Sendable, Equatable, Codable {
    public var total: Int64
    /// What Finder shows: free plus purgeable.
    public var free: Int64
    /// What `df` shows.
    public var freeStrict: Int64

    public init(total: Int64, free: Int64, freeStrict: Int64) {
        self.total = total
        self.free = free
        self.freeStrict = freeStrict
    }

    public var purgeable: Int64 { max(0, free - freeStrict) }
    public var used: Int64 { max(0, total - free) }
}

public enum FreeSpace {
    public struct Unavailable: Error {}

    /// Reads the space of the volume that holds `url` (the home folder in the app).
    public static func read(at url: URL) throws -> VolumeSpace {
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        guard
            let total = values.volumeTotalCapacity,
            let free = values.volumeAvailableCapacityForImportantUsage,
            let strict = values.volumeAvailableCapacity
        else { throw Unavailable() }
        return VolumeSpace(total: Int64(total), free: free, freeStrict: Int64(strict))
    }
}
