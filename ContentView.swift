//
//  ContentView.swift
//  StrikeGold
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
    // MARK: - Saving Models
    struct SavedStrategy: Identifiable, Codable, Hashable {
        enum Kind: String, Codable {
            case singleCall, singlePut, bullCallSpread
        }
        struct SavedLeg: Codable, Hashable {
            var type: String // "call" or "put"
            var side: String // "long" or "short"
            var strike: Double
            var premium: Double
            var contracts: Int
            var multiplier: Double
        }
        var id: UUID = UUID()
        var createdAt: Date = Date()
        var kind: Kind
        var symbol: String
        var expiration: Date?
        var legs: [SavedLeg]
        var marketPriceAtSave: Double?
        var note: String?
    }

    final class StrategyStore {
        static let shared = StrategyStore()
        private let key = "saved_strategies_v1"
        func load() -> [SavedStrategy] {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SavedStrategy].self, from: data)) ?? []
        }
        func save(_ strategies: [SavedStrategy]) {
            if let data = try? JSONEncoder().encode(strategies) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        func append(_ strategy: SavedStrategy) {
            var all = load()
            all.append(strategy)
            save(all)
        }
        func remove(id: UUID) {
            var all = load()
            all.removeAll { $0.id == id }
            save(all)
        }
    }

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
    @State private var shortCallStrikeText: String = ""
    @State private var shortCallPremiumText: String = ""
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
    
    @State private var selectedCallContract: OptionContract? = nil
    @State private var selectedPutContract: OptionContract? = nil
    
    @State private var cachedCallContracts: [OptionContract] = []
    @State private var cachedPutContracts: [OptionContract] = []
    
    @State private var callMenuStrikeWidth: Int = 0
    @State private var putMenuStrikeWidth: Int = 0
    
    @State private var useMarketPremium: Bool = true

    @State private var lastRefresh: Date?
    @State private var showSettings: Bool = false
    @State private var showSavedConfirmation: Bool = false
    @State private var symbolLookupTask: Task<Void, Never>? = nil
    @State private var showWhatIfSheet: Bool = false
    @State private var showEducation: Bool = false

    @AppStorage("lastEnabledProvider") private var lastEnabledProviderRaw: String = ""
    @AppStorage("tradierEnvironment") private var tradierEnvironmentRaw: String = "production"
    @State private var appQuoteService: QuoteService = QuoteService()
    @State private var isUsingCustomProvider: Bool = false
    @State private var suppressExpirationRefetch: Bool = false

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
            .navigationTitle("StrikeGold")
            .toolbar {
                // Leading: Save + Saved
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        saveCurrentStrategy()
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }

                    NavigationLink(destination: SavedStrategiesView()) {
                        Image(systemName: "tray.full")
                    }
                }

                // Trailing: Settings
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
            rebuildProviderFromStorage()
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
        .onChange(of: lastEnabledProviderRaw) { _, _ in
            rebuildProviderFromStorage()
        }
        .onChange(of: tradierEnvironmentRaw) { _, _ in
            rebuildProviderFromStorage()
        }
        .onChange(of: underlyingNowText) { _, _ in
            // Keep slider roughly aligned if user edits underlying
            expirySpot = underlyingNow
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            rebuildProviderFromStorage()
            Task { await lookupSymbol() }
        }) {
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
        if !isUsingCustomProvider { return "Delayed data via Yahoo" }
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
        }
        return "Delayed data via Yahoo"
    }

    private var isDelayedBadgeVisible: Bool {
        return !isUsingCustomProvider
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
                        Image(systemName: isDelayedBadgeVisible ? "clock.badge.exclamationmark" : "bolt.fill")
                        Text("\(dataSourceLabel) • \(lastRefresh.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")")
                        if isDelayedBadgeVisible {
                            Text("Delayed")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
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
                    Text("Option Chain" + (isDelayedBadgeVisible ? " (delayed)" : ""))
                        .font(.subheadline)
                    
                    if strategy == .bullCallSpread {
                        ViewThatFits(in: .horizontal) {
                            // Horizontal layout: Expiration + Long + Short
                            HStack(spacing: 8) {
                                // Expiration picker
                                Picker("Expiration", selection: $selectedExpiration) {
                                    Text("Select Expiration").tag(Optional<Date>.none)
                                    ForEach(expirations, id: \.self) { d in
                                        Text(d.formatted(date: .abbreviated, time: .omitted)).tag(Optional(d))
                                    }
                                }
                                .onChange(of: selectedExpiration) { _, _ in
                                    if suppressExpirationRefetch {
                                        suppressExpirationRefetch = false
                                    } else {
                                        Task { await refetchForExpiration() }
                                    }
                                }
                                .fixedSize(horizontal: true, vertical: false)

                                // Long (lower) call picker
                                VStack(alignment: .leading, spacing: 4) {
                                    GeometryReader { geo in
                                        let col = geo.size.width / 2
                                        HStack(spacing: 0) {
                                            Text("Long Call")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: 12)
                                            Text("Mid")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: -12)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 16)

                                    Picker(selection: $selectedCallContract) {
                                        Text("Select Long").tag(Optional<OptionContract>.none)
                                        ForEach(filteredLongCallContracts(), id: \.self) { c in
                                            Text(contractMenuRowText(c))
                                                .font(.body)
                                                .monospacedDigit()
                                                .tag(Optional(c))
                                        }
                                    } label: {
                                        HStack {
                                            Text(selectedCallContract.map { OptionsFormat.number($0.strike) } ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                            Text((selectedCallContract?.mid ?? selectedCallContract?.last).map(OptionsFormat.number) ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                        .font(.body)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: 260, alignment: .center)
                                .onChange(of: selectedCallContract) { _, new in
                                    #if DEBUG
                                    if let c = new {
                                        print("[DEBUG][ContentView] Selected Long Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                                    }
                                    #endif
                                    if let c = new {
                                        selectedCallStrike = c.strike
                                        strikeText = OptionsFormat.number(c.strike)
                                        if useMarketPremium, let mid = c.mid { premiumText = OptionsFormat.number(mid) }
                                        // Enforce lower < upper by nudging upper up if needed
                                        if let upper = selectedPutStrike, upper <= c.strike {
                                            if let newUpper = nextHigherStrike(after: c.strike, in: callStrikes) {
                                                selectedPutStrike = newUpper
                                                selectedPutContract = cachedCallContracts.first(where: { $0.strike == newUpper })
                                            }
                                        }
                                    }
                                }

                                // Short (upper) call picker
                                VStack(alignment: .leading, spacing: 4) {
                                    GeometryReader { geo in
                                        let col = geo.size.width / 2
                                        HStack(spacing: 0) {
                                            Text("Short Call")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: 12)
                                            Text("Mid")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: -12)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 16)

                                    Picker(selection: $selectedPutContract) {
                                        Text("Select Short").tag(Optional<OptionContract>.none)
                                        ForEach(filteredShortCallContracts(), id: \.self) { c in
                                            Text(contractMenuRowText(c))
                                                .font(.body)
                                                .monospacedDigit()
                                                .tag(Optional(c))
                                        }
                                    } label: {
                                        HStack {
                                            Text(selectedPutContract.map { OptionsFormat.number($0.strike) } ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                            Text((selectedPutContract?.mid ?? selectedPutContract?.last).map(OptionsFormat.number) ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                        .font(.body)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: 260, alignment: .center)
                                .onChange(of: selectedPutContract) { _, new in
                                    #if DEBUG
                                    if let c = new {
                                        print("[DEBUG][ContentView] Selected Short Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                                    }
                                    #endif
                                    if let c = new {
                                        selectedPutStrike = c.strike
                                        // Enforce lower < upper by nudging lower down if needed
                                        if let lower = selectedCallStrike, lower >= c.strike {
                                            if let newLower = callStrikes.filter({ $0 < c.strike }).max() {
                                                selectedCallStrike = newLower
                                                strikeText = OptionsFormat.number(newLower)
                                                selectedCallContract = cachedCallContracts.first(where: { $0.strike == newLower })
                                                if useMarketPremium, let mid2 = selectedCallContract?.mid { premiumText = OptionsFormat.number(mid2) }
                                            }
                                        }
                                    }
                                }
                            }

                            // Vertical fallback: stack Expiration, Long, Short
                            VStack(alignment: .leading, spacing: 8) {
                                // Expiration picker
                                Picker("Expiration", selection: $selectedExpiration) {
                                    Text("Select Expiration").tag(Optional<Date>.none)
                                    ForEach(expirations, id: \.self) { d in
                                        Text(d.formatted(date: .abbreviated, time: .omitted)).tag(Optional(d))
                                    }
                                }
                                .onChange(of: selectedExpiration) { _, _ in
                                    if suppressExpirationRefetch {
                                        suppressExpirationRefetch = false
                                    } else {
                                        Task { await refetchForExpiration() }
                                    }
                                }
                                .fixedSize(horizontal: true, vertical: false)

                                // Long (lower) call picker
                                VStack(alignment: .leading, spacing: 4) {
                                    GeometryReader { geo in
                                        let col = geo.size.width / 2
                                        HStack(spacing: 0) {
                                            Text("Long Call")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: 12)
                                            Text("Mid")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: -12)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 16)

                                    Picker(selection: $selectedCallContract) {
                                        Text("Select Long").tag(Optional<OptionContract>.none)
                                        ForEach(filteredLongCallContracts(), id: \.self) { c in
                                            Text(contractMenuRowText(c))
                                                .font(.body)
                                                .monospacedDigit()
                                                .tag(Optional(c))
                                        }
                                    } label: {
                                        HStack {
                                            Text(selectedCallContract.map { OptionsFormat.number($0.strike) } ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                            Text((selectedCallContract?.mid ?? selectedCallContract?.last).map(OptionsFormat.number) ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                        .font(.body)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: 260, alignment: .center)
                                .onChange(of: selectedCallContract) { _, new in
                                    #if DEBUG
                                    if let c = new {
                                        print("[DEBUG][ContentView] Selected Long Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                                    }
                                    #endif
                                    if let c = new {
                                        selectedCallStrike = c.strike
                                        strikeText = OptionsFormat.number(c.strike)
                                        if useMarketPremium, let mid = c.mid { premiumText = OptionsFormat.number(mid) }
                                        // Enforce lower < upper by nudging upper up if needed
                                        if let upper = selectedPutStrike, upper <= c.strike {
                                            if let newUpper = nextHigherStrike(after: c.strike, in: callStrikes) {
                                                selectedPutStrike = newUpper
                                                selectedPutContract = cachedCallContracts.first(where: { $0.strike == newUpper })
                                            }
                                        }
                                    }
                                }

                                // Short (upper) call picker
                                VStack(alignment: .leading, spacing: 4) {
                                    GeometryReader { geo in
                                        let col = geo.size.width / 2
                                        HStack(spacing: 0) {
                                            Text("Short Call")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: 12)
                                            Text("Mid")
                                                .frame(width: col, alignment: .center)
                                                .offset(x: -12)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 16)

                                    Picker(selection: $selectedPutContract) {
                                        Text("Select Short").tag(Optional<OptionContract>.none)
                                        ForEach(filteredShortCallContracts(), id: \.self) { c in
                                            Text(contractMenuRowText(c))
                                                .font(.body)
                                                .monospacedDigit()
                                                .tag(Optional(c))
                                        }
                                    } label: {
                                        HStack {
                                            Text(selectedPutContract.map { OptionsFormat.number($0.strike) } ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                            Text((selectedPutContract?.mid ?? selectedPutContract?.last).map(OptionsFormat.number) ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                        .font(.body)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: 260, alignment: .center)
                                .onChange(of: selectedPutContract) { _, new in
                                    #if DEBUG
                                    if let c = new {
                                        print("[DEBUG][ContentView] Selected Short Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                                    }
                                    #endif
                                    if let c = new {
                                        selectedPutStrike = c.strike
                                        // Enforce lower < upper by nudging lower down if needed
                                        if let lower = selectedCallStrike, lower >= c.strike {
                                            if let newLower = callStrikes.filter({ $0 < c.strike }).max() {
                                                selectedCallStrike = newLower
                                                strikeText = OptionsFormat.number(newLower)
                                                selectedCallContract = cachedCallContracts.first(where: { $0.strike == newLower })
                                                if useMarketPremium, let mid2 = selectedCallContract?.mid { premiumText = OptionsFormat.number(mid2) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            // Expiration picker
                            Picker("Expiration", selection: $selectedExpiration) {
                                Text("Select Expiration").tag(Optional<Date>.none)
                                ForEach(expirations, id: \.self) { d in
                                    Text(d.formatted(date: .abbreviated, time: .omitted)).tag(Optional(d))
                                }
                            }
                            .onChange(of: selectedExpiration) { _, _ in
                                if suppressExpirationRefetch {
                                    suppressExpirationRefetch = false
                                } else {
                                    Task { await refetchForExpiration() }
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)

                            if strategy == .singleCall {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Call").frame(maxWidth: .infinity, alignment: .center)
                                        Text("Mid").frame(maxWidth: .infinity, alignment: .center).offset(x: -10)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    Picker(selection: $selectedCallContract) {
                                        Text("Select Call").tag(Optional<OptionContract>.none)
                                        ForEach(appContractsFor(kind: .call), id: \.self) { c in
                                            Text(contractMenuRowText(c))
                                                .font(.body)
                                                .monospacedDigit()
                                                .tag(Optional(c))
                                        }
                                    } label: {
                                        HStack {
                                            Text(selectedCallContract.map { OptionsFormat.number($0.strike) } ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                            Text((selectedCallContract?.mid ?? selectedCallContract?.last).map(OptionsFormat.number) ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                        .font(.body)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .onChange(of: selectedCallContract) { _, new in
                                    #if DEBUG
                                    if let c = new {
                                        print("[DEBUG][ContentView] Selected Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                                    }
                                    #endif
                                    if let c = new {
                                        selectedCallStrike = c.strike
                                        strikeText = OptionsFormat.number(c.strike)
                                        if useMarketPremium, let mid = c.mid { premiumText = OptionsFormat.number(mid) }
                                    }
                                }
                            }
                            else if strategy == .singlePut {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Put").frame(maxWidth: .infinity, alignment: .center)
                                        Text("Mid").frame(maxWidth: .infinity, alignment: .center).offset(x: -10)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    Picker(selection: $selectedPutContract) {
                                        Text("Select Put").tag(Optional<OptionContract>.none)
                                        ForEach(appContractsFor(kind: .put), id: \.self) { c in
                                            Text(contractMenuRowText(c))
                                                .font(.body)
                                                .monospacedDigit()
                                                .tag(Optional(c))
                                        }
                                    } label: {
                                        HStack {
                                            Text(selectedPutContract.map { OptionsFormat.number($0.strike) } ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                            Text((selectedPutContract?.mid ?? selectedPutContract?.last).map(OptionsFormat.number) ?? "—")
                                                .monospacedDigit()
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                        .font(.body)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .onChange(of: selectedPutContract) { _, new in
                                    #if DEBUG
                                    if let c = new {
                                        print("[DEBUG][ContentView] Selected Put -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                                    }
                                    #endif
                                    if let c = new {
                                        selectedPutStrike = c.strike
                                        strikeText = OptionsFormat.number(c.strike)
                                        if useMarketPremium, let mid = c.mid { premiumText = OptionsFormat.number(mid) }
                                    }
                                }
                            }
                        }
                    }
                    
                    Toggle(isOn: $useMarketPremium) {
                        Text("Use market mid for premium")
                    }
                    .toggleStyle(.switch)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(value: $contracts, in: 1...50) {
                            VStack(alignment: .center, spacing: 2) {
                                Text("Contracts")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                Text("\(contracts)")
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .controlSize(.small)
                        .frame(minWidth: 165, maxWidth: .infinity, alignment: .leading)

                        Text("1 contract ≈ 100 shares")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 12) {

                    Button {
                        showWhatIfSheet = true
                    } label: {
                        Label("What-If: Market Price at Expiration", systemImage: "slider.horizontal.3")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.8) 
                    }
                    .buttonStyle(.bordered)
                }
                .alert("Saved", isPresented: $showSavedConfirmation) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Your strategy was saved locally.")
                }
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

                Text(quotesFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var educationCard: some View {
        GroupBox {
            DisclosureGroup("Education", isExpanded: $showEducation) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Payoff charts show profit/loss at expiration based on the selected strategy, strikes, and premiums.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Link("Options basics", destination: URL(string: "https://www.investopedia.com/options-basics-tutorial-4583012")!)
                        Link("Calls vs. Puts", destination: URL(string: "https://www.investopedia.com/ask/answers/042415/whats-difference-between-call-and-put-options.asp")!)
                    }
                    .font(.caption2)

                    // Strategy-specific tips (no disclosure)
                    if strategy == .singleCall {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tips for Calls").font(.caption).foregroundStyle(.secondary)
                            Text("• Breakeven = strike + premium")
                            Text("• Max loss = premium paid × contracts × multiplier")
                            Text("• Upside is theoretically unlimited above strike")
                            Text("• Consider time to expiration and implied volatility")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    } else if strategy == .singlePut {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tips for Puts").font(.caption).foregroundStyle(.secondary)
                            Text("• Breakeven = strike − premium")
                            Text("• Max loss = premium paid × contracts × multiplier")
                            Text("• Max gain occurs if underlying → 0")
                            Text("• Useful for bearish views or as protection")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    } else if strategy == .bullCallSpread {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tips for Bull Call Spreads").font(.caption).foregroundStyle(.secondary)
                            Text("• Buy lower-strike call, sell higher-strike call (same expiration)")
                            Text("• Net premium is typically a debit (reduced vs. single call)")
                            Text("• Max gain = (upper − lower) × contracts × multiplier − net debit")
                            Text("• Max loss = net debit paid")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }

                    // Glossary (no disclosure)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Glossary").font(.caption).foregroundStyle(.secondary)
                        Text("• Debit/Credit: Net premium paid (debit) or received (credit)")
                        Text("• Breakeven: Price where payoff crosses zero at expiration")
                        Text("• Multiplier: Typically 100 shares per contract for US equity options")
                        Text("• Contracts: ‘× N’ indicates number of contracts; each is typically 100 shares.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var resultsCard: some View {
        GroupBox("Results") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    metricTile(title: "Max Loss", value: OptionsFormat.money(metrics.maxLoss))
                    metricTile(title: "Breakeven", value: metrics.breakeven.map(OptionsFormat.money) ?? "—")
                    metricTile(title: "Max Gain", value: maxGainText)
                    metricTile(title: "Net Premium", value: netPremiumValueText, valueColor: netPremiumColor)

                }
                Text("Results reflect payoff at expiration and exclude fees, taxes, and early assignment.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chartCard: some View {
        GroupBox("Payoff at Expiration") {
            VStack(alignment: .leading, spacing: 8) {
                Chart(curve) { pt in
                    LineMark(
                        x: .value("Underlying", pt.underlying),
                        y: .value("P/L", pt.profitLoss)
                    )
                    .foregroundStyle(.blue)
                }
                .chartYAxisLabel(position: .leading) { Text("P/L ($)") }
                .chartXAxisLabel(position: .bottom) { Text("Underlying Price ($)") }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartPlotStyle { plot in
                    plot.background(.ultraThinMaterial)
                }
                .overlay(
                    ZStack {
                        // Zero P/L baseline
                        Chart {
                            RuleMark(y: .value("Zero", 0))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(.secondary)
                        }
                        // Expiry spot marker
                        Chart {
                            RuleMark(x: .value("Expiry Spot", expirySpot))
                                .lineStyle(StrokeStyle(lineWidth: 1))
                                .foregroundStyle(.orange)
                                .annotation(position: .top, spacing: 2) {
                                    Text("Expiry spot")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                        }
                        // Breakeven marker (if any)
                        if let be = metrics.breakeven {
                            Chart {
                                RuleMark(x: .value("Breakeven", be))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6]))
                                    .foregroundStyle(.green)
                                    .annotation(position: .top, spacing: 2) {
                                        Text("Breakeven")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                            }
                        }
                    }
                )
                .frame(height: 240)

                Text("Drag the What‑If slider to shift the price range and markers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    // Rebuild/refresh the provider-related state from persisted storage.
    // Minimal implementation to satisfy compile-time references without external dependencies.
    private func rebuildProviderFromStorage() {
        #if DEBUG
        print("[DEBUG][ContentView] Rebuilding provider from storage…")
        #endif
        isUsingCustomProvider = false
        if let provider = SettingsViewModel.BYOProvider(rawValue: lastEnabledProviderRaw) {
            switch provider {
            case .tradier:
                if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradierToken) {
                    let env: TradierProvider.Environment = (tradierEnvironmentRaw == "sandbox") ? .sandbox : .production
                    appQuoteService = QuoteService(provider: TradierProvider(token: token, environment: env))
                    isUsingCustomProvider = true
                }
            case .finnhub:
                if let token = KeychainHelper.load(key: KeychainHelper.Keys.finnhubToken) {
                    appQuoteService = QuoteService(provider: FinnhubProvider(token: token))
                    isUsingCustomProvider = true
                }
            case .polygon:
                if let token = KeychainHelper.load(key: KeychainHelper.Keys.polygonToken) {
                    appQuoteService = QuoteService(provider: PolygonProvider(token: token))
                    isUsingCustomProvider = true
                }
            case .tradestation:
                if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradestationToken) {
                    appQuoteService = QuoteService(provider: TradeStationProvider(token: token))
                    isUsingCustomProvider = true
                }
            }
        }
        if !isUsingCustomProvider {
            appQuoteService = QuoteService()
        }
        #if DEBUG
        print("[DEBUG][ContentView] Provider:", isUsingCustomProvider ? "Custom" : "Yahoo fallback")
        #endif
    }

    // Returns the start of the given date in the specified time zone
    private func startOfDay(_ date: Date, in timeZoneIdentifier: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        if let tz = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = tz
        }
        return calendar.startOfDay(for: date)
    }

    // Filters expirations to those on/after the start of today in the provider's time zone (US/Eastern)
    private func filterExpirationsForProviderTZ(_ dates: [Date]) -> [Date] {
        let easternID = "America/New_York"
        var calendar = Calendar(identifier: .gregorian)
        if let tz = TimeZone(identifier: easternID) {
            calendar.timeZone = tz
        }
        // Start of today in Eastern
        let easternStartOfToday = calendar.startOfDay(for: Date())
        // Keep expirations whose Eastern calendar day is today or later
        let filtered = dates.filter { d in
            let dayStart = calendar.startOfDay(for: d)
            return dayStart >= easternStartOfToday
        }
        return filtered.isEmpty ? dates : filtered
    }

    private func nearestStrike(to price: Double, in strikes: [Double]) -> Double? {
        guard !strikes.isEmpty else { return nil }
        return strikes.min(by: { abs($0 - price) < abs($1 - price) })
    }

    private func nextHigherStrike(after strike: Double, in strikes: [Double]) -> Double? {
        let higher = strikes.filter { $0 > strike }.sorted()
        return higher.first
    }

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
        cachedCallContracts = []
        cachedPutContracts = []
        selectedCallContract = nil
        selectedPutContract = nil
    }
    
    private func appContractsFor(kind: OptionContract.Kind) -> [OptionContract] {
        return (kind == .call) ? cachedCallContracts : cachedPutContracts
    }
    
    private func contractLabel(_ c: OptionContract) -> String {
        let k = OptionsFormat.number(c.strike)
        if let b = c.bid, let a = c.ask, b > 0, a > 0 {
            let mid = (b + a) / 2.0
            return "\(k)  \(OptionsFormat.number(mid))"
        } else if let last = c.last {
            return "\(k)  \(OptionsFormat.number(last))"
        } else {
            return k
        }
    }
    
    private func padRight(_ s: String, to width: Int) -> String {
        let n = s.count
        if n >= width { return s }
        return s + String(repeating: " ", count: width - n)
    }

    private func contractMenuRowText(_ c: OptionContract) -> String {
        let strike = OptionsFormat.number(c.strike)
        let mid = (c.mid ?? c.last).map(OptionsFormat.number) ?? "—"
        // Base width is the max strike width for this kind, plus an extra buffer to push Mid further right
        let baseWidth = (c.kind == .put) ? putMenuStrikeWidth : callMenuStrikeWidth
        let extraBuffer = 8 // increase/decrease to move Mid further right/left
        let targetWidth = max(baseWidth + extraBuffer, strike.count + extraBuffer)
        let paddedStrike = padRight(strike, to: targetWidth)
        return "\(paddedStrike)\(mid)"
    }
    
    private func filteredLongCallContracts() -> [OptionContract] {
        let all = appContractsFor(kind: .call)
        guard let upper = selectedPutStrike else { return all }
        // Only filter if upper is greater than the currently selected lower (if any)
        if let lower = selectedCallStrike, upper <= lower { return all }
        // If upper is not above the minimum strike, don't filter
        let minStrike = all.map { $0.strike }.min() ?? .leastNonzeroMagnitude
        if upper <= minStrike { return all }
        let filtered = all.filter { $0.strike < upper }
        return filtered.isEmpty ? all : filtered
    }

    private func filteredShortCallContracts() -> [OptionContract] {
        let all = appContractsFor(kind: .call)
        guard let lower = selectedCallStrike else { return all }
        // If lower is not below the maximum strike, don't filter
        let maxStrike = all.map { $0.strike }.max() ?? .greatestFiniteMagnitude
        if lower >= maxStrike { return all }
        let filtered = all.filter { $0.strike > lower }
        return filtered.isEmpty ? all : filtered
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
                expirations = filterExpirationsForProviderTZ(chain.expirations)
                
                #if DEBUG
                let rawCount = chain.expirations.count
                let filteredCount = filterExpirationsForProviderTZ(chain.expirations).count
                print("[DEBUG][ContentView] Expirations raw=\(rawCount), filtered(Eastern today+)=\(filteredCount)")
                if let firstRaw = chain.expirations.first {
                    print("[DEBUG][ContentView] First raw expiration:", firstRaw.formatted(date: .abbreviated, time: .omitted))
                }
                if let firstFiltered = expirations.first {
                    print("[DEBUG][ContentView] First filtered expiration:", firstFiltered.formatted(date: .abbreviated, time: .omitted))
                }
                #endif
                if expirations.isEmpty && fetchError == nil {
                    fetchError = "Option chain unavailable (no expirations)."
                }
                
                callStrikes = chain.callStrikes
                putStrikes = chain.putStrikes
                cachedCallContracts = chain.callContracts
                cachedPutContracts  = chain.putContracts

                callMenuStrikeWidth = cachedCallContracts.map { OptionsFormat.number($0.strike).count }.max() ?? 0
                putMenuStrikeWidth  = cachedPutContracts.map  { OptionsFormat.number($0.strike).count }.max() ?? 0
                
                #if DEBUG
                let pricedCalls = cachedCallContracts.filter { $0.bid != nil || $0.ask != nil || $0.last != nil }
                let pricedPuts  = cachedPutContracts.filter  { $0.bid != nil || $0.ask != nil || $0.last != nil }
                print("[DEBUG][ContentView] Cached contracts -> calls: \(cachedCallContracts.count) (priced: \(pricedCalls.count)), puts: \(cachedPutContracts.count) (priced: \(pricedPuts.count))")
                if let c0 = cachedCallContracts.first {
                    print("[DEBUG][ContentView] Sample call: strike=\(c0.strike) bid=\(String(describing: c0.bid)) ask=\(String(describing: c0.ask)) last=\(String(describing: c0.last)) mid=\(String(describing: c0.mid))")
                }
                if let p0 = cachedPutContracts.first {
                    print("[DEBUG][ContentView] Sample put: strike=\(p0.strike) bid=\(String(describing: p0.bid)) ask=\(String(describing: p0.ask)) last=\(String(describing: p0.last)) mid=\(String(describing: p0.mid))")
                }
                #endif
                
                // If we don't have a selected expiration yet, choose the nearest and suppress refetch
                if selectedExpiration == nil {
                    selectedExpiration = expirations.first
                    suppressExpirationRefetch = true
                }
                // Auto-select near-the-money strikes and contracts
                let price = Double(underlyingNowText) ?? expirySpot
                if strategy == .singleCall {
                    if let s = nearestStrike(to: price, in: callStrikes) {
                        selectedCallStrike = s
                        strikeText = OptionsFormat.number(s)
                        selectedCallContract = cachedCallContracts.first(where: { $0.strike == s })
                        if useMarketPremium, let mid = selectedCallContract?.mid {
                            premiumText = OptionsFormat.number(mid)
                        }
                    }
                } else if strategy == .singlePut {
                    if let s = nearestStrike(to: price, in: putStrikes) {
                        selectedPutStrike = s
                        strikeText = OptionsFormat.number(s)
                        selectedPutContract = cachedPutContracts.first(where: { $0.strike == s })
                        if useMarketPremium, let mid = selectedPutContract?.mid {
                            premiumText = OptionsFormat.number(mid)
                        }
                    }
                } else {
                    // Bull Call Spread: choose lower ~ATM and upper next higher if available
                    if let lower = nearestStrike(to: price, in: callStrikes) {
                        selectedCallStrike = lower
                        strikeText = OptionsFormat.number(lower)
                        selectedCallContract = cachedCallContracts.first(where: { $0.strike == lower })
                        if useMarketPremium, let mid = selectedCallContract?.mid {
                            premiumText = OptionsFormat.number(mid)
                        }
                        let upper = nextHigherStrike(after: lower, in: callStrikes) ?? lower
                        selectedPutStrike = upper
                        selectedPutContract = cachedCallContracts.first(where: { $0.strike == upper })
                    }
                }
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
        await MainActor.run {
            isFetching = true
            fetchError = nil
        }
        do {
            let chain = try await appQuoteService.fetchOptionChain(symbol: symbolText, expiration: selectedExpiration)
            await MainActor.run {
                expirations = filterExpirationsForProviderTZ(chain.expirations)
                
                #if DEBUG
                let rawCount = chain.expirations.count
                let filteredCount = filterExpirationsForProviderTZ(chain.expirations).count
                print("[DEBUG][ContentView] Expirations raw=\(rawCount), filtered(Eastern today+)=\(filteredCount)")
                if let firstRaw = chain.expirations.first {
                    print("[DEBUG][ContentView] First raw expiration:", firstRaw.formatted(date: .abbreviated, time: .omitted))
                }
                if let firstFiltered = expirations.first {
                    print("[DEBUG][ContentView] First filtered expiration:", firstFiltered.formatted(date: .abbreviated, time: .omitted))
                }
                #endif
                if expirations.isEmpty && fetchError == nil {
                    fetchError = "Option chain unavailable (no expirations)."
                }
                
                callStrikes = chain.callStrikes
                putStrikes = chain.putStrikes
                cachedCallContracts = chain.callContracts
                cachedPutContracts  = chain.putContracts

                callMenuStrikeWidth = cachedCallContracts.map { OptionsFormat.number($0.strike).count }.max() ?? 0
                putMenuStrikeWidth  = cachedPutContracts.map  { OptionsFormat.number($0.strike).count }.max() ?? 0

                #if DEBUG
                let pricedCalls = cachedCallContracts.filter { $0.bid != nil || $0.ask != nil || $0.last != nil }
                let pricedPuts  = cachedPutContracts.filter  { $0.bid != nil || $0.ask != nil || $0.last != nil }
                print("[DEBUG][ContentView] (Refetch) Cached contracts -> calls: \(cachedCallContracts.count) (priced: \(pricedCalls.count)), puts: \(cachedPutContracts.count) (priced: \(pricedPuts.count))")
                if let c0 = cachedCallContracts.first {
                    print("[DEBUG][ContentView] (Refetch) Sample call: strike=\(c0.strike) bid=\(String(describing: c0.bid)) ask=\(String(describing: c0.ask)) last=\(String(describing: c0.last)) mid=\(String(describing: c0.mid))")
                }
                if let p0 = cachedPutContracts.first {
                    print("[DEBUG][ContentView] (Refetch) Sample put: strike=\(p0.strike) bid=\(String(describing: p0.bid)) ask=\(String(describing: p0.ask)) last=\(String(describing: p0.last)) mid=\(String(describing: p0.mid))")
                }
                #endif

                lastRefresh = Date()
                isFetching = false
                // Auto-select near-the-money strikes and contracts for the selected expiration
                let price = Double(underlyingNowText) ?? expirySpot
                if strategy == .singleCall {
                    if let s = nearestStrike(to: price, in: callStrikes) {
                        selectedCallStrike = s
                        strikeText = OptionsFormat.number(s)
                        selectedCallContract = cachedCallContracts.first(where: { $0.strike == s })
                        if useMarketPremium, let mid = selectedCallContract?.mid {
                            premiumText = OptionsFormat.number(mid)
                        }
                    }
                } else if strategy == .singlePut {
                    if let s = nearestStrike(to: price, in: putStrikes) {
                        selectedPutStrike = s
                        strikeText = OptionsFormat.number(s)
                        selectedPutContract = cachedPutContracts.first(where: { $0.strike == s })
                        if useMarketPremium, let mid = selectedPutContract?.mid {
                            premiumText = OptionsFormat.number(mid)
                        }
                    }
                } else {
                    if let lower = nearestStrike(to: price, in: callStrikes) {
                        selectedCallStrike = lower
                        strikeText = OptionsFormat.number(lower)
                        selectedCallContract = cachedCallContracts.first(where: { $0.strike == lower })
                        if useMarketPremium, let mid = selectedCallContract?.mid {
                            premiumText = OptionsFormat.number(mid)
                        }
                        let upper = nextHigherStrike(after: lower, in: callStrikes) ?? lower
                        selectedPutStrike = upper
                        selectedPutContract = cachedCallContracts.first(where: { $0.strike == upper })
                    }
                }
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

    private var netPremiumValueText: String {
          let v = multiAnalysis.totalDebit
          let absMoney = OptionsFormat.money(abs(v))
          if v > 0 { return "-" + absMoney } // debit shown as negative
          if v < 0 { return "+" + absMoney } // credit shown as positive
          return absMoney
      }

      private var netPremiumColor: Color {
          let v = multiAnalysis.totalDebit
          if v > 0 { return .red }
          if v < 0 { return .green }
          return .primary
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

    private func metricTile(title: String, value: String, valueColor: Color? = nil) -> some View {
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
                .foregroundStyle(valueColor ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var hasSelectedMarketPremium: Bool {
        if !useMarketPremium { return false }
        switch strategy {
        case .singleCall:
            return (selectedCallContract?.mid ?? selectedCallContract?.last) != nil
        case .singlePut:
            return (selectedPutContract?.mid ?? selectedPutContract?.last) != nil
        case .bullCallSpread:
            let longHas = (selectedCallContract?.mid ?? selectedCallContract?.last) != nil
            let shortHas = (selectedPutContract?.mid ?? selectedPutContract?.last) != nil
            return longHas || shortHas
        }
    }

    private var providerCaption: String {
        if !isUsingCustomProvider {
            return "quotes are delayed via Yahoo"
        }
        if let provider = SettingsViewModel.BYOProvider(rawValue: lastEnabledProviderRaw) {
            switch provider {
            case .tradier:
                return tradierEnvironmentRaw == "sandbox" ? "quotes via Tradier Sandbox" : "quotes via Tradier"
            case .finnhub:
                return "quotes via Finnhub"
            case .polygon:
                return "quotes via Polygon"
            case .tradestation:
                return "quotes via TradeStation"
            }
        }
        return "quotes are delayed via Yahoo"
    }

    private var quotesFooterText: String {
        let premiumPart = hasSelectedMarketPremium ? "Premiums use market mid when available" : "Premiums are manual"
//        let providerPart = providerCaption
        let providerPart = ""
        return "\(premiumPart); \(providerPart)."
    }

    // MARK: - Saving Current Strategy
    private func saveCurrentStrategy() {
        // Map current UI state to a SavedStrategy and persist it
        let savedKind: SavedStrategy.Kind
        switch strategy {
        case .singleCall: savedKind = .singleCall
        case .singlePut: savedKind = .singlePut
        case .bullCallSpread: savedKind = .bullCallSpread
        }

        // Map working legs (OptionLeg) into SavedLegs for persistence
        let savedLegs: [SavedStrategy.SavedLeg] = legs.map { leg in
            let typeString = (leg.type == .call) ? "call" : "put"
            let sideString = (leg.side == .long) ? "long" : "short"
            return SavedStrategy.SavedLeg(
                type: typeString,
                side: sideString,
                strike: leg.strike,
                premium: leg.premium,
                contracts: leg.contracts,
                multiplier: leg.multiplier
            )
        }

        let trimmedSymbol = symbolText.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedStrategy(
            kind: savedKind,
            symbol: trimmedSymbol,
            expiration: selectedExpiration,
            legs: savedLegs,
            marketPriceAtSave: underlyingNow,
            note: nil
        )

        StrategyStore.shared.append(saved)
        showSavedConfirmation = true
    }
}

#Preview {
    ContentView()
}

