//
//  ManualDataProvider.swift
//  StrikeGold
//
//  A user-driven provider that reads/writes market data from in-memory state
//  with persistence to UserDefaults. Designed to satisfy QuoteDataProvider
//  so the rest of the app can function without a network data source.
//

import Foundation

// MARK: - Codable storage models

private struct StoredContract: Codable, Hashable {
    enum Kind: String, Codable { case call, put }
    let kind: Kind
    let strike: Double
    let bid: Double?
    let ask: Double?
    let last: Double?
}

private struct StoredChain: Codable, Hashable {
    var calls: [StoredContract]
    var puts: [StoredContract]
}

// MARK: - Actor-backed store

actor ManualMarketDataStore {
    static let shared = ManualMarketDataStore()

    // Uppercased symbol -> price
    private var underlyings: [String: Double] = [:]
    // Uppercased symbol -> (UTC yyyy-MM-dd) -> chain
    private var chains: [String: [String: StoredChain]] = [:]

    private let underlyingKey = "manual_underlyings_v1"
    private let chainsKey = "manual_option_chains_v1"

    init() {
        load()
    }

    // MARK: Persistence
    private func load() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: underlyingKey) {
            if let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
                underlyings = decoded
            }
        }
        if let data = ud.data(forKey: chainsKey) {
            if let decoded = try? JSONDecoder().decode([String: [String: StoredChain]].self, from: data) {
                chains = decoded
            }
        }
    }

    private func save() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(underlyings) {
            ud.set(data, forKey: underlyingKey)
        }
        if let data = try? JSONEncoder().encode(chains) {
            ud.set(data, forKey: chainsKey)
        }
    }

    // MARK: - Helpers
    private func dateKeyUTC(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private func dateFromKeyNoonEastern(_ key: String) -> Date? {
        // key is yyyy-MM-dd in UTC calendar-day semantics; render as noon Eastern
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d
        dc.hour = 12; dc.minute = 0
        return cal.date(from: dc)
    }

    private func sameMarketDay(_ a: Date, _ b: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.isDate(a, inSameDayAs: b)
    }

    // MARK: - Underlyings
    func setUnderlying(symbol: String, price: Double) {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return }
        underlyings[upper] = price
        save()
    }

    func getUnderlying(symbol: String) -> Double? {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return underlyings[upper]
    }

    // MARK: - Chains
    fileprivate func setChain(symbol: String, expiration: Date, calls: [StoredContract], puts: [StoredContract]) {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return }
        let key = dateKeyUTC(expiration)
        var byDate = chains[upper] ?? [:]
        byDate[key] = StoredChain(calls: calls, puts: puts)
        chains[upper] = byDate
        save()
    }

    fileprivate func upsertContract(symbol: String, expiration: Date, contract: StoredContract) {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return }
        let key = dateKeyUTC(expiration)
        var byDate = chains[upper] ?? [:]
        var chain = byDate[key] ?? StoredChain(calls: [], puts: [])
        switch contract.kind {
        case .call:
            if let idx = chain.calls.firstIndex(where: { abs($0.strike - contract.strike) < 0.0001 }) {
                chain.calls[idx] = contract
            } else {
                chain.calls.append(contract)
            }
            chain.calls.sort { $0.strike < $1.strike }
        case .put:
            if let idx = chain.puts.firstIndex(where: { abs($0.strike - contract.strike) < 0.0001 }) {
                chain.puts[idx] = contract
            } else {
                chain.puts.append(contract)
            }
            chain.puts.sort { $0.strike < $1.strike }
        }
        byDate[key] = chain
        chains[upper] = byDate
        save()
    }

    fileprivate func getChain(symbol: String, expiration: Date) -> StoredChain? {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let byDate = chains[upper] else { return nil }
        // Try exact key first
        let exactKey = dateKeyUTC(expiration)
        if let c = byDate[exactKey] { return c }
        // Fallback: find by market-day equality
        if let match = byDate.first(where: { key, _ in
            if let d = dateFromKeyNoonEastern(key) { return sameMarketDay(d, expiration) }
            return false
        })?.value {
            return match
        }
        return nil
    }

    func getExpirations(symbol: String) -> [Date] {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let byDate = chains[upper] else { return [] }
        let dates = byDate.keys.compactMap { dateFromKeyNoonEastern($0) }.sorted()
        return dates
    }

    func clearAll() {
        underlyings = [:]
        chains = [:]
        save()
    }
}

// MARK: - Provider

final class ManualDataProvider: QuoteDataProvider {
    static let shared = ManualDataProvider(store: .shared)

    private let store: ManualMarketDataStore

    init(store: ManualMarketDataStore = .shared) {
        self.store = store
    }

    // MARK: QuoteDataProvider
    func fetchDelayedPrice(symbol: String) async throws -> Double {
        if let price = await store.getUnderlying(symbol: symbol) {
            return price
        }
        throw QuoteService.QuoteError.noData
    }

    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        let expirations = await store.getExpirations(symbol: symbol)
        // Choose an expiration that matches the requested market day, else first available
        let selectedExp: Date? = {
            if let match = expirations.first(where: { exp in
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "America/New_York")!
                return cal.isDate(exp, inSameDayAs: expiration)
            }) { return match }
            return expirations.first
        }()

        guard let exp = selectedExp, let stored = await store.getChain(symbol: symbol, expiration: exp) else {
            return OptionChainData(
                expirations: expirations,
                callStrikes: [],
                putStrikes: [],
                callContracts: [],
                putContracts: []
            )
        }

        // Map stored contracts to runtime OptionContract values
        let callContracts: [OptionContract] = stored.calls.map { sc in
            OptionContract(kind: .call, strike: sc.strike, bid: sc.bid, ask: sc.ask, last: sc.last)
        }.sorted { $0.strike < $1.strike }
        let putContracts: [OptionContract] = stored.puts.map { sc in
            OptionContract(kind: .put, strike: sc.strike, bid: sc.bid, ask: sc.ask, last: sc.last)
        }.sorted { $0.strike < $1.strike }

        let callStrikes = Array(Set(callContracts.map { $0.strike })).sorted()
        let putStrikes  = Array(Set(putContracts.map { $0.strike })).sorted()

        return OptionChainData(
            expirations: expirations,
            callStrikes: callStrikes,
            putStrikes: putStrikes,
            callContracts: callContracts,
            putContracts: putContracts
        )
    }

    // MARK: - Convenience mutation APIs (for future UI or programmatic seeding)
    /// Convenience getter for underlying price used by ManualDataEditorView.
    /// Returns nil when no price has been stored for the symbol.
    func getUnderlying(symbol: String) async -> Double? {
        return await store.getUnderlying(symbol: symbol)
    }

    func setUnderlying(symbol: String, price: Double) async {
        await store.setUnderlying(symbol: symbol, price: price)
    }

    func setOptionChain(symbol: String, expiration: Date, calls: [OptionContract], puts: [OptionContract]) async {
        let storedCalls = calls.map { c in
            StoredContract(kind: .call, strike: c.strike, bid: c.bid, ask: c.ask, last: c.last)
        }
        let storedPuts = puts.map { c in
            StoredContract(kind: .put, strike: c.strike, bid: c.bid, ask: c.ask, last: c.last)
        }
        await store.setChain(symbol: symbol, expiration: expiration, calls: storedCalls, puts: storedPuts)
    }

    func upsertContract(symbol: String, expiration: Date, kind: OptionContract.Kind, strike: Double, bid: Double?, ask: Double?, last: Double?) async {
        let k: StoredContract.Kind = (kind == .call) ? .call : .put
        let sc = StoredContract(kind: k, strike: strike, bid: bid, ask: ask, last: last)
        await store.upsertContract(symbol: symbol, expiration: expiration, contract: sc)
    }
}

