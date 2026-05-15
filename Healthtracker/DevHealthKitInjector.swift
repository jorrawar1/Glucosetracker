#if DEBUG
import Foundation
import HealthKit

/// DEV-ONLY: Loads CGM data from a bundled CSV into Apple Health.
/// Only runs when the app is launched with the `-InjectHealthData` argument.
///
/// Before injecting, deletes all previously-injected glucose samples from
/// THIS app's source. Real CGM data from other apps (e.g. Dexcom G6) is
/// untouched. This makes re-injection idempotent during development.
final class DevHealthKitInjector {
    private let healthStore = HKHealthStore()
    private let csvResourceName = "cgm_data_shifted"

    func injectIfLaunchArgPresent() async {
        guard CommandLine.arguments.contains("-InjectHealthData") else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[Injector] HealthKit unavailable.")
            return
        }

        do {
            try await requestPermissions()
            let deleted = try await deleteExistingSamples()
            print("[Injector] Deleted \(deleted) prior glucose samples from this app.")

            let samples = try loadSamplesFromCSV()
            try await healthStore.save(samples)
            print("[Injector] Injected \(samples.count) glucose samples.")
        } catch {
            print("[Injector] Failed: \(error)")
        }
    }

    // MARK: Permissions

    private func requestPermissions() async throws {
        guard let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return }
        try await healthStore.requestAuthorization(
            toShare: [glucoseType],
            read: [glucoseType]
        )
    }

    // MARK: Delete

    /// Delete all blood-glucose samples whose source is this app.
    /// Returns the count of samples deleted.
    private func deleteExistingSamples() async throws -> Int {
        guard let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else {
            return 0
        }

        // Scope to samples written by this app's bundle. Without this scope,
        // delete(_:) would also remove samples from Dexcom, LibreView, etc.
        let mySource = HKSource.default()  // this app
        let predicate = HKQuery.predicateForObjects(from: mySource)

        return try await withCheckedThrowingContinuation { continuation in
            healthStore.deleteObjects(of: glucoseType, predicate: predicate) { _, count, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }

    // MARK: Load

    private func loadSamplesFromCSV() throws -> [HKQuantitySample] {
        guard let url = Bundle.main.url(forResource: csvResourceName, withExtension: "csv") else {
            throw NSError(domain: "Injector", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "CSV not in bundle"])
        }

        let content = try String(contentsOf: url)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return [] }
        let unit = HKUnit(from: "mg/dL")
        let metadata: [String: Any] = [HKMetadataKeyTimeZone: "America/New_York"]

        var samples: [HKQuantitySample] = []

        for line in content.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3,
                  let date = formatter.date(from: cols[0]),
                  let value = Double(cols[2]) else {
                continue  // header / malformed
            }

            let quantity = HKQuantity(unit: unit, doubleValue: value)
            let sample = HKQuantitySample(
                type: glucoseType,
                quantity: quantity,
                start: date,
                end: date,
                metadata: metadata
            )
            samples.append(sample)
        }

        return samples
    }
}
#endif
