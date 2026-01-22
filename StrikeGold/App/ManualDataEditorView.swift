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
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
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

    @State private var showFileImporter: Bool = false
    @State private var importedRows: [ImportedRow] = []
    @State private var importRawPreview: String = ""
    @State private var importAnalysis: String? = nil
    @State private var showImportPreview: Bool = false
    @State private var importOverrideKindEnabled: Bool = false
    @State private var importOverrideKind: OptionContract.Kind = .call

    @State private var importTargetSymbol: String = ""
    @State private var importSymbolsFound: [String] = []
    @State private var showChainViewer: Bool = false
    @State private var chainSearchText: String = ""
    @State private var chainFilterSelection: Int = 0 // 0=All, 1=Calls, 2=Puts

    @State private var allExpirations: [Date] = []
    @State private var allChains: [Date: (calls: [OptionContract], puts: [OptionContract])] = [:]
    @State private var isLoadingAllChains: Bool = false

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

    private struct ImportedRow {
        let symbol: String?
        let strike: Double
        let last: Double?
        let bid: Double?
        let ask: Double?
        let kind: OptionContract.Kind?
        let expiration: Date?
    }

    private func beginImport(from text: String) {
        let rows = parseImportedText(text, defaultKind: importOverrideKind)
        self.importedRows = rows
        // Compute unique symbols found (uppercased, non-empty)
        let syms = Array(Set(rows.compactMap { $0.symbol?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty })).sorted()
        self.importSymbolsFound = syms
        let current = self.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if syms.count == 1, let only = syms.first {
            if current.isEmpty { self.symbol = only }
            self.importTargetSymbol = current.isEmpty ? only : (syms.contains(current) ? current : only)
        } else if syms.count > 1 {
            self.importTargetSymbol = syms.contains(current) ? current : (syms.first ?? "")
        } else {
            // No symbol column present; use current editor symbol (may be empty)
            self.importTargetSymbol = current
        }
        self.importOverrideKindEnabled = false
        self.importOverrideKind = .call
        self.showImportPreview = true

        let previewLines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").prefix(8)
        self.importRawPreview = previewLines.joined(separator: "\n")
        self.importAnalysis = rows.isEmpty ? analyzeImportFailure(rawText: text) : nil

        Task { @MainActor in
            if rows.isEmpty { self.statusMessage = "No importable rows found." }
        }
    }

    private func parseImportedText(_ text: String, defaultKind: OptionContract.Kind) -> [ImportedRow] {
        // Normalize line endings and split lines
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let lines = rawLines
            .map { $0.replacingOccurrences(of: "\u{2014}", with: "-") /* em dash */
                        .replacingOccurrences(of: "\u{2013}", with: "-") /* en dash */
                        .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        // Detect header (scan the first few lines to handle a leading Calls/Puts label)
        let headerKeywords = ["strike", "last", "last price", "mark", "bid", "ask", "type", "option", "call/put", "right", "symbol", "ticker", "underlying", "root", "expiration", "expiry", "exp", "expiration date", "exp date", "expire", "expire date", "contract name", "last trade date"]
        let headerIdx: Int? = {
            let limit = min(8, lines.count)
            for i in 0..<limit {
                let l = lines[i].lowercased()
                if headerKeywords.contains(where: { kw in l.contains(kw) }) { return i }
            }
            return nil
        }()
        let hasHeader = (headerIdx != nil)
        let headerLine = hasHeader ? lines[headerIdx!].lowercased() : lines.first!.lowercased()
        // Tokenize a line by comma or tab or runs of 2+ spaces
        func split(_ line: String) -> [String] {
            // Split by comma, tab, or runs of 2+ spaces (to handle table copies robustly)
            var tokens: [String] = []
            let primary = line.components(separatedBy: CharacterSet(charactersIn: ",\t"))
            for var chunk in primary {
                // Convert any run of 2+ spaces into a single tab, iteratively
                while chunk.contains("  ") { chunk = chunk.replacingOccurrences(of: "  ", with: "\t") }
                while chunk.contains("\t\t") { chunk = chunk.replacingOccurrences(of: "\t\t", with: "\t") }
                let parts = chunk.components(separatedBy: "\t")
                for p in parts {
                    let t = p.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { tokens.append(t) }
                }
            }
            return tokens
        }
        func cleanDouble(_ s: String?) -> Double? {
            guard let s = s else { return nil }
            let cleaned = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            return Double(cleaned)
        }
        // Build header index map if present
        var symbolIdx: Int? = nil
        var strikeIdx: Int? = nil
        var lastIdx: Int? = nil
        var bidIdx: Int? = nil
        var askIdx: Int? = nil
        var typeIdx: Int? = nil
        var expirationIdx: Int? = nil
        var bodyLines: ArraySlice<String>
        if let hIdx = headerIdx {
            bodyLines = lines.dropFirst(hIdx + 1)[...]
        } else {
            bodyLines = lines[...]
        }
        if hasHeader {
            let headers = split(lines[headerIdx!])
            func indexOf(_ candidates: [String]) -> Int? {
                // Exact equality first
                for (i, h) in headers.enumerated() {
                    let hl = h.lowercased()
                    if candidates.contains(where: { hl == $0 }) { return i }
                }
                // Then contains, but only for multi-word candidates (avoid matching 'last' to 'last trade date')
                for (i, h) in headers.enumerated() {
                    let hl = h.lowercased()
                    for c in candidates where c.contains(" ") {
                        if hl.contains(c) { return i }
                    }
                }
                return nil
            }
            symbolIdx = indexOf(["symbol", "ticker", "underlying", "root", "contract name"])
            strikeIdx = indexOf(["strike", "strike price"])
            lastIdx   = indexOf(["last price", "mark", "last"])
            bidIdx    = indexOf(["bid", "bid price"])
            askIdx    = indexOf(["ask", "ask price", "offer"])
            typeIdx   = indexOf(["type", "option type", "call/put", "right"])
            expirationIdx = indexOf(["expiration", "expiry", "exp", "expiration date", "exp date", "expire", "expire date"])
        }
        // Track current section kind when Yahoo copies include "Calls" / "Puts" headers
        var currentSectionKind: OptionContract.Kind? = nil
        var currentSectionExpiration: Date? = nil

        let mmmDYFormatter: DateFormatter = { let df = DateFormatter(); df.dateFormat = "MMM d, yyyy"; df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(secondsFromGMT: 0); return df }()
        let mmmmDYFormatter: DateFormatter = { let df = DateFormatter(); df.dateFormat = "MMMM d, yyyy"; df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(secondsFromGMT: 0); return df }()

        var rows: [ImportedRow] = []
        rows.reserveCapacity(bodyLines.count)
        for line in bodyLines {
            let lower = line.lowercased()
            // Detect lines that look like an expiration heading (e.g., "Feb 21, 2025" or "2025-02-21")
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty {
                // Try ISO-like date first
                if let isoDate = parseExpirationDate(trimmedLine) {
                    currentSectionExpiration = isoDate
                    continue
                }
                // Try textual month formats
                if let d = mmmDYFormatter.date(from: trimmedLine) ?? mmmmDYFormatter.date(from: trimmedLine) {
                    currentSectionExpiration = d
                    continue
                }
            }
            // Skip obvious non-data lines
            if lower.hasPrefix("contract name") || lower.hasPrefix("last trade") || lower.hasPrefix("change") || lower.hasPrefix("volume") || lower.hasPrefix("open interest") || lower.contains("in the money") || lower == "calls" || lower == "puts" {
                if lower == "calls" { currentSectionKind = .call }
                if lower == "puts" { currentSectionKind = .put }
                continue
            }
            let parts = split(line)
            if parts.isEmpty { continue }
            // If first token is a single letter C/P, use it as kind and remove from parts
            var mutableParts = parts
            var rowKind: OptionContract.Kind? = currentSectionKind
            if let first = mutableParts.first, first.count == 1 {
                let f = first.lowercased()
                if f == "c" { rowKind = .call; mutableParts.removeFirst() }
                else if f == "p" { rowKind = .put; mutableParts.removeFirst() }
            }

            var parsedSymbol: String? = nil
            if let symIdx = symbolIdx, symIdx < parts.count {
                let s = parts[symIdx].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                parsedSymbol = s.isEmpty ? nil : s
            }

            var occSymbol: String? = nil
            var occStrike: Double? = nil
            var occKind: OptionContract.Kind? = nil
            var occExp: Date? = nil
            // Attempt to parse OCC contract code from the "Contract Name" field or first token
            let nameCandidate: String = {
                if let symIdx = symbolIdx, symIdx < parts.count { return parts[symIdx] }
                return parts.first ?? ""
            }()
            let occParsed = parseOCCContract(nameCandidate)
            occSymbol = occParsed.symbol
            occStrike = occParsed.strike
            occKind = occParsed.kind
            occExp = occParsed.expiration
            if parsedSymbol == nil, let os = occSymbol { parsedSymbol = os }

            // If the parsedSymbol appears to be an OCC contract code, prefer the OCC-derived underlying symbol
            if let ps = parsedSymbol {
                let occCheck = parseOCCContract(ps)
                if let occUnderlying = occCheck.symbol, occUnderlying != ps {
                    parsedSymbol = occUnderlying
                }
            }

            // Header-based mapping preferred
            var strike: Double? = nil
            var last: Double? = nil
            var bid: Double? = nil
            var ask: Double? = nil
            var kindDetected: OptionContract.Kind? = nil
            var parsedExpiration: Date? = nil
            if let sIdx = strikeIdx, sIdx < mutableParts.count { strike = cleanDouble(mutableParts[sIdx]) }
            if let lIdx = lastIdx, lIdx < mutableParts.count { last = cleanDouble(mutableParts[lIdx]) }
            if let bIdx = bidIdx,  bIdx < mutableParts.count { bid  = cleanDouble(mutableParts[bIdx]) }
            if let aIdx = askIdx,  aIdx < mutableParts.count { ask  = cleanDouble(mutableParts[aIdx]) }
            if let tIdx = typeIdx, tIdx < mutableParts.count {
                let t = mutableParts[tIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t.hasPrefix("c") { kindDetected = .call } else if t.hasPrefix("p") { kindDetected = .put }
            }
            if let eIdx = expirationIdx, eIdx < mutableParts.count {
                parsedExpiration = parseExpirationDate(mutableParts[eIdx])
            }
            if strike == nil, let s = occStrike { strike = s }
            if parsedExpiration == nil, let e = occExp { parsedExpiration = e }
            if parsedExpiration == nil, let e = currentSectionExpiration { parsedExpiration = e }
            if kindDetected == nil, let k = occKind { kindDetected = k }
            // If no header mapping, use positional heuristics
            if strike == nil && last == nil && bid == nil && ask == nil {
                if mutableParts.count >= 4, let s = cleanDouble(mutableParts[0]) {
                    strike = s; last = cleanDouble(mutableParts[1]); bid = cleanDouble(mutableParts[2]); ask = cleanDouble(mutableParts[3])
                } else if mutableParts.count >= 3 {
                    // Not enough info to set strike; skip this row
                    continue
                }
            }
            guard let s = strike else { continue }
            let finalKind = rowKind ?? kindDetected
            rows.append(ImportedRow(symbol: parsedSymbol, strike: s, last: last, bid: bid, ask: ask, kind: finalKind, expiration: parsedExpiration))
        }
        return rows
    }

    private func analyzeImportFailure(rawText: String) -> String {
        // Normalize and split into lines
        let normalized = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty {
            return "Clipboard contained no text."
        }
        // Tokenize similar to parseImportedText: comma, tab, or runs of 2+ spaces
        func split(_ line: String) -> [String] {
            var tokens: [String] = []
            let primary = line.components(separatedBy: CharacterSet(charactersIn: ",\t"))
            for chunk in primary {
                let parts = chunk.replacingOccurrences(of: "  ", with: "\t").components(separatedBy: "\t")
                for p in parts {
                    let t = p.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { tokens.append(t) }
                }
            }
            return tokens
        }
        func toDouble(_ s: String) -> Double? {
            let cleaned = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            return Double(cleaned)
        }
        var maxNumericPerLine = 0
        var linesWithAtLeastThree = 0
        for line in lines.prefix(50) { // limit work
            let tokens = split(line)
            let nums = tokens.compactMap(toDouble)
            maxNumericPerLine = max(maxNumericPerLine, nums.count)
            if nums.count >= 3 { linesWithAtLeastThree += 1 }
        }
        if linesWithAtLeastThree == 0 {
            return "We couldn’t find at least three numeric values on a single line. Expect rows like: Strike, Last, Bid, Ask."
        }
        let header = lines.first!.lowercased()
        let hasHeader = header.contains("strike") || header.contains("last") || header.contains("mark") || header.contains("bid") || header.contains("ask") || header.contains("type") || header.contains("expiration") || header.contains("expiry") || header.contains("exp date") || header.contains("expire") || header.contains("expire date")
        if !hasHeader {
            return "We found numbers but couldn’t map columns. Include a header row with Strike, Last (or Mark), Bid, Ask (and optional Type/Expiration), or ensure each row is: Strike, Last, Bid, Ask."
        }
        return "We found a header but couldn’t map the expected columns. Make sure the header includes Strike and at least one of Last/Mark, Bid, or Ask. Supported headers: Strike, Last (or Mark), Bid, Ask, Type, Expiration."
    }

    private func commitImport(rows: [ImportedRow], overrideKind: OptionContract.Kind?) async {
        // Determine target symbol
        let chosen = importTargetSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let current = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let target = chosen.isEmpty ? current : chosen
        guard !target.isEmpty else {
            await MainActor.run { self.statusMessage = "Choose a symbol to import into." }
            return
        }
        // Filter rows to target symbol
        let filtered: [ImportedRow] = rows.filter { ($0.symbol ?? target) == target }
        guard !filtered.isEmpty else {
            await MainActor.run { self.statusMessage = "No rows for symbol \(target)." }
            return
        }
        // Group by expiration (default to current editor selection when missing)
        let defaultExp = self.expiration
        var groups: [Date: [ImportedRow]] = [:]
        for r in filtered {
            let exp = normalizeToNoonEastern(r.expiration ?? defaultExp)
            groups[exp, default: []].append(r)
        }
        // Persist each group
        var total = 0
        for (exp, groupRows) in groups {
            var callContracts: [OptionContract] = []
            var putContracts: [OptionContract] = []
            for r in groupRows {
                let k = overrideKind ?? r.kind ?? .call
                let oc = OptionContract(kind: k, strike: r.strike, bid: r.bid, ask: r.ask, last: r.last)
                if k == .call { callContracts.append(oc) } else { putContracts.append(oc) }
            }
            callContracts.sort { $0.strike < $1.strike }
            putContracts.sort { $0.strike < $1.strike }
            await ManualDataProvider.shared.setOptionChain(symbol: target, expiration: exp, calls: callContracts, puts: putContracts)
            total += groupRows.count
        }
        // Update editor symbol and refresh
        await MainActor.run { self.symbol = target }
        await refreshChain()
        await MainActor.run {
            let expCount = groups.keys.count
            self.statusMessage = "Imported \(total) rows for \(target) across \(expCount) expiration(s)."
            self.showImportPreview = false
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
                    Text("Symbol and Strike are needed to browse Yahoo. Then copy 'last bid ask' and paste the row.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Bulk Import") {
                    HStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text("Paste CSV/Text").font(.caption2).foregroundStyle(.secondary)
                            Button {
                                #if canImport(UIKit)
                                if let s = UIPasteboard.general.string { beginImport(from: s) } else { Task { await MainActor.run { statusMessage = "Clipboard is empty." } } }
                                #elseif canImport(AppKit)
                                if let s = NSPasteboard.general.string(forType: .string) { beginImport(from: s) } else { Task { await MainActor.run { statusMessage = "Clipboard is empty." } } }
                                #endif
                            } label: { Image(systemName: "doc.on.clipboard.fill") }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Paste CSV or tab-delimited rows")
                        }
                        Spacer()
                        VStack(spacing: 4) {
                            Text("Import CSV File").font(.caption2).foregroundStyle(.secondary)
                            Button { showFileImporter = true } label: { Image(systemName: "tray.and.arrow.down.fill") }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Choose a CSV or text file to import")
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.caption2).foregroundStyle(.secondary)
                        Text("Supports headers: Strike, Last, Bid, Ask, Type. You can override Call/Put in the preview.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    Text("(manually input)")
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
//                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await loadAllFutureChains(); showChainViewer = true }
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("View full option chain")
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
#if canImport(UniformTypeIdentifiers)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                do {
                    let data = try Data(contentsOf: url)
                    if let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                        beginImport(from: s)
                    } else {
                        Task { await MainActor.run { statusMessage = "Couldn’t read file as text." } }
                    }
                } catch {
                    Task { await MainActor.run { statusMessage = "Failed to read file: \(error.localizedDescription)" } }
                }
            case .failure(let err):
                Task { await MainActor.run { statusMessage = "Import canceled: \(err.localizedDescription)" } }
            }
        }
#endif
        .sheet(isPresented: $showImportPreview) {
            NavigationStack {
                VStack(spacing: 12) {
                    if importedRows.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No rows detected.")
                                    .font(.headline)
                                if let analysis = importAnalysis, !analysis.isEmpty {
                                    Text(analysis)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !importRawPreview.isEmpty {
                                    GroupBox("Clipboard sample") {
                                        ScrollView {
                                            Text(importRawPreview)
                                                .font(.system(.caption2, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxHeight: 180)
                                    }
                                }
                                Text("Tips:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("• Include a header row with Strike, Last (or Mark), Bid, Ask, and optionally Type/Expiration; or paste rows as Strike, Last, Bid, Ask.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("• Copies from Yahoo tables are supported. Use the table rows, not links or screenshots.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("• If Type is missing, you can override Call/Put in the preview.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal)
                        }
                    } else {
                        List {
                            Section("Symbol") {
                                if importSymbolsFound.count > 1 {
                                    Picker("Import into", selection: $importTargetSymbol) {
                                        ForEach(importSymbolsFound, id: \.self) { Text($0).tag($0) }
                                    }
                                } else {
                                    TextField("Symbol", text: $importTargetSymbol)
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled(true)
                                }
                                let target = importTargetSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                let skipped = importedRows.filter { ($0.symbol ?? target) != target }.count
                                if skipped > 0 {
                                    Text("\(skipped) rows will be skipped (different symbol).")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Section("Preview (\(importedRows.count) rows)") {
                                ForEach(Array(importedRows.enumerated()), id: \.offset) { idx, r in
                                    HStack(spacing: 8) {
                                        let kind = (r.kind ?? (importOverrideKindEnabled ? importOverrideKind : .call))
                                        Text(kind == .call ? "C" : "P").font(.caption2).foregroundStyle(.secondary).frame(width: 14)
                                        Text(Self.formatNumber(r.strike)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                                        let bidText = r.bid.map(Self.formatNumber) ?? "—"
                                        let askText = r.ask.map(Self.formatNumber) ?? "—"
                                        let lastText = r.last.map(Self.formatNumber) ?? "—"
                                        Text("L \(lastText)  B \(bidText)  A \(askText)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                            .lineLimit(1)
                                        if let exp = r.expiration {
                                            Text(exp.formatted(.dateTime.month(.abbreviated).day()))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("—")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                            Section {
                                Toggle("Override kind for all rows", isOn: $importOverrideKindEnabled)
                                if importOverrideKindEnabled {
                                    Picker("Kind", selection: $importOverrideKind) {
                                        Text("Call").tag(OptionContract.Kind.call)
                                        Text("Put").tag(OptionContract.Kind.put)
                                    }.pickerStyle(.segmented)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Import Preview")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showImportPreview = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            let override = importOverrideKindEnabled ? importOverrideKind : nil
                            Task { await commitImport(rows: importedRows, overrideKind: override) }
                        }.disabled(importedRows.isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showChainViewer) {
            NavigationStack {
                VStack(spacing: 0) {
                    if isLoadingAllChains {
                        ProgressView("Loading all expirations…")
                            .padding()
                    }
                    List {
                        let q = chainSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        ForEach(allExpirations.sorted(), id: \.self) { exp in
                            if let tuple = allChains[exp] {
                                let calls = tuple.calls
                                let puts = tuple.puts
                                let filteredCalls: [OptionContract] = {
                                    if q.isEmpty { return calls }
                                    return calls.filter { OptionsFormat.number($0.strike).lowercased().contains(q) || String(format: "%.2f", $0.strike).lowercased().contains(q) }
                                }()
                                let filteredPuts: [OptionContract] = {
                                    if q.isEmpty { return puts }
                                    return puts.filter { OptionsFormat.number($0.strike).lowercased().contains(q) || String(format: "%.2f", $0.strike).lowercased().contains(q) }
                                }()
                                if chainFilterSelection == 0 || chainFilterSelection == 1 {
                                    if !filteredCalls.isEmpty {
                                        Section(header: Text(exp.formatted(.dateTime.month(.abbreviated).day()))) {
                                            Section("Calls") {
                                                ForEach(filteredCalls, id: \._id) { c in
                                                    ContractRow(contract: c, expiration: exp)
                                                }
                                            }
                                        }
                                    }
                                }
                                if chainFilterSelection == 0 || chainFilterSelection == 2 {
                                    if !filteredPuts.isEmpty {
                                        Section(header: Text(exp.formatted(.dateTime.month(.abbreviated).day()))) {
                                            Section("Puts") {
                                                ForEach(filteredPuts, id: \._id) { c in
                                                    ContractRow(contract: c, expiration: exp)
                                                }
                                            }
                                        }
                                    }
                                }
                                if (chainFilterSelection == 1 && filteredCalls.isEmpty) || (chainFilterSelection == 2 && filteredPuts.isEmpty) || (chainFilterSelection == 0 && filteredCalls.isEmpty && filteredPuts.isEmpty) {
                                    // No rows for this expiration under current filter; omit section entirely
                                }
                            }
                        }
                        if allExpirations.isEmpty {
                            Text("No future expirations to display.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .searchable(text: $chainSearchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search strike")
                .navigationTitle("Chain \(symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showChainViewer = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Clear") {
                            Task { @MainActor in
                                self.allExpirations = []
                                self.allChains = [:]
                                self.chainSearchText = ""
                                self.statusMessage = "Cleared option chain viewer."
                            }
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("Filter", selection: $chainFilterSelection) {
                            Text("All").tag(0)
                            Text("Calls").tag(1)
                            Text("Puts").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }
                }
            }
        }
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

    private func loadAllFutureChains() async {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        await MainActor.run { isLoadingAllChains = true }
        defer { Task { await MainActor.run { isLoadingAllChains = false } } }
        do {
            // Start with expirations known for the currently selected expiration
            let data = try await ManualDataProvider.shared.fetchOptionChain(symbol: sym, expiration: expiration)
            var exps = data.expirations.filter { $0 >= Date() }.sorted()
            await MainActor.run { allExpirations = exps; allChains = [:] }
            for exp in exps {
                do {
                    let chain = try await ManualDataProvider.shared.fetchOptionChain(symbol: sym, expiration: exp)
                    await MainActor.run { allChains[exp] = (calls: chain.callContracts, puts: chain.putContracts) }
                } catch {
                    // Skip this expiration on failure
                }
            }
        } catch {
            // If initial fetch fails, clear data
            await MainActor.run { allExpirations = []; allChains = [:] }
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

    private func parseExpirationDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Epoch seconds
        if let secs = Int(trimmed), secs > 946684800, secs < 4102444800 {
            return Date(timeIntervalSince1970: TimeInterval(secs))
        }
        // yyMMdd (OCC)
        let occ = DateFormatter(); occ.dateFormat = "yyMMdd"; occ.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = occ.date(from: trimmed) { return d }
        // yyyy-MM-dd
        let ymd = DateFormatter(); ymd.dateFormat = "yyyy-MM-dd"; ymd.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = ymd.date(from: trimmed) { return d }
        // yyyy/MM/dd
        let ymd2 = DateFormatter(); ymd2.dateFormat = "yyyy/MM/dd"; ymd2.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = ymd2.date(from: trimmed) { return d }
        // MM/dd/yyyy
        let mdy = DateFormatter(); mdy.dateFormat = "MM/dd/yyyy"; mdy.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = mdy.date(from: trimmed) { return d }
        // dd/MM/yyyy
        let dmy = DateFormatter(); dmy.dateFormat = "dd/MM/yyyy"; dmy.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = dmy.date(from: trimmed) { return d }
        // yyyyMMdd
        let ymdc = DateFormatter(); ymdc.dateFormat = "yyyyMMdd"; ymdc.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = ymdc.date(from: trimmed) { return d }
        return nil
    }

    private func parseOCCContract(_ raw: String) -> (symbol: String?, expiration: Date?, kind: OptionContract.Kind?, strike: Double?) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // OCC format: ROOT(1-6) + YYMMDD(6) + [C|P](1) + STRIKE(8, price*1000)
        let minLen = 1 + 6 + 1 + 8
        guard s.count >= minLen else { return (nil, nil, nil, nil) }
        let total = s.count
        let suffixLen = 6 + 1 + 8
        let rootLen = total - suffixLen
        guard rootLen > 0 else { return (nil, nil, nil, nil) }
        let root = String(s.prefix(rootLen))
        let dateStart = s.index(s.startIndex, offsetBy: rootLen)
        let dateEnd = s.index(dateStart, offsetBy: 6)
        let rightIdx = s.index(dateEnd, offsetBy: 0)
        let strikeStart = s.index(rightIdx, offsetBy: 1)
        let strikeEnd = s.index(strikeStart, offsetBy: 8)
        let dateStr = String(s[dateStart..<dateEnd])
        let rightChar = s[rightIdx]
        let strikeStr = String(s[strikeStart..<strikeEnd])
        // Validate numeric portions
        guard dateStr.allSatisfy({ $0.isNumber }), strikeStr.allSatisfy({ $0.isNumber }), rightChar == "C" || rightChar == "P" else {
            return (nil, nil, nil, nil)
        }
        // Parse expiration YYMMDD -> 20YY-MM-DD
        let yy = Int(dateStr.prefix(2)) ?? 0
        let mm = Int(dateStr.dropFirst(2).prefix(2)) ?? 0
        let dd = Int(dateStr.suffix(2)) ?? 0
        var dc = DateComponents()
        dc.year = 2000 + yy
        dc.month = mm
        dc.day = dd
        dc.hour = 12
        dc.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let exp = cal.date(from: dc)
        let strikeInt = Int(strikeStr) ?? 0
        let strike = Double(strikeInt) / 1000.0
        let kind: OptionContract.Kind = (rightChar == "C") ? .call : .put
        return (root, exp, kind, strike)
    }

    private func normalizeToNoonEastern(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        var dc = DateComponents()
        dc.year = comps.year; dc.month = comps.month; dc.day = comps.day; dc.hour = 12; dc.minute = 0
        return cal.date(from: dc) ?? date
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

