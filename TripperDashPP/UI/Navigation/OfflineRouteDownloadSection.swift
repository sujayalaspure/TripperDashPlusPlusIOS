//
//  OfflineRouteDownloadSection.swift
//  TripperDashPP
//
//  "Download for offline" for one route: a Form section used on the saved
//  route screen and inside the planner's offline sheet, plus the Settings
//  list of every download. The work lives in `OfflineMapStore`.
//

import CoreLocation
import SwiftUI

struct OfflineRouteDownloadSection: View {
    let name: String
    /// Identifies the route in `OfflineMapStore` (`saved:<id>` / `plan:<sig>`).
    let routeKey: String
    /// Fingerprint of the route as it is now; differs from the stored one
    /// when the route was edited after downloading.
    let signature: String
    var footer: String?
    /// The road geometry to cover. May call MKDirections, so it can throw.
    let resolve: () async throws -> [CLLocationCoordinate2D]

    @State private var preparing = false
    @State private var errorText: String?
    @State private var pendingTiles: [TileKey]?

    private var store: OfflineMapStore { .shared }

    var body: some View {
        let job = store.job.flatMap { $0.routeKey == routeKey ? $0 : nil }
        let existing = store.download(forKey: routeKey)
        Section {
            if let job, job.phase == .running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: job.fraction)
                    Text("\(job.done.formatted()) of \(job.total.formatted()) map tiles")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Cancel download", role: .cancel) { store.cancel() }
            } else if let existing {
                statusRow(existing)
                if !existing.isComplete || existing.signature != signature {
                    downloadButton(existing.isComplete ? "Download again" : "Resume download")
                }
                Button(role: .destructive) {
                    Task { await store.delete(id: existing.id) }
                } label: {
                    Label("Delete offline map", systemImage: "trash")
                }
            } else {
                downloadButton("Download for offline")
            }
        } header: {
            Text("Offline map")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else if case .stopped(let why)? = job?.phase {
                    Text(why).foregroundStyle(.orange)
                }
                Text(footer ?? "Saves the map along this route so the dash keeps showing it without mobile signal. Routing, search, weather and speed cameras still need signal.")
            }
        }
        .confirmationDialog(
            "Download offline map?",
            isPresented: Binding(get: { pendingTiles != nil },
                                 set: { if !$0 { pendingTiles = nil } }),
            titleVisibility: .visible,
            presenting: pendingTiles
        ) { tiles in
            Button("Download") { start(tiles) }
            Button("Cancel", role: .cancel) { pendingTiles = nil }
        } message: { tiles in
            Text("\(tiles.count.formatted()) map tiles, about \(Self.bytes(tiles.count * OfflineCorridor.estimatedBytesPerTile)). Tiles you already have are not downloaded again. Use Wi-Fi with internet if you can, and keep the app open until it finishes.")
        }
    }

    @ViewBuilder
    private func statusRow(_ d: OfflineDownload) -> some View {
        let changed = d.signature != signature
        LabeledContent {
            Text(Self.bytes(d.bytes)).monospacedDigit()
        } label: {
            if changed {
                Label("Route changed since download", systemImage: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(.orange)
            } else if d.isComplete {
                Label("Available offline", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Incomplete: \((d.tileCount - d.missingCount).formatted()) of \(d.tileCount.formatted()) tiles",
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func downloadButton(_ title: String) -> some View {
        Button {
            Task { await prepare() }
        } label: {
            HStack {
                Label(title, systemImage: "arrow.down.circle")
                if preparing {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(preparing || store.job?.phase == .running)
    }

    private func prepare() async {
        errorText = nil
        preparing = true
        defer { preparing = false }
        do {
            let coords = try await resolve()
            let tiles = await OfflineMapStore.plan(coords)
            guard !tiles.isEmpty else { throw OfflineMapStore.StartError.empty }
            guard tiles.count <= OfflineCorridor.maxTiles else {
                throw OfflineMapStore.StartError.tooLarge(tiles.count)
            }
            pendingTiles = tiles
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func start(_ tiles: [TileKey]) {
        pendingTiles = nil
        do {
            try store.start(name: name, routeKey: routeKey, signature: signature, tiles: tiles)
        } catch {
            errorText = error.localizedDescription
        }
    }

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Settings list of every offline download, with swipe-to-delete.
struct OfflineMapsSettingsSection: View {
    private var store: OfflineMapStore { .shared }

    var body: some View {
        Section {
            if let job = store.job, job.phase == .running {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading \(job.name)")
                    ProgressView(value: job.fraction)
                    Button("Cancel", role: .cancel) { store.cancel() }
                        .font(.footnote)
                }
            }
            if store.downloads.isEmpty {
                Text("No routes downloaded. Open a planned or saved route and tap Download for offline.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.downloads) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).lineLimit(1)
                    Text(detail(d))
                        .font(.caption)
                        .foregroundStyle(d.isComplete ? Color.secondary : Color.orange)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await store.delete(id: d.id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Offline maps")
        } footer: {
            if !store.downloads.isEmpty {
                Text("\(OfflineRouteDownloadSection.bytes(store.totalBytes)) in total. Kept until you delete them; Clear cache doesn't remove them. Swipe to delete.")
            }
        }
    }

    private func detail(_ d: OfflineDownload) -> String {
        let size = OfflineRouteDownloadSection.bytes(d.bytes)
        let date = d.createdAt.formatted(date: .abbreviated, time: .omitted)
        if d.isComplete { return "\(size) · \(date)" }
        return "Incomplete (\((d.tileCount - d.missingCount).formatted()) of \(d.tileCount.formatted()) tiles) · \(size)"
    }
}
