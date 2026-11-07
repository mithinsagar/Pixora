import Foundation

/// A look back chosen for today: photos from this date in earlier years or, for a library that's younger than a
/// year, from around this date in an earlier month.
public struct Memory: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        public var id: String { label }
        public let label: String
        public let photos: [Photo]
    }
    public let title: String
    public let subtitle: String
    public let groups: [Group]
    public var photos: [Photo] { groups.flatMap(\.photos) }
}

public enum Memories {
    /// The most a memory shows, spread evenly so one busy hour doesn't fill it.
    static let limit = 40
    /// "Around this time" means this many days either side.
    static let nearby = 3

    public static func make(from photos: [Photo], today: Date = Date(), calendar: Calendar = .current) -> Memory? {
        let start = calendar.startOfDay(for: today)
        let past = photos.filter { $0.takenAt.map { $0 < start } ?? false }
        guard !past.isEmpty else { return nil }
        return years(past, today: start, calendar: calendar, window: 0)
            ?? years(past, today: start, calendar: calendar, window: nearby)
            ?? months(past, today: start, calendar: calendar)
    }

    private static func years(_ photos: [Photo], today: Date, calendar: Calendar, window: Int) -> Memory? {
        let thisYear = calendar.component(.year, from: today)
        var byYear: [Int: [Photo]] = [:]
        for p in photos {
            guard let d = p.takenAt else { continue }
            let year = calendar.component(.year, from: d)
            guard year < thisYear, let anniversary = calendar.date(byAdding: .year, value: year - thisYear, to: today) else { continue }
            let days = abs(calendar.dateComponents([.day], from: anniversary, to: calendar.startOfDay(for: d)).day ?? .max)
            if days <= window { byYear[year, default: []].append(p) }
        }
        guard !byYear.isEmpty else { return nil }
        let groups = byYear.sorted { $0.key > $1.key }.map { year, list in
            Memory.Group(label: ago(thisYear - year, "year"), photos: sample(list, limit: max(6, limit / byYear.count)))
        }
        return Memory(title: window == 0 ? "On This Day" : "This Week in Past Years", subtitle: summary(groups), groups: groups)
    }

    private static func months(_ photos: [Photo], today: Date, calendar: Calendar) -> Memory? {
        for back in 1...11 {
            guard let date = calendar.date(byAdding: .month, value: -back, to: today) else { continue }
            let list = photos.filter { p in
                guard let d = p.takenAt else { return false }
                return abs(calendar.dateComponents([.day], from: date, to: calendar.startOfDay(for: d)).day ?? .max) <= nearby
            }
            guard !list.isEmpty else { continue }
            let label = ago(back, "month")
            let exact = list.contains { calendar.isDate($0.takenAt!, inSameDayAs: date) }
            let group = Memory.Group(label: label, photos: sample(list, limit: limit))
            return Memory(title: exact ? "This Day, \(label)" : "Around This Time, \(label)", subtitle: summary([group]), groups: [group])
        }
        return nil
    }

    private static func ago(_ n: Int, _ unit: String) -> String {
        let number = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
        return "\(n < number.count ? number[n] : "\(n)") \(unit.capitalized)\(n == 1 ? "" : "s") Ago"
    }

    private static func summary(_ groups: [Memory.Group]) -> String {
        let n = groups.reduce(0) { $0 + $1.photos.count }
        return n == 1 ? "1 photo" : "\(n) photos"
    }

    /// Up to `limit` photos at even steps through the day, oldest first.
    static func sample(_ photos: [Photo], limit: Int) -> [Photo] {
        let sorted = photos.sorted { ($0.takenAt ?? .distantPast, $0.filename) < ($1.takenAt ?? .distantPast, $1.filename) }
        guard sorted.count > limit else { return sorted }
        return (0..<limit).map { sorted[$0 * sorted.count / limit] }
    }
}
