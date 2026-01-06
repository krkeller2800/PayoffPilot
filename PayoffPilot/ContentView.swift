//
//  ContentView.swift
//  PayoffPilot
//
//  Created by Karl Keller on 12/30/25.
//
import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#endif
import Foundation

@MainActor
struct ContentView: View {
    private enum Strategy: String, CaseIterable, Identifiable {
        case singleCall = "Call"
        case singlePut = "Put"
        case bullCallSpread = "Bull Call Spread"
        var id: String { rawValue }
        var isSingle: Bool { self == .singleCall || self == .singlePut }
    }

    @State private var strategy: Strategy = .singleCall
    // Inputs (MVP: manual)
    @State private var strikeText: String = "100"
    @State private var premiumText: String = "2.50"
    @State private var shortCallStrikeText: String = "110"
    @State private var shortCallPremiumText: String = "1.00"
    @State private var underlyingNowText: String = "100"
    @State private var contracts: Int = 1

    // What-if: shift the center of the payoff range / show an “expiry spot” marker
    @State private var expirySpot: Double = 100

    @State private var symbolText: String = "AAPL"
    @State private var isFetching: Bool = false
    @State private var fetchError: String?
    @State private var expirations: [Date] = []
    @State private var selectedExpiration: Date?
    @State private var callStrikes: [Double] = []
    @State private var putStrikes: [Double] = []
    @State private var selectedCallStrike: Double?
    @State private var selectedPutStrike: Double?
    @State private var lastRefresh: Date?
    @State private var showSettings: Bool = false
    @State private var symbolLookupTask: Task<Void, Never>? = nil
    @State private var showWhatIfSheet: Bool = false
    
    @AppStorage("lastEnabledProvider") private var lastEnabledProviderRaw: String = ""
    @AppStorage("tradierEnvironment") private var tradierEnvironmentRaw: String = "production"
    @State private var appQuoteService: QuoteService = QuoteService()

    private let multiplier: Double = 100

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    inputsCard
                    educationCard
                }
                .padding()
            }
            .navigationTitle("PayoffPilot")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .onAppear {
            // Initialize expirySpot from underlying input
            expirySpot = underlyingNow
            Task { await lookupSymbol() }
            
            // Configure app-level provider if a last-enabled provider is persisted
            if let provider = SettingsViewModel.BYOProvider(rawValue: lastEnabledProviderRaw) {
                switch provider {
                case .tradier:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradierToken) {
                        let env: TradierProvider.Environment = (tradierEnvironmentRaw == "sandbox") ? .sandbox : .production
                        appQuoteService = QuoteService(provider: TradierProvider(token: token, environment: env))
                    }
                case .finnhub:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.finnhubToken) {
                        appQuoteService = QuoteService(provider: FinnhubProvider(token: token))
                    }
                case .polygon:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.polygonToken) {
                        appQuoteService = QuoteService(provider: PolygonProvider(token: token))
                    }
                case .tradestation:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradestationToken) {
                        appQuoteService = QuoteService(provider: TradeStationProvider(token: token))
                    }
                }
            } else {
                appQuoteService = QuoteService() // default (Yahoo/Stooq)
            }
        }
        .onChange(of: symbolText) { _, _ in
            // Debounce rapid typing; update underlying and chain shortly after edits
            symbolLookupTask?.cancel()
            symbolLookupTask = Task { [symbolText] in
                try? await Task.sleep(nanoseconds: 350_000_000) // ~0.35s debounce
                let trimmed = symbolText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                await lookupSymbol()
            }
        }
        .onChange(of: lastEnabledProviderRaw) { _, newValue in
            if let provider = SettingsViewModel.BYOProvider(rawValue: newValue) {
                switch provider {
                case .tradier:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradierToken) {
                        let env: TradierProvider.Environment = (tradierEnvironmentRaw == "sandbox") ? .sandbox : .production
                        appQuoteService = QuoteService(provider: TradierProvider(token: token, environment: env))
                    }
                case .finnhub:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.finnhubToken) {
                        appQuoteService = QuoteService(provider: FinnhubProvider(token: token))
                    }
                case .polygon:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.polygonToken) {
                        appQuoteService = QuoteService(provider: PolygonProvider(token: token))
                    }
                case .tradestation:
                    if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradestationToken) {
                        appQuoteService = QuoteService(provider: TradeStationProvider(token: token))
                    }
                }
            } else {
                appQuoteService = QuoteService()
            }
        }
        .onChange(of: tradierEnvironmentRaw) { _, _ in
            // If Tradier is the active provider, rebuild the QuoteService with the new environment
            guard let provider = SettingsViewModel.BYOProvider(rawValue: lastEnabledProviderRaw), provider == .tradier else { return }
            if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradierToken) {
                let env: TradierProvider.Environment = (tradierEnvironmentRaw == "sandbox") ? .sandbox : .production
                appQuoteService = QuoteService(provider: TradierProvider(token: token, environment: env))
            }
        }
        .onChange(of: underlyingNowText) { _, _ in
            // Keep slider roughly aligned if user edits underlying
            expirySpot = underlyingNow
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Derived values

    private var strike: Double { Double(strikeText) ?? 0 }
    private var premium: Double { Double(premiumText) ?? 0 }
    private var underlyingNow: Double { Double(underlyingNowText) ?? 0 }

    private var lowerStrike: Double { Double(strikeText) ?? 0 }
    private var lowerPremium: Double { Double(premiumText) ?? 0 }
    private var upperStrike: Double { Double(shortCallStrikeText) ?? 0 }
    private var upperPremium: Double { Double(shortCallPremiumText) ?? 0 }

    private var legs: [OptionLeg] {
        switch strategy {
        case .singleCall:
            return [
                OptionLeg(
                    type: .call,
                    side: .long,
                    strike: max(0, lowerStrike),
                    premium: max(0, lowerPremium),
                    contracts: max(1, contracts),
                    multiplier: multiplier
                )
            ]
        case .singlePut:
            return [
                OptionLeg(
                    type: .put,
                    side: .long,
                    strike: max(0, lowerStrike),
                    premium: max(0, lowerPremium),
                    contracts: max(1, contracts),
                    multiplier: multiplier
                )
            ]
        case .bullCallSpread:
            return [
                OptionLeg(
                    type: .call,
                    side: .long,
                    strike: max(0, lowerStrike),
                    premium: max(0, lowerPremium),
                    contracts: max(1, contracts),
                    multiplier: multiplier
                ),
                OptionLeg(
                    type: .call,
                    side: .short,
                    strike: max(0, upperStrike),
                    premium: max(0, upperPremium),
                    contracts: max(1, contracts),
                    multiplier: multiplier
                )
            ]
        }
    }

    private var multiAnalysis: MultiLegAnalysis {
        MultiLegAnalysis(legs: legs)
    }

    private var curve: [PayoffPoint] {
        multiAnalysis.payoffCurve(center: max(0.01, expirySpot), widthFactor: 0.6, steps: 90)
    }

    private var metrics: (maxLoss: Double, maxGain: Double?, breakeven: Double?) {
        multiAnalysis.metrics(center: max(0.01, expirySpot))
    }

    private var dataSourceLabel: String {
        if let provider = SettingsViewModel.BYOProvider(rawValue: lastEnabledProviderRaw) {
            switch provider {
            case .tradier:
                let envSuffix = (tradierEnvironmentRaw == "sandbox") ? " (Sandbox)" : ""
                return "Data via Tradier\(envSuffix)"
            case .finnhub:
                return "Data via Finnhub"
            case .polygon:
                return "Data via Polygon"
            case .tradestation:
                return "Data via TradeStation"
            }
        } else {
            // Default provider (Yahoo/Stooq) is delayed
            return "Delayed data via Yahoo"
        }
    }

    // MARK: - UI

    private var inputsCard: some View {
        GroupBox("Inputs") {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        labeledTextField("Symbol", text: $symbolText)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)
                        Button {
                            Task { await lookupSymbol() }
                        } label: {
                            if isFetching { ProgressView() } else { Text("Lookup") }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let fetchError {
                        Text(fetchError)
                            .font(.caption)
                            .foregroundStyle(fetchError.contains("Option chain") ? Color(red: 0.85, green: 0.65, blue: 0.0) : Color.red)
                    }
                }

                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("\(dataSourceLabel) • \(lastRefresh.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")")
                    }
                    .font(.caption2)
                    .padding(6)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    Spacer(minLength: 0)
                }

                Picker("Strategy", selection: $strategy) {
                    ForEach(Strategy.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                if strategy.isSingle {
                    HStack(spacing: 12) {
                        labeledTextField("Strike", text: $strikeText, keyboardType: PPKeyboardType.decimalPad)
                        labeledTextField("Premium", text: $premiumText, keyboardType: PPKeyboardType.decimalPad)
                    }
                } else {
                    // Bull Call Spread inputs
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Long Call (Lower Strike)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            labeledTextField("Lower Strike", text: $strikeText, keyboardType: PPKeyboardType.decimalPad)
                            labeledTextField("Premium Paid", text: $premiumText, keyboardType: PPKeyboardType.decimalPad)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Short Call (Upper Strike)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            labeledTextField("Upper Strike", text: $shortCallStrikeText, keyboardType: PPKeyboardType.decimalPad)
                            labeledTextField("Premium Received", text: $shortCallPremiumText, keyboardType: PPKeyboardType.decimalPad)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Option Chain (delayed)")
                        .font(.subheadline)
                    HStack(spacing: 12) {
                        // Expiration picker
                        Picker("Expiration", selection: $selectedExpiration) {
                            ForEach(expirations, id: \.self) { d in
                                Text(d.formatted(date: .abbreviated, time: .omitted)).tag(Optional(d))
                            }
                        }
                        .onChange(of: selectedExpiration) { _, _ in
                            Task { await refetchForExpiration() }
                        }
                        .frame(maxWidth: .infinity)

                        // Strike picker(s)
                        if strategy == .singleCall {
                            Picker("Call Strike", selection: $selectedCallStrike) {
                                ForEach(callStrikes, id: \.self) { s in
                                    Text(OptionsFormat.number(s)).tag(Optional(s))
                                }
                            }
                            .onChange(of: selectedCallStrike) { _, new in
                                if let s = new { strikeText = OptionsFormat.number(s) }
                            }
                        } else if strategy == .singlePut {
                            Picker("Put Strike", selection: $selectedPutStrike) {
                                ForEach(putStrikes, id: \.self) { s in
                                    Text(OptionsFormat.number(s)).tag(Optional(s))
                                }
                            }
                            .onChange(of: selectedPutStrike) { _, new in
                                if let s = new { strikeText = OptionsFormat.number(s) }
                            }
                        } else {
                            // Bull Call Spread: choose lower and upper call strikes
                            Picker("Lower Call", selection: $selectedCallStrike) {
                                ForEach(callStrikes, id: \.self) { s in
                                    Text(OptionsFormat.number(s)).tag(Optional(s))
                                }
                            }
                            .onChange(of: selectedCallStrike) { _, new in
                                if let s = new { strikeText = OptionsFormat.number(s) }
                            }

                            Picker("Upper Call", selection: $selectedPutStrike) {
                                ForEach(callStrikes, id: \.self) { s in
                                    Text(OptionsFormat.number(s)).tag(Optional(s))
                                }
                            }
                            .onChange(of: selectedPutStrike) { _, new in
                                if let s = new { shortCallStrikeText = OptionsFormat.number(s) }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    labeledTextField("Market Price", text: $underlyingNowText, keyboardType: PPKeyboardType.decimalPad)

                    Button {
                        Task {
                            await MainActor.run { isFetching = true }
                            do {
                                let price = try await appQuoteService.fetchDelayedPrice(symbol: symbolText)
                                await MainActor.run {
                                    underlyingNowText = OptionsFormat.number(price)
                                    expirySpot = price
                                    lastRefresh = Date()
                                    isFetching = false
                                }
                            } catch {
                                await MainActor.run {
                                    fetchError = (error as? LocalizedError)?.errorDescription ?? "Price refresh failed."
                                    isFetching = false
                                }
                            }
                        }
                    } label: {
                        if isFetching { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.bordered)

                    Stepper(value: $contracts, in: 1...50) {
                        VStack(alignment: .center, spacing: 2) {
                            Text("Contracts:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text("\(contracts)")
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Button {
                    showWhatIfSheet = true
                } label: {
                    Label("What-If: Market Price at Expiration", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .sheet(isPresented: $showWhatIfSheet) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("What-If: Market Price at Expiration")
                                    .font(.headline)
                                Spacer()
                                Button("Done") { showWhatIfSheet = false }
                                    .buttonStyle(.borderedProminent)
                            }

                            Slider(
                                value: $expirySpot,
                                in: max(0, underlyingNow * 0.2)...max(underlyingNow * 2.0, underlyingNow + 1),
                                step: 0.5
                            )

                            Text("Price at Expiration: \(OptionsFormat.number(expirySpot))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            // Results and Payoff Curve moved into the sheet
                            resultsCard
                            chartCard
                        }
                        .padding()
                    }
                    .presentationDetents([.large])
                }

                Text("Premiums are manual; quotes are delayed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resultsCard: some View {
        GroupBox("Results (at Expiration)") {
            VStack(spacing: 10) {
                HStack {
                    metricTile(title: "Max Loss", value: OptionsFormat.money(metrics.maxLoss))
                    metricTile(title: "Breakeven", value: metrics.breakeven.map(OptionsFormat.money) ?? "—")
                    metricTile(title: "Max Gain", value: maxGainText)
                    metricTile(title: netPremiumLabel, value: OptionsFormat.money(multiAnalysis.totalDebit))
                }

                Divider()

                let pl = multiAnalysis.profitLoss(at: expirySpot)
                HStack {
                    Text("P/L at \(OptionsFormat.number(expirySpot)):")
                        .font(.subheadline)
                    Spacer()
                    Text(OptionsFormat.money(pl))
                        .font(.subheadline.weight(.semibold))
                }

                Text("Net Premium is the sum of premiums paid and received for all legs. Positive = cash paid to open; negative = cash received to open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartCard: some View {
        GroupBox("Payoff Curve") {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(curve) { p in
                        LineMark(
                            x: .value("Market Price", p.underlying),
                            y: .value("P/L", p.profitLoss)
                        )
                    }

                    // Zero line
                    RuleMark(y: .value("Break-even", 0))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // Strike line(s)
                    if strategy.isSingle {
                        if let first = legs.first {
                            RuleMark(x: .value("Strike", first.strike))
                                .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    } else {
                        RuleMark(x: .value("Lower Strike", lowerStrike))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        RuleMark(x: .value("Upper Strike", upperStrike))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }

                    // Marker for selected expiry spot
                    PointMark(
                        x: .value("Expiry Spot", expirySpot),
                        y: .value("P/L", multiAnalysis.profitLoss(at: expirySpot))
                    )
                }
                .frame(height: 260)

                Text("Tip: This is payoff at expiration only (ignores IV changes, time value, early assignment, and bid/ask spreads).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var educationCard: some View {
        GroupBox {
            DisclosureGroup("Education") {
                VStack(alignment: .leading, spacing: 8) {
                    if strategy == .bullCallSpread {
                        Text("• Bull Call Spread = Buy lower-strike call, sell higher-strike call.")
                        Text("• Max loss = net debit paid.")
                        Text("• Max gain = spread width − net debit.")
                        Text("• Breakeven ≈ lower strike + net debit.")
                    } else {
                        Text("• Max loss is the premium you pay (debit).")
                        Text(strategy == .singleCall
                             ? "• Call breakeven = strike + premium."
                             : "• Put breakeven = strike − premium.")
                        Text("• The chart helps you plan outcomes across different prices at expiration.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func clearOptionInputsForUnavailableChain() {
        expirations = []
        selectedExpiration = nil
        callStrikes = []
        putStrikes = []
        selectedCallStrike = nil
        selectedPutStrike = nil
        strikeText = ""
        premiumText = ""
        shortCallStrikeText = ""
        shortCallPremiumText = ""
    }

    private func lookupSymbol() async {
        await MainActor.run { isFetching = true; fetchError = nil }

        // 1) Fetch price first so underlying is shown even if chain fails
        do {
            let price = try await appQuoteService.fetchDelayedPrice(symbol: symbolText)
            await MainActor.run {
                underlyingNowText = OptionsFormat.number(price)
                expirySpot = price
                lastRefresh = Date()
            }
        } catch {
            await MainActor.run {
                fetchError = (error as? LocalizedError)?.errorDescription ?? "Price refresh failed."
            }
        }

        // 2) Best-effort fetch for option chain (may be unavailable)
        do {
            let chain = try await appQuoteService.fetchOptionChain(symbol: symbolText, expiration: selectedExpiration)
            await MainActor.run {
                expirations = chain.expirations
                callStrikes = chain.callStrikes
                putStrikes = chain.putStrikes
                // If we don't have a selected expiration yet, choose the nearest
                if selectedExpiration == nil { selectedExpiration = expirations.first }
            }
        } catch {
            await MainActor.run {
                if case QuoteService.QuoteError.unauthorized = error {
                    clearOptionInputsForUnavailableChain()
                }
                if fetchError == nil {
                    fetchError = (error as? LocalizedError)?.errorDescription ?? "Chain fetch failed."
                }
            }
        }

        await MainActor.run { isFetching = false }
    }

    private func refetchForExpiration() async {
        await MainActor.run { isFetching = true; fetchError = nil }
        do {
            let chain = try await appQuoteService.fetchOptionChain(symbol: symbolText, expiration: selectedExpiration)
            await MainActor.run {
                callStrikes = chain.callStrikes
                putStrikes = chain.putStrikes
                lastRefresh = Date()
                isFetching = false
            }
        } catch {
            await MainActor.run {
                isFetching = false
                if case QuoteService.QuoteError.unauthorized = error {
                    clearOptionInputsForUnavailableChain()
                }
                fetchError = (error as? LocalizedError)?.errorDescription ?? "Chain fetch failed."
            }
        }
    }

    private var maxGainText: String {
        if let mg = metrics.maxGain {
            return OptionsFormat.money(mg)
        }
        return "Unlimited"
    }

    private var netPremiumLabel: String {
        let v = multiAnalysis.totalDebit
        if v > 0 { return "Net Premium (Debit)" }
        if v < 0 { return "Net Premium (Credit)" }
        return "Net Premium (Even)"
    }

    private enum PPKeyboardType {
        case `default`
        case decimalPad
    }

    private func labeledTextField(_ label: String, text: Binding<String>, keyboardType: PPKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Determine placeholder: for numeric fields, show "0.00"; otherwise reuse label
            let placeholder = (keyboardType == .decimalPad) ? "0.00" : label
            // Base TextField with placeholder
            let field = TextField(placeholder, text: text)
            // Apply platform-specific modifiers
            #if canImport(UIKit)
            let configured = field.keyboardType(keyboardType == .decimalPad ? .decimalPad : .default)
                .textFieldStyle(.roundedBorder)
            #else
            let configured = field
            #endif
            configured
        }
        .frame(maxWidth: .infinity)
    }

    private func metricTile(title: String, value: String) -> some View {
        // Ensure the title's last line aligns across tiles by reserving space for up to 2 lines
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView()
}

