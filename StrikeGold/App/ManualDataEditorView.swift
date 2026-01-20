//
//  ManualDataEditorView.swift
//  StrikeGold
//
//  A basic UI to manage user-entered market data used by ManualDataProvider.
//

import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ManualDataEditorView: View {
    @State private var symbol: String = ""
    @State private var underlyingText: String = ""
    @State private var expiration: Date = Date()
    @State private var kind: OptionContract.Kind = .call
    @State private var strikeText: String = ""
    @State private var bidText: String = ""
    @State private var askText: String = ""
    @State private var lastText: String = ""

    @State private var expirations: [Date] = []
    @State private var callContracts: [OptionContract] = []
    @State private var putContracts: [OptionContract] = []

    @State private var isLoading: Bool = false
    @State private var statusMessage: String? = nil
    @FocusState private var priceFieldFocused: Bool
    @FocusState private var symbolFieldFocused: Bool
    
    private enum UnderlyingSource { case yahoo, saved, manual }
    @State private var underlyingSource: UnderlyingSource? = nil
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var canPasteRow: Bool = false

    @AppStorage("manual_autoUpdateUnderlyingAtExpiration") private var autoUpdateUnderlyingAtExpiration: Bool = false
    @State private var didAutoUpdateForCurrentSelection: Bool = false

    // MARK: - Yahoo Finance Fetch
    private func fetchUnderlyingFromYahoo(symbol raw: String) async -> Double? {
        let sym = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        print("[Yahoo] Start fetch for symbol='\(sym)'")
        guard !sym.isEmpty else {
            print("[Yahoo] Aborting: empty symbol")
            return nil
        }
        // Primary: v7 quote endpoint
        guard var comps = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote") else {
            print("[Yahoo] Failed to build URLComponents")
            return nil
        }
        comps.queryItems = [URLQueryItem(name: "symbols", value: sym)]
        guard let url = comps.url else {
            print("[Yahoo] Failed to build URL from components")
            return nil
        }
        print("[Yahoo] URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Use a common Safari iOS User-Agent to avoid being blocked
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("[Yahoo] HTTP status: \(http.statusCode)")
            } else {
                print("[Yahoo] Non-HTTP response")
            }
            print("[Yahoo] Data length: \(data.count) bytes")
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                print("[Yahoo] Non-2xx response body: \(body)")
                // Fall back to chart endpoint
                print("[Yahoo] Falling back to chart endpoint…")
                return await fetchUnderlyingFromYahooChart(symbol: sym)
            }
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let json = obj as? [String: Any] else {
                print("[Yahoo] JSON root not dictionary")
                return await fetchUnderlyingFromYahooChart(symbol: sym)
            }
            let quoteResponse = json["quoteResponse"] as? [String: Any]
            let result = quoteResponse?["result"] as? [[String: Any]]
            let errorField = quoteResponse?["error"]
            print("[Yahoo] quoteResponse.error: \(String(describing: errorField))")
            let count = result?.count ?? 0
            print("[Yahoo] result count: \(count)")
            guard let first = result?.first else {
                print("[Yahoo] No first result")
                return await fetchUnderlyingFromYahooChart(symbol: sym)
            }
            if let priceNum = first["regularMarketPrice"] as? NSNumber {
                print("[Yahoo] Found price (NSNumber): \(priceNum)")
                return priceNum.doubleValue
            } else if let price = first["regularMarketPrice"] as? Double {
                print("[Yahoo] Found price (Double): \(price)")
                return price
            } else if let priceStr = first["regularMarketPrice"] as? String, let price = Double(priceStr) {
                print("[Yahoo] Found price (String): \(priceStr) -> \(price)")
                return price
            } else {
                print("[Yahoo] regularMarketPrice missing or wrong type. Keys: \(Array(first.keys))")
                return await fetchUnderlyingFromYahooChart(symbol: sym)
            }
        } catch {
            print("[Yahoo] Request failed with error: \(error)")
            print("[Yahoo] Falling back to chart endpoint…")
            return await fetchUnderlyingFromYahooChart(symbol: sym)
        }
    }

    private func fetchUnderlyingFromYahooChart(symbol sym: String) async -> Double? {
        // Fallback: v8 chart endpoint often returns meta.regularMarketPrice
        let path = "https://query1.finance.yahoo.com/v8/finance/chart/\(sym)"
        guard var comps = URLComponents(string: path) else {
            print("[Yahoo-Chart] Failed to build URLComponents")
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "range", value: "1d"),
            URLQueryItem(name: "interval", value: "1m")
        ]
        guard let url = comps.url else {
            print("[Yahoo-Chart] Failed to build URL")
            return nil
        }
        print("[Yahoo-Chart] URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("[Yahoo-Chart] HTTP status: \(http.statusCode)")
            }
            print("[Yahoo-Chart] Data length: \(data.count) bytes")
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                print("[Yahoo-Chart] Non-2xx response body: \(body)")
                return nil
            }
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let json = obj as? [String: Any] else {
                print("[Yahoo-Chart] JSON root not dictionary")
                return nil
            }
            guard let chart = json["chart"] as? [String: Any],
                  let result = chart["result"] as? [[String: Any]],
                  let first = result.first,
                  let meta = first["meta"] as? [String: Any] else {
                print("[Yahoo-Chart] Missing chart/result/meta")
                return nil
            }
            if let num = meta["regularMarketPrice"] as? NSNumber {
                print("[Yahoo-Chart] meta.regularMarketPrice (NSNumber): \(num)")
                return num.doubleValue
            } else if let price = meta["regularMarketPrice"] as? Double {
                print("[Yahoo-Chart] meta.regularMarketPrice (Double): \(price)")
                return price
            } else if let prev = meta["previousClose"] as? Double {
                print("[Yahoo-Chart] Falling back to previousClose: \(prev)")
                return prev
            } else {
                print("[Yahoo-Chart] Price not found. meta keys: \(Array(meta.keys))")
                return nil
            }
        } catch {
            print("[Yahoo-Chart] Request failed with error: \(error)")
            return nil
        }
    }

    var body: some View {
        Form {
            Section("Underlying") {
                HStack(spacing: 6) {
                    TextField("Symbol", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .focused($symbolFieldFocused)
                    if let src = underlyingSource {
                        Text(src == .yahoo ? "Yahoo" : (src == .saved ? "Saved" : "Typed"))
                            .font(.caption2)
                            .foregroundStyle(src == .yahoo ? Color.blue : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.thinMaterial))
                    }
                    TextField("Price", text: $underlyingText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($priceFieldFocused)
                    Text("Yahoo price →")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        Task { await fetchAndFillUnderlying() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Fetch price from Yahoo Finance")
                    .disabled(isLoading || symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
//                HStack {
//                    Spacer()
//                    Button("Save Underlying") { Task { await saveUnderlying() } }
//                        .buttonStyle(.bordered)
//                        .disabled(self.parseDouble(underlyingText) == nil || symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
//                }
                Toggle("Update Underlying at expiration", isOn: $autoUpdateUnderlyingAtExpiration)
                  Text("On expiration day after market close, the app (if open) will fetch the final price from Yahoo and save it.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                DatePicker("Expiration Date", selection: $expiration, displayedComponents: .date)
                Picker("Kind", selection: $kind) {
                    Text("Call").tag(OptionContract.Kind.call)
                    Text("Put").tag(OptionContract.Kind.put)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Strike")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("000.00", text: $strikeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $lastText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Bid")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $bidText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Ask")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $askText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if strikeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let s = suggestedStrike() {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Suggested strike: \(Self.formatNumber(s))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Browse Yahoo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            openYahooOptionsWithCurrentSelection()
                        } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parseDouble(strikeText) == nil)
                        .help("Open Yahoo options for the current symbol, expiration date, and strike")
                    }
                    
                    Spacer()

                    VStack(spacing: 4) {
                        Text("Paste Row")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            pasteStrikeLastBidAsk()
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!canPasteRow)
                        .help("Paste Strike, Last, Bid, Ask from clipboard")
                    }

                    Spacer()

                    VStack(spacing: 4) {
                        Text("Save Contract")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await addOrUpdateContract() }
                        } label: {
                            Image(systemName: "tray.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(self.parseDouble(strikeText) == nil || symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Save/Add this contract")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Strike is needed to browse Yahoo. Then copy 'last bid ask' and paste the row.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !callContracts.isEmpty || !putContracts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if !callContracts.isEmpty {
                            Text("Calls").font(.caption).foregroundStyle(.secondary)
                            ForEach(callContracts, id: \._id) { c in
                                ContractRow(contract: c, expiration: expiration)
                                    .contentShape(Rectangle())
                                    .onTapGesture { self.populateFields(from: c) }
                            }
                        }
                        if !putContracts.isEmpty {
                            Text("Puts").font(.caption).foregroundStyle(.secondary)
                            ForEach(putContracts, id: \._id) { c in
                                ContractRow(contract: c, expiration: expiration)
                                    .contentShape(Rectangle())
                                    .onTapGesture { self.populateFields(from: c) }
                            }
                        }
                    }
                } else {
                    Text("No contracts yet for this symbol/expiration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Option Chain")
                    Text("(not automatically retrievable)")
                        .font(.caption)
//                        .foregroundStyle(.secondary)
                }
            }

            if let msg = statusMessage, !msg.isEmpty {
                Section("Status") { Text(msg).font(.footnote) }
            }
        }
        .navigationTitle("Manual Data")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await initialLoadIfPossible(); await maybeAutoUpdateUnderlyingAtExpiration() } }
        .onAppear {
            expiration = followingFriday(from: Date())
            applySuggestedStrikeIfEmpty()
        }
        .onAppear { updateCanPasteRow() }
        .onChange(of: symbol) {
            didAutoUpdateForCurrentSelection = false
            underlyingText = ""
            underlyingSource = nil
            let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sym.isEmpty {
                Task { await refreshChain() }
                Task { await maybeAutoUpdateUnderlyingAtExpiration() }
                Task { await autoLoadUnderlyingIfEmpty() }
            }
        }
        .onChange(of: expiration) {
            didAutoUpdateForCurrentSelection = false
            Task { await refreshChain() }
            Task { await maybeAutoUpdateUnderlyingAtExpiration() }
            Task { await autoLoadUnderlyingIfEmpty() }
        }
        .onChange(of: strikeText) {
            populateFieldsFromExistingIfAny()
        }
        .onChange(of: kind) {
            populateFieldsFromExistingIfAny()
        }
        .onChange(of: underlyingText) {
            if priceFieldFocused { underlyingSource = .manual }
            applySuggestedStrikeIfEmpty()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                updateCanPasteRow()
            }
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            updateCanPasteRow()
        }
        #endif
    }

    // MARK: - Actions
    private func initialLoadIfPossible() async {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        await refreshChain()
        await loadUnderlying()
    }

    private func loadUnderlying() async {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        if let px = await ManualDataProvider.shared.getUnderlying(symbol: sym) {
            await MainActor.run {
                underlyingText = Self.formatNumber(px)
                underlyingSource = .saved
                statusMessage = "Loaded underlying for \(sym)."
                priceFieldFocused = false
                symbolFieldFocused = false
                dismissKeyboard()
            }
        } else {
            await MainActor.run { statusMessage = "No underlying found for \(sym)." }
        }
    }

    private func autoLoadUnderlyingIfEmpty() async {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        let current = underlyingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty else { return }
        await loadUnderlying()
    }

    private func fetchAndFillUnderlying() async {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Yahoo] FetchAndFill: symbol='\(sym)'")
        guard !sym.isEmpty else {
            print("[Yahoo] FetchAndFill aborted: empty symbol")
            return
        }
        if let price = await fetchUnderlyingFromYahoo(symbol: sym) {
            await ManualDataProvider.shared.setUnderlying(symbol: sym, price: price)
            await MainActor.run {
                underlyingText = Self.formatNumber(price)
                underlyingSource = .yahoo
                statusMessage = "Fetched price from Yahoo for \(sym)."
                priceFieldFocused = false
                symbolFieldFocused = false
                dismissKeyboard()
            }
            print("[Yahoo] FetchAndFill success: \(price)")
        } else {
            await MainActor.run {
                statusMessage = "Couldn’t fetch price from Yahoo for \(sym)."
            }
            print("[Yahoo] FetchAndFill failed")
        }
    }

    private func saveUnderlying() async {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty, let price = parseDouble(underlyingText) else { return }
        await ManualDataProvider.shared.setUnderlying(symbol: sym, price: price)
        await MainActor.run {
            statusMessage = "Saved underlying for \(sym)."
            underlyingSource = .saved
            priceFieldFocused = false
            symbolFieldFocused = false
            dismissKeyboard()
        }
    }

    private func refreshChain() async {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        do {
            let data = try await ManualDataProvider.shared.fetchOptionChain(symbol: sym, expiration: expiration)
            await MainActor.run {
                expirations = data.expirations
                callContracts = data.callContracts
                putContracts = data.putContracts
                statusMessage = "Refreshed chain for \(sym)."
                populateFieldsFromExistingIfAny()
            }
        } catch {
            await MainActor.run { statusMessage = "Failed to load chain: \(error.localizedDescription)" }
        }
    }

    private func addOrUpdateContract() async {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        guard let strike = parseDouble(strikeText) else { return }
        let bid = parseDouble(bidText)
        let ask = parseDouble(askText)
        let last = parseDouble(lastText)
        if let u = parseDouble(underlyingText) {
            await ManualDataProvider.shared.setUnderlying(symbol: sym, price: u)
        }
        await ManualDataProvider.shared.upsertContract(symbol: sym, expiration: expiration, kind: kind, strike: strike, bid: bid, ask: ask, last: last)
        await refreshChain()
        await MainActor.run { statusMessage = "Saved \(kind == .call ? "Call" : "Put") @ \(Self.formatNumber(strike))." }
    }

    // MARK: - Helpers
    private func isSameMarketDay(_ a: Date, _ b: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.isDate(a, inSameDayAs: b)
    }

    private func isAfterMarketCloseNow() -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let comps = cal.dateComponents([.hour, .minute], from: Date())
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        return (hour > 16) || (hour == 16 && minute >= 10)
    }

    private func maybeAutoUpdateUnderlyingAtExpiration() async {
        guard autoUpdateUnderlyingAtExpiration else { return }
        guard isSameMarketDay(expiration, Date()), isAfterMarketCloseNow() else { return }
        guard !didAutoUpdateForCurrentSelection else { return }
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        if let px = await fetchUnderlyingFromYahoo(symbol: sym) {
            await ManualDataProvider.shared.setUnderlying(symbol: sym, price: px)
            await MainActor.run {
                underlyingText = Self.formatNumber(px)
                underlyingSource = .yahoo
                statusMessage = "Auto-updated underlying for \(sym) at expiration."
                didAutoUpdateForCurrentSelection = true
                priceFieldFocused = false
                symbolFieldFocused = false
                self.dismissKeyboard()
            }
        }
    }

    @MainActor
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func parseDouble(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed)
    }

    @MainActor
    private func populateFieldsFromExistingIfAny() {
        guard let strike = parseDouble(strikeText) else { return }
        let list = (kind == .call) ? callContracts : putContracts
        if let existing = list.first(where: { abs($0.strike - strike) < 0.0001 }) {
            bidText = existing.bid.map(Self.formatNumber) ?? ""
            askText = existing.ask.map(Self.formatNumber) ?? ""
            lastText = existing.last.map(Self.formatNumber) ?? ""
        }
    }

    @MainActor
    private func populateFields(from contract: OptionContract) {
        kind = contract.kind
        strikeText = Self.formatNumber(contract.strike)
        bidText = contract.bid.map(Self.formatNumber) ?? ""
        askText = contract.ask.map(Self.formatNumber) ?? ""
        lastText = contract.last.map(Self.formatNumber) ?? ""
        priceFieldFocused = false
        symbolFieldFocused = false
        dismissKeyboard()
    }

    private func setLoading(_ v: Bool) async {
        await MainActor.run { isLoading = v }
    }

    private func pasteStrikeLastBidAsk() {
        #if canImport(UIKit)
        if let s = UIPasteboard.general.string {
            Task { await applyPastedRow(s) }
        } else {
            Task { await MainActor.run { statusMessage = "Clipboard is empty." } }
        }
        #elseif canImport(AppKit)
        if let s = NSPasteboard.general.string(forType: .string) {
            Task { await applyPastedRow(s) }
        } else {
            Task { await MainActor.run { statusMessage = "Clipboard is empty." } }
        }
        #endif
    }

    private func parseNumbers(from s: String) -> [Double] {
        let cleaned = s
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")

        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\t"))
        let tokens = cleaned.components(separatedBy: separators).filter { !$0.isEmpty }

        var nums: [Double] = []
        nums.reserveCapacity(8)
        for t in tokens {
            if let v = Double(t) {
                nums.append(v)
            }
        }
        return nums
    }

    @MainActor
    private func applyPastedRow(_ s: String) async {
        let nums = parseNumbers(from: s)
        if nums.count >= 4 {
            let strike = nums[0], last = nums[1], bid = nums[2], ask = nums[3]
            strikeText = Self.formatNumber(strike)
            lastText   = Self.formatNumber(last)
            bidText    = Self.formatNumber(bid)
            askText    = Self.formatNumber(ask)
            statusMessage = "Pasted Strike/L/B/A."
            populateFieldsFromExistingIfAny()
            return
        } else if nums.count == 3 {
            let last = nums[0], bid = nums[1], ask = nums[2]
            lastText   = Self.formatNumber(last)
            bidText    = Self.formatNumber(bid)
            askText    = Self.formatNumber(ask)
            // If strike is empty, try to suggest one from the underlying
            applySuggestedStrikeIfEmpty()
            statusMessage = "Pasted L/B/A."
            populateFieldsFromExistingIfAny()
            return
        } else {
            statusMessage = "Couldn’t find 3 or 4 numbers (L,B,A or Strike,L,B,A) in pasted text."
            return
        }
    }

    private func clipboardString() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    @MainActor
    private func updateCanPasteRow() {
        #if canImport(UIKit)
        canPasteRow = UIPasteboard.general.hasStrings
        #elseif canImport(AppKit)
        canPasteRow = NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.string.rawValue])
        #else
        canPasteRow = false
        #endif
    }

    private func followingFriday(from date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let weekday = cal.component(.weekday, from: date) // 1=Sun ... 6=Fri
        let targetWeekday = 6 // Friday
        var daysToAdd = (targetWeekday - weekday + 7) % 7
        if daysToAdd == 0 { daysToAdd = 7 } // ensure following Friday, not today
        guard let next = cal.date(byAdding: .day, value: daysToAdd, to: date) else { return date }
        let comps = cal.dateComponents([.year, .month, .day], from: next)
        return cal.date(from: comps) ?? next
    }

    private func suggestedStrikeIncrement(for underlying: Double) -> Double {
        // Simple heuristic: $1 under 100, $5 at/above 100
        return underlying >= 100 ? 5.0 : 1.0
    }

    private func suggestedStrike() -> Double? {
        guard let u = parseDouble(underlyingText) else { return nil }
        let inc = suggestedStrikeIncrement(for: u)
        return (u / inc).rounded() * inc
    }

    @MainActor
    private func applySuggestedStrikeIfEmpty() {
        let empty = strikeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty, let s = suggestedStrike() {
            strikeText = Self.formatNumber(s)
        }
    }

    private func expirationEpochSeconds(_ date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let midnightUTC = cal.date(from: comps) ?? date
        return Int(midnightUTC.timeIntervalSince1970)
    }

    private func yahooOptionsURL(symbol sym: String, strike: Double?, expiration: Date?, kind: OptionContract.Kind?) -> URL? {
        var comps = URLComponents(string: "https://finance.yahoo.com/quote/\(sym)/options")
        var items: [URLQueryItem] = []
        if let strike {
            items.append(URLQueryItem(name: "strike", value: String(strike)))
        }
        if let expiration {
            items.append(URLQueryItem(name: "date", value: String(expirationEpochSeconds(expiration))))
        }
        if let kind {
            // Yahoo expects type=calls for calls and type=puts for puts
            let typeValue = (kind == .call) ? "calls" : "puts"
            items.append(URLQueryItem(name: "type", value: typeValue))
        }
        comps?.queryItems = items.isEmpty ? nil : items
        return comps?.url
    }

    private func openYahooOptionsWithCurrentSelection() {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !sym.isEmpty else { return }
        let strike = parseDouble(strikeText)
        let url = yahooOptionsURL(symbol: sym, strike: strike, expiration: expiration, kind: kind)
        guard let url else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private static func formatNumber(_ value: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        return nf.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

@MainActor private struct ContractRow: View {
    let contract: OptionContract
    let expiration: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(contract.kind == .call ? "C" : "P")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(OptionsFormat.number(contract.strike))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            let bidText = contract.bid.map(OptionsFormat.number) ?? "—"
            let askText = contract.ask.map(OptionsFormat.number) ?? "—"
            let lastText = contract.last.map(OptionsFormat.number) ?? "—"
            Text("L \(lastText)  B \(bidText)  A \(askText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            Text(expiration.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private extension OptionContract {
    // Stable identity for ForEach in the local view; reuse existing id property
    var _id: String { self.id }
}

