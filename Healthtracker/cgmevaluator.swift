import Foundation

enum DeviationRating: String, Codable {
    case negative
    case typical
    case positive
    case insufficientData = "insufficient_data"
    case insufficientHistory = "insufficient_history"
}

struct MetricScore: Codable {
    let metric: String
    let label: String
    let value: Double
    let typical: Double
    let rawZ: Double
    let signedZ: Double
    let nBaselineDays: Int
    let unit: String
}

struct DeviationReport: Codable {
    let rating: DeviationRating
    let targetDate: Date
    let elapsedMin: Int
    let asOf: Date
    let reason: String?
    let nBaselineDays: Int
    let topFactors: [MetricScore]
    let allMetrics: [MetricScore]
    let baselineAGP: AGPBaseline?
}


enum EvaluatorConfig {
    static let nBaselineDays = 30
    static let minBaselineDays = 7
    static let shrinkageK = 10.0
    static let negativeZThreshold = 2.5
    static let positiveZThreshold = 1.5
    static let minTodayReadings = 5
}

private enum MetricDirection { case higherIsBetter, lowerIsBetter }

private let scoringMetrics: [(name: String, direction: MetricDirection)] = [
    ("tir_70_180",      .higherIsBetter),
    ("cv",              .lowerIsBetter),
    ("mage",            .lowerIsBetter),
    ("lbgi",            .lowerIsBetter),
    ("hbgi",            .lowerIsBetter),
    ("hypo_events",     .lowerIsBetter),
    ("hyper_events",    .lowerIsBetter),
    ("max_excursion",   .lowerIsBetter),
    ("overnight_cv",    .lowerIsBetter),
    ("dawn_rise",       .lowerIsBetter),
    ("agp_deviation",   .lowerIsBetter),
    ("breakfast_mean",  .lowerIsBetter),
    ("lunch_mean",      .lowerIsBetter),
    ("afternoon_mean",  .lowerIsBetter),
    ("dinner_mean",     .lowerIsBetter),
]

private let displayOnlyMetrics = ["mean"]

private let metricLabels: [String: String] = [
    "mean":             "Mean glucose",
    "tir_70_180":       "TIR (70–180)",
    "cv":               "CV (variability)",
    "mage":             "MAGE",
    "lbgi":             "LBGI (hypo risk)",
    "hbgi":             "HBGI (hyper risk)",
    "hypo_events":      "Hypo events",
    "hyper_events":     "Hyper events",
    "max_excursion":    "Biggest spike",
    "overnight_cv":     "Overnight CV (0–6 AM)",
    "dawn_rise":        "Dawn rise (3→9 AM)",
    "agp_deviation":    "AGP-band deviation",
    "breakfast_mean":   "Breakfast period (6–11 AM) mean",
    "lunch_mean":       "Lunch period (11 AM–3 PM) mean",
    "afternoon_mean":   "Afternoon (3–7 PM) mean",
    "dinner_mean":      "Dinner period (7 PM–midnight) mean",
]

private let metricUnits: [String: String] = [
    "mean":             "mg/dL",
    "tir_70_180":       "%",
    "cv":               "%",
    "mage":             "mg/dL",
    "lbgi":             "",
    "hbgi":             "",
    "hypo_events":      "",
    "hyper_events":     "",
    "max_excursion":    "mg/dL",
    "overnight_cv":     "%",
    "dawn_rise":        "mg/dL",
    "agp_deviation":    "%",
    "breakfast_mean":   "mg/dL",
    "lunch_mean":       "mg/dL",
    "afternoon_mean":   "mg/dL",
    "dinner_mean":      "mg/dL",
]

func evaluate(asOf: Date, history: [GlucoseReading]) -> DeviationReport {
    let targetDate = AnalysisCalendar.startOfDay(for: asOf)
    let elapsedMin = AnalysisCalendar.minutesSinceMidnight(asOf)

    let todayReadings = history.filter { r in
        AnalysisCalendar.startOfDay(for: r.timestamp) == targetDate
            && AnalysisCalendar.minutesSinceMidnight(r.timestamp) < elapsedMin
    }
    guard todayReadings.count >= EvaluatorConfig.minTodayReadings else {
        return DeviationReport(
            rating: .insufficientData,
            targetDate: targetDate,
            elapsedMin: elapsedMin,
            asOf: asOf,
            reason: "only \(todayReadings.count) readings by \(formatTime(elapsedMin))",
            nBaselineDays: 0,
            topFactors: [],
            allMetrics: [],
            baselineAGP: nil
        )
    }

    guard let baseline = buildTrailingBaseline(
        history: history,
        targetDate: targetDate,
        elapsedMin: elapsedMin
    ) else {
        return DeviationReport(
            rating: .insufficientHistory,
            targetDate: targetDate,
            elapsedMin: elapsedMin,
            asOf: asOf,
            reason: "fewer than \(EvaluatorConfig.minBaselineDays) prior days with data",
            nBaselineDays: 0,
            topFactors: [],
            allMetrics: [],
            baselineAGP: nil
        )
    }

    let todayMetrics = windowedMetrics(for: todayReadings, agpBaseline: baseline.agp)
    let scores = classifyAgainstBaseline(today: todayMetrics, baseline: baseline)
    let rating = ratingFor(scores: scores)
    let topFactors = topContributors(from: scores, limit: 3)

    return DeviationReport(
        rating: rating,
        targetDate: targetDate,
        elapsedMin: elapsedMin,
        asOf: asOf,
        reason: nil,
        nBaselineDays: scores.map { $0.nBaselineDays }.max() ?? 0,
        topFactors: topFactors,
        allMetrics: scores,
        baselineAGP: baseline.agp
    )
}

private func metricsAsDictionary(_ m: DailyMetricsValues) -> [String: Double] {
    var out: [String: Double] = [
        "mean":             m.mean,
        "tir_70_180":       m.tir70to180,
        "cv":               m.cv,
        "mage":             m.mage,
        "lbgi":             m.lbgi,
        "hbgi":             m.hbgi,
        "hypo_events":      Double(m.hypoEvents),
        "hyper_events":     Double(m.hyperEvents),
        "max_excursion":    m.maxExcursion,
        "overnight_cv":     m.overnightCV,
        "dawn_rise":        m.dawnRise,
        "agp_deviation":    m.agpDeviation,
    ]
    for (name, value) in m.bucketMeans {
        out[name] = value
    }
    return out
}

struct DailyMetricsValues {
    let mean: Double
    let tir70to180: Double
    let cv: Double
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

private func windowedMetrics(for readings: [GlucoseReading],
                             agpBaseline: AGPBaseline) -> DailyMetricsValues {
    let values = readings.map { $0.valueMgDl }

    var bucketMeans: [String: Double] = [:]
    for b in CGMConstants.mealBuckets {
        bucketMeans[b.name] = bucketMean(readings, startHour: b.start, endHour: b.end)
    }

    return DailyMetricsValues(
        mean: meanGlucose(values),
        tir70to180: inRangePercent(values),
        cv: cvGlucose(values),
        mage: mage(values),
        lbgi: lbgi(values),
        hbgi: hbgi(values),
        hypoEvents: countEpisodes(values, threshold: CGMConstants.lowMgDl, above: false),
        hyperEvents: countEpisodes(values, threshold: CGMConstants.highMgDl, above: true),
        maxExcursion: maxExcursionAmplitude(values),
        overnightCV: overnightCV(readings),
        dawnRise: dawnRise(readings),
        agpDeviation: agpDeviation(readings, baseline: agpBaseline),
        bucketMeans: bucketMeans
    )
}

private struct TrailingBaseline {
    let agp: AGPBaseline
    let perMetric: [String: MetricBaseline]
}

private struct MetricBaseline {
    let median: Double
    let mad: Double
    let scale: Double
    let n: Int
    let p10: Double
    let p90: Double
}

private func buildTrailingBaseline(history: [GlucoseReading],
                                   targetDate: Date,
                                   elapsedMin: Int) -> TrailingBaseline? {

    let allDays = Set(history.map { AnalysisCalendar.startOfDay(for: $0.timestamp) })
    let priorDays = allDays
        .filter { $0 < targetDate }
        .sorted()
        .suffix(EvaluatorConfig.nBaselineDays)

    guard priorDays.count >= EvaluatorConfig.minBaselineDays else { return nil }

    var perDayReadings: [Date: [GlucoseReading]] = [:]
    for r in history {
        let day = AnalysisCalendar.startOfDay(for: r.timestamp)
        guard priorDays.contains(day) else { continue }
        guard AnalysisCalendar.minutesSinceMidnight(r.timestamp) < elapsedMin else { continue }
        perDayReadings[day, default: []].append(r)
    }

    let allWindowedReadings = perDayReadings.values.flatMap { $0 }
    let agp = buildAGPBaseline(allWindowedReadings)

    var perMetricValues: [String: [Double]] = [:]
    for day in priorDays {
        guard let dayReadings = perDayReadings[day],
              dayReadings.count >= EvaluatorConfig.minTodayReadings else { continue }
        let dayMetrics = windowedMetrics(for: dayReadings, agpBaseline: agp)
        for (name, value) in metricsAsDictionary(dayMetrics) {
            guard !value.isNaN else { continue }
            perMetricValues[name, default: []].append(value)
        }
    }

    var perMetric: [String: MetricBaseline] = [:]
    for (name, values) in perMetricValues {
        guard values.count >= EvaluatorConfig.minBaselineDays else { continue }
        let median = percentile(values, 50)
        let absDeviations = values.map { abs($0 - median) }
        let mad = percentile(absDeviations, 50)
        let n = values.count
        let baseScale = Swift.max(mad, 0.5)
        let shrinkage = (1 + EvaluatorConfig.shrinkageK / Double(n)).squareRoot()
        let scale = baseScale * shrinkage
        perMetric[name] = MetricBaseline(
            median: median,
            mad: mad,
            scale: scale,
            n: n,
            p10: percentile(values, 10),
            p90: percentile(values, 90)
        )
    }

    return TrailingBaseline(agp: agp, perMetric: perMetric)
}

private func classifyAgainstBaseline(today: DailyMetricsValues,
                                     baseline: TrailingBaseline) -> [MetricScore] {
    let todayDict = metricsAsDictionary(today)
    var scores: [MetricScore] = []

    let allMetricNames = scoringMetrics.map { $0.name } + displayOnlyMetrics
    for name in allMetricNames {
        guard let value = todayDict[name], !value.isNaN else { continue }
        guard let b = baseline.perMetric[name] else { continue }

        let rawZ = 0.6745 * (value - b.median) / b.scale
        let direction = scoringMetrics.first(where: { $0.name == name })?.direction
        let signedZ: Double
        switch direction {
        case .higherIsBetter: signedZ = rawZ
        case .lowerIsBetter:  signedZ = -rawZ
        case .none:           signedZ = 0
        }
        scores.append(MetricScore(
            metric: name,
            label: metricLabels[name] ?? name,
            value: value,
            typical: b.median,
            rawZ: rawZ,
            signedZ: signedZ,
            nBaselineDays: b.n,
            unit: metricUnits[name] ?? ""
        ))
    }
    return scores
}

private func ratingFor(scores: [MetricScore]) -> DeviationRating {
    let scoringNames = Set(scoringMetrics.map { $0.name })
    let scoringSigned = scores
        .filter { scoringNames.contains($0.metric) }
        .map { $0.signedZ }
    guard !scoringSigned.isEmpty else { return .typical }

    if let minZ = scoringSigned.min(), minZ < -EvaluatorConfig.negativeZThreshold {
        return .negative
    }
    if let maxZ = scoringSigned.max(), maxZ > EvaluatorConfig.positiveZThreshold {
        return .positive
    }
    return .typical
}

private func topContributors(from scores: [MetricScore], limit: Int) -> [MetricScore] {
    scores
        .sorted(by: { abs($0.rawZ) > abs($1.rawZ) })
        .prefix(limit)
        .filter { abs($0.rawZ) > 1.0 }
        .map { $0 }
}

func evaluateBatch(asOfTimestamps: [Date],
                   history: [GlucoseReading]) -> [DeviationReport] {

    var readingsByDay: [Date: [GlucoseReading]] = [:]
    for r in history {
        let day = AnalysisCalendar.startOfDay(for: r.timestamp)
        readingsByDay[day, default: []].append(r)
    }
    for day in readingsByDay.keys {
        readingsByDay[day]?.sort(by: { $0.timestamp < $1.timestamp })
    }

    struct CacheKey: Hashable {
        let day: Date
        let elapsedMin: Int
    }
    var metricsCache: [CacheKey: DailyMetricsValues] = [:]

    func windowedReadings(for day: Date, elapsedMin: Int) -> [GlucoseReading] {
        guard let all = readingsByDay[day] else { return [] }
        if elapsedMin >= 1440 { return all }
        return all.filter { AnalysisCalendar.minutesSinceMidnight($0.timestamp) < elapsedMin }
    }

    func metrics(for day: Date, elapsedMin: Int, agp: AGPBaseline) -> DailyMetricsValues? {
        let key = CacheKey(day: day, elapsedMin: elapsedMin)
        if let cached = metricsCache[key] { return cached }
        let readings = windowedReadings(for: day, elapsedMin: elapsedMin)
        guard readings.count >= EvaluatorConfig.minTodayReadings else { return nil }
        let computed = windowedMetrics(for: readings, agpBaseline: agp)
        metricsCache[key] = computed
        return computed
    }

    return asOfTimestamps.map { asOf in
        evaluateOne(
            asOf: asOf,
            readingsByDay: readingsByDay,
            metrics: metrics
        )
    }
}

private func evaluateOne(
    asOf: Date,
    readingsByDay: [Date: [GlucoseReading]],
    metrics: (Date, Int, AGPBaseline) -> DailyMetricsValues?
) -> DeviationReport {

    let targetDate = AnalysisCalendar.startOfDay(for: asOf)
    let elapsedMin = AnalysisCalendar.minutesSinceMidnight(asOf)

    let todayReadings = (readingsByDay[targetDate] ?? []).filter {
        AnalysisCalendar.minutesSinceMidnight($0.timestamp) < elapsedMin
    }
    guard todayReadings.count >= EvaluatorConfig.minTodayReadings else {
        return DeviationReport(
            rating: .insufficientData,
            targetDate: targetDate,
            elapsedMin: elapsedMin,
            asOf: asOf,
            reason: "only \(todayReadings.count) readings by \(formatTime(elapsedMin))",
            nBaselineDays: 0,
            topFactors: [],
            allMetrics: [],
            baselineAGP: nil
        )
    }

    let allDays = readingsByDay.keys.sorted()
    let priorDays = allDays
        .filter { $0 < targetDate }
        .suffix(EvaluatorConfig.nBaselineDays)

    guard priorDays.count >= EvaluatorConfig.minBaselineDays else {
        return DeviationReport(
            rating: .insufficientHistory,
            targetDate: targetDate,
            elapsedMin: elapsedMin,
            asOf: asOf,
            reason: "fewer than \(EvaluatorConfig.minBaselineDays) prior days with data",
            nBaselineDays: 0,
            topFactors: [],
            allMetrics: [],
            baselineAGP: nil
        )
    }

    var allWindowedReadings: [GlucoseReading] = []
    for day in priorDays {
        let readings = (readingsByDay[day] ?? []).filter {
            AnalysisCalendar.minutesSinceMidnight($0.timestamp) < elapsedMin
        }
        allWindowedReadings.append(contentsOf: readings)
    }
    let agp = buildAGPBaseline(allWindowedReadings)

    var perMetricValues: [String: [Double]] = [:]
    for day in priorDays {
        guard let dayMetrics = metrics(day, elapsedMin, agp) else { continue }
        for (name, value) in metricsAsDictionary(dayMetrics) {
            guard !value.isNaN else { continue }
            perMetricValues[name, default: []].append(value)
        }
    }

    var perMetric: [String: MetricBaseline] = [:]
    for (name, values) in perMetricValues {
        guard values.count >= EvaluatorConfig.minBaselineDays else { continue }
        let median = percentile(values, 50)
        let absDeviations = values.map { abs($0 - median) }
        let mad = percentile(absDeviations, 50)
        let n = values.count
        let baseScale = Swift.max(mad, 0.5)
        let shrinkage = (1 + EvaluatorConfig.shrinkageK / Double(n)).squareRoot()
        let scale = baseScale * shrinkage
        perMetric[name] = MetricBaseline(
            median: median, mad: mad, scale: scale, n: n,
            p10: percentile(values, 10),
            p90: percentile(values, 90)
        )
    }
    let baseline = TrailingBaseline(agp: agp, perMetric: perMetric)

    let todayValues = windowedMetrics(for: todayReadings, agpBaseline: agp)
    let scores = classifyAgainstBaseline(today: todayValues, baseline: baseline)
    let rating = ratingFor(scores: scores)
    let topFactors = topContributors(from: scores, limit: 3)

    return DeviationReport(
        rating: rating,
        targetDate: targetDate,
        elapsedMin: elapsedMin,
        asOf: asOf,
        reason: nil,
        nBaselineDays: scores.map { $0.nBaselineDays }.max() ?? 0,
        topFactors: topFactors,
        allMetrics: scores,
        baselineAGP: baseline.agp
    )
}

private func formatTime(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    return String(format: "%02d:%02d", h, m)
}
