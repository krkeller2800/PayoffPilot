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
    @State private var debugLogsEnabled: Bool = false
    #if DEBUG
    private func dlog(_ message: @autoclosure () -> String) {
        if debugLogsEnabled { print(message()) }
    }
    #endif

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

    // Side selection for single-leg strategies
    private enum Side: String, CaseIterable, Identifiable { case buy = "Buy", sell = "Sell"; var id: String { rawValue } }
    @State private var side: Side = .buy

    // Inputs (MVP: manual)
    @State private var strikeText: String = ""
    @State private var premiumText: String = ""
    @State private var shortCallStrikeText: String = ""
    @State private var shortCallPremiumText: String = ""
    @State private var underlyingNowText: String = ""
    @State private var contracts: Int = 1

    // What-if: shift the center of the payoff range / show an “expiry spot” marker
    @State private var expirySpot: Double = 100

    @State private var symbolText: String = ""
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
    @State private var showOrders: Bool = false

    private enum OrderSide { case buy, sell }

    // Paper order sheet state
    @State private var showOrderSheet: Bool = false
    @State private var orderContract: OptionContract? = nil
    @State private var orderSideTS: OrderSide = .buy
    @State private var orderInitialLimit: Double? = nil
    @State private var orderInitialQty: Int = 1
    @State private var showOrderResultAlert: Bool = false
    @State private var orderResultText: String = ""

    @AppStorage("lastEnabledProvider") private var lastEnabledProviderRaw: String = ""
    @AppStorage("tradierEnvironment") private var tradierEnvironmentRaw: String = "production"
    @State private var appQuoteService: QuoteService = QuoteService()
    @State private var isUsingCustomProvider: Bool = false
    @State private var suppressExpirationRefetch: Bool = false

    private let multiplier: Double = 100

    var body: some View {
        mainContent
            .sheet(
                isPresented: Binding(
                    get: { orderContract != nil },
                    set: { if $0 == false { orderContract = nil } }
                )
            ) {
                if let c = orderContract {
                    PlaceOrderSheet(
                        contract: c,
                        prefilledSide: (orderSideTS == .buy) ? PlaceOrderSheet.OrderSide.buy : PlaceOrderSheet.OrderSide.sell,
                        initialQuantity: orderInitialQty,
                        initialLimit: orderInitialLimit,
                        expirations: expirations,
                        preselectedExpiration: selectedExpiration,
                        onConfirm: { limit, tif, quantity, chosenExpiration in
                            // If user chose a different expiration, persist it before placing the order
                            if let exp = chosenExpiration, exp != selectedExpiration {
                                suppressExpirationRefetch = true
                                selectedExpiration = exp
                            }
                            Task {
                                await handlePlaceOrderConfirm(limit: limit, tif: tif, quantity: quantity, contract: c)
                            }
                        },
                        onCancel: { orderContract = nil }
                    )
                }
            }
            .alert("Order Result", isPresented: $showOrderResultAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(orderResultText)
            }
    }

    @ViewBuilder private var mainContent: some View {
        AnyView(MainContentRoot(
            inputsCard: { AnyView(self.inputsCard) },
            educationCard: { AnyView(self.educationCard) },
            showSettings: $showSettings,
            showSavedConfirmation: $showSavedConfirmation,
            showWhatIfSheet: $showWhatIfSheet,
            showOrders: $showOrders,
            dataSourceLabel: dataSourceLabel,
            isDelayedBadgeVisible: isDelayedBadgeVisible,
            lastRefresh: lastRefresh,
            fetchError: fetchError,
            isFetching: isFetching,
            symbolText: $symbolText,
            expirySpot: $expirySpot,
            underlyingNowText: $underlyingNowText,
            onLookup: { Task { await lookupSymbol() } },
            rebuildProviderFromStorage: rebuildProviderFromStorage,
            quotesFooterText: quotesFooterText,
            onPlaceOrder: { self.startOrderFlow() },
            canPlaceOrder: self.canPlaceOrder,
            debugLogsEnabled: $debugLogsEnabled
        ))
    }

    private struct MainContentRoot: View {
        let inputsCard: () -> AnyView
        let educationCard: () -> AnyView

        @Binding var showSettings: Bool
        @Binding var showSavedConfirmation: Bool
        @Binding var showWhatIfSheet: Bool
        @Binding var showOrders: Bool

        let dataSourceLabel: String
        let isDelayedBadgeVisible: Bool
        let lastRefresh: Date?
        let fetchError: String?
        let isFetching: Bool

        @Binding var symbolText: String
        @Binding var expirySpot: Double
        @Binding var underlyingNowText: String

        let onLookup: () -> Void
        let rebuildProviderFromStorage: () -> Void
        let quotesFooterText: String
        let onPlaceOrder: () -> Void
        let canPlaceOrder: Bool

        @Binding var debugLogsEnabled: Bool

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        inputsCard()
                        educationCard()
                    }
                    .padding()
                }
                .navigationTitle("StrikeGold")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Disable the entire Order menu if canPlaceOrder is false to prevent accidental taps causing UI stalls
                        Menu {
                            Button("Place Order") { onPlaceOrder() }
                            Button("See Orders") { showOrders = true }
                        } label: {
                            Text("Order")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            #if DEBUG
                            Toggle(isOn: $debugLogsEnabled) { Image(systemName: debugLogsEnabled ? "ladybug.fill" : "ladybug") }
                                .toggleStyle(.switch)
                            #endif
                        }
                    }
                }
            }
            .onAppear {
                expirySpot = Double(underlyingNowText) ?? expirySpot
                Task { onLookup() }
                rebuildProviderFromStorage()
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                rebuildProviderFromStorage()
                Task { onLookup() }
            }) {
                SettingsView()
            }
            .sheet(isPresented: $showOrders) {
                OrderHistoryView()
            }
            .alert("Saved", isPresented: $showSavedConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your strategy was saved locally.")
            }
            .sheet(isPresented: $showWhatIfSheet) {
                // Present the existing what-if sheet via ContentView's closure; the actual content is in ContentView
                // The caller manages the content; we just toggle the sheet binding here
                // The actual sheet content remains defined in ContentView and presented where needed
                EmptyView()
            }
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
                    side: (side == .buy ? .long : .short),
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
                    side: (side == .buy ? .long : .short),
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
            case .alpaca:
                return "Data via Alpaca"
            }
        }
        return "Delayed data via Yahoo"
    }

    private var isDelayedBadgeVisible: Bool {
        return !isUsingCustomProvider
    }

    // Profit/Loss at a specific underlying price (used for What-If marker)
    private func profitLoss(at price: Double) -> Double {
        var total: Double = 0
        for leg in legs {
            let qty = Double(max(1, leg.contracts)) * leg.multiplier
            switch (leg.type, leg.side) {
            case (.call, .long):
                let intrinsic = max(price - leg.strike, 0)
                total += (intrinsic - leg.premium) * qty
            case (.call, .short):
                let intrinsic = max(price - leg.strike, 0)
                total += (-intrinsic + leg.premium) * qty
            case (.put, .long):
                let intrinsic = max(leg.strike - price, 0)
                total += (intrinsic - leg.premium) * qty
            case (.put, .short):
                let intrinsic = max(leg.strike - price, 0)
                total += (-intrinsic + leg.premium) * qty
            }
        }
        return total
    }

    private var profitLossAtExpirySpot: Double {
        profitLoss(at: max(0.01, expirySpot))
    }

    // MARK: - UI

    @ViewBuilder private var inputsCard: some View {
        GroupBox("Inputs") {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        labeledTextField("Symbol", text: $symbolText)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)
                        Button {
                            // Dismiss the keyboard before starting lookup
                            #if canImport(UIKit)
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            #endif
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
                    Picker("Side", selection: $side) {
                        ForEach(Side.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if strategy.isSingle {
                    HStack(spacing: 12) {
                        labeledTextField("Strike", text: $strikeText, keyboardType: PPKeyboardType.decimalPad)
                        labeledTextField(side == .buy ? "Premium Paid" : "Premium Received", text: $premiumText, keyboardType: PPKeyboardType.decimalPad)
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

                optionChainSection

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
                    whatIfSheetContent
                }

                Text(quotesFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var optionChainSection: some View {
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
                                Text(expirationLabel(d)).tag(Optional(d))
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
                                dlog("[DEBUG][ContentView] Selected Long Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
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
                                dlog("[DEBUG][ContentView] Selected Short Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                            }
                            #endif
                            if let c = new {
                                selectedPutStrike = c.strike
                                // Populate short leg inputs for payoff calculations
                                shortCallStrikeText = OptionsFormat.number(c.strike)
                                if useMarketPremium, let mid = c.mid { shortCallPremiumText = OptionsFormat.number(mid) }
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
                                Text(expirationLabel(d)).tag(Optional(d))
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
                                dlog("[DEBUG][ContentView] Selected Long Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
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
                                dlog("[DEBUG][ContentView] Selected Short Call -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
                            }
                            #endif
                            if let c = new {
                                selectedPutStrike = c.strike
                                // Populate short leg inputs for payoff calculations
                                shortCallStrikeText = OptionsFormat.number(c.strike)
                                if useMarketPremium, let mid = c.mid { shortCallPremiumText = OptionsFormat.number(mid) }
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
                    if strategy == .singlePut {
                        // Expiration picker replaced with VStack header + picker
                        VStack(alignment: .leading, spacing: 4) {
                            Text("      Expiration")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(height: 16)
                            Picker("Expiration", selection: $selectedExpiration) {
                                Text("Select Expiration").tag(Optional<Date>.none)
                                ForEach(expirations, id: \.self) { d in
                                    Text(expirationLabel(d)).tag(Optional(d))
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
                        }
                    }

                    // Single Call: Expiration + Call|Mid on one row; picker spans the two right columns
                    if strategy == .singleCall {
                        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6) {
                            GridRow {
                                // Expiration picker replaced with VStack header + picker
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("      Expiration")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(height: 16)
                                    Picker("Expiration", selection: $selectedExpiration) {
                                        Text("Select Expiration").tag(Optional<Date>.none)
                                        ForEach(expirations, id: \.self) { d in
                                            Text(expirationLabel(d)).tag(Optional(d))
                                        }
                                    }
                                    .labelsHidden()
                                    .onChange(of: selectedExpiration) { _, _ in
                                        if suppressExpirationRefetch {
                                            suppressExpirationRefetch = false
                                        } else {
                                            Task { await refetchForExpiration() }
                                        }
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                }

                                VStack(alignment: .center, spacing: 4) {
                                    HStack {
                                        Text("Call").frame(maxWidth: .infinity, alignment: .center)
                                        Text("Mid").frame(maxWidth: .infinity, alignment: .center)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 16)

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
                                }
                                .gridCellColumns(2) // span the Call + Mid columns
                            }
                        }
                    }
                    else if strategy == .singlePut {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Put").frame(maxWidth: .infinity, alignment: .center)
                                Text("Mid").frame(maxWidth: .infinity, alignment: .center)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 16)

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
                                dlog("[DEBUG][ContentView] Selected Put -> strike=\(c.strike) bid=\(String(describing: c.bid)) ask=\(String(describing: c.ask)) last=\(String(describing: c.last)) mid=\(String(describing: c.mid))")
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
    }

    @ViewBuilder private var whatIfSheetContent: some View {
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
                    in: max(0, underlyingNow * 0.75)...max(underlyingNow * 1.25, underlyingNow + 1), // ±25% band around current price (ensure ≥ $1 span)
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

    @ViewBuilder private var educationCard: some View {
        GroupBox {
            DisclosureGroup("Education (for current order)", isExpanded: $showEducation) {
                VStack(alignment: .leading, spacing: 10) {
                    // Removed inner divider here
                    VStack(alignment: .leading, spacing: 6) {
                        Text("")
                        Text(educationHeader)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.bottom, 8)
                        Text(educationAboveLabel)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                        Text("•  " + educationAboveBullet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(educationBelowLabel)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                        Text("•  " + educationBelowBullet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                    Color.clear.frame(height: 8)

                    Divider()

                    Text("Payoff charts show profit/loss at expiration based on the selected strategy, strikes, and premiums.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()

                    HStack(spacing: 12) {
                        Link("Options basics", destination: URL(string: "https://www.investopedia.com/options-basics-tutorial-4583012")!)
                        Link("Calls vs. Puts", destination: URL(string: "https://www.investopedia.com/options-and-derivatives-trading-4689663")!)
                    }
                    .font(.caption2)
                    Divider()

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
                    }
                    Divider()

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
                    Divider()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var resultsCard: some View {
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

    @ViewBuilder private var chartCard: some View {
        GroupBox("Payoff at Expiration") {
            VStack(alignment: .leading, spacing: 12) {
                // Compute a reasonable Y-axis domain: derive from curve, add padding, and clamp to a max range per contract
                let plValues = curve.map { $0.profitLoss }
                let rawMin = plValues.min() ?? -1
                let rawMax = plValues.max() ?? 1
                // Add 10% padding
                let paddedMin = rawMin * 1.1
                let paddedMax = rawMax * 1.1
                // Define a sensible cap per contract (e.g., $10,000 per contract)
                let capPerContract: Double = 10_000
                let cap = capPerContract * Double(max(1, contracts))
                // Symmetric clamp around zero for readability
                let maxAbs = max(abs(paddedMin), abs(paddedMax))
                let clampedAbs = min(maxAbs, cap)
                let yDomain: ClosedRange<Double> = (-clampedAbs)...(clampedAbs)

                // Align X-axis with the What-If slider range so the payoff line stays within bounds
                let xLower = max(0, underlyingNow * 0.75)
                let xUpper = max(underlyingNow * 1.25, underlyingNow + 1)
                let xDomain: ClosedRange<Double> = xLower...xUpper

//                let beValue = metrics.breakeven
//                let _: Bool = {
//                    guard let be = beValue else { return false }
//                    let range = xUpper - xLower
//                    return range > 0 ? abs(be - expirySpot) <= range * 0.05 : false
//                }()

                Chart {
                    // Filter curve points to the slider's X-domain so the line doesn't extend beyond chart bounds
                    ForEach(curve.filter { $0.underlying >= xLower && $0.underlying <= xUpper }, id: \.underlying) { pt in
                        LineMark(
                            x: .value("Underlying", pt.underlying),
                            y: .value("P/L", pt.profitLoss)
                        )
                        .foregroundStyle(.blue)
                    }

                    // Zero P/L baseline
                    RuleMark(y: .value("Zero", 0))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(.secondary)

                    // Expiry spot marker
                    RuleMark(x: .value("At Expiration", expirySpot))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.orange)
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text("At Expiration")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }

                    // Breakeven marker (if any)
                    if let be = metrics.breakeven {
                        RuleMark(x: .value("Breakeven", be))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [6]))
                            .foregroundStyle(.green)
                            .annotation(position: .top, alignment: .center, spacing: 2) {
                                Text("Breakeven")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .offset(y: 12)
                            }
                    }

                    // What-If marker: show P/L at the slider's underlying price
                    PointMark(
                        x: .value("Underlying", expirySpot),
                        y: .value("P/L", profitLossAtExpirySpot)
                    )
                    .symbol(.circle)
                    .symbolSize(40)
                    .foregroundStyle(.orange)
                    .annotation(position: .top, spacing: 2) {
                        Text(OptionsFormat.money(profitLossAtExpirySpot))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    // Legend series entries (minimal line segments off-plot to populate legend)
                    // Removed as per instruction

                }
                .chartYAxisLabel(position: .leading) { Text("P/L ($)") }
                .chartXAxisLabel(position: .bottom) { Text("Underlying Price ($)").padding(.top, 6) }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)))
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXScale(domain: xDomain)
                .chartPlotStyle { plot in
                    plot.background(.ultraThinMaterial)
                }
                //.chartLegend(position: .bottom, alignment: .leading) // Removed as per instruction
                .frame(height: 240)
                .padding(.top, 4)

                Text("Drag the What‑If slider to shift the price range and markers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("X-axis shows underlying price ($) at expiration; Y-axis shows profit/loss ($).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func currentSelectedContract() -> OptionContract? {
        switch strategy {
        case .singleCall:
            return selectedCallContract
        case .singlePut:
            return selectedPutContract
        case .bullCallSpread:
            return nil
        }
    }

    private func startOrderFlow() {
        // Build a checklist of missing prerequisites
        var missing: [String] = []
        let trimmedSymbol = symbolText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSymbol.isEmpty {
            missing.append("Enter a symbol")
        }
        if selectedExpiration == nil {
            missing.append("Select an expiration")
        }
        switch strategy {
        case .singleCall:
            if selectedCallContract == nil { missing.append("Select a call contract") }
        case .singlePut:
            if selectedPutContract == nil { missing.append("Select a put contract") }
        case .bullCallSpread:
            if selectedCallContract == nil { missing.append("Select a long call contract") }
            if selectedPutContract == nil { missing.append("Select a short call contract") }
        }
        // If anything is missing, present a helpful alert and return
        if !missing.isEmpty {
            let bulletList = missing.map { "• \($0)" }.joined(separator: "\n")
            orderResultText = "To place an order, please:\n\n\(bulletList)"
            // Present alert on next runloop tick so the Menu can dismiss first
            DispatchQueue.main.async { self.showOrderResultAlert = true }
            return
        }
        if strategy == .bullCallSpread {
            Task { await placeBullCallSpreadOrders() }
            return
        }
        // All good — proceed
        Task { await prepareAndStartOrderFlow() }
    }

    private func placeBullCallSpreadOrders() async {
        // Ensure we have an expiration to trade against (fallback to first available)
        let expFallback = selectedExpiration ?? expirations.first
        guard let exp = expFallback else {
            orderResultText = "Please select an expiration before placing an order."
            showOrderResultAlert = true
            return
        }
        // If we used the fallback, persist it without triggering a refetch
        if selectedExpiration == nil {
            suppressExpirationRefetch = true
            selectedExpiration = exp
        }

        guard let longCall = selectedCallContract, let shortCall = selectedPutContract else {
            orderResultText = "Please select both long and short call contracts for the spread."
            showOrderResultAlert = true
            return
        }

        let symbol = symbolText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Determine sensible default limits for each leg
        guard let longLimit = initialLimit(for: longCall, isBuy: true),
              let shortLimit = initialLimit(for: shortCall, isBuy: false) else {
            orderResultText = "Unable to determine a limit price for one or both legs (no market prices)."
            showOrderResultAlert = true
            return
        }

        let tifMapped: TIF = .day
        let qty = max(1, contracts)

        // Build requests
        let longReq = OrderRequest(
            symbol: symbol,
            option: OptionSpec(expiration: exp, right: .call, strike: longCall.strike),
            side: StrikeGold.Side.buy,
            quantity: qty,
            limit: longLimit,
            tif: tifMapped
        )

        let shortReq = OrderRequest(
            symbol: symbol,
            option: OptionSpec(expiration: exp, right: .call, strike: shortCall.strike),
            side: StrikeGold.Side.sell,
            quantity: qty,
            limit: shortLimit,
            tif: tifMapped
        )

        let trader = PaperTradingService(quotes: appQuoteService)

        do {
            let longResult = try await trader.placeOptionOrder(longReq)
            let shortResult = try await trader.placeOptionOrder(shortReq)

            // Persist both legs to order history
            let longSaved = SavedOrder(
                id: longResult.placed.id,
                placedAt: Date(),
                symbol: symbol,
                expiration: selectedExpiration,
                right: SavedOrder.Right.call,
                strike: longCall.strike,
                side: SavedOrder.Side.buy,
                quantity: qty,
                limit: longLimit,
                tif: SavedOrder.TIF.day,
                status: (longResult.fill != nil) ? .filled : .working,
                fillPrice: longResult.fill?.price,
                fillQuantity: longResult.fill?.quantity,
                note: nil
            )
            await OrderStore.shared.append(longSaved)

            let shortSaved = SavedOrder(
                id: shortResult.placed.id,
                placedAt: Date(),
                symbol: symbol,
                expiration: selectedExpiration,
                right: SavedOrder.Right.call,
                strike: shortCall.strike,
                side: SavedOrder.Side.sell,
                quantity: qty,
                limit: shortLimit,
                tif: SavedOrder.TIF.day,
                status: (shortResult.fill != nil) ? .filled : .working,
                fillPrice: shortResult.fill?.price,
                fillQuantity: shortResult.fill?.quantity,
                note: nil
            )
            await OrderStore.shared.append(shortSaved)

            // Build a combined user-facing message
            let longMsg: String = {
                if let fill = longResult.fill {
                    return "Long Call (K=\(OptionsFormat.number(longCall.strike))) filled \(fill.quantity) @ \(OptionsFormat.money(fill.price)). ID: \(longResult.placed.id)"
                } else {
                    return "Long Call (K=\(OptionsFormat.number(longCall.strike))) working @ \(OptionsFormat.money(longLimit)). ID: \(longResult.placed.id)"
                }
            }()

            let shortMsg: String = {
                if let fill = shortResult.fill {
                    return "Short Call (K=\(OptionsFormat.number(shortCall.strike))) filled \(fill.quantity) @ \(OptionsFormat.money(fill.price)). ID: \(shortResult.placed.id)"
                } else {
                    return "Short Call (K=\(OptionsFormat.number(shortCall.strike))) working @ \(OptionsFormat.money(shortLimit)). ID: \(shortResult.placed.id)"
                }
            }()

            orderResultText = "Spread orders placed:\n\n\(longMsg)\n\n\(shortMsg)"
        } catch {
            orderResultText = "Spread order failed: \(error.localizedDescription)"
        }

        showOrderResultAlert = true
    }

    private func prepareAndStartOrderFlow() async {
        // Require expiration to be selected; do not auto-assign here
        guard selectedExpiration != nil else { return }

        // If no contracts are cached yet for the selected expiration, refetch in the background
        if cachedCallContracts.isEmpty && cachedPutContracts.isEmpty {
            Task { await refetchForExpiration() }
        }

        // Attempt default selection from whatever is already loaded
        autoSelectDefaultContractIfNeeded()

        guard let c = currentSelectedContract() else { return }
        orderContract = c
        orderSideTS = (side == .buy) ? .buy : .sell
        orderInitialQty = contracts
        orderInitialLimit = initialLimit(for: c, isBuy: orderSideTS == .buy)
        // Present sheet by setting orderContract (sheet is driven by non-nil contract)
    }

    private func autoSelectDefaultContractIfNeeded() {
        // Auto-select near-the-money strikes and contracts ONLY if an expiration is selected
        guard selectedExpiration != nil else { return }
        let price = Double(underlyingNowText) ?? expirySpot
        switch strategy {
        case .singleCall:
            if selectedCallContract == nil {
                if let s = nearestStrike(to: price, in: callStrikes) {
                    selectedCallStrike = s
                    strikeText = OptionsFormat.number(s)
                    selectedCallContract = cachedCallContracts.first(where: { $0.strike == s })
                    if useMarketPremium, let mid = selectedCallContract?.mid {
                        premiumText = OptionsFormat.number(mid)
                    }
                }
            }
        case .singlePut:
            if selectedPutContract == nil {
                if let s = nearestStrike(to: price, in: putStrikes) {
                    selectedPutStrike = s
                    strikeText = OptionsFormat.number(s)
                    selectedPutContract = cachedPutContracts.first(where: { $0.strike == s })
                    if useMarketPremium, let mid = selectedPutContract?.mid {
                        premiumText = OptionsFormat.number(mid)
                    }
                }
            }
        case .bullCallSpread:
            if selectedCallContract == nil || selectedPutContract == nil {
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
                    shortCallStrikeText = OptionsFormat.number(upper)
                    if useMarketPremium, let mid = selectedPutContract?.mid {
                        shortCallPremiumText = OptionsFormat.number(mid)
                    }
                }
            }
        }
    }

    private var canPlaceOrder: Bool {
        let hasExpiration = (selectedExpiration != nil)
        switch strategy {
        case .singleCall:
            return hasExpiration && selectedCallContract != nil
        case .singlePut:
            return hasExpiration && selectedPutContract != nil
        case .bullCallSpread:
            return hasExpiration && selectedCallContract != nil && selectedPutContract != nil
        }
    }

    private func initialLimit(for contract: OptionContract, isBuy: Bool) -> Double? {
        if isBuy {
            if let ask = contract.ask { return ask }
            if let mid = contract.mid { return mid }
            if let last = contract.last { return last }
            return nil
        } else {
            if let bid = contract.bid { return bid }
            if let mid = contract.mid { return mid }
            if let last = contract.last { return last }
            return nil
        }
    }

    // Rebuild/refresh the provider-related state from persisted storage.
    // Minimal implementation to satisfy compile-time references without external dependencies.
    private func rebuildProviderFromStorage() {
        #if DEBUG
        dlog("[DEBUG][ContentView] Rebuilding provider from storage…")
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
            case .alpaca:
                let keyId = KeychainHelper.load(key: KeychainHelper.Keys.alpacaKey) ?? KeychainHelper.load(key: KeychainHelper.Keys.alpacaKeyId)
                let secret = KeychainHelper.load(key: KeychainHelper.Keys.alpacaSecret)
                let envString = UserDefaults.standard.string(forKey: "alpacaEnvironment") ?? "paper"
                let env: AlpacaProvider.Environment = (envString == "live") ? .live : .paper
                if let keyId = keyId, !keyId.isEmpty, let secret = secret, !secret.isEmpty {
                    appQuoteService = QuoteService(provider: AlpacaProvider(keyId: keyId, secretKey: secret, environment: env))
                    isUsingCustomProvider = true
                }
            }
        }
        if !isUsingCustomProvider {
            appQuoteService = QuoteService()
        }
        #if DEBUG
        dlog("[DEBUG][ContentView] Provider: \(isUsingCustomProvider ? "Custom" : "Yahoo fallback")")
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

    private func expirationLabel(_ date: Date) -> String {
        // Normalize the provider date to a calendar day and render it as noon US/Eastern
        // This avoids day shifts when the provider gives midnight UTC instants.
        let eastern = TimeZone(identifier: "America/New_York")!

        // Extract Y/M/D in UTC to get the intended calendar day
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = utcCal.dateComponents([.year, .month, .day], from: date)

        // Construct a date at 12:00 (noon) in Eastern on that calendar day
        var easternCal = Calendar(identifier: .gregorian)
        easternCal.timeZone = eastern
        var dc = DateComponents()
        dc.year = comps.year
        dc.month = comps.month
        dc.day = comps.day
        dc.hour = 12
        dc.minute = 0
        let marketNoonEastern = easternCal.date(from: dc) ?? date

        // Format in Eastern
        struct Formatter {
            static let shared: DateFormatter = {
                let df = DateFormatter()
                df.timeZone = TimeZone(identifier: "America/New_York")
                df.dateFormat = "MMM d, yyyy"
                return df
            }()
        }
        return Formatter.shared.string(from: marketNoonEastern)
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
        // Choose a side-aware displayed price: Ask for Buy, Bid for Sell, fall back to Mid then Last
        let displayedPriceNumber: Double? = {
            switch side {
            case .buy:
                return c.ask ?? c.mid ?? c.last
            case .sell:
                return c.bid ?? c.mid ?? c.last
            }
        }()
        let displayed = displayedPriceNumber.map(OptionsFormat.number) ?? "—"
        // Base width is the max strike width for this kind, plus an extra buffer to push price further right
        let baseWidth = (c.kind == .put) ? putMenuStrikeWidth : callMenuStrikeWidth
        let extraBuffer = 8 // increase/decrease to move price further right/left
        let targetWidth = max(baseWidth + extraBuffer, strike.count + extraBuffer)
        let paddedStrike = padRight(strike, to: targetWidth)
        return "\(paddedStrike)\(displayed)"
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
            let chain = try await appQuoteService.fetchOptionChain(symbol: symbolText, expiration: selectedExpiration ?? Date())
            await MainActor.run {
                expirations = filterExpirationsForProviderTZ(chain.expirations)

                #if DEBUG
                let rawCount = chain.expirations.count
                let filteredCount = filterExpirationsForProviderTZ(chain.expirations).count
                dlog("[DEBUG][ContentView] Expirations raw=\(rawCount), filtered(Eastern today+)=\(filteredCount)")
                if let firstRaw = chain.expirations.first {
                    dlog("[DEBUG][ContentView] First raw expiration: \(firstRaw.formatted(date: .abbreviated, time: .omitted))")
                }
                if let firstFiltered = expirations.first {
                    dlog("[DEBUG][ContentView] First filtered expiration: \(firstFiltered.formatted(date: .abbreviated, time: .omitted))")
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
                dlog("[DEBUG][ContentView] Cached contracts -> calls: \(cachedCallContracts.count) (priced: \(pricedCalls.count)), puts: \(cachedPutContracts.count) (priced: \(pricedPuts.count))")
                if let c0 = cachedCallContracts.first {
                    dlog("[DEBUG][ContentView] Sample call: strike=\(c0.strike) bid=\(String(describing: c0.bid)) ask=\(String(describing: c0.ask)) last=\(String(describing: c0.last)) mid=\(String(describing: c0.mid))")
                }
                if let p0 = cachedPutContracts.first {
                    dlog("[DEBUG][ContentView] Sample put: strike=\(p0.strike) bid=\(String(describing: p0.bid)) ask=\(String(describing: p0.ask)) last=\(String(describing: p0.last)) mid=\(String(describing: p0.mid))")
                }
                #endif

                // Removed unconditional auto-assignment of selectedExpiration:
                /*
                // If we don't have a selected expiration yet, choose the nearest and suppress refetch
                if selectedExpiration == nil {
                    selectedExpiration = expirations.first
                    suppressExpirationRefetch = true
                }
                */

                // Auto-select near-the-money strikes and contracts ONLY if an expiration is selected
                if selectedExpiration != nil {
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
                            shortCallStrikeText = OptionsFormat.number(upper)
                            if useMarketPremium, let mid = selectedPutContract?.mid {
                                shortCallPremiumText = OptionsFormat.number(mid)
                            }
                        }
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
            guard let exp = selectedExpiration else {
                await MainActor.run {
                    isFetching = false
                    fetchError = "Please select an expiration."
                }
                return
            }
            let chain = try await appQuoteService.fetchOptionChain(symbol: symbolText, expiration: exp)
            await MainActor.run {
                expirations = filterExpirationsForProviderTZ(chain.expirations)

                #if DEBUG
                let rawCount = chain.expirations.count
                let filteredCount = filterExpirationsForProviderTZ(chain.expirations).count
                dlog("[DEBUG][ContentView] Expirations raw=\(rawCount), filtered(Eastern today+)=\(filteredCount)")
                if let firstRaw = chain.expirations.first {
                    dlog("[DEBUG][ContentView] First raw expiration: \(firstRaw.formatted(date: .abbreviated, time: .omitted))")
                }
                if let firstFiltered = expirations.first {
                    dlog("[DEBUG][ContentView] First filtered expiration: \(firstFiltered.formatted(date: .abbreviated, time: .omitted))")
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
                dlog("[DEBUG][ContentView] (Refetch) Cached contracts -> calls: \(cachedCallContracts.count) (priced: \(pricedCalls.count)), puts: \(cachedPutContracts.count) (priced: \(pricedPuts.count))")
                if let c0 = cachedCallContracts.first {
                    dlog("[DEBUG][ContentView] (Refetch) Sample call: strike=\(c0.strike) bid=\(String(describing: c0.bid)) ask=\(String(describing: c0.ask)) last=\(String(describing: c0.last)) mid=\(String(describing: c0.mid))")
                }
                if let p0 = cachedPutContracts.first {
                    dlog("[DEBUG][ContentView] (Refetch) Sample put: strike=\(p0.strike) bid=\(String(describing: p0.bid)) ask=\(String(describing: p0.ask)) last=\(String(describing: p0.last)) mid=\(String(describing: p0.mid))")
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
                        shortCallStrikeText = OptionsFormat.number(upper)
                        if useMarketPremium, let mid = selectedPutContract?.mid {
                            shortCallPremiumText = OptionsFormat.number(mid)
                        }
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
            case .alpaca:
                return "quotes via Alpaca"
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

    private var orderExplanation: String {
        let qty = max(1, contracts)
        let mult = Int(multiplier)
        let underlyingStr = OptionsFormat.number(underlyingNow)
        let kLower = OptionsFormat.number(lowerStrike)
        let kUpper = OptionsFormat.number(upperStrike)
        let premLower = OptionsFormat.number(lowerPremium)
        let premUpper = OptionsFormat.number(upperPremium)

        switch strategy {
        case .singleCall:
            let premSign = (side == .buy) ? "+" : "-"
            let premLabel = (side == .buy) ? "Premium Paid" : "Premium Received"
            return "Underlying ($\(underlyingStr)), Strike (\(kLower)), \(premLabel) (\(premSign)\(premLower)), Contracts (\(qty) × \(mult))"

        case .singlePut:
            let premSign = (side == .buy) ? "+" : "-"
            let premLabel = (side == .buy) ? "Premium Paid" : "Premium Received"
            return "Underlying ($\(underlyingStr)), Strike (\(kLower)), \(premLabel) (\(premSign)\(premLower)), Contracts (\(qty) × \(mult))"

        case .bullCallSpread:
            let net = multiAnalysis.totalDebit
            let netAbs = OptionsFormat.number(abs(net))
            let netLabel: String
            if net > 0 {
                netLabel = "Net Debit (+\(netAbs))"
            } else if net < 0 {
                netLabel = "Net Credit (-\(netAbs))"
            } else {
                netLabel = "Net Even"
            }
            return "Underlying ($\(underlyingStr)), Lower Strike (\(kLower)), Upper Strike (\(kUpper)), Long Premium (+\(premLower)), Short Premium (-\(premUpper)), \(netLabel), Contracts (\(qty) × \(mult))"
        }
    }

    private var strikeBehaviorExplanation: String {
        let lowerK = OptionsFormat.number(lowerStrike)
        let upperK = OptionsFormat.number(upperStrike)
        let mult = Int(multiplier)
        switch strategy {
        case .singleCall:
            let isLong = (side == .buy)
            if isLong {
                return "Call (long): Above $\(lowerK) → value ≈ (underlying price − $\(lowerK)) × \(mult) minus premium; below $\(lowerK) → expires worthless (max loss = premium)."
            } else {
                return "Call (short): Above $\(lowerK) → liability ≈ (underlying price − $\(lowerK)) × \(mult) minus premium received; below $\(lowerK) → keep premium (max gain = premium)."
            }
        case .singlePut:
            let isLong = (side == .buy)
            if isLong {
                return "Put (long): Below $\(lowerK) → value ≈ ($\(lowerK) − underlying price) × \(mult) minus premium; above $\(lowerK) → expires worthless (max loss = premium)."
            } else {
                return "Put (short): Below $\(lowerK) → liability ≈ ($\(lowerK) − underlying price) × \(mult) minus premium received; above $\(lowerK) → keep premium (max gain = premium)."
            }
        case .bullCallSpread:
            // Always long lower, short upper in this UI
            return "Bull call spread: Below $\(lowerK) → lose net debit; between $\(lowerK) and $\(upperK) → approx (underlying price − $\(lowerK)) × \(mult) minus net debit; above $\(upperK) → capped ≈ ($\(upperK) − $\(lowerK)) × \(mult) minus net debit."
        }
    }

    private var educationHeader: String {
        switch strategy {
        case .singleCall:
            return "Call (" + (side == .buy ? "Long" : "Short") + ") → Above/Below Strike at Expiration"
        case .singlePut:
            return "Put (" + (side == .buy ? "Long" : "Short") + ") → Above/Below Strike at Expiration"
        case .bullCallSpread:
            return "Bull Call Spread → Above/Below K at Expiration"
        }
    }

    private var educationAboveLabel: String {
        switch strategy {
        case .singleCall, .singlePut:
            let kLower = OptionsFormat.number(lowerStrike)
            return "Above $\(kLower): (UL = underlying, K = strike)"
        case .bullCallSpread:
            let kUpper = OptionsFormat.number(upperStrike)
            return "Above $\(kUpper): (UL = underlying, K = strike)"
        }
    }

    private var educationAboveBullet: String {
        let kLower = OptionsFormat.number(lowerStrike)
        let kUpper = OptionsFormat.number(upperStrike)
        let ul = OptionsFormat.number(underlyingNow)
        let prem = OptionsFormat.number(lowerPremium)
        let mult = Int(multiplier)
        switch strategy {
        case .singleCall:
            if side == .buy {
                return "(UL $\(ul) − K $\(kLower)) × \(mult) − prem (+\(prem) × \(mult))."
            } else {
                return "Liability ≈ (UL $\(ul) − K $\(kLower)) × \(mult) − prem received."
            }
        case .singlePut:
            if side == .buy {
                return "Expires worthless (max loss = prem (+\(prem) × \(mult)))."
            } else {
                return "Keep prem (max gain = prem (+\(prem) × \(mult)))."
            }
        case .bullCallSpread:
            let net = multiAnalysis.totalDebit
            let netAbs = OptionsFormat.number(abs(net))
            let netLabel = net > 0 ? "+" + netAbs : (net < 0 ? "-" + netAbs : netAbs)
            return "Capped ≈ ($\(kUpper) − $\(kLower)) × \(mult) − net debit/credit (\(netLabel) × \(mult))."
        }
    }

    private var educationBelowLabel: String {
        switch strategy {
        case .singleCall, .singlePut:
            let kLower = OptionsFormat.number(lowerStrike)
            return "Below $\(kLower):"
        case .bullCallSpread:
            let kLower = OptionsFormat.number(lowerStrike)
            return "Below $\(kLower):"
        }
    }

    private var educationBelowBullet: String {
        let kLower = OptionsFormat.number(lowerStrike)
        let ul = OptionsFormat.number(underlyingNow)
        let prem = OptionsFormat.number(lowerPremium)
        let mult = Int(multiplier)
        switch strategy {
        case .singleCall:
            if side == .buy {
                return "Expires worthless (max loss = prem (+\(prem) × \(mult)))."
            } else {
                return "Keep prem (max gain = prem (+\(prem) × \(mult)))."
            }
        case .singlePut:
            if side == .buy {
                return "(K $\(kLower) − UL $\(ul)) × \(mult) − prem (+\(prem) × \(mult))."
            } else {
                return "Liability ≈ (K $\(kLower) − UL $\(ul)) × \(mult) − prem received."
            }
        case .bullCallSpread:
            let net = multiAnalysis.totalDebit
            let netAbs = OptionsFormat.number(abs(net))
            let netLabel = net > 0 ? "+" + netAbs : (net < 0 ? "-" + netAbs : netAbs)
            return "Lose net debit/credit (\(netLabel) × \(mult))."
        }
    }

    private var educationAboveIsCalculation: Bool {
        switch strategy {
        case .singleCall:
            return true
        case .singlePut:
            return false
        case .bullCallSpread:
            return false
        }
    }

    private var educationBelowIsCalculation: Bool {
        switch strategy {
        case .singleCall:
            return false
        case .singlePut:
            return true
        case .bullCallSpread:
            return false
        }
    }

    private func handlePlaceOrderConfirm(limit: Double, tif: PlaceOrderSheet.TimeInForce, quantity: Int, contract: OptionContract) async {
        // Ensure we have an expiration to trade against (fallback to first available)
        let expFallback = selectedExpiration ?? expirations.first
        guard let exp = expFallback else {
            orderResultText = "Please select an expiration before placing an order."
            showOrderResultAlert = true
            orderContract = nil
            return
        }
        // If we used the fallback, persist it without triggering a refetch
        if selectedExpiration == nil {
            suppressExpirationRefetch = true
            selectedExpiration = exp
        }

        let symbol = symbolText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let right: OptionRight = (contract.kind == .call) ? .call : .put
        // Map local OrderSide to model Side expected by OrderRequest
        // Qualify the model `Side` type with the module name to avoid shadowing by `ContentView.Side`
        let sideMapped: StrikeGold.Side = (orderSideTS == .buy) ? StrikeGold.Side.buy : StrikeGold.Side.sell
        let tifMapped: TIF = (tif == .day) ? .day : .gtc

        let request = OrderRequest(
            symbol: symbol,
            option: OptionSpec(expiration: exp, right: right, strike: contract.strike),
            side: sideMapped,
            quantity: quantity,
            limit: limit,
            tif: tifMapped
        )

        let trader = PaperTradingService(quotes: appQuoteService)
        do {
            let result = try await trader.placeOptionOrder(request)
            if let fill = result.fill {
                let px = OptionsFormat.money(fill.price)
                orderResultText = "Filled \(fill.quantity) @ \(px). Order ID: \(result.placed.id)"

//                _ = (contract.kind == .call) ? "call" : "put"
//                _ = (orderSideTS == .buy) ? "buy" : "sell"
//                _ = (tif == .day) ? "DAY" : "GTC"
                let saved = SavedOrder(
                    id: result.placed.id,
                    placedAt: Date(),
                    symbol: symbol,
                    expiration: selectedExpiration,
                    right: (contract.kind == .call) ? SavedOrder.Right.call : SavedOrder.Right.put,
                    strike: contract.strike,
                    side: (orderSideTS == .buy) ? SavedOrder.Side.buy : SavedOrder.Side.sell,
                    quantity: quantity,
                    limit: limit,
                    tif: (tif == .day) ? SavedOrder.TIF.day : SavedOrder.TIF.gtc,
                    status: (result.fill != nil) ? .filled : .working,
                    fillPrice: result.fill?.price,
                    fillQuantity: result.fill?.quantity,
                    note: nil
                )
                await OrderStore.shared.append(saved)

            } else {
                let px = OptionsFormat.money(limit)
                orderResultText = "Accepted. Working at \(px). Order ID: \(result.placed.id)"

//                _ = (contract.kind == .call) ? "call" : "put"
//                _ = (orderSideTS == .buy) ? "buy" : "sell"
//                _ = (tif == .day) ? "DAY" : "GTC"
                let saved = SavedOrder(
                    id: result.placed.id,
                    placedAt: Date(),
                    symbol: symbol,
                    expiration: selectedExpiration,
                    right: (contract.kind == .call) ? SavedOrder.Right.call : SavedOrder.Right.put,
                    strike: contract.strike,
                    side: (orderSideTS == .buy) ? SavedOrder.Side.buy : SavedOrder.Side.sell,
                    quantity: quantity,
                    limit: limit,
                    tif: (tif == .day) ? SavedOrder.TIF.day : SavedOrder.TIF.gtc,
                    status: (result.fill != nil) ? .filled : .working,
                    fillPrice: result.fill?.price,
                    fillQuantity: result.fill?.quantity,
                    note: nil
                )
                await OrderStore.shared.append(saved)

            }
        } catch {
            orderResultText = "Order failed: \(error.localizedDescription)"
        }
        showOrderResultAlert = true
        orderContract = nil
    }
}

#Preview {
    ContentView()
}

