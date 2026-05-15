#if DEBUG
import Foundation
import HealthKit

final class HealthKitProbe {
    private let healthStore = HKHealthStore()
    
    func probe() async {
        guard let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return }
        
        // Authorize for read
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [glucoseType])
        } catch {
            print("[Probe] Auth failed: \(error)")
            return
        }
        
        // Pull every glucose sample, sorted ascending
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: nil,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, error in
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
        
        let unit = HKUnit(from: "mg/dL")
        print("=== HealthKitProbe ===")
        print("Total samples: \(samples.count)")
        
        guard !samples.isEmpty else { return }
        
        // 1. Date range + timezone behavior
        let first = samples.first!, last = samples.last!
        print("First sample: \(first.startDate) (\(first.quantity.doubleValue(for: unit)) mg/dL)")
        print("Last  sample: \(last.startDate)  (\(last.quantity.doubleValue(for: unit)) mg/dL)")
        print("Span: \(last.startDate.timeIntervalSince(first.startDate) / 86400) days")
        
        // 2. Are start == end? (point sample) Or did HealthKit do anything?
        let pointSamples = samples.filter { $0.startDate == $0.endDate }.count
        print("Point-sample (start==end): \(pointSamples)/\(samples.count)")
        
        // 3. Inter-sample gaps — show distribution
        var gaps: [TimeInterval] = []
        for i in 1..<samples.count {
            gaps.append(samples[i].startDate.timeIntervalSince(samples[i-1].startDate))
        }
        let gapsSorted = gaps.sorted()
        let p50 = gapsSorted[gapsSorted.count / 2]
        let p95 = gapsSorted[Int(Double(gapsSorted.count) * 0.95)]
        let p99 = gapsSorted[Int(Double(gapsSorted.count) * 0.99)]
        print("Gap p50: \(p50)s, p95: \(p95)s, p99: \(p99)s, max: \(gapsSorted.last!)s")
        print("Gaps > 10 min: \(gaps.filter { $0 > 600 }.count)")
        print("Gaps > 1 hour: \(gaps.filter { $0 > 3600 }.count)")
        
        // 4. Duplicate detection
        let timestamps = samples.map { $0.startDate }
        let uniqueTimestamps = Set(timestamps)
        print("Unique timestamps: \(uniqueTimestamps.count) / \(samples.count) (\(samples.count - uniqueTimestamps.count) duplicates)")
        
        // 5. Value precision — count distinct values, range
        let values = samples.map { $0.quantity.doubleValue(for: unit) }
        let distinct = Set(values.map { Int($0) }).count  // integer-binned
        print("Distinct integer values: \(distinct), min: \(values.min()!), max: \(values.max()!)")
        // Are any non-integer?
        let nonInteger = values.filter { $0 != Double(Int($0)) }.count
        print("Non-integer values: \(nonInteger)/\(values.count)")
        
        // 6. Day grouping — useful as a sanity check vs Python
        let cal = Calendar.current
        var byDay: [Date: Int] = [:]
        for s in samples {
            let day = cal.startOfDay(for: s.startDate)
            byDay[day, default: 0] += 1
        }
        print("Days with data: \(byDay.count)")
        let readingsPerDay = byDay.values.sorted()
        print("Readings/day min: \(readingsPerDay.first!), median: \(readingsPerDay[readingsPerDay.count/2]), max: \(readingsPerDay.last!)")
        
        // 7. First day's first 5 samples — full detail, for byte-level checks
        print("\nFirst 5 samples in detail:")
        for s in samples.prefix(5) {
            print("  start=\(s.startDate) end=\(s.endDate) value=\(s.quantity.doubleValue(for: unit)) source=\(s.sourceRevision.source.name) tz_source=\(s.metadata?[HKMetadataKeyTimeZone] ?? "nil")")
        }
        
        // Compare against an injected reading we know about
        let target = ISO8601DateFormatter().date(from: "2026-03-27T09:00:00-04:00")!
        let nearTarget = samples.min(by: { abs($0.startDate.timeIntervalSince(target)) < abs($1.startDate.timeIntervalSince(target)) })!
        print("Nearest to 2026-03-27 09:00 EDT: \(nearTarget.startDate), delta=\(nearTarget.startDate.timeIntervalSince(target))s")
    }
}
#endif
