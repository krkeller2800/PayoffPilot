import SwiftUI

struct ScenarioSheetView: View {
    let symbol: String
    let legs: [OptionLeg]
    let centerPrice: Double
    let upMovePct: Double
    let downMovePct: Double

    @Environment(\.dismiss) private var dismiss

    init(symbol: String, legs: [OptionLeg], centerPrice: Double, upMovePct: Double = 0.10, downMovePct: Double = 0.10) {
        self.symbol = symbol
        self.legs = legs
        self.centerPrice = max(0.01, centerPrice)
        self.upMovePct = max(0, upMovePct)
        self.downMovePct = max(0, downMovePct)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    scenariosContent
                }
                .padding()
            }
            .navigationTitle("Scenarios")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(symbol)
                .font(.headline)
            Text("Assumes underlying moves ±\(Int(upMovePct * 100))% from center price.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var analysis: MultiLegAnalysis { MultiLegAnalysis(legs: legs) }

    private var upPrice: Double { max(0, centerPrice * (1 + upMovePct)) }
    private var downPrice: Double { max(0, centerPrice * (1 - downMovePct)) }

    private var scenariosContent: some View {
        let up = scenarioResult(at: upPrice)
        let down = scenarioResult(at: downPrice)
        // Order scenarios by P/L to highlight money-making vs losing
        let first: ScenarioResult
        let second: ScenarioResult
        if up.totalPL >= down.totalPL {
            first = up; second = down
        } else {
            first = down; second = up
        }
        return VStack(alignment: .leading, spacing: 16) {
            scenarioSection(title: label(for: first, other: second), result: first)
            scenarioSection(title: label(for: second, other: first), result: second)
        }
    }

    private func label(for a: ScenarioResult, other b: ScenarioResult) -> String {
        if a.totalPL > 0 && b.totalPL <= 0 { return "Money-making scenario" }
        if a.totalPL <= 0 && b.totalPL > 0 { return "Money-losing scenario" }
        if a.totalPL > b.totalPL { return "More profitable scenario" }
        if a.totalPL < b.totalPL { return "Less profitable scenario" }
        return "Scenario"
    }

    private func scenarioSection(title: String, result: ScenarioResult) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Underlying @ ") + Text(OptionsFormat.money(result.underlying)).monospacedDigit()
                    Spacer()
                    let plText = OptionsFormat.money(result.totalPL)
                    Text(result.totalPL >= 0 ? "+" + plText.dropFirst() : plText)
                        .foregroundStyle(result.totalPL >= 0 ? Color.green : Color.red)
                        .monospacedDigit()
                        .font(.headline)
                }
                .accessibilityLabel("Total P and L \(result.totalPL >= 0 ? "profit" : "loss") \(OptionsFormat.money(abs(result.totalPL)))")

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.legs.enumerated()), id: \.offset) { idx, leg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(leg.title)
                                .font(.subheadline)
                            Text(leg.intrinsicExplanation)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(leg.perShareExplanation)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(leg.legPLExplanation)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if idx < result.legs.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }

                HStack {
                    Text("Total")
                    Spacer()
                    let plText = OptionsFormat.money(result.totalPL)
                    Text(result.totalPL >= 0 ? "+" + plText.dropFirst() : plText)
                        .foregroundStyle(result.totalPL >= 0 ? Color.green : Color.red)
                        .monospacedDigit()
                        .font(.subheadline)
                }
            }
        }
    }

    // MARK: - Scenario math
    private func scenarioResult(at underlying: Double) -> ScenarioResult {
        let legsBreakdown = legs.map { leg -> ScenarioLegBreakdown in
            let type = leg.type
            let side = leg.side
            let K = leg.strike
            let prem = leg.premium
            let qty = leg.contracts
            let mult = leg.multiplier

            let intrinsicPerShare: Double
            switch type {
            case .call: intrinsicPerShare = max(0, underlying - K)
            case .put:  intrinsicPerShare = max(0, K - underlying)
            }
            let rawPerShare = intrinsicPerShare - prem
            let perSharePL = (side == .long) ? rawPerShare : -rawPerShare
            let legPL = perSharePL * Double(qty) * mult

            let legTitle = "\(side == .long ? "Long" : "Short") \(type == .call ? "Call" : "Put")  K=\(OptionsFormat.number(K))  Prem=\(OptionsFormat.number(prem))  ×\(qty)"

            let intrinsicExpl = {
                switch type {
                case .call:
                    return "Intrinsic = max(0, S − K) = max(0, \(OptionsFormat.number(underlying)) − \(OptionsFormat.number(K))) = \(OptionsFormat.number(intrinsicPerShare))"
                case .put:
                    return "Intrinsic = max(0, K − S) = max(0, \(OptionsFormat.number(K)) − \(OptionsFormat.number(underlying))) = \(OptionsFormat.number(intrinsicPerShare))"
                }
            }()

            let perShareExpl = {
                let base = "Per‑share P/L = Intrinsic − Premium = \(OptionsFormat.number(intrinsicPerShare)) − \(OptionsFormat.number(prem)) = \(OptionsFormat.number(rawPerShare))"
                return (side == .long) ? base : "Short flips sign: −(\(OptionsFormat.number(rawPerShare))) = \(OptionsFormat.number(perSharePL))"
            }()

            let legPLExpl = "Leg P/L = per‑share × contracts × 100 = \(OptionsFormat.number(perSharePL)) × \(qty) × \(Int(mult)) = \(OptionsFormat.money(legPL))"

            return ScenarioLegBreakdown(
                title: legTitle,
                intrinsicExplanation: intrinsicExpl,
                perShareExplanation: perShareExpl,
                legPLExplanation: legPLExpl,
                legPL: legPL
            )
        }
        let total = legsBreakdown.reduce(0) { $0 + $1.legPL }
        return ScenarioResult(underlying: underlying, legs: legsBreakdown, totalPL: total)
    }
}

private struct ScenarioResult {
    let underlying: Double
    let legs: [ScenarioLegBreakdown]
    let totalPL: Double
}

private struct ScenarioLegBreakdown {
    let title: String
    let intrinsicExplanation: String
    let perShareExplanation: String
    let legPLExplanation: String
    let legPL: Double
}

// MARK: - Convenience mapping for a single SavedOrder
extension ScenarioSheetView {
    init?(order: SavedOrder, underlyingCenter: Double?, marketMid: Double?) {
        // Determine premium to use: fillPrice, else limit, else marketMid
        let premium: Double? = order.fillPrice ?? order.limit ?? marketMid
        guard let premium = premium else { return nil }
        let contracts = order.fillQuantity ?? order.quantity
        let type: OptionType = (order.right == .call) ? .call : .put
        let side: OptionSide = (order.side == .buy) ? .long : .short
        let leg = OptionLeg(type: type, side: side, strike: order.strike, premium: premium, contracts: max(1, contracts), multiplier: 100)
        let center = underlyingCenter ?? order.strike
        self.init(symbol: order.symbol, legs: [leg], centerPrice: center)
    }
}

#Preview("Scenario Sheet (single leg)") {
    let leg = OptionLeg(type: .call, side: .long, strike: 180, premium: 2.50, contracts: 1, multiplier: 100)
    ScenarioSheetView(symbol: "AAPL", legs: [leg], centerPrice: 185)
}
