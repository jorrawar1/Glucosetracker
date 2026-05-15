import Foundation
import HealthKit

enum CGMReaderError: Error, LocalizedError {
    case healthKitUnavailable
    case glucoseTypeUnavailable
    case authorizationDenied
    case queryFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            return "HealthKit is unavailable on this device."
        case .glucoseTypeUnavailable:
            return "Blood glucose type is not available."
        case .authorizationDenied:
            return "Permission to read glucose data was not granted."
        case .queryFailed(let error):
            return "HealthKit query failed: \(error.localizedDescription)"
        }
    }
}

final class CGMReader {

    private let healthStore = HKHealthStore()

    /// The mg/dL unit. Constructed once; HKUnit construction is non-trivial.
    private let glucoseUnit = HKUnit(from: "mg/dL")

    /// The glucose quantity type. Constant for the app lifetime.
    private let glucoseType: HKQuantityType = {
        guard let t = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else {
            fatalError("Blood glucose type unavailable — this should never happen on iOS")
        }
        return t
    }()

    func requestReadAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw CGMReaderError.healthKitUnavailable
        }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [glucoseType])
        } catch {
            throw CGMReaderError.queryFailed(underlying: error)
        }
    }

    func readReadings(from start: Date, to end: Date) async throws -> [GlucoseReading] {
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate]   // sample's start must be within the range
        )
        return try await runQuery(predicate: predicate)
    }

    func readAllReadings() async throws -> [GlucoseReading] {
        try await runQuery(predicate: nil)
    }

    private func runQuery(predicate: NSPredicate?) async throws -> [GlucoseReading] {
        let sort = NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { [glucoseUnit] _, samples, error in
                if let error = error {
                    continuation.resume(throwing: CGMReaderError.queryFailed(underlying: error))
                    return
                }
                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                let readings = quantitySamples.map { s in
                    GlucoseReading(
                        timestamp: s.startDate,
                        valueMgDl: s.quantity.doubleValue(for: glucoseUnit)
                    )
                }
                continuation.resume(returning: readings)
            }
            healthStore.execute(query)
        }
    }
}
