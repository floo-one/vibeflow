import Foundation

/// Every IANA time zone with its main cities, country and abbreviations, for the Clocks
/// search. Data: vvo/tzdb (MIT), trimmed by scripts/update-time-zones.py.
public struct TimeZoneCatalog: Sendable {
    public struct Zone: Decodable, Sendable {
        public var id: String
        public var aliases: [String]
        public var name: String
        public var abbreviations: [String]
        public var country: String
        public var countryCode: String
        public var cities: [String]
    }

    public let zones: [Zone]

    /// Keeps only zones macOS can resolve, under the identifier it accepts: tzdb's
    /// Asia/Kolkata is Asia/Calcutta to Foundation. Adds UTC, which tzdb leaves out.
    public init(zones: [Zone]) {
        let utc = Zone(id: "UTC", aliases: ["GMT", "Etc/UTC"], name: "Coordinated Universal Time",
                       abbreviations: ["UTC", "GMT"], country: "", countryCode: "", cities: ["UTC"])
        self.zones = (zones + [utc]).compactMap { zone in
            guard let id = ([zone.id] + zone.aliases).first(where: { TimeZone(identifier: $0) != nil }) else { return nil }
            var zone = zone
            zone.id = id
            return zone
        }
    }

    /// The bundled list, decoded once.
    public static let bundled: TimeZoneCatalog = {
        guard let url = Bundle.module.url(forResource: "time-zones", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let zones = try? JSONDecoder().decode([Zone].self, from: data)
        else { return TimeZoneCatalog(zones: []) }
        return TimeZoneCatalog(zones: zones)
    }()

    /// Clocks matching a city, country, country code, abbreviation, zone name or IANA id.
    /// A city match shows that city ("Munich" -> Munich, Europe/Berlin); any other match
    /// shows the zone's main city. Best matches first.
    public func search(_ query: String, limit: Int = 8) -> [WorldClock] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return [] }
        var hits: [(rank: Int, weight: Int, order: Int, clock: WorldClock)] = []
        for (order, zone) in zones.enumerated() {
            // An exact country code or abbreviation ("de", "CEST") beats any partial match.
            let exact = Self.normalize(zone.countryCode) == q || zone.abbreviations.contains { Self.normalize($0) == q }
            let city = zone.cities.compactMap { city in Self.rank(city, q).map { (rank: $0, name: city) } }.min { $0.rank < $1.rank }
            let other = ([zone.country, zone.name, zone.id] + zone.aliases).compactMap { Self.rank($0, q) }.min().map { $0 + 1 }
            guard let rank = [exact ? -1 : nil, city?.rank, other].compactMap({ $0 }).min() else { continue }
            // Keep a matched city unless the exact code or abbreviation won.
            let name = (rank == city?.rank ? city?.name : nil) ?? zone.cities.first ?? Self.cityName(fromID: zone.id)
            hits.append((rank, -zone.aliases.count, order, WorldClock(zoneID: zone.id, city: name, countryCode: zone.countryCode)))
        }
        // Ties go to canonical zones (most aliases: New York carries US/Eastern, EST5EDT, ...).
        return hits.sorted { ($0.rank, $0.weight, $0.order) < ($1.rank, $1.weight, $1.order) }.prefix(limit).map(\.clock)
    }

    /// The catalog entry for a clock, for its country and zone name in Settings.
    public func zone(for clock: WorldClock) -> Zone? {
        zones.first { $0.id == clock.zoneID }
    }

    /// 0 = starts with the query, 1 = a word starts with it, 2 = contains it.
    private static func rank(_ text: String, _ query: String) -> Int? {
        let text = normalize(text)
        if text.hasPrefix(query) { return 0 }
        if text.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 1 }
        return text.contains(query) ? 2 : nil
    }

    /// Case and accent blind, IANA underscores and slashes as spaces: "koln" finds Köln.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func cityName(fromID id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }
}
