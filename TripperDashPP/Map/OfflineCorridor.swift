//
//  OfflineCorridor.swift
//  TripperDashPP
//
//  Which OSM tiles a route needs so it can be ridden with no signal.
//
//  The ride never reads tiles by itself: `RouteTileCache` builds
//  composites at anchors along the route and each composite reads a
//  gridSide × gridSide block of tiles from `TileDiskCache`. So the offline
//  tile set is exactly the union of those blocks, for every anchor of
//  every layer the renderer can draw — computed here with the SAME anchor
//  sampling (`RouteTileCache.anchorsAlongPolyline` / `lateralAnchors`) and
//  the SAME block origin (`RouteTileCache.compositeBlockOrigin`), so the
//  download and the ride can't disagree.
//
//  Layers mirror `MapViewSource` (pinned by `OfflineCorridorTests`):
//    * base   z15, 5×5, 700 m stride, ±1500 m wing rows
//    * fine   z16, 7×7, 700 m stride, main row only (normal riding zoom)
//    * coarse z13, 7×7, 1400 m stride, main row only (joystick zoom-out)
//
//  Not covered: the position-fallback composite around a rider who is
//  more than ~2 km off the route (same as online: that needs signal).
//

import CoreLocation
import Foundation
import MapKit

/// One slippy-map tile address.
nonisolated struct TileKey: Hashable, Sendable, Codable {
    let z: Int
    let x: Int
    let y: Int
}

nonisolated enum OfflineCorridor {

    /// One renderer layer's composite geometry.
    struct Layer: Sendable, Equatable {
        let zoom: Int
        let gridSide: Int
        let stride: CLLocationDistance
        let lateralRows: Bool
    }

    /// Base first: if a download is cut short, the layer every frame can
    /// fall back to is the most complete one.
    static let layers: [Layer] = [
        Layer(zoom: RouteTileCache.zoom, gridSide: RouteTileCache.gridSide,
              stride: RouteTileCache.stride, lateralRows: true),
        Layer(zoom: 16, gridSide: 7, stride: RouteTileCache.stride, lateralRows: false),
        Layer(zoom: 13, gridSide: 7, stride: 1400, lateralRows: false),
    ]

    /// Refuse downloads above this many tiles (~1,000 km of route, roughly
    /// 300–400 MB). Keeps one tap from bulk-scraping the OSM tile servers,
    /// which their usage policy forbids; a longer trip downloads in parts.
    static let maxTiles = 20_000

    /// Rough average PNG size, for the size estimate shown before a
    /// download. Measured OSM Carto tiles run ~5 KB (fields) to ~40 KB
    /// (city centres).
    static let estimatedBytesPerTile = 18_000

    /// Every tile the renderer can read while riding `coordinates`, in
    /// download order: layer by layer (base first), along the route.
    static func tiles(along coordinates: [CLLocationCoordinate2D]) -> [TileKey] {
        let coords = coordinates.filter { CLLocationCoordinate2DIsValid($0) }
        guard !coords.isEmpty else { return [] }
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        var seen = Set<TileKey>()
        var out: [TileKey] = []
        for layer in layers {
            let main = RouteTileCache.anchorsAlongPolyline(polyline, stride: layer.stride)
            var anchors = main
            if layer.lateralRows {
                anchors += RouteTileCache.lateralAnchors(main, offsetMeters: -RouteTileCache.lateralOffset)
                anchors += RouteTileCache.lateralAnchors(main, offsetMeters: +RouteTileCache.lateralOffset)
            }
            let n = 1 << layer.zoom
            for anchor in anchors {
                let (fx, fy) = WebMercator.tile(for: anchor, zoom: layer.zoom)
                let (tlx, tly) = RouteTileCache.compositeBlockOrigin(fx: fx, fy: fy, gridSide: layer.gridSide)
                for dy in 0..<layer.gridSide {
                    for dx in 0..<layer.gridSide {
                        let y = tly + dy
                        guard y >= 0 && y < n else { continue }
                        // Same antimeridian wrap as OSMTileFetcher.
                        let x = ((tlx + dx) % n + n) % n
                        let key = TileKey(z: layer.zoom, x: x, y: y)
                        if seen.insert(key).inserted { out.append(key) }
                    }
                }
            }
        }
        return out
    }

    /// Stable fingerprint of a coordinate list (FNV-1a over coordinates
    /// rounded to ~1 m). `Hasher` is seeded per launch, so it can't be
    /// persisted; this can.
    static func signature(of coordinates: [CLLocationCoordinate2D]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ v: Int64) {
            var u = UInt64(bitPattern: v)
            for _ in 0..<8 {
                h ^= u & 0xff
                h = h &* 0x100000001b3
                u >>= 8
            }
        }
        for c in coordinates {
            mix(Int64((c.latitude * 100_000).rounded()))
            mix(Int64((c.longitude * 100_000).rounded()))
        }
        return String(h, radix: 16)
    }

    /// All points of an MKPolyline.
    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&out, range: NSRange(location: 0, length: polyline.pointCount))
        return out
    }
}
