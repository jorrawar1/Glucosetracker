import Foundation

@MainActor
final class CGMReportCache {

    static let cacheVersion = 1

    private let fileURL: URL
    private var memory: [Date: CachedEntry] = [:]

    init() {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cgm_reports_v\(Self.cacheVersion).json")
        load()
    }

    func report(for day: Date) -> DeviationReport? {
        memory[day]?.report
    }

    func store(_ report: DeviationReport, for day: Date) {
        memory[day] = CachedEntry(report: report)
        save()
    }

    func storeMany(_ entries: [(day: Date, report: DeviationReport)]) {
        for entry in entries {
            memory[entry.day] = CachedEntry(report: entry.report)
        }
        save()
    }

    private struct CachedEntry: Codable {
        let report: DeviationReport
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: CachedEntry].self, from: data)
        else { return }
        let formatter = ISO8601DateFormatter()
        for (dateString, entry) in decoded {
            if let date = formatter.date(from: dateString) {
                memory[date] = entry
            }
        }
    }

    private func save() {
        let formatter = ISO8601DateFormatter()
        var out: [String: CachedEntry] = [:]
        for (date, entry) in memory {
            out[formatter.string(from: date)] = entry
        }
        guard let data = try? JSONEncoder().encode(out) else { return }
        try? data.write(to: fileURL)
    }
    
    func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
        memory.removeAll()
    }
}
