//
//  OfflineMapStore.swift
//  TripperDashPP
//
//  Routes downloaded for offline riding. A download pins every tile the
//  renderer can read along the route (`OfflineCorridor`) into
//  `TileDiskCache`'s pinned tree, which iOS and the cache eviction never
//  touch; `TileDiskCache.read` falls back to it on a cache miss, so the
//  ride needs no other change to work without signal.
//
//  Storage, all under Application Support/OfflineTiles (excluded from backup):
//    downloads.json          — the [OfflineDownload] list
//    manifests/<id>.json     — that download's tile keys
//    osm/<z>/<x>/<y>.png     — the pinned tiles (owned by TileDiskCache)
//  Tiles are shared between downloads; deleting one only removes the
//  tiles no remaining download lists.
//
//  One download runs at a time. Each tile: already pinned → skip; in the
//  regular cache → copy, no network; else fetched through OSMTileFetcher
//  (4 in flight, the app's User-Agent, its retry rules). A 429 stops the
//  run instead of pushing on. A cancelled or failed run is kept as an
//  incomplete download that "Resume" finishes.
//

import CoreLocation
import Foundation
import OSLog
import UIKit

nonisolated struct OfflineDownload: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    /// What the download belongs to: `saved:<uuid>` for a saved route,
    /// `plan:<signature>` for a planner route.
    var routeKey: String
    /// Fingerprint of the route it was made from, to spot a saved route
    /// edited since (`OfflineCorridor.signature`).
    var signature: String
    var createdAt: Date
    var tileCount: Int
    /// Tiles that are not pinned (failed or not reached). 0 = complete.
    var missingCount: Int
    var bytes: Int

    var isComplete: Bool { missingCount == 0 }
}

/// What happened to one tile in a download run.
nonisolated private enum TilePinResult: Sendable {
    case pinned(Int)
    case failed
    case rateLimited
}

@MainActor
@Observable
final class OfflineMapStore {

    static let shared = OfflineMapStore()

    /// The running (or just finished) download.
    struct Job: Equatable {
        enum Phase: Equatable {
            case running
            case finished
            case stopped(String)
        }
        let routeKey: String
        let name: String
        var total: Int
        var done = 0
        var failed = 0
        var phase: Phase = .running
        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    enum StartError: LocalizedError {
        case busy
        case empty
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .busy: "Another route is downloading. Wait for it to finish or cancel it."
            case .empty: "This route has no geometry to download."
            case .tooLarge(let n):
                "This route needs \(n.formatted()) map tiles; the limit is \(OfflineCorridor.maxTiles.formatted()). Save the trip as shorter routes and download each one."
            }
        }
    }

    private(set) var downloads: [OfflineDownload] = []
    private(set) var job: Job?

    private var runTask: Task<Void, Never>?
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "OfflineMaps")
    /// Tiles go into the shared `osm` namespace either way; the palette
    /// is applied when composites are stitched.
    private let style: MapStyle = .light
    /// Tiles worked on at once. OSMTileFetcher caps HTTP at 4 itself; a
    /// little more keeps cache copies flowing while fetches wait.
    private static let width = 6

    private let rootDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("OfflineTiles", isDirectory: true)
    }()
    private var listURL: URL { rootDir.appendingPathComponent("downloads.json") }
    private var manifestDir: URL { rootDir.appendingPathComponent("manifests", isDirectory: true) }
    private func manifestURL(_ id: UUID) -> URL { manifestDir.appendingPathComponent("\(id.uuidString).json") }

    private init() {
        if let data = try? Data(contentsOf: listURL),
           let list = try? JSONDecoder().decode([OfflineDownload].self, from: data) {
            downloads = list
        }
    }

    // MARK: - Queries

    func download(forKey key: String) -> OfflineDownload? {
        downloads.first { $0.routeKey == key }
    }

    var totalBytes: Int { downloads.reduce(0) { $0 + $1.bytes } }

    // MARK: - Download

    /// Tile list for `coordinates`, computed off the main actor.
    nonisolated static func plan(_ coordinates: [CLLocationCoordinate2D]) async -> [TileKey] {
        await Task.detached(priority: .userInitiated) {
            OfflineCorridor.tiles(along: coordinates)
        }.value
    }

    /// Start downloading `tiles` for the route identified by `routeKey`.
    /// Replaces any earlier download of the same route.
    func start(name: String, routeKey: String, signature: String, tiles: [TileKey]) throws {
        if let job, job.phase == .running { throw StartError.busy }
        guard !tiles.isEmpty else { throw StartError.empty }
        guard tiles.count <= OfflineCorridor.maxTiles else { throw StartError.tooLarge(tiles.count) }

        let previous = download(forKey: routeKey)
        let id = previous?.id ?? UUID()
        job = Job(routeKey: routeKey, name: name, total: tiles.count)
        let style = self.style
        runTask = Task { [weak self] in
            // Ask iOS for a little time if the rider switches apps; a long
            // download still needs the app open.
            let bg = UIApplication.shared.beginBackgroundTask(withName: "OfflineMapDownload")
            defer { UIApplication.shared.endBackgroundTask(bg) }

            let outcome = await Self.fetch(tiles, style: style) { done, failed in
                self?.job?.done = done
                self?.job?.failed = failed
            }
            guard let self else { return }
            // Tiles a replaced download listed that this one doesn't.
            if let previous {
                let old = self.loadManifest(previous.id)
                self.writeManifest(id, tiles)
                await self.unpinUnreferenced(Set(old).subtracting(tiles))
            } else {
                self.writeManifest(id, tiles)
            }
            let entry = OfflineDownload(
                id: id, name: name, routeKey: routeKey, signature: signature,
                createdAt: Date(), tileCount: tiles.count,
                missingCount: tiles.count - outcome.pinned, bytes: outcome.bytes)
            self.downloads.removeAll { $0.routeKey == routeKey }
            self.downloads.insert(entry, at: 0)
            self.saveList()
            self.job?.phase = outcome.stopReason.map { .stopped($0) } ?? .finished
            self.log.info("Offline download \(entry.isComplete ? "complete" : "incomplete", privacy: .public): \(outcome.pinned, privacy: .public)/\(tiles.count, privacy: .public) tiles, \(outcome.bytes / 1024, privacy: .public) KiB")
            self.runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    /// Forget the finished job's status line.
    func clearJob() {
        if job?.phase != .running { job = nil }
    }

    /// Delete a download and every tile only it used.
    func delete(id: UUID) async {
        guard let entry = downloads.first(where: { $0.id == id }) else { return }
        if job?.routeKey == entry.routeKey, job?.phase == .running { return }
        let keys = loadManifest(id)
        downloads.removeAll { $0.id == id }
        saveList()
        try? FileManager.default.removeItem(at: manifestURL(id))
        await unpinUnreferenced(Set(keys))
        if job?.routeKey == entry.routeKey { job = nil }
    }

    func delete(routeKey: String) async {
        if let d = download(forKey: routeKey) { await delete(id: d.id) }
    }

    // MARK: - Worker

    nonisolated private struct Outcome {
        var pinned = 0
        var bytes = 0
        var stopReason: String?
    }

    /// Pin every tile, `width` at a time. `progress` gets (done, failed).
    nonisolated private static func fetch(
        _ tiles: [TileKey],
        style: MapStyle,
        progress: @MainActor @escaping (Int, Int) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        var done = 0, failed = 0
        await withTaskGroup(of: TilePinResult.self) { group in
            var next = 0
            func add() {
                guard next < tiles.count else { return }
                let k = tiles[next]
                next += 1
                group.addTask {
                    let disk = TileDiskCache.shared
                    if await disk.hasPinned(style: style, z: k.z, x: k.x, y: k.y) {
                        return .pinned(await disk.pinnedSize(style: style, z: k.z, x: k.x, y: k.y))
                    }
                    if let size = await disk.pin(style: style, z: k.z, x: k.x, y: k.y) {
                        return .pinned(size)
                    }
                    do {
                        let data = try await OSMTileFetcher.shared.fetch(style: style, z: k.z, x: k.x, y: k.y)
                        if let size = await disk.pin(style: style, z: k.z, x: k.x, y: k.y, pngData: data) {
                            return .pinned(size)
                        }
                        return .failed
                    } catch OSMTileFetchError.rateLimited {
                        return .rateLimited
                    } catch {
                        return .failed
                    }
                }
            }
            for _ in 0..<width { add() }
            while let r = await group.next() {
                done += 1
                switch r {
                case .pinned(let size):
                    outcome.pinned += 1
                    outcome.bytes += size
                case .failed:
                    failed += 1
                case .rateLimited:
                    failed += 1
                    if outcome.stopReason == nil {
                        outcome.stopReason = "The OpenStreetMap tile server asked the app to slow down. Try again later; tiles already downloaded are kept."
                    }
                }
                await progress(done, failed)
                if outcome.stopReason != nil || Task.isCancelled {
                    if outcome.stopReason == nil { outcome.stopReason = "Cancelled. Tiles already downloaded are kept." }
                    group.cancelAll()
                    // Drain without starting more.
                    for await r in group { if case .pinned(let s) = r { outcome.pinned += 1; outcome.bytes += s } }
                    break
                }
                add()
            }
        }
        if outcome.stopReason == nil, failed > 0 {
            outcome.stopReason = "\(failed.formatted()) tiles couldn't be downloaded (no signal?). Resume to retry them."
        }
        return outcome
    }

    // MARK: - Persistence

    private func saveList() {
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(downloads) {
            try? data.write(to: listURL, options: .atomic)
        }
    }

    private func writeManifest(_ id: UUID, _ keys: [TileKey]) {
        try? FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        // [[z, x, y], …] — about half the size of keyed objects.
        let flat = keys.map { [$0.z, $0.x, $0.y] }
        if let data = try? JSONEncoder().encode(flat) {
            try? data.write(to: manifestURL(id), options: .atomic)
        }
    }

    private func loadManifest(_ id: UUID) -> [TileKey] {
        guard let data = try? Data(contentsOf: manifestURL(id)),
              let flat = try? JSONDecoder().decode([[Int]].self, from: data) else { return [] }
        return flat.compactMap { $0.count == 3 ? TileKey(z: $0[0], x: $0[1], y: $0[2]) : nil }
    }

    /// Unpin the tiles in `candidates` that no remaining download lists.
    private func unpinUnreferenced(_ candidates: Set<TileKey>) async {
        guard !candidates.isEmpty else { return }
        var orphans = candidates
        for d in downloads {
            orphans.subtract(loadManifest(d.id))
            if orphans.isEmpty { return }
        }
        await TileDiskCache.shared.unpin(style: style, keys: orphans)
    }
}
