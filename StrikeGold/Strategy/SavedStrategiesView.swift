//
//  SavedStrategiesView.swift
//  StrikeGold
//
//  Created by Assistant on 1/8/26.
//
import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#endif

struct SavedStrategiesView: View {
    @State private var strategies: [SavedStrategy] = []

    var body: some View {
        List {
            if strategies.isEmpty {
                Section {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No saved strategies yet")
                            .font(.headline)
                        Text("Pull to refresh or tap the tray icon in the main screen to save your current setup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                }
            }
            ForEach(strategies) { s in
                NavigationLink(destination: SavedStrategyDetailView(saved: s)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(for: s))
                                .font(.headline)
                            Text(subtitle(for: s))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let exp = s.expiration {
                            Text(exp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(id: s.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .refreshable { reload() }
        .navigationTitle("Saved")
        .task {
            if strategies.isEmpty {
                reload()
            }
        }
    }

    private func reload() {
        strategies = StrategyStore.shared.load().sorted(by: { $0.createdAt > $1.createdAt })
    }

    private func delete(id: UUID) {
        StrategyStore.shared.remove(id: id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000) // ~0.08s to avoid racing navigation transitions
            reload()
        }
    }

    private func title(for s: SavedStrategy) -> String {
        let kind: String
        switch s.kind {
        case .singleCall: kind = "Call"
        case .singlePut: kind = "Put"
        case .bullCallSpread: kind = "Bull Call Spread"
        }
        return "\(s.symbol) • \(kind)"
    }

    private func subtitle(for s: SavedStrategy) -> String {
        var parts: [String] = []
        if let first = s.legs.first {
            parts.append("K=\(OptionsFormat.number(first.strike))")
        }
        if s.kind == .bullCallSpread, s.legs.count >= 2 {
            let upper = s.legs[1]
            parts.append("K2=\(OptionsFormat.number(upper.strike))")
        }
        parts.append("Saved \(s.createdAt.formatted(date: .abbreviated, time: .shortened))")
        return parts.joined(separator: " • ")
    }
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
                        Text("\(saved.symbol)")
                            .font(.headline)
                        HStack(spacing: 8) {
                            Text(kindText)
                            if let exp = saved.expiration {
                                Text("• Expires \(exp.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                    Label("Scenarios", systemImage: "lightbulb")
                }
            }
        }
        .sheet(isPresented: $showScenarioSheet) {
            let center = max(0.01, (saved.marketPriceAtSave ?? legs.map { $0.strike }.sorted().first ?? 100))
            ScenarioSheetView(symbol: saved.symbol, legs: legs, centerPrice: center)
                .presentationDetents([.medium, .large])
        }
    }

    private var kindText: String {
        switch saved.kind {
        case .singleCall: return "Call"
        case .singlePut: return "Put"
        case .bullCallSpread: return "Bull Call Spread"
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

