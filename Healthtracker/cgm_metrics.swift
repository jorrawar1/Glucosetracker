import Foundation


struct GlucoseReading {
    let timestamp: Date
    let valueMgDl: Double
}


enum AnalysisCalendar {
    static let timeZone = TimeZone(identifier: "America/New_York")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    static func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }

    static func minutesSinceMidnight(_ date: Date) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    static func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}

extension AnalysisCalendar {
    static func endOfDay(for day: Date) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: startOfDay(for: day))!
        return next.addingTimeInterval(-1)
    }
}

enum CGMConstants {
    static let lowMgDl: Double = 70
    static let highMgDl: Double = 180

    static let readingIntervalMin = 5
    static let eventMinDurationMin = 15
    static var eventMinReadings: Int { eventMinDurationMin / readingIntervalMin }

    static let mealBuckets: [(name: String, start: Int, end: Int)] = [
        ("breakfast_mean", 6, 11),
        ("lunch_mean",     11, 15),
        ("afternoon_mean", 15, 19),
        ("dinner_mean",    19, 24),
    ]
}


func meanGlucose(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    return values.reduce(0, +) / Double(values.count)
}

func cvGlucose(_ values: [Double]) -> Double {
    guard values.count > 1 else { return .nan }
    let m = meanGlucose(values)
    guard m != 0 else { return .nan }
    let n = Double(values.count)
    let variance = values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / (n - 1)
    return (variance.squareRoot() / m) * 100
}

func inRangePercent(_ values: [Double],
                    lo: Double = CGMConstants.lowMgDl,
                    hi: Double = CGMConstants.highMgDl) -> Double {
    guard !values.isEmpty else { return .nan }
    let inRange = values.filter { $0 >= lo && $0 <= hi }.count
    return Double(inRange) / Double(values.count) * 100
}

func gmi(_ values: [Double]) -> Double {
    return 3.31 + 0.02392 * meanGlucose(values)
}

private func bgRiskTransform(_ bg: Double) -> Double {
    return 1.509 * (pow(log(bg), 1.084) - 5.381)
}


func lbgi(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let risks = values.map { v -> Double in
        let f = bgRiskTransform(v)
        return f < 0 ? 10 * f * f : 0
    }
    return risks.reduce(0, +) / Double(risks.count)
}

func hbgi(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let risks = values.map { v -> Double in
        let f = bgRiskTransform(v)
        return f > 0 ? 10 * f * f : 0
    }
    return risks.reduce(0, +) / Double(risks.count)
}

private func centeredRollingMean(_ values: [Double], window: Int) -> [Double] {
    guard window > 1 else { return values }
    let half = window / 2
    var out = [Double](repeating: 0, count: values.count)
    for i in 0..<values.count {
        let lo = max(0, i - half)
        let hi = min(values.count - 1, i + half)
        let slice = values[lo...hi]
        out[i] = slice.reduce(0, +) / Double(slice.count)
    }
    return out
}

private func sampleStd(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let m = meanGlucose(values)
    let n = Double(values.count)
    let variance = values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / (n - 1)
    return variance.squareRoot()
}

enum MAGEDirection { case avg, plus, minus, max }

func mage(_ values: [Double],
         shortMA: Int = 5,
         longMA: Int = 32,
         sdMultiplier: Double = 1.0,
         direction: MAGEDirection = .avg) -> Double {

    let n = values.count
    guard n >= longMA + 1 else { return .nan }

    let sd = sampleStd(values)
    guard sd > 0 else { return 0 }

    let shortAvg = centeredRollingMean(values, window: shortMA)
    let longAvg = centeredRollingMean(values, window: longMA)

    var sign = [Int](repeating: 0, count: n)
    for i in 0..<n {
        let d = shortAvg[i] - longAvg[i]
        sign[i] = d > 0 ? 1 : (d < 0 ? -1 : 0)
    }
    for i in 1..<n where sign[i] == 0 {
        sign[i] = sign[i - 1]
    }

    var boundaries = [0]
    for i in 1..<n where sign[i] != sign[i - 1] {
        boundaries.append(i)
    }
    boundaries.append(n)

    enum ExtremumKind { case peak, nadir }
    var extrema: [(index: Int, value: Double, kind: ExtremumKind)] = []
    for j in 0..<(boundaries.count - 1) {
        let start = boundaries[j], end = boundaries[j + 1]
        guard start < end else { continue }
        let mid = (start + end) / 2
        let segment = Array(values[start..<end])
        if sign[mid] > 0 {
            var maxIdx = 0, maxVal = segment[0]
            for k in 1..<segment.count where segment[k] > maxVal {
                maxIdx = k; maxVal = segment[k]
            }
            extrema.append((start + maxIdx, maxVal, .peak))
        } else if sign[mid] < 0 {
            var minIdx = 0, minVal = segment[0]
            for k in 1..<segment.count where segment[k] < minVal {
                minIdx = k; minVal = segment[k]
            }
            extrema.append((start + minIdx, minVal, .nadir))
        }
    }

    guard extrema.count >= 2 else { return .nan }

    var ups: [Double] = []
    var downs: [Double] = []
    let threshold = sdMultiplier * sd
    for i in 0..<(extrema.count - 1) {
        let a = extrema[i], b = extrema[i + 1]
        guard a.kind != b.kind else { continue }
        let amp = abs(b.value - a.value)
        guard amp > threshold else { continue }
        if b.value > a.value {
            ups.append(amp)
        } else {
            downs.append(amp)
        }
    }

    if ups.isEmpty && downs.isEmpty { return 0 }

    let upMean = ups.isEmpty ? nil : ups.reduce(0, +) / Double(ups.count)
    let downMean = downs.isEmpty ? nil : downs.reduce(0, +) / Double(downs.count)

    switch direction {
    case .plus:  return upMean ?? 0
    case .minus: return downMean ?? 0
    case .max:   return Swift.max(upMean ?? 0, downMean ?? 0)
    case .avg:
        let parts = [upMean, downMean].compactMap { $0 }
        return parts.reduce(0, +) / Double(parts.count)
    }
}

func countEpisodes(_ values: [Double],
                   threshold: Double,
                   above: Bool,
                   readingIntervalMin: Int = CGMConstants.readingIntervalMin,
                   minDurationMin: Int = CGMConstants.eventMinDurationMin) -> Int {
    let minReadings = Swift.max(1, minDurationMin / readingIntervalMin)
    var events = 0
    var runExcursion = 0
    var runSafe = minReadings   // start "safe"
    var inEvent = false

    for v in values {
        let isEx = above ? (v > threshold) : (v < threshold)
        if isEx {
            runExcursion += 1
            runSafe = 0
            if !inEvent && runExcursion >= minReadings {
                events += 1
                inEvent = true
            }
        } else {
            runSafe += 1
            runExcursion = 0
            if inEvent && runSafe >= minReadings {
                inEvent = false
            }
        }
    }
    return events
}

func maxExcursionAmplitude(_ values: [Double],
                           minProminence: Double = 25,
                           smoothingWindow: Int = 5) -> Double {
    guard values.count >= 10 else { return .nan }
    let smoothed = centeredRollingMean(values, window: smoothingWindow)

    var biggest: Double = 0
    for i in 1..<(smoothed.count - 1) {
        guard smoothed[i] > smoothed[i - 1], smoothed[i] >= smoothed[i + 1] else {
            continue
        }

        var leftMin = smoothed[i]
        var k = i - 1
        while k >= 0 && smoothed[k] <= smoothed[i] {
            leftMin = Swift.min(leftMin, smoothed[k])
            k -= 1
        }

        var rightMin = smoothed[i]
        var j = i + 1
        while j < smoothed.count && smoothed[j] <= smoothed[i] {
            rightMin = Swift.min(rightMin, smoothed[j])
            j += 1
        }

        let referenceMin = Swift.max(leftMin, rightMin)
        let prominence = smoothed[i] - referenceMin
        if prominence >= minProminence {
            biggest = Swift.max(biggest, prominence)
        }
    }
    return biggest
}

func bucketMean(_ dayReadings: [GlucoseReading],
                startHour: Int,
                endHour: Int,
                minReadings: Int = 5) -> Double {
    let inBucket = dayReadings.filter { r in
        let h = AnalysisCalendar.hour(of: r.timestamp)
        return h >= startHour && h < endHour
    }
    guard inBucket.count >= minReadings else { return .nan }
    return meanGlucose(inBucket.map { $0.valueMgDl })
}

func overnightCV(_ dayReadings: [GlucoseReading]) -> Double {
    let overnight = dayReadings.filter { r in
        AnalysisCalendar.hour(of: r.timestamp) < 6
    }
    guard overnight.count >= 20 else { return .nan }
    return cvGlucose(overnight.map { $0.valueMgDl })
}

func dawnRise(_ dayReadings: [GlucoseReading]) -> Double {
    let pre = dayReadings.filter { r in
        let h = AnalysisCalendar.hour(of: r.timestamp)
        return h >= 3 && h < 6
    }.map { $0.valueMgDl }
    let post = dayReadings.filter { r in
        let h = AnalysisCalendar.hour(of: r.timestamp)
        return h >= 6 && h < 9
    }.map { $0.valueMgDl }
    guard pre.count >= 10, post.count >= 10 else { return .nan }
    return (post.max() ?? 0) - (pre.min() ?? 0)
}

struct AGPBaselineBand: Codable {
    let p25: Double
    let p75: Double
}

typealias AGPBaseline = [Int: AGPBaselineBand]

func buildAGPBaseline(_ readings: [GlucoseReading]) -> AGPBaseline {
    var byHour: [Int: [Double]] = [:]
    for r in readings {
        let h = AnalysisCalendar.hour(of: r.timestamp)
        byHour[h, default: []].append(r.valueMgDl)
    }
    var baseline: AGPBaseline = [:]
    for (hour, values) in byHour {
        baseline[hour] = AGPBaselineBand(
            p25: percentile(values, 25),
            p75: percentile(values, 75)
        )
    }
    return baseline
}

func agpDeviation(_ dayReadings: [GlucoseReading],
                  baseline: AGPBaseline,
                  wakingStart: Int = 6,
                  wakingEnd: Int = 24) -> Double {

    var byHour: [Int: [Double]] = [:]
    for r in dayReadings {
        let h = AnalysisCalendar.hour(of: r.timestamp)
        byHour[h, default: []].append(r.valueMgDl)
    }

    var outside = 0, total = 0
    for hour in wakingStart..<wakingEnd {
        guard let dayValues = byHour[hour], !dayValues.isEmpty,
              let band = baseline[hour] else { continue }
        let median = percentile(dayValues, 50)
        total += 1
        if median < band.p25 || median > band.p75 {
            outside += 1
        }
    }
    return total == 0 ? .nan : Double(outside) / Double(total) * 100
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = (p / 100.0) * Double(sorted.count - 1)
    let lo = Int(rank.rounded(.down))
    let hi = Int(rank.rounded(.up))
    if lo == hi { return sorted[lo] }
    let frac = rank - Double(lo)
    return sorted[lo] + frac * (sorted[hi] - sorted[lo])
}

struct DailyMetrics {
    let date: Date
    let readings: Int

    let mean: Double
    let tir70to180: Double
    let cv: Double
    let gmi: Double
    let mage: Double
    let lbgi: Double
    let hbgi: Double
    let hypoEvents: Int
    let hyperEvents: Int
    let maxExcursion: Double
    let overnightCV: Double
    let dawnRise: Double
    let agpDeviation: Double

    let bucketMeans: [String: Double]
}

func computeDailyMetrics(_ readings: [GlucoseReading],
                         minReadingsPerDay: Int = 50) -> [DailyMetrics] {
    var byDay: [Date: [GlucoseReading]] = [:]
    for r in readings {
        let day = AnalysisCalendar.startOfDay(for: r.timestamp)
        byDay[day, default: []].append(r)
    }

    let agpBase = buildAGPBaseline(readings)

    return byDay.keys.sorted().compactMap { day in
        let dayReadings = byDay[day]!.sorted(by: { $0.timestamp < $1.timestamp })
        guard dayReadings.count >= minReadingsPerDay else { return nil }
        let values = dayReadings.map { $0.valueMgDl }

        var bucketMeans: [String: Double] = [:]
        for b in CGMConstants.mealBuckets {
            bucketMeans[b.name] = bucketMean(dayReadings, startHour: b.start, endHour: b.end)
        }

        return DailyMetrics(
            date: day,
            readings: dayReadings.count,
            mean: meanGlucose(values),
            tir70to180: inRangePercent(values),
            cv: cvGlucose(values),
            gmi: gmi(values),
            mage: mage(values),
            lbgi: lbgi(values),
            hbgi: hbgi(values),
            hypoEvents: countEpisodes(values, threshold: CGMConstants.lowMgDl, above: false),
            hyperEvents: countEpisodes(values, threshold: CGMConstants.highMgDl, above: true),
            maxExcursion: maxExcursionAmplitude(values),
            overnightCV: overnightCV(dayReadings),
            dawnRise: dawnRise(dayReadings),
            agpDeviation: agpDeviation(dayReadings, baseline: agpBase),
            bucketMeans: bucketMeans
        )
    }
}
