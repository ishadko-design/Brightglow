import Foundation

/// Device-local record of the searches the user has run, surfaced in their
/// profile so they can jump back to a past request. Stored in UserDefaults (same
/// lightweight, best-effort pattern as ScreeningStore) — this is convenience
/// history, not synced account data. Tapping an entry re-runs the search.
enum SearchHistoryStore {
    private static let key = "searchHistory.v1"
    private static let maxEntries = 30

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let query: String
        let date: Date
    }

    /// Record a search. The most recent duplicate wins (case-insensitively), so
    /// repeating a query moves it to the top instead of stacking up.
    static func record(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var entries = all()
        entries.removeAll { $0.query.caseInsensitiveCompare(q) == .orderedSame }
        entries.insert(Entry(query: q, date: Date()), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save(entries)
    }

    /// All searches, most recent first.
    static func all() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    static func remove(_ entry: Entry) {
        save(all().filter { $0.id != entry.id })
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
