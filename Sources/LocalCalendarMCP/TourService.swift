import Foundation
import MapKit
import MCP

private struct TourPoint: Codable {
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var mapValue: String { "\(latitude),\(longitude)" }

    init(_ latitude: Double, _ longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw Err.message("Coordinates must be finite latitude -90...90 and longitude -180...180.")
        }
        self.latitude = latitude
        self.longitude = longitude
    }
}

private struct TourStop: Codable {
    let id: UUID
    var name: String
    var point: TourPoint
    var note: String?
}

private enum TourMode: String, Codable {
    case walking
    case cycling

    var transportType: MKDirectionsTransportType { self == .cycling ? .cycling : .walking }
    var metresPerMinute: Double { self == .cycling ? 250 : 95 }
}

private struct WalkingTour: Codable {
    let id: UUID
    var title: String
    // Optional so tours saved before cycling was added still decode as walking tours.
    var mode: TourMode?
    var stops: [TourStop]
    var nextStopID: UUID
    var currentPosition: TourPoint?
    var updatedAt: Date

    var travelMode: TourMode { mode ?? .walking }
}

@MainActor
final class TourService {
    private let folder: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() throws {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Err.message("Cannot locate Application Support for private tour storage.")
        }
        folder = support.appendingPathComponent("LocalMacAppIntegrations/Tours", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func call(_ name: String, _ a: [String: Value]) async throws -> String {
        switch name {
        case "search_map_places":
            let query = try required(a, "query")
            let point = try optionalPoint(a, latitude: "near_latitude", longitude: "near_longitude")
            let limit = a["limit"]?.intValue ?? 8
            guard (1...20).contains(limit) else { throw Err.message("limit must be 1...20.") }
            return try encode(try await search(query: query, near: point, limit: limit))

        case "create_tour", "create_walking_tour", "create_biking_tour":
            let title = try required(a, "title")
            let requestedMode = name == "create_biking_tour" ? "cycling" : (a["mode"]?.stringValue ?? "walking")
            guard let mode = TourMode(rawValue: requestedMode) else {
                throw Err.message("mode must be walking or cycling.")
            }
            let stops = try parseStops(a["stops"])
            guard (2...30).contains(stops.count) else { throw Err.message("A tour needs 2...30 ordered stops.") }
            let tour = WalkingTour(id: UUID(), title: title, mode: mode, stops: stops, nextStopID: stops[0].id,
                                   currentPosition: nil, updatedAt: Date())
            try save(tour)
            return try encode([summary(tour)])

        case "list_tours", "list_walking_tours":
            let tours = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .compactMap { try? decoder.decode(WalkingTour.self, from: Data(contentsOf: $0)) }
                .sorted { $0.updatedAt > $1.updatedAt }
            return try encode(tours.map(summary))

        case "get_tour", "get_walking_tour":
            return try encode([summary(try load(try tourID(a)))])

        case "preview_tour", "preview_walking_tour":
            let tour = try load(try tourID(a))
            guard let active = tour.stops.firstIndex(where: { $0.id == tour.nextStopID }) else {
                throw Err.message("Tour progress is invalid.")
            }
            let remaining = Array(tour.stops[active...])
            var previous = tour.currentPosition ?? remaining[0].point
            var legs: [[String: Any]] = []
            var distance = 0.0
            var seconds = 0.0
            for (index, stop) in remaining.enumerated() where tour.currentPosition != nil || index > 0 {
                let route = try await route(from: previous, to: stop.point, mode: tour.travelMode)
                legs.append(["to_stop_id": stop.id.uuidString, "to": stop.name,
                             "distance_metres": Int(route.distance),
                             "travel_minutes": Int(ceil(route.expectedTravelTime / 60))])
                distance += route.distance
                seconds += route.expectedTravelTime
                previous = stop.point
            }
            let warnings = legs.compactMap { leg -> String? in
                guard let metres = leg["distance_metres"] as? Int, metres > 100_000 else { return nil }
                return "The leg to \(leg["to"] as? String ?? "a stop") is over 100 km; check that the place coordinates are correct."
            }
            return try encode([["tour_id": tour.id.uuidString, "mode": tour.travelMode.rawValue,
                                "remaining_travel_minutes": Int(ceil(seconds / 60)),
                                "remaining_distance_metres": Int(distance), "legs": legs,
                                "warnings": warnings,
                                "apple_maps_url": mapsURL(tour)]])

        case "set_tour_mode":
            var tour = try load(try tourID(a))
            guard let mode = TourMode(rawValue: try required(a, "mode")) else {
                throw Err.message("mode must be walking or cycling.")
            }
            tour.mode = mode
            tour.updatedAt = Date()
            try save(tour)
            return try encode([summary(tour)])

        case "set_tour_progress", "set_walking_tour_progress":
            var tour = try load(try tourID(a))
            let next = try uuid(a, "next_stop_id")
            guard tour.stops.contains(where: { $0.id == next }) else { throw Err.message("next_stop_id is not in this tour.") }
            tour.nextStopID = next
            if let current = try optionalPoint(a, latitude: "current_latitude", longitude: "current_longitude") {
                tour.currentPosition = current
            }
            tour.updatedAt = Date()
            try save(tour)
            return try encode([summary(tour)])

        case "insert_tour_stop", "insert_walking_tour_stop":
            var tour = try load(try tourID(a))
            guard tour.stops.count < 30 else { throw Err.message("A tour can have at most 30 stops.") }
            let stop = TourStop(id: UUID(), name: try required(a, "name"),
                                point: try point(a, latitude: "latitude", longitude: "longitude"),
                                note: a["note"]?.stringValue)
            let before = try uuid(a, "before_stop_id")
            guard let index = tour.stops.firstIndex(where: { $0.id == before }) else {
                throw Err.message("before_stop_id is not in this tour.")
            }
            guard let active = tour.stops.firstIndex(where: { $0.id == tour.nextStopID }), index >= active else {
                throw Err.message("Insert a detour before a remaining stop, not behind the current position.")
            }
            tour.stops.insert(stop, at: index)
            if before == tour.nextStopID { tour.nextStopID = stop.id }
            if let current = try optionalPoint(a, latitude: "current_latitude", longitude: "current_longitude") {
                tour.currentPosition = current
            }
            tour.updatedAt = Date()
            try save(tour)
            return try encode([summary(tour)])

        case "remove_tour_stop", "remove_walking_tour_stop":
            var tour = try load(try tourID(a))
            let stopID = try uuid(a, "stop_id")
            guard let index = tour.stops.firstIndex(where: { $0.id == stopID }) else { throw Err.message("stop_id is not in this tour.") }
            guard tour.stops.count > 2 else { throw Err.message("A tour must retain at least two stops.") }
            let nextIndex = tour.stops.firstIndex(where: { $0.id == tour.nextStopID })!
            if stopID == tour.nextStopID {
                guard index + 1 < tour.stops.count else { throw Err.message("Cannot remove the final remaining stop.") }
                tour.nextStopID = tour.stops[index + 1].id
            } else if index < nextIndex {
                throw Err.message("This stop is already behind the current position.")
            }
            tour.stops.remove(at: index)
            tour.updatedAt = Date()
            try save(tour)
            return try encode([summary(tour)])

        case "suggest_tour_detours", "suggest_walking_tour_detours":
            let tour = try load(try tourID(a))
            let current = try point(a, latitude: "current_latitude", longitude: "current_longitude")
            let query = try required(a, "query")
            let minutes = a["max_travel_minutes"]?.intValue ?? a["max_walk_minutes"]?.intValue ?? 30
            guard (5...90).contains(minutes) else { throw Err.message("max_travel_minutes must be 5...90.") }
            let maxExtra = a["max_extra_minutes"]?.intValue ?? 20
            guard (0...120).contains(maxExtra) else { throw Err.message("max_extra_minutes must be 0...120.") }
            guard let nextStop = tour.stops.first(where: { $0.id == tour.nextStopID }) else {
                throw Err.message("Tour progress is invalid.")
            }
            let direct = try await route(from: current, to: nextStop.point, mode: tour.travelMode)
            let radius = min(Double(minutes) * tour.travelMode.metresPerMinute, 20_000)
            let items = try await searchItems(query: query, near: current, radius: radius)
            var candidates: [[String: Any]] = []
            for item in items.prefix(12) {
                guard let place = try? TourPoint(item.placemark.coordinate.latitude, item.placemark.coordinate.longitude),
                      let outbound = try? await route(from: current, to: place, mode: tour.travelMode),
                      outbound.expectedTravelTime <= Double(minutes * 60),
                      let onward = try? await route(from: place, to: nextStop.point, mode: tour.travelMode) else { continue }
                let extra = max(0, (outbound.expectedTravelTime + onward.expectedTravelTime - direct.expectedTravelTime) / 60)
                guard extra <= Double(maxExtra) else { continue }
                candidates.append([
                    "name": item.name ?? "Unnamed place",
                    "address": item.placemark.title ?? "",
                    "latitude": item.placemark.coordinate.latitude,
                    "longitude": item.placemark.coordinate.longitude,
                    "travel_minutes_from_current_position": Int(ceil(outbound.expectedTravelTime / 60)),
                    "extra_minutes_before_next_stop": Int(ceil(extra)),
                    "distance_metres_from_current_position": Int(outbound.distance),
                    "mode": tour.travelMode.rawValue,
                    "tour_id": tour.id.uuidString,
                    "insert_before_stop_id": tour.nextStopID.uuidString,
                ])
            }
            candidates.sort { ($0["extra_minutes_before_next_stop"] as? Int ?? 999) < ($1["extra_minutes_before_next_stop"] as? Int ?? 999) }
            return try encode(Array(candidates.prefix(8)))

        case "export_tour_gpx", "export_walking_tour_gpx":
            let tour = try load(try tourID(a))
            let path = try await exportGPX(tour)
            return try encode([["tour_id": tour.id.uuidString, "mode": tour.travelMode.rawValue, "path": path,
                                "format": "GPX 1.1 track", "apple_maps_url": mapsURL(tour),
                                "note": "The GPX file is local to this Mac. Import it in a route app that supports GPX and Apple Watch navigation."]])

        default:
            throw Err.message("Unknown tour tool: \(name)")
        }
    }

    private func search(query: String, near: TourPoint?, limit: Int) async throws -> [[String: Any]] {
        let items = try await searchItems(query: query, near: near, radius: 5_000)
        return Array(items.prefix(limit)).map { item in
            ["name": item.name ?? "Unnamed place", "address": item.placemark.title ?? "",
             "latitude": item.placemark.coordinate.latitude, "longitude": item.placemark.coordinate.longitude]
        }
    }

    private func searchItems(query: String, near: TourPoint?, radius: Double) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near {
            request.region = MKCoordinateRegion(center: near.coordinate,
                                                latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        }
        let items = try await MKLocalSearch(request: request).start().mapItems
        guard let near else { return items }
        let center = CLLocation(latitude: near.latitude, longitude: near.longitude)
        return items.filter { item in
            let place = CLLocation(latitude: item.placemark.coordinate.latitude,
                                   longitude: item.placemark.coordinate.longitude)
            return center.distance(from: place) <= radius
        }.sorted { left, right in
            let leftPlace = CLLocation(latitude: left.placemark.coordinate.latitude,
                                       longitude: left.placemark.coordinate.longitude)
            let rightPlace = CLLocation(latitude: right.placemark.coordinate.latitude,
                                        longitude: right.placemark.coordinate.longitude)
            return center.distance(from: leftPlace) < center.distance(from: rightPlace)
        }
    }

    private func route(from: TourPoint, to: TourPoint, mode: TourMode) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.transportType = mode.transportType
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw Err.message("Apple Maps could not calculate this \(mode.rawValue) leg. Check directions coverage for these places.")
        }
        return route
    }

    private func exportGPX(_ tour: WalkingTour) async throws -> String {
        guard let active = tour.stops.firstIndex(where: { $0.id == tour.nextStopID }) else {
            throw Err.message("Tour progress is invalid.")
        }
        var points: [TourPoint] = []
        let remaining = Array(tour.stops[active...])
        var legs = remaining.map(\.point)
        if let current = tour.currentPosition { legs.insert(current, at: 0) }
        guard legs.count >= 2 else { throw Err.message("Need a current position or two remaining stops to export a route.") }
        for i in 0..<(legs.count - 1) {
            let route = try await route(from: legs[i], to: legs[i + 1], mode: tour.travelMode)
            let polyline = route.polyline
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            points.append(contentsOf: try coordinates.map { try TourPoint($0.latitude, $0.longitude) })
        }
        guard !points.isEmpty else { throw Err.message("Apple Maps returned an empty route.") }
        let waypoints = remaining.map { stop in
            "<wpt lat=\"\(stop.point.latitude)\" lon=\"\(stop.point.longitude)\"><name>\(xml(stop.name))</name></wpt>"
        }.joined()
        let track = points.map { "<trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"/>" }.joined()
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Local Mac App Integrations" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>\(xml(tour.title))</name></metadata>\(waypoints)
        <trk><name>\(xml(tour.title))</name><trkseg>\(track)</trkseg></trk>
        </gpx>
        """
        let path = folder.appendingPathComponent("\(tour.id.uuidString)-\(tour.travelMode.rawValue)-route.gpx")
        try Data(gpx.utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path.path
    }

    private func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func mapsURL(_ tour: WalkingTour) -> String {
        guard let active = tour.stops.firstIndex(where: { $0.id == tour.nextStopID }) else { return "" }
        let remaining = Array(tour.stops[active...])
        var components = URLComponents(string: "https://maps.apple.com/directions")!
        let source = tour.currentPosition ?? (remaining.count > 1 ? remaining.first?.point : nil)
        var items: [URLQueryItem] = []
        if let source { items.append(URLQueryItem(name: "source", value: source.mapValue)) }
        if let last = remaining.last { items.append(URLQueryItem(name: "destination", value: last.point.mapValue)) }
        if remaining.count > 1 {
            items += remaining.dropLast().dropFirst(tour.currentPosition == nil ? 1 : 0)
                .map { URLQueryItem(name: "waypoint", value: $0.point.mapValue) }
        }
        items.append(URLQueryItem(name: "mode", value: tour.travelMode.rawValue))
        components.queryItems = items
        return components.url?.absoluteString ?? ""
    }

    private func summary(_ tour: WalkingTour) -> [String: Any] {
        ["id": tour.id.uuidString, "title": tour.title, "mode": tour.travelMode.rawValue,
         "updated_at": ISO8601DateFormatter().string(from: tour.updatedAt),
         "next_stop_id": tour.nextStopID.uuidString, "current_position": tour.currentPosition.map {
             ["latitude": $0.latitude, "longitude": $0.longitude]
         } as Any? ?? NSNull(),
         "apple_maps_url": mapsURL(tour),
         "maps_handoff_note": "Open the link on iPhone and review the \(tour.travelMode.rawValue) route. Apple Maps may not retain every waypoint; this server cannot update navigation already running on Apple Watch.",
         "stops": tour.stops.map { stop in
             ["id": stop.id.uuidString, "name": stop.name, "latitude": stop.point.latitude,
              "longitude": stop.point.longitude, "note": stop.note as Any? ?? NSNull()] as [String: Any]
         }]
    }

    private func parseStops(_ value: Value?) throws -> [TourStop] {
        guard let values = value?.arrayValue else { throw Err.message("Provide an ordered stops array.") }
        return try values.map { value in
            guard let a = value.objectValue else { throw Err.message("Each stop must be an object.") }
            return TourStop(id: UUID(), name: try required(a, "name"),
                            point: try point(a, latitude: "latitude", longitude: "longitude"),
                            note: a["note"]?.stringValue)
        }
    }

    private func required(_ a: [String: Value], _ key: String) throws -> String {
        guard let value = a[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw Err.message("Missing nonempty string: \(key)")
        }
        return value
    }

    private func point(_ a: [String: Value], latitude: String, longitude: String) throws -> TourPoint {
        guard let lat = a[latitude]?.doubleValue ?? a[latitude]?.intValue.map(Double.init),
              let lon = a[longitude]?.doubleValue ?? a[longitude]?.intValue.map(Double.init) else {
            throw Err.message("Provide numeric \(latitude) and \(longitude).")
        }
        return try TourPoint(lat, lon)
    }

    private func optionalPoint(_ a: [String: Value], latitude: String, longitude: String) throws -> TourPoint? {
        if a[latitude] == nil && a[longitude] == nil { return nil }
        return try point(a, latitude: latitude, longitude: longitude)
    }

    private func uuid(_ a: [String: Value], _ key: String) throws -> UUID {
        guard let text = a[key]?.stringValue, let id = UUID(uuidString: text) else { throw Err.message("Provide a valid \(key) UUID.") }
        return id
    }

    private func tourID(_ a: [String: Value]) throws -> UUID { try uuid(a, "tour_id") }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    private func load(_ id: UUID) throws -> WalkingTour {
        let path = url(id)
        guard FileManager.default.fileExists(atPath: path.path) else { throw Err.message("Tour not found: \(id.uuidString)") }
        return try decoder.decode(WalkingTour.self, from: Data(contentsOf: path))
    }

    private func save(_ tour: WalkingTour) throws {
        let path = url(tour.id)
        try encoder.encode(tour).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func encode(_ items: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
