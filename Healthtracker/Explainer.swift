import Foundation

enum Explainer {
    static func summary(for report: DeviationReport) -> String? {
        switch report.rating {
        case .insufficientData, .insufficientHistory:
            return nil

        case .typical:
            return "Today is tracking close to your usual pattern. " +
                   "Nothing about your glucose stands out from your last few weeks."

        case .negative, .positive:
            let factorSentences = report.topFactors.prefix(2).compactMap {
                phrase(for: $0)
            }
            let opening = (report.rating == .negative)
                ? "Today is running rougher than your typical day."
                : "Today is running better than your typical day."

            if factorSentences.isEmpty {
                return opening
            }
            return opening + " " + factorSentences.joined(separator: " ")
        }
    }

    static func phrase(for factor: MetricScore) -> String? {
        let isHigh = factor.value > factor.typical
        let label = factor.metric  // matches the keys used by the evaluator

        switch (label, isHigh) {
        case ("mean", true):
            return "Your average glucose has been higher than usual."
        case ("mean", false):
            return "Your average glucose has been lower than usual."

        case ("tir_70_180", true):
            return "You've been in range much more than usual."
        case ("tir_70_180", false):
            return "You've spent less time in range than usual."

        case ("cv", true):
            return "Your glucose has been swinging more than usual."
        case ("cv", false):
            return "Your glucose has been steadier than usual."

        case ("mage", true):
            return "Your glucose excursions have been larger than usual."
        case ("mage", false):
            return "Your glucose has had fewer large swings than usual."

        case ("lbgi", true):
            return "Your low-glucose risk has been elevated today."
        case ("lbgi", false):
            return "Your low-glucose risk has been lower than usual."

        case ("hbgi", true):
            return "Your hyperglycemia risk has been elevated today."
        case ("hbgi", false):
            return "Your hyperglycemia risk has been lower than usual."

        case ("hypo_events", true):
            let n = Int(factor.value)
            return "You've had \(n) low-glucose episode\(n == 1 ? "" : "s") today, more than typical."
        case ("hypo_events", false):
            return "You've had fewer low-glucose episodes than usual."

        case ("hyper_events", true):
            let n = Int(factor.value)
            return "You've had \(n) high-glucose episode\(n == 1 ? "" : "s") today, more than typical."
        case ("hyper_events", false):
            return "You've had fewer high-glucose episodes than usual."

        case ("max_excursion", true):
            return "Your biggest glucose spike today was larger than your usual peak."
        case ("max_excursion", false):
            return "Your biggest glucose spike today was smaller than usual."

        case ("overnight_cv", true):
            return "Your overnight glucose was more volatile than your usual sleep."
        case ("overnight_cv", false):
            return "Your overnight glucose was more stable than usual."

        case ("dawn_rise", true):
            return "Your morning rise was steeper than your usual dawn pattern."
        case ("dawn_rise", false):
            return "Your morning rise was gentler than usual."

        case ("agp_deviation", true):
            return "Your hour-by-hour pattern today diverged from your typical shape."
        case ("agp_deviation", false):
            return "Your hour-by-hour pattern today closely matched your typical shape."

        case ("breakfast_mean", true):
            return "Your breakfast period ran higher than usual."
        case ("breakfast_mean", false):
            return "Your breakfast period ran lower than usual."

        case ("lunch_mean", true):
            return "Your lunch period ran higher than usual."
        case ("lunch_mean", false):
            return "Your lunch period ran lower than usual."

        case ("afternoon_mean", true):
            return "Your afternoon ran higher than usual."
        case ("afternoon_mean", false):
            return "Your afternoon ran lower than usual."

        case ("dinner_mean", true):
            return "Your dinner period ran higher than usual."
        case ("dinner_mean", false):
            return "Your dinner period ran lower than usual."

        default:
            return nil
        }
    }
}
