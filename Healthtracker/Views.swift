//
//  Views.swift
//  Healthtracker
//
//  SwiftUI views for the Today and Review screens.
//

import SwiftUI
import Charts
import Combine

// MARK: - Palette

enum AppColor {
    static let bg          = Color(red: 0.97, green: 0.97, blue: 0.97)
    static let panel       = Color.white
    static let border      = Color(red: 0.90, green: 0.90, blue: 0.91)
    static let text        = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let muted       = Color(red: 0.42, green: 0.42, blue: 0.44)
    static let negative    = Color(red: 0.77, green: 0.19, blue: 0.19)
    static let positive    = Color(red: 0.18, green: 0.52, blue: 0.35)
    static let typical     = Color(red: 0.35, green: 0.39, blue: 0.47)
    static let insufficient = Color(red: 0.61, green: 0.55, blue: 0.25)
}

extension DeviationRating {
    var color: Color {
        switch self {
        case .negative: return AppColor.negative
        case .positive: return AppColor.positive
        case .typical:  return AppColor.typical
        case .insufficientData, .insufficientHistory: return AppColor.insufficient
        }
    }

    var displayText: String {
        switch self {
        case .negative: return "NEGATIVE"
        case .positive: return "POSITIVE"
        case .typical:  return "TYPICAL"
        case .insufficientData: return "INSUFFICIENT DATA"
        case .insufficientHistory: return "INSUFFICIENT HISTORY"
        }
    }

    var isInsufficient: Bool {
        self == .insufficientData || self == .insufficientHistory
    }
}

// MARK: - Reusable view pieces

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(14)
            .background(AppColor.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppColor.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(AppColor.muted)
    }
}

struct RatingBadge: View {
    let rating: DeviationRating

    var body: some View {
        Text(rating.displayText)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.3)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(rating.color.opacity(0.15))
            .foregroundStyle(rating.color)
            .clipShape(Capsule())
    }
}

/// Centered card for empty / error / "not enough data yet" states.
struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(icon: String, title: String, message: String,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        Card {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(AppColor.muted)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(AppColor.text)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Glucose chart

struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let baseline: AGPBaseline?
    let rating: DeviationRating
    let elapsedMin: Int
    let compact: Bool

    private var lineColor: Color { rating.color }

    private struct ChartPoint: Identifiable {
        let id: TimeInterval     // exact timestamp - never collides
        let hour: Double
        let value: Double
    }

    private var todayPoints: [ChartPoint] {
        // Sort + dedupe by timestamp + filter invalid values, all defensive.
        let unique = Dictionary(grouping: readings, by: { $0.timestamp })
            .compactMap { $0.value.first }
        return unique
            .sorted(by: { $0.timestamp < $1.timestamp })
            .filter { $0.valueMgDl.isFinite && $0.valueMgDl > 0 }
            .map { r in
                let mins = AnalysisCalendar.minutesSinceMidnight(r.timestamp)
                return ChartPoint(
                    id: r.timestamp.timeIntervalSince1970,
                    hour: Double(mins) / 60.0,
                    value: r.valueMgDl
                )
            }
    }

    private var baselinePoints: [(hour: Double, p25: Double, p75: Double)] {
        guard let baseline else { return [] }
        // Restrict the band to elapsed hours (Today view at 2 PM → band stops at 14).
        // For full-day evaluations (elapsedMin = 1439-1440), this is effectively
        // the whole day.
        let cutoff = Double(elapsedMin) / 60.0
        return baseline.keys.sorted().compactMap { hour -> (Double, Double, Double)? in
            guard let band = baseline[hour], Double(hour) <= cutoff else { return nil }
            return (Double(hour), band.p25, band.p75)
        }
    }

    var body: some View {
        if todayPoints.isEmpty {
            Text("No readings for this day")
                .foregroundStyle(AppColor.muted)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: compact ? 60 : 280)
        } else {
            Chart {
                // Target band (70-180) shaded faint green
                RectangleMark(
                    xStart: .value("x", 0),
                    xEnd: .value("x", 24),
                    yStart: .value("y", 70),
                    yEnd: .value("y", 180)
                )
                .foregroundStyle(AppColor.positive.opacity(0.06))


                // Today's glucose curve
                ForEach(todayPoints) { p in
                    LineMark(
                        x: .value("Hour", p.hour),
                        y: .value("Glucose", p.value)
                    )
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2.5))
                    .interpolationMethod(.linear)
                }

                // "Now" marker for partial days
                if !compact && elapsedMin > 0 && elapsedMin < 1439 {
                    RuleMark(x: .value("Now", Double(elapsedMin) / 60.0))
                        .foregroundStyle(AppColor.muted.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: 0...24)
            .chartYScale(domain: 40...320)
            .chartXAxis {
                AxisMarks(values: stride(from: 0, through: 24, by: 6).map { $0 }) { value in
                    AxisGridLine().foregroundStyle(AppColor.border)
                    AxisTick().foregroundStyle(AppColor.border)
                    AxisValueLabel {
                        if let h = value.as(Int.self) {
                            Text(String(format: "%02d:00", h))
                                .font(.system(size: 10))
                                .foregroundStyle(AppColor.muted)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [70, 180, 250]) { value in
                    AxisGridLine().foregroundStyle(AppColor.border)
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)")
                                .font(.system(size: 10))
                                .foregroundStyle(AppColor.muted)
                        }
                    }
                }
            }
            .frame(height: compact ? 60 : 280)
        }
    }
}

// MARK: - View models

@MainActor
final class TodayViewModel: ObservableObject {
    @Published var report: DeviationReport?
    @Published var todayReadings: [GlucoseReading] = []
    @Published var isLoading = true
    @Published var error: String?

    private let reader = CGMReader()

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await reader.requestReadAuthorization()
            let now = Date()
            let start = Calendar.current.date(byAdding: .day, value: -35, to: now)!
            let readings = try await reader.readReadings(from: start, to: now)

            let todayStart = AnalysisCalendar.startOfDay(for: now)
            self.todayReadings = readings.filter {
                AnalysisCalendar.startOfDay(for: $0.timestamp) == todayStart
            }
            self.report = evaluate(asOf: now, history: readings)
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var isLoading = true
    @Published var error: String?

    struct Entry: Identifiable {
        let id: Date
        let date: Date
        let report: DeviationReport
        let readings: [GlucoseReading]
    }

    private let reader = CGMReader()
    private let cache = CGMReportCache()
    private let daysToReview = 30

    func load() async {
        let t0 = Date()
        isLoading = true
        defer { isLoading = false }
        do {
            try await reader.requestReadAuthorization()

            let now = Date()
            let calendar = AnalysisCalendar.calendar
            let today = AnalysisCalendar.startOfDay(for: now)
            let dayDates = (1...daysToReview).compactMap { daysAgo in
                calendar.date(byAdding: .day, value: -daysAgo, to: today)
            }

            // Which days still need computing
            let uncachedDays = dayDates.filter { cache.report(for: $0) == nil }

            // Read enough history to cover the oldest uncached day's baseline
            let oldestNeededDay = uncachedDays.min() ?? today
            let oldestPossibleBaselineDay = calendar.date(
                byAdding: .day,
                value: -(EvaluatorConfig.nBaselineDays + 5),
                to: oldestNeededDay
            ) ?? oldestNeededDay
            let readings = try await reader.readReadings(
                from: oldestPossibleBaselineDay,
                to: now
            )

            // Pre-group readings by day, used for chart display
            var readingsByDay: [Date: [GlucoseReading]] = [:]
            for r in readings {
                let day = AnalysisCalendar.startOfDay(for: r.timestamp)
                readingsByDay[day, default: []].append(r)
            }

            // Batch-evaluate just the uncached days
            var computedReports: [Date: DeviationReport] = [:]
            if !uncachedDays.isEmpty {
                let asOfTimestamps = uncachedDays.map { AnalysisCalendar.endOfDay(for: $0) }
                let reports = evaluateBatch(asOfTimestamps: asOfTimestamps, history: readings)
                for (day, report) in zip(uncachedDays, reports) {
                    computedReports[day] = report
                }
                // Cache only "real" results — don't cache insufficient ratings
                // because next time the user wears their CGM more, those days
                // might become evaluatable.
                let toCache = uncachedDays.compactMap { day -> (day: Date, report: DeviationReport)? in
                    guard let r = computedReports[day], !r.rating.isInsufficient else { return nil }
                    return (day, r)
                }
                cache.storeMany(toCache)
            }

            // Build entries: cache hit OR newly computed OR fallback
            self.entries = dayDates.map { day in
                let report = cache.report(for: day) ?? computedReports[day] ?? DeviationReport(
                    rating: .insufficientData,
                    targetDate: day,
                    elapsedMin: 1440,
                    asOf: day,
                    reason: "no data",
                    nBaselineDays: 0,
                    topFactors: [],
                    allMetrics: [],
                    baselineAGP: nil
                )
                let dayReadings = readingsByDay[day] ?? []
                return Entry(id: day, date: day, report: report, readings: dayReadings)
            }
            self.error = nil
            print("[Review] loaded in \(Date().timeIntervalSince(t0))s, \(uncachedDays.count) recomputed")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Today screen

struct TodayView: View {
    @StateObject private var vm = TodayViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
            }
            .padding(16)
        }
        .background(AppColor.bg.ignoresSafeArea())
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let error = vm.error {
            EmptyStateCard(
                icon: "exclamationmark.triangle",
                title: "Couldn't load data",
                message: error,
                actionTitle: "Try again",
                action: { Task { await vm.load() } }
            )
        } else if let report = vm.report {
            switch report.rating {
            case .insufficientData:
                EmptyStateCard(
                    icon: "waveform.path.ecg",
                    title: "Not enough data yet today",
                    message: "Connect a CGM and check back later — we need a few hours of readings before we can evaluate your day."
                )
            case .insufficientHistory:
                EmptyStateCard(
                    icon: "calendar.badge.clock",
                    title: "Building your baseline",
                    message: "We need at least \(EvaluatorConfig.minBaselineDays) days of history before we can tell you what's typical for you. Keep your CGM on and we'll start showing insights soon."
                )
            case .negative, .positive, .typical:
                RatingCard(report: report)
                if let summary = Explainer.summary(for: report) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            CardTitle(text: "What's going on")
                            Text(summary)
                                .font(.system(size: 14))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                chartCard(report: report)
                if !report.topFactors.isEmpty {
                    ExpandableCard(title: "Top contributing factors") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(report.topFactors, id: \.metric) { f in
                                FactorRow(score: f)
                            }
                        }
                    }
                }
                ExpandableCard(title: "All metrics") {
                    MetricsTable(scores: report.allMetrics)
                }
            }
        } else {
            EmptyStateCard(
                icon: "heart.text.square",
                title: "Health permission needed",
                message: "Grant access to your blood glucose data in the Health app to start seeing your day evaluated.",
                actionTitle: "Open Health",
                action: openHealthApp
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today").font(.system(size: 28, weight: .semibold))
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.system(size: 13))
                .foregroundStyle(AppColor.muted)
        }
    }

    private func chartCard(report: DeviationReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle(text: "Glucose so far")
                    Spacer()
                    Text("as of \(timeString(report.elapsedMin))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.muted)
                }
                GlucoseChart(
                    readings: vm.todayReadings,
                    baseline: report.baselineAGP,
                    rating: report.rating,
                    elapsedMin: report.elapsedMin,
                    compact: false
                )
            }
        }
    }


    private func timeString(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func openHealthApp() {
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Review screen

struct ReviewView: View {
    @StateObject private var vm = ReviewViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    content
                }
                .padding(16)
            }
            .navigationTitle("Past 30 days")
            .background(AppColor.bg.ignoresSafeArea())
            .task { await vm.load() }
            .refreshable { await vm.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if let error = vm.error {
            EmptyStateCard(
                icon: "exclamationmark.triangle",
                title: "Couldn't load history",
                message: error,
                actionTitle: "Try again",
                action: { Task { await vm.load() } }
            )
        } else if vm.entries.isEmpty {
            EmptyStateCard(
                icon: "calendar",
                title: "No past days to show",
                message: "Once you've worn your CGM for a few days, this view will show how each day compared to your typical pattern."
            )
        } else {
            ForEach(vm.entries) { entry in
                NavigationLink {
                    DayDetailView(entry: entry)
                } label: {
                    ReviewRow(entry: entry)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ReviewRow: View {
    let entry: ReviewViewModel.Entry

    private var isInsufficient: Bool { entry.report.rating.isInsufficient }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 15, weight: .semibold))
                        if isInsufficient {
                            Text("not enough data")
                                .font(.system(size: 11))
                                .foregroundStyle(AppColor.muted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppColor.bg)
                                .clipShape(Capsule())
                        } else {
                            RatingBadge(rating: entry.report.rating)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(entry.date.formatted(.dateTime.weekday(.wide)))
                        .font(.system(size: 12))
                        .foregroundStyle(AppColor.muted)
                    if let phrase = entry.report.topFactors.first.flatMap(Explainer.phrase(for:)) {
                        Text(phrase)
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.muted)
                            .lineLimit(2)
                    }
                    else if entry.report.rating == .typical {
                        Text("Tracked close to your usual pattern.")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isInsufficient && !entry.readings.isEmpty {
                    GlucoseChart(
                        readings: entry.readings,
                        baseline: nil,
                        rating: entry.report.rating,
                        elapsedMin: 1440,
                        compact: true
                    )
                    .frame(width: 140, height: 60)
                }
            }
        }
    }
}

// MARK: - Day detail view

struct DayDetailView: View {
    let entry: ReviewViewModel.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let summary = Explainer.summary(for: entry.report) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            CardTitle(text: "What's going on")
                            Text(summary)
                                .font(.system(size: 14))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card {
                    GlucoseChart(
                        readings: entry.readings,
                        baseline: nil,
                        rating: entry.report.rating,
                        elapsedMin: 1440,
                        compact: false
                    )
                }
                if !entry.report.topFactors.isEmpty {
                    ExpandableCard(title: "Top contributing factors") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(entry.report.topFactors, id: \.metric) { f in
                                FactorRow(score: f)
                            }
                        }
                    }
                }
                ExpandableCard(title: "All metrics") {
                    MetricsTable(scores: entry.report.allMetrics)
                }
            }
            .padding(16)
        }
        .background(AppColor.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(entry.date.formatted(date: .complete, time: .omitted))
                    .font(.system(size: 20, weight: .semibold))
                if !entry.report.rating.isInsufficient {
                    RatingBadge(rating: entry.report.rating)
                }
            }
            Text("Evaluated against \(entry.report.nBaselineDays) prior days")
                .font(.system(size: 12))
                .foregroundStyle(AppColor.muted)
        }
    }
}

// MARK: - Shared sub-views

struct RatingCard: View {
    let report: DeviationReport

    var body: some View {
        Card {
            VStack(spacing: 6) {
                Text(report.rating.displayText)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(report.rating.color)
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private var detailText: String {
        switch report.rating {
        case .negative:
            return "At least one metric is significantly worse than typical."
        case .positive:
            return "At least one metric is significantly better than typical."
        case .typical:
            return "All metrics are within typical ranges."
        case .insufficientData, .insufficientHistory:
            return report.reason ?? ""
        }
    }
}

struct FactorRow: View {
    let score: MetricScore

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(score.label)
                .font(.system(size: 13, weight: .semibold))
            Text(detailText)
                .font(.system(size: 12))
                .foregroundStyle(AppColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailText: String {
        let direction = score.value > score.typical ? "higher" : "lower"
        let zStr = String(format: "%+.1f", score.rawZ)
        return "\(formatValue(score.value, unit: score.unit)) " +
               "(typical \(formatValue(score.typical, unit: score.unit)), " +
               "\(direction), z=\(zStr))"
    }
}

struct MetricsTable: View {
    let scores: [MetricScore]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Metric").frame(maxWidth: .infinity, alignment: .leading)
                Text("Today").frame(width: 64, alignment: .trailing)
                Text("Typical").frame(width: 64, alignment: .trailing)
                Text("z").frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .tracking(0.3)
            .foregroundStyle(AppColor.muted)
            .padding(.vertical, 6)

            Divider().background(AppColor.border)

            ForEach(scores, id: \.metric) { score in
                HStack(spacing: 4) {
                    Text(score.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Text(formatValue(score.value, unit: score.unit))
                        .frame(width: 64, alignment: .trailing)
                        .monospacedDigit()
                    Text(formatValue(score.typical, unit: score.unit))
                        .frame(width: 64, alignment: .trailing)
                        .foregroundStyle(AppColor.muted)
                        .monospacedDigit()
                    Text(String(format: "%+.1f", score.rawZ))
                        .frame(width: 44, alignment: .trailing)
                        .monospacedDigit()
                        .foregroundStyle(zColor(score))
                        .fontWeight(zColor(score) == AppColor.text ? .regular : .semibold)
                }
                .font(.system(size: 12))
                .padding(.vertical, 4)
                Divider().background(AppColor.border)
            }
        }
    }

    private func zColor(_ score: MetricScore) -> Color {
        if score.signedZ < -EvaluatorConfig.negativeZThreshold { return AppColor.negative }
        if score.signedZ > EvaluatorConfig.positiveZThreshold { return AppColor.positive }
        return AppColor.text
    }
}

// MARK: - Formatting helpers

func formatValue(_ value: Double, unit: String) -> String {
    let formatted: String
    if value.truncatingRemainder(dividingBy: 1) == 0 {
        formatted = String(format: "%.0f", value)
    } else {
        formatted = String(format: "%.1f", value)
    }
    return unit.isEmpty ? formatted : "\(formatted)\(unit)"
}

// MARK: - Root tab view

struct ContentView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "sun.max")
                }
            ReviewView()
                .tabItem {
                    Label("Review", systemImage: "calendar")
                }
        }
    }
}

/// A card containing a disclosure that hides detail content by default.
struct ExpandableCard<Content: View>: View {
    let title: String
    @State private var isExpanded = false
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $isExpanded) {
                content
                    .padding(.top, 10)
            } label: {
                CardTitle(text: title)
            }
            .tint(AppColor.muted)
            .accentColor(AppColor.muted)
        }
    }
}
