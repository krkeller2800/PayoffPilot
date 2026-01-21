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
        VStack(alignment: .leading, spacing: 8) {
            Text(symbol)
                .font(.headline)
            Text("Let’s imagine two simple endings at expiration:")
                .font(.caption)
//                .foregroundStyle(.secondary)
            Text("• Price rises to \(OptionsFormat.money(upPrice))")
                .font(.caption2)
//                .foregroundStyle(.secondary)
            Text("• Price falls to \(OptionsFormat.money(downPrice))")
                .font(.caption2)
//                .foregroundStyle(.secondary)
            Text("These are simplified walk‑throughs. No fees or early assignment considered.")
                .font(.caption2)
//                .foregroundStyle(.secondary)
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
        let direction = a.underlying >= centerPrice ? "If price rises to \(OptionsFormat.money(a.underlying))" : "If price falls to \(OptionsFormat.money(a.underlying))"
        let qualifier: String
        if a.totalPL > 0 && b.totalPL <= 0 { qualifier = " • likely profit" }
        else if a.totalPL < 0 && b.totalPL >= 0 { qualifier = " • likely loss" }
        else if a.totalPL > b.totalPL { qualifier = " • better outcome" }
        else if a.totalPL < b.totalPL { qualifier = " • worse outcome" }
        else { qualifier = "" }
        return direction + qualifier
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

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(result.legs.enumerated()), id: \.offset) { idx, leg in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(leg.title)
                                .font(.subheadline)
                            if let first = leg.narrativeLines.first {
                                Text(first)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if leg.narrativeLines.count > 1 {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(leg.narrativeLines.dropFirst()), id: \.self) { line in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("•")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                            Text(line)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
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

            let legTitle: String = {
                let sideText = (side == .long) ? "Long" : "Short"
                let typeText = (type == .call) ? "Call" : "Put"
                return "\(sideText) \(typeText) — strike \(OptionsFormat.number(K)), premium \(OptionsFormat.number(prem)), ×\(qty)"
            }()

            var lines: [String] = []
            // Opening: set the scene
            lines.append("If \(symbol) finishes around \(OptionsFormat.money(underlying)):")

            switch (side, type) {
            case (.long, .call):
                if intrinsicPerShare > 0 {
                    lines.append("Your right to buy at \(OptionsFormat.money(K)) would be worth about \(OptionsFormat.number(intrinsicPerShare)) per share.")
                } else {
                    lines.append("This call would likely expire worthless because the price is below \(OptionsFormat.money(K)).")
                }
                lines.append("You paid about \(OptionsFormat.number(prem)) per share for this option.")
            case (.long, .put):
                if intrinsicPerShare > 0 {
                    lines.append("Your right to sell at \(OptionsFormat.money(K)) would be worth about \(OptionsFormat.number(intrinsicPerShare)) per share.")
                } else {
                    lines.append("This put would likely expire worthless because the price is above \(OptionsFormat.money(K)).")
                }
                lines.append("You paid about \(OptionsFormat.number(prem)) per share for this option.")
            case (.short, .call):
                lines.append("You sold this call and collected about \(OptionsFormat.number(prem)) per share up front.")
                if intrinsicPerShare > 0 {
                    lines.append("At this price, the call would be worth about \(OptionsFormat.number(intrinsicPerShare)) per share to the buyer, so you’d give up value against what you collected.")
                } else {
                    lines.append("If the price stays below \(OptionsFormat.money(K)), the call likely expires worthless and you keep what you collected.")
                }
            case (.short, .put):
                lines.append("You sold this put and collected about \(OptionsFormat.number(prem)) per share up front.")
                if intrinsicPerShare > 0 {
                    lines.append("At this price, the put would be worth about \(OptionsFormat.number(intrinsicPerShare)) per share to the buyer, so you’d give up value against what you collected.")
                } else {
                    lines.append("If the price stays above \(OptionsFormat.money(K)), the put likely expires worthless and you keep what you collected.")
                }
            }

            let perShareWord = perSharePL >= 0 ? "ahead" : "behind"
            let perShareAbs = OptionsFormat.number(abs(perSharePL))
            let contractsWord = qty == 1 ? "contract" : "contracts"
            lines.append("After that, you’re \(perShareWord) by about \(perShareAbs) per share, which comes to \(OptionsFormat.money(legPL)) for \(qty) \(contractsWord) (\(Int(mult)) shares each).")

            return ScenarioLegBreakdown(
                title: legTitle,
                narrativeLines: lines,
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
    let narrativeLines: [String]
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
