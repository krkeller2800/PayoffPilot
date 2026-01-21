import SwiftUI
import Foundation
import Charts

struct SavedStrategiesView: View {
    @State private var strategies: [SavedStrategy] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if strategies.isEmpty {
                    Text("No saved strategies")
                        .foregroundColor(.secondary)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List {
                        ForEach(strategies) { strategy in
                            NavigationLink {
                                SavedStrategyDetailView(saved: strategy)
                            } label: {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(strategy.symbol)
                                            .font(.headline)
                                        Spacer()
                                        Text(Self.displayName(for: strategy.kind))
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(strategy.expiration.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(Self.createdAtFormatter.string(from: strategy.createdAt))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Saved Strategies")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                strategies = StrategyStore.shared.load()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let id = strategies[index].id
            StrategyStore.shared.remove(id: id)
        }
        strategies.remove(atOffsets: offsets)
    }

    private static func displayName(for kind: SavedStrategy.Kind) -> String {
        switch kind {
        case .singleCall: return "Single Call"
        case .singlePut: return "Single Put"
        case .bullCallSpread: return "Bull Call Spread"
        case .bullPutSpread: return "Bull Put Spread"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        return df
    }()

    private static let createdAtFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()
}

@MainActor
struct SavedStrategyDetailView: View {
    let saved: SavedStrategy
    @State private var showScenarioSheet = false

    private var legs: [OptionLeg] {
        saved.legs.map { leg in
            OptionLeg(
                type: leg.type.lowercased() == "call" ? .call : .put,
                side: leg.side.lowercased() == "long" ? .long : .short,
                strike: leg.strike,
                premium: leg.premium,
                contracts: leg.contracts,
                multiplier: leg.multiplier
            )
        }
    }

    private var analysis: MultiLegAnalysis { MultiLegAnalysis(legs: legs) }

    private var curve: [PayoffPoint] {
        let center = max(0.01, (saved.marketPriceAtSave ?? legs.map { $0.strike }.sorted().first ?? 100))
        return analysis.payoffCurve(center: center, widthFactor: 0.6, steps: 90)
    }

    private var metrics: (maxLoss: Double, maxGain: Double?, breakeven: Double?) {
        let center = max(0.01, (saved.marketPriceAtSave ?? legs.map { $0.strike }.sorted().first ?? 100))
        return analysis.metrics(center: center)
    }

    private var netPremiumValueText: String {
        let v = analysis.totalDebit
        let absMoney = OptionsFormat.money(abs(v))
        if v > 0 { return "-" + absMoney } // debit shown as negative
        if v < 0 { return "+" + absMoney } // credit shown as positive
        return absMoney
    }

    private var netPremiumColor: Color {
        let v = analysis.totalDebit
        if v > 0 { return .red }
        if v < 0 { return .green }
        return .primary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Overview") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("\(saved.symbol)")
                                .font(.subheadline)
                            Text(kindText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let exp = saved.expiration {
                                Text("• Expires \(exp.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                    }
                }

                GroupBox("Results (at Expiration)") {
                    VStack(spacing: 8) {
                        HStack {
                            metricTile(title: "Max Loss", value: OptionsFormat.money(metrics.maxLoss))
                            metricTile(title: "Breakeven", value: metrics.breakeven.map(OptionsFormat.money) ?? "—")
                            metricTile(title: "Max Gain", value: metrics.maxGain.map(OptionsFormat.money) ?? "Unlimited")
                            metricTile(title: "Net Premium", value: netPremiumValueText, valueColor: netPremiumColor)
                        }
                    }
                }

                GroupBox("Payoff Curve") {
                    Chart(curve) { pt in
                        LineMark(
                            x: .value("Underlying", pt.underlying),
                            y: .value("P/L", pt.profitLoss)
                        )
                    }
                    .frame(height: 240)
                    .overlay(
                        Chart {
                            RuleMark(y: .value("Zero", 0))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(.secondary)
                        }
                    )
                }

                GroupBox("Legs") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(legs.enumerated()), id: \.offset) { idx, leg in
                            HStack {
                                Text(leg.side == .long ? "Long" : "Short")
                                Text(leg.type == .call ? "Call" : "Put")
                                Text("K=\(OptionsFormat.number(leg.strike))")
                                Text("Prem=\(OptionsFormat.number(leg.premium))")
                                Text("× \(leg.contracts)")
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Strategy")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScenarioSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .imageScale(.small)
                        Text("Scenarios")
                    }
                }
                .accessibilityLabel("Scenario Analysis")
                .help("Open scenario analysis")
            }
        }
        .sheet(isPresented: $showScenarioSheet) {
            let center = max(0.01, (saved.marketPriceAtSave ?? legs.map { $0.strike }.sorted().first ?? 100))
            ScenarioSheetView(symbol: saved.symbol, legs: legs, centerPrice: center)
                .presentationDetents([.large, .large])
        }
    }

    private var kindText: String {
        switch saved.kind {
        case .singleCall: return "Call"
        case .singlePut: return "Put"
        case .bullCallSpread: return "Bull Call Spread"
        case .bullPutSpread: return "Bull Put Spread"
        }
    }

    private func metricTile(title: String, value: String, valueColor: Color? = nil) -> some View {
        #if canImport(UIKit)
        let headerMinHeight = UIFont.preferredFont(forTextStyle: .caption1).lineHeight * 2
        #else
        let headerMinHeight: CGFloat = 28
        #endif

        return VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: headerMinHeight, alignment: .bottomLeading)

            Text(value)
                .font(.caption2)
                .foregroundStyle(valueColor ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    NavigationStack {
        SavedStrategiesView()
    }
}

