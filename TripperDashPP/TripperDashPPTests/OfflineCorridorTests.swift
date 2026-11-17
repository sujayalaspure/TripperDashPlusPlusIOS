//
//  OfflineCorridorTests.swift
//  TripperDashPPTests
//
//  The offline route download must pin every tile the ride will read.
//  These pin `OfflineCorridor`'s layers to the renderer's and check its
//  tile set covers every composite block along a sample route.
//

import CoreLocation
import MapKit
import Testing
@testable import TripperDashPP

@MainActor
struct OfflineCorridorTests {

    /// ~12 km through central Delhi with a bend, so wing rows and the
    /// stride walk both matter.
    private let route: [CLLocationCoordinate2D] = [
        .init(latitude: 28.6139, longitude: 77.2090),
        .init(latitude: 28.6500, longitude: 77.2300),
        .init(latitude: 28.6600, longitude: 77.2800),
    ]

    @Test func layersMatchTheRenderer() {
        let zooms = OfflineCorridor.layers.map(\.zoom)
        #expect(zooms == [MapViewSource.baseLayerZoom, MapViewSource.fineLayerZoom, MapViewSource.coarseLayerZoom])
        #expect(OfflineCorridor.layers.allSatisfy { $0.gridSide % 2 == 1 })
        #expect(OfflineCorridor.layers[0].gridSide == RouteTileCache.gridSide)
        #expect(OfflineCorridor.layers[0].lateralRows)
    }

    @Test func coversEveryCompositeBlock() {
        let tiles = Set(OfflineCorridor.tiles(along: route))
        let polyline = MKPolyline(coordinates: route, count: route.count)
        for layer in OfflineCorridor.layers {
            let main = RouteTileCache.anchorsAlongPolyline(polyline, stride: layer.stride)
            var anchors = main
            if layer.lateralRows {
                anchors += RouteTileCache.lateralAnchors(main, offsetMeters: -RouteTileCache.lateralOffset)
                anchors += RouteTileCache.lateralAnchors(main, offsetMeters: RouteTileCache.lateralOffset)
            }
            #expect(!anchors.isEmpty)
            for a in anchors {
                let (fx, fy) = WebMercator.tile(for: a, zoom: layer.zoom)
                let (tlx, tly) = RouteTileCache.compositeBlockOrigin(fx: fx, fy: fy, gridSide: layer.gridSide)
                for dy in 0..<layer.gridSide {
                    for dx in 0..<layer.gridSide {
                        #expect(tiles.contains(TileKey(z: layer.zoom, x: tlx + dx, y: tly + dy)))
                    }
                }
            }
        }
    }

    @Test func noDuplicatesAndBaseFirst() {
        let tiles = OfflineCorridor.tiles(along: route)
        #expect(Set(tiles).count == tiles.count)
        #expect(tiles.first?.z == RouteTileCache.zoom)
        // Sanity: a 12 km route is hundreds of tiles, nowhere near the cap.
        #expect(tiles.count > 100 && tiles.count < 2_000)
    }

    @Test func emptyAndInvalidInput() {
        #expect(OfflineCorridor.tiles(along: []).isEmpty)
        #expect(OfflineCorridor.tiles(along: [kCLLocationCoordinate2DInvalid]).isEmpty)
    }

    /// A pinned tile is what the ride reads when the regular cache has
    /// none (both palettes share it). z=1 tile (1,1) is never fetched by
    /// the renderer, so the regular cache can't hold it.
    @Test func pinnedTileIsReadOnCacheMiss() async {
        let disk = TileDiskCache.shared
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let key = TileKey(z: 1, x: 1, y: 1)
        #expect(await disk.pin(style: .light, z: 1, x: 1, y: 1, pngData: png) == png.count)
        #expect(await disk.read(style: .dark, z: 1, x: 1, y: 1) == png)
        await disk.unpin(style: .light, keys: [key])
        #expect(await disk.read(style: .light, z: 1, x: 1, y: 1) == nil)
    }

    @Test func signatureIsStableAndSensitive() {
        let a = OfflineCorridor.signature(of: route)
        #expect(a == OfflineCorridor.signature(of: route))
        var moved = route
        moved[1].latitude += 0.001
        #expect(a != OfflineCorridor.signature(of: moved))
        #expect(a != OfflineCorridor.signature(of: Array(route.reversed())))
    }
}
