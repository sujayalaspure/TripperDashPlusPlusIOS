//
//  DestinationSearchSheet.swift
//  TripperDashPP
//
//  Phase 7b — full-screen sheet with sticky search field + live
//  results (India only, nearest first, with distance). Each row is
//  already a Destination; selecting one calls `onPick`.
//

import MapKit
import SwiftUI

struct DestinationSearchSheet: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.dismiss) private var dismiss

    /// Caller hook. Sheet auto-dismisses after invoking this.
    let onPick: (Destination) -> Void

    /// Optional text to seed the search field with on first appear — used
    /// by "Share to TripperDash++" when a shared link couldn't be geocoded
    /// but yielded a place/road label to look up manually.
    var initialQuery: String? = nil

    @State private var search = LocalSearchService()
    @State private var didSeed = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let err = search.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if search.query.isEmpty {
                    let recents = status.recentDestinationsStore.items
                    if recents.isEmpty {
                        Section("Tip") {
                            Text("Start typing an address, city, or place name. Results are limited to India.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            ForEach(recents) { r in
                                Button {
                                    onPick(r.destination)
                                    status.recentDestinationsStore.record(r.destination)
                                    dismiss()
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.name).foregroundStyle(.primary)
                                            if let line = r.addressLine, !line.isEmpty {
                                                Text(line).font(.footnote).foregroundStyle(.secondary)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        status.recentDestinationsStore.remove(id: r.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Recent")
                                Spacer()
                                Button("Clear") {
                                    status.recentDestinationsStore.clear()
                                }
                                .font(.footnote)
                                .textCase(nil)
                            }
                        }
                    }
                } else if search.results.isEmpty {
                    Section {
                        Text(search.isSearching ? "Searching…" : "No places in India match that search.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Row ids come from the place itself (name + coordinate) and
                // are de-duplicated per snapshot in LocalSearchService, so they
                // are unique AND stable — what SwiftUI's List diff needs. Keying
                // on offsets or non-unique ids crashed with "Invalid Number Of
                // Items In Section" (TestFlight 1.0.2; see
                // `LocalSearchService.publish`).
                ForEach(search.results) { r in
                    Button {
                        pick(r.destination)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).foregroundStyle(.primary)
                                if !r.subtitle.isEmpty {
                                    Text(r.subtitle).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if let d = r.distance {
                                Text(Self.distanceText(d))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    // .plain stops the List/Form from tinting the whole row
                    // label with the accent colour — otherwise the result
                    // titles render blue (accent) and are hard to read.
                    // Setting .foregroundStyle(.primary) on the Text alone
                    // does NOT override the button tint inside a List.
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
            .searchable(text: $search.query, prompt: "Where to?")
            .searchFocused($searchFocused)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                // Open with the keyboard up so the rider can type straight away.
                searchFocused = true
                // Seed the search bias from current GPS, if available.
                search.biasCenter = status.locationService.lastFix?.coordinate
                // "Share to TripperDash++" fallback: pre-fill the query with
                // the label recovered from an un-geocodable shared link so
                // the rider just picks from the results. Once only.
                if !didSeed, let seed = initialQuery,
                   !seed.trimmingCharacters(in: .whitespaces).isEmpty {
                    search.query = seed
                    didSeed = true
                }
            }
        }
    }

    private func pick(_ dest: Destination) {
        status.recentDestinationsStore.record(dest)
        onPick(dest)
        dismiss()
    }

    /// "850 m", "12 km", "1,240 km" — metres under 1 km, whole km above.
    private static func distanceText(_ metres: CLLocationDistance) -> String {
        if metres < 1_000 {
            return "\(Int((metres / 50).rounded()) * 50) m"
        }
        let km = metres < 10_000 ? (metres / 100).rounded() / 10 : (metres / 1_000).rounded()
        return km.formatted(.number.precision(.fractionLength(0...1))) + " km"
    }
}
