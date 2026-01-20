import Foundation

// MARK: - Shared Option Types

/// A lightweight representation of an option contract used by the app.
struct OptionContract: Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable { case call, put; var id: String { rawValue } }

    // Provide a stable id based on kind+strike to satisfy SwiftUI/Identifiable use.
    var id: String { "\(kind.rawValue)-\(strike)" }

    let kind: Kind
    let strike: Double
    let bid: Double?
    let ask: Double?
    let last: Double?

    /// Midpoint convenience computed from bid/ask/last
    var mid: Double? {
        if let b = bid, let a = ask, b > 0, a > 0 { return (b + a) / 2 }
        if let a = ask { return a }
        if let b = bid { return b }
        return last
    }
}

/// Container for an option chain snapshot and its available expirations.
struct OptionChainData {
    let expirations: [Date]
    let callStrikes: [Double]
    let putStrikes: [Double]
    let callContracts: [OptionContract]
    let putContracts: [OptionContract]
}

// MARK: - Provider Protocol

/// Abstraction over different market data providers (Tradier, Finnhub, Polygon, Alpaca).
protocol QuoteDataProvider {
    /// Fetch a delayed underlying price for a stock symbol.
    func fetchDelayedPrice(symbol: String) async throws -> Double
    /// Fetch an option chain for a specific expiration date.
    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData
}

// MARK: - Quote Service

/// Facade that delegates quote/chain requests to a concrete provider.
/// Provides a default fallback provider so the app can run even when no BYO key is configured.
final class QuoteService {
    enum QuoteError: Error {
        case network
        case unauthorized
        case invalidSymbol
        case noData
    }

    private let provider: any QuoteDataProvider

    /// Default initializer uses a simple fallback provider that returns empty chains and throws for price when unavailable.
    init() {
        self.provider = DefaultProvider()
    }

    /// Initialize with a specific data provider.
    init(provider: any QuoteDataProvider) {
        self.provider = provider
    }

    func fetchDelayedPrice(symbol: String) async throws -> Double {
        return try await provider.fetchDelayedPrice(symbol: symbol)
    }

    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        return try await provider.fetchOptionChain(symbol: symbol, expiration: expiration)
    }
}

// MARK: - Default Fallback Provider

/// A minimal provider used as a safe default when no external provider is configured.
private struct DefaultProvider: QuoteDataProvider {
    func fetchDelayedPrice(symbol: String) async throws -> Double {
        // No default data source; report missing data.
        throw QuoteService.QuoteError.noData
    }

    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        // Return an empty chain with the requested expiration for graceful UI handling.
        return OptionChainData(
            expirations: [expiration],
            callStrikes: [],
            putStrikes: [],
            callContracts: [],
            putContracts: []
        )
    }
}

// MARK: - Utilities

extension Array {
    /// Splits the array into consecutive chunks of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var result: [[Element]] = []
        result.reserveCapacity((self.count / size) + 1)
        var idx = startIndex
        while idx < endIndex {
            let next = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[idx..<next]))
            idx = next
        }
        return result
    }
}

/// Alpaca-backed provider for quotes and option chains (BYO key/secret).
/// Uses Alpaca Market Data v2 for stocks and v1beta1 for options.
struct AlpacaProvider: QuoteDataProvider {
    enum Environment {
        case paper
        case live
        var baseURL: String {
            // Alpaca Market Data uses the same host for paper/live; trading uses different hosts.
            // We keep the switch for future flexibility and clarity.
            switch self {
            case .paper: return "https://data.alpaca.markets"
            case .live:  return "https://data.alpaca.markets"
            }
        }
    }

    private let keyId: String
    private let secretKey: String
    private let environment: Environment
    private let optionsFeed: String

    private var debugLogsEnabled: Bool
    fileprivate func dlog(_ message: @autoclosure () -> String) { if debugLogsEnabled { print(message()) } }

    init(keyId: String, secretKey: String, environment: Environment = .paper, optionsFeed: String = "indicative", debugLogsEnabled: Bool = true) {
        self.keyId = keyId
        self.secretKey = secretKey
        self.environment = environment
        self.optionsFeed = optionsFeed
        self.debugLogsEnabled = debugLogsEnabled
        dlog("[Alpaca] logging enabled")
    }

    fileprivate func makeRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        var comps = URLComponents(string: environment.baseURL)
        comps?.path = path
        if !queryItems.isEmpty { comps?.queryItems = queryItems }
        guard let url = comps?.url else { throw QuoteService.QuoteError.invalidSymbol }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(keyId, forHTTPHeaderField: "APCA-API-KEY-ID")
        req.setValue(secretKey, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    // MARK: - QuoteDataProvider
    func fetchDelayedPrice(symbol: String) async throws -> Double {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteService.QuoteError.invalidSymbol }

        // 1) Try latest trade price
        do {
            let req = try makeRequest(path: "/v2/stocks/trades/latest", queryItems: [
                URLQueryItem(name: "symbols", value: trimmed.uppercased())
            ])
            dlog("[Alpaca] GET \(req.url?.absoluteString ?? "")")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                dlog("[Alpaca] /v2/stocks/trades/latest status=\(http.statusCode)")
                if http.statusCode != 200 {
                    if let s = String(data: data, encoding: .utf8) { dlog("[Alpaca] trades/latest body: \(s)") }
                }
                if http.statusCode == 401 || http.statusCode == 403 { throw QuoteService.QuoteError.unauthorized }
                guard http.statusCode == 200 else { throw QuoteService.QuoteError.network }
            }
            let troot = try JSONDecoder().decode(APLatestStockTradesLatestRoot.self, from: data)
            if let t = troot.trades?[trimmed.uppercased()], let p = t.p ?? t.price { return p }
            // Fallback to single-object shape if needed
            if let sroot = try? JSONDecoder().decode(APLatestStockTradeRoot.self, from: data),
               let p = sroot.trade?.p ?? sroot.trade?.price { return p }
        } catch let decErr as DecodingError {
            dlog("[Alpaca] decode error trades/latest: \(decErr)")
        } catch let e as QuoteService.QuoteError {
            if case .unauthorized = e { throw e }
            // fall through to quote mid on other errors
        } catch {
            // fall through
        }

        // 2) Fallback to latest quote mid
        let req2 = try makeRequest(path: "/v2/stocks/quotes/latest", queryItems: [
            URLQueryItem(name: "symbols", value: trimmed.uppercased())
        ])
        dlog("[Alpaca] GET \(req2.url?.absoluteString ?? "")")
        let (data2, response2) = try await URLSession.shared.data(for: req2)
        if let http = response2 as? HTTPURLResponse {
            dlog("[Alpaca] /v2/stocks/quotes/latest status=\(http.statusCode)")
            if http.statusCode != 200 {
                if let s = String(data: data2, encoding: .utf8) { dlog("[Alpaca] quotes/latest body: \(s)") }
            }
            if http.statusCode == 401 || http.statusCode == 403 { throw QuoteService.QuoteError.unauthorized }
            guard http.statusCode == 200 else { throw QuoteService.QuoteError.network }
        }
        let qmap = try JSONDecoder().decode(APLatestStockQuotesLatestRoot.self, from: data2)
        if let q = qmap.quotes?[trimmed.uppercased()] {
            let bid = q.bp ?? q.bid_price
            let ask = q.ap ?? q.ask_price
            if let b = bid, let a = ask, b > 0, a > 0 { return (b + a) / 2 }
            if let a = ask { return a }
            if let b = bid { return b }
        }
        let qroot = try JSONDecoder().decode(APLatestStockQuoteRoot.self, from: data2)
        let bid = qroot.quote?.bp ?? qroot.quote?.bid_price
        let ask = qroot.quote?.ap ?? qroot.quote?.ask_price
        if let b = bid, let a = ask, b > 0, a > 0 { return (b + a) / 2 }
        if let a = ask { return a }
        if let b = bid { return b }
        throw QuoteService.QuoteError.noData
    }

    func fetchOptionChain(symbol: String, expiration: Date?) async throws -> OptionChainData {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteService.QuoteError.invalidSymbol }
        dlog("[Alpaca] fetchOptionChain symbol=\(trimmed.uppercased()) feed=\(optionsFeed)")

        // Build expirations and contracts from snapshots only using OCC symbols
        let yydf = DateFormatter()
        yydf.dateFormat = "yyMMdd"
        yydf.timeZone = TimeZone(secondsFromGMT: 0)

        let upper = trimmed.uppercased()

        // Fetch snapshots for the underlying
        var snapshots: [String: APOptionSnapshot] = [:]
        do {
            let snapReq = try makeRequest(path: "/v1beta1/options/snapshots/\(upper)", queryItems: [
                URLQueryItem(name: "feed", value: optionsFeed),
                URLQueryItem(name: "limit", value: "1000")
            ])
            dlog("[Alpaca] GET \(snapReq.url?.absoluteString ?? "")")
            let (data, resp) = try await URLSession.shared.data(for: snapReq)
            if let http = resp as? HTTPURLResponse {
                dlog("[Alpaca] /v1beta1/options/snapshots status=\(http.statusCode)")
                if http.statusCode != 200 {
                    if let s = String(data: data, encoding: .utf8) { dlog("[Alpaca] snapshots body: \(s)") }
                }
                if http.statusCode == 401 || http.statusCode == 403 { throw QuoteService.QuoteError.unauthorized }
                guard http.statusCode == 200 else { throw QuoteService.QuoteError.network }
            }
            let root = try JSONDecoder().decode(APOptionSnapshotsRoot.self, from: data)
            snapshots = root.snapshots ?? [:]
            dlog("[Alpaca] snapshots count=\(snapshots.count)")
        } catch {
            dlog("[Alpaca] snapshots fetch failed: \(error.localizedDescription)")
            return OptionChainData(expirations: [], callStrikes: [], putStrikes: [], callContracts: [], putContracts: [])
        }

        // Parse OCC symbols: UNDERLYING(1-6) + YYMMDD + C/P + STRIKE(8 with 3 implied decimals)
        struct ParsedOption { let exp: Date; let kind: OptionContract.Kind; let strike: Double; let bid: Double?; let ask: Double? }
        var parsed: [ParsedOption] = []
        parsed.reserveCapacity(snapshots.count)

        for (sym, snap) in snapshots {
            guard sym.hasPrefix(upper) else { continue }
            let remainder = String(sym.dropFirst(upper.count))
            guard remainder.count >= 15 else { continue }
            let dateStr = String(remainder.prefix(6))
            let typeChar = remainder.dropFirst(6).prefix(1)
            let strikeStr = String(remainder.dropFirst(7).prefix(8))
            guard let exp = yydf.date(from: dateStr) else { continue }
            let kind: OptionContract.Kind = (typeChar.uppercased() == "C") ? .call : .put
            guard let strikeInt = Int(strikeStr) else { continue }
            let strike = Double(strikeInt) / 1000.0
            let bid = snap.latestQuote?.bp ?? snap.latestQuote?.bid_price
            let ask = snap.latestQuote?.ap ?? snap.latestQuote?.ask_price
            parsed.append(ParsedOption(exp: exp, kind: kind, strike: strike, bid: bid, ask: ask))
        }

        // Build expirations list
        let expirationsSet = Set(parsed.map { $0.exp })
        let expirations = expirationsSet.sorted()

        // Select target expiration
        let targetExp: Date? = expiration ?? expirations.first
        guard let selectedExp = targetExp else {
            return OptionChainData(expirations: expirations, callStrikes: [], putStrikes: [], callContracts: [], putContracts: [])
        }

        // Filter parsed options for the selected expiration
        let optionsForDay = parsed.filter { Calendar.current.isDate($0.exp, inSameDayAs: selectedExp) }

        // Collect strikes by kind
        let callStrikes = Array(Set(optionsForDay.filter { $0.kind == .call }.map { $0.strike })).sorted()
        let putStrikes  = Array(Set(optionsForDay.filter { $0.kind == .put  }.map { $0.strike })).sorted()

        // Build contracts with latest bid/ask from snapshots
        let callContracts: [OptionContract] = callStrikes.map { s in
            if let opt = optionsForDay.first(where: { $0.kind == .call && abs($0.strike - s) < 0.0001 }) {
                return OptionContract(kind: .call, strike: s, bid: opt.bid, ask: opt.ask, last: nil)
            }
            return OptionContract(kind: .call, strike: s, bid: nil, ask: nil, last: nil)
        }.sorted { $0.strike < $1.strike }

        let putContracts: [OptionContract] = putStrikes.map { s in
            if let opt = optionsForDay.first(where: { $0.kind == .put && abs($0.strike - s) < 0.0001 }) {
                return OptionContract(kind: .put, strike: s, bid: opt.bid, ask: opt.ask, last: nil)
            }
            return OptionContract(kind: .put, strike: s, bid: nil, ask: nil, last: nil)
        }.sorted { $0.strike < $1.strike }

        dlog("[Alpaca] expirations=\(expirations.count) selected=\(selectedExp) calls=\(callContracts.count) puts=\(putContracts.count)")

        return OptionChainData(
            expirations: expirations,
            callStrikes: callStrikes,
            putStrikes: putStrikes,
            callContracts: callContracts,
            putContracts: putContracts
        )
    }
}

extension AlpacaProvider {
    /// Bridge to satisfy `QuoteDataProvider` which requires a non-optional expiration parameter.
    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        return try await self.fetchOptionChain(symbol: symbol, expiration: Optional(expiration))
    }
}
// MARK: - Alpaca API DTOs

/// Latest stock trade response
struct APLatestStockTradeRoot: Codable {
    let trade: APLatestStockTrade?
}

struct APLatestStockTradesLatestRoot: Codable {
    let trades: [String: APLatestStockTrade]?
}

struct APLatestStockQuotesLatestRoot: Codable {
    let quotes: [String: APLatestStockQuote]?
}

struct APLatestStockTrade: Codable {
    /// Price fields may appear as `p` or `price` depending on feed
    let p: Double?
    let price: Double?
}

/// Latest stock quote response
struct APLatestStockQuoteRoot: Codable {
    let quote: APLatestStockQuote?
}

struct APLatestStockQuote: Codable {
    /// Bid may appear as `bp` or `bid_price`
    let bp: Double?
    let bid_price: Double?
    /// Ask may appear as `ap` or `ask_price`
    let ap: Double?
    let ask_price: Double?
}

/// Option contracts list response
struct APOptionContractsRoot: Codable {
    let contracts: [APOptionContract]?
}

struct APOptionContract: Codable {
    let symbol: String?
    let expiration_date: String?
    let strike_price: Double?
    /// "call" or "put"
    let type: String?
}

/// Latest option quotes (batched) response
struct APOptionQuotesLatestRoot: Codable {
    let quotes: [String: APOptionQuote]?
}

struct APOptionQuote: Codable {
    let bid: Double?
    let ask: Double?
}

struct APOptionSnapshotsRoot: Codable {
    let snapshots: [String: APOptionSnapshot]?
    let next_page_token: String?
}
struct APOptionSnapshot: Codable {
    let latestQuote: APOptionSnapshotQuote?
}

struct APOptionSnapshotQuote: Codable {
    let bp: Double?
    let ap: Double?
    let bid_price: Double?
    let ask_price: Double?
}

