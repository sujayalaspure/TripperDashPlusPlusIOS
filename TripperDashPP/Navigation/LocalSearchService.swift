//
//  LocalSearchService.swift
//  TripperDashPP
//
//  Phase 7b — place search for the destination sheet. Runs a debounced
//  MKLocalSearch on the typed text, so every row already carries a
//  coordinate and a country code: the list shows only places in India,
//  sorted nearest-first from the current GPS fix, and picking a row needs
//  no second lookup.
//
//  Why not MKLocalSearchCompleter: its rows have no coordinate or country,
//  so they can be neither sorted by distance nor filtered to India, and
//  MapKit does not enforce a `.required` region on them (measured: "Paris"
//  suggests and resolves to France).
//

import CoreLocation
import Foundation
import MapKit
import os
import SwiftUI

@MainActor
@Observable
final class LocalSearchService {

    /// One search row: a resolved destination plus what the row renders.
    struct Result: Identifiable {
        let id: String
        let destination: Destination
        let title: String
        let subtitle: String
        /// Metres from `biasCenter`; nil when there is no GPS fix.
        let distance: CLLocationDistance?
    }

    /// Current results, India only, nearest first. UI observes this.
    private(set) var results: [Result] = []
    /// Any error from the most recent search.
    private(set) var lastError: String?
    /// True while a search for the current query is pending or running.
    private(set) var isSearching = false

    /// Free-form text the user has typed. Setting this schedules a search.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    /// Current GPS fix. UI sets this on appear; results are sorted by
    /// distance from it. Without a fix, MapKit's own ranking is kept.
    var biasCenter: CLLocationCoordinate2D? {
        didSet {
            guard biasCenter != oldValue else { return }
            scheduleSearch(debounce: false)
        }
    }

    private var searchTask: Task<Void, Never>?
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "LocalSearch")

    /// Pause after the last keystroke before searching. MKLocalSearch is
    /// rate-limited per app, so one request per keystroke would get
    /// throttled while typing.
    private static let debounce: Duration = .milliseconds(300)
    /// Shortest query worth sending; one letter returns noise.
    private static let minQueryLength = 2

    /// A box covering India, used with `.required` priority when there is
    /// no GPS fix. MapKit treats it as a strong hint, not a guarantee, so
    /// results are always filtered to ISO country code IN as well.
    private static let indiaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 21.5, longitude: 82.5),
        latitudinalMeters: 3_600_000,
        longitudinalMeters: 3_600_000)
    /// Side of the box around the rider when there is a fix.
    private static let nearbySpan: CLLocationDistance = 50_000
    private static let countryCode = "IN"

    private static func inIndia(_ items: [MKMapItem]) -> [MKMapItem] {
        items.filter { $0.placemark.isoCountryCode == countryCode }
    }

    /// With a fix: a 50 km box around the rider at `.default` priority.
    /// Measured from Delhi: "Pizza Hut" then returns outlets 1–6 km away
    /// (the India-wide box returned a country-wide sample, nearest 642 km),
    /// while "Mumbai" still finds the city. `.required` on the small box
    /// is wrong — "Mumbai" became a nearby expressway named after it.
    private static func request(for text: String,
                                near center: CLLocationCoordinate2D?) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let center {
            request.region = MKCoordinateRegion(center: center,
                                                latitudinalMeters: nearbySpan,
                                                longitudinalMeters: nearbySpan)
            request.regionPriority = .default
        } else {
            request.region = indiaRegion
            request.regionPriority = .required
        }
        return request
    }

    // MARK: - Live search

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minQueryLength else {
            isSearching = false
            lastError = nil
            publish([])
            return
        }
        isSearching = true
        let center = biasCenter
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: Self.debounce)
            }
            guard !Task.isCancelled else { return }
            await self?.run(text, center: center)
        }
    }

    private func run(_ text: String, center: CLLocationCoordinate2D?) async {
        let items: [MKMapItem]
        var errorMessage: String?
        do {
            items = try await MKLocalSearch(request: Self.request(for: text, near: center)).start().mapItems
        } catch {
            items = []
            let ns = error as NSError
            // placemarkNotFound = nothing matched; not worth a red banner.
            if !(ns.domain == MKErrorDomain && ns.code == Int(MKError.Code.placemarkNotFound.rawValue)) {
                let msg = error.localizedDescription
                log.warning("search failed: \(msg, privacy: .public)")
                errorMessage = msg
            }
        }
        // A newer keystroke superseded this search while it was in flight.
        guard !Task.isCancelled else { return }
        publish(Self.rows(from: items, near: center))
        lastError = errorMessage
        isSearching = false
    }

    /// India only, de-duplicated, nearest first when there is a fix.
    private static func rows(from items: [MKMapItem],
                             near center: CLLocationCoordinate2D?) -> [Result] {
        let origin = center.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        var seen = Set<String>()
        var rows: [Result] = []
        for item in inIndia(items) {
            let dest = Destination.from(mapItem: item)
            let c = dest.coordinate
            let id = "\(dest.name)\u{1F}\(String(format: "%.5f,%.5f", c.latitude, c.longitude))"
            guard seen.insert(id).inserted else { continue }
            let distance = origin?.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            rows.append(Result(id: id,
                               destination: dest,
                               title: dest.name,
                               subtitle: dest.addressLine ?? "",
                               distance: distance))
        }
        if origin != nil {
            // Stable: equal distances keep MapKit's relevance order.
            rows = rows.enumerated()
                .sorted { ($0.element.distance ?? .infinity, $0.offset) < ($1.element.distance ?? .infinity, $1.offset) }
                .map(\.element)
        }
        return rows
    }

    // MARK: - One-shot geocode

    /// Geocode a free-text place name (e.g. a shared "Share to
    /// TripperDash++" label from Google/Apple Maps that carried no
    /// coordinates) into a concrete `Destination` in India. When `near`
    /// is given, the nearest match wins. Returns nil on no results /
    /// failure.
    func geocode(_ text: String,
                 near: CLLocationCoordinate2D? = nil) async -> Destination? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let items = try await MKLocalSearch(request: Self.request(for: trimmed, near: near)).start().mapItems
            return Self.rows(from: items, near: near).first?.destination
        } catch {
            log.debug("geocode failed for \(trimmed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Reverse-geocode a tapped coordinate into an address line (best
    /// effort — returns nil silently on failure).
    func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first?.formattedOneLine
        } catch {
            log.debug("reverse-geocode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Result publishing

private extension LocalSearchService {
    /// Publish a new result snapshot to the UI.
    ///
    /// Guards against a TestFlight 1.0.2 crash (iPhone 13 Pro Max, iOS
    /// 26.6.1): `NSInternalInconsistencyException` "Invalid Number Of Items
    /// In Section" inside SwiftUI's List-backing UICollectionView batch
    /// update — a List told one item count and handed another, most likely
    /// because results were written mid-animation. Two mitigations, neither
    /// changing what the user sees:
    ///   1. Skip the write when the rendered rows are unchanged.
    ///   2. Apply the change with animations disabled, so the List swaps
    ///      rows outright instead of running an interruptible batch update.
    /// Row ids are unique per snapshot (de-duplicated in `rows(from:near:)`)
    /// and derived from the place itself, so they are stable across
    /// snapshots too — the two properties the List diff needs.
    func publish(_ new: [Result]) {
        let unchanged = new.count == results.count
            && zip(new, results).allSatisfy { $0.id == $1.id }
        guard !unchanged else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { results = new }
    }
}

// MARK: - Helpers

private extension CLPlacemark {
    /// One-line address, defensively built from whatever CLGeocoder
    /// gave us: street + number, postal code + city.
    var formattedOneLine: String {
        var parts: [String] = []
        if let street = thoroughfare {
            if let num = subThoroughfare {
                parts.append("\(street) \(num)")
            } else {
                parts.append(street)
            }
        }
        if let pc = postalCode, let city = locality {
            parts.append("\(pc) \(city)")
        } else if let city = locality {
            parts.append(city)
        }
        if parts.isEmpty, let name { parts.append(name) }
        return parts.joined(separator: ", ")
    }
}
