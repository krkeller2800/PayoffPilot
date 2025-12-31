//
//  QuoteService.swift
//  PayoffPilot
//
//  Created by Assistant on 12/31/25.
//

import Foundation

// A lightweight, no-cost delayed quote and options chain fetcher using Yahoo Finance public endpoints.
// For educational use only. This is not guaranteed for production trading apps.

struct OptionChainData {
    let expirations: [Date]
    let callStrikes: [Double]
    let putStrikes: [Double]
}

/// Abstraction for pluggable quote/chain providers.
protocol QuoteDataProvider {
    func fetchDelayedPrice(symbol: String) async throws -> Double
    func fetchOptionChain(symbol: String, expiration: Date?) async throws -> OptionChainData
}

/// Tradier-backed provider for quotes and option chains (BYO key).
/// Initialize with a user-provided OAuth token. Choose sandbox vs production via `environment`.
struct TradierProvider: QuoteDataProvider {
    enum Environment {
        case production
        case sandbox
        var baseURL: String {
            switch self {
            case .production: return "https://api.tradier.com"
            case .sandbox: return "https://sandbox.tradier.com"
            }
        }
    }

    private let token: String
    private let environment: Environment

    init(token: String, environment: Environment = .production) {
        self.token = token
        self.environment = environment
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        var comps = URLComponents(string: environment.baseURL)
        comps?.path = path
        if !queryItems.isEmpty { comps?.queryItems = queryItems }
        guard let url = comps?.url else { throw QuoteService.QuoteError.invalidSymbol }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    func fetchDelayedPrice(symbol: String) async throws -> Double {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteService.QuoteError.invalidSymbol }
        let req = try makeRequest(path: "/v1/markets/quotes", queryItems: [
            URLQueryItem(name: "symbols", value: trimmed.uppercased()),
            URLQueryItem(name: "greeks", value: "false")
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw QuoteService.QuoteError.unauthorized }
            guard http.statusCode == 200 else { throw QuoteService.QuoteError.network }
        }
        do {
            let root = try JSONDecoder().decode(TradierQuotesRoot.self, from: data)
            guard let inner = root.quotes else { throw QuoteService.QuoteError.noData }
            switch inner.quote {
            case .one(let q):
                if let p = q.last ?? q.close { return p }
                if let b = q.bid, let a = q.ask, b > 0, a > 0 { return (b + a) / 2 }
            case .many(let arr):
                if let q = arr.first {
                    if let p = q.last ?? q.close { return p }
                    if let b = q.bid, let a = q.ask, b > 0, a > 0 { return (b + a) / 2 }
                }
            }
            throw QuoteService.QuoteError.noData
        } catch is DecodingError {
            throw QuoteService.QuoteError.parse
        }
    }

    func fetchOptionChain(symbol: String, expiration: Date?) async throws -> OptionChainData {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteService.QuoteError.invalidSymbol }

        // Fetch expirations first
        let expReq = try makeRequest(path: "/v1/markets/options/expirations", queryItems: [
            URLQueryItem(name: "symbol", value: trimmed.uppercased()),
            URLQueryItem(name: "includeAllRoots", value: "true"),
            URLQueryItem(name: "strikes", value: "false")
        ])
        let (expData, expResp) = try await URLSession.shared.data(for: expReq)
        if let http = expResp as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw QuoteService.QuoteError.unauthorized }
            guard http.statusCode == 200 else { throw QuoteService.QuoteError.network }
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(secondsFromGMT: 0)

        var expirations: [Date] = []
        if let root = try? JSONDecoder().decode(TradierExpirationsRoot.self, from: expData) {
            let strings = root.expirations?.date ?? []
            expirations = strings.compactMap { df.date(from: $0) }.sorted()
        }

        // Determine which expiration to use
        var expToUseString: String? = nil
        if let expiration { expToUseString = df.string(from: expiration) }
        else if let first = expirations.first { expToUseString = df.string(from: first) }

        var callStrikes: [Double] = []
        var putStrikes: [Double] = []
        if let expStr = expToUseString {
            let chainReq = try makeRequest(path: "/v1/markets/options/chains", queryItems: [
                URLQueryItem(name: "symbol", value: trimmed.uppercased()),
                URLQueryItem(name: "expiration", value: expStr)
            ])
            let (chainData, chainResp) = try await URLSession.shared.data(for: chainReq)
            if let http = chainResp as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 { throw QuoteService.QuoteError.unauthorized }
                guard http.statusCode == 200 else { throw QuoteService.QuoteError.network }
            }
            do {
                let chain = try JSONDecoder().decode(TradierChainsRoot.self, from: chainData)
                let options = chain.options?.option ?? []
                let calls = Set(options.filter { ($0.option_type ?? "").lowercased() == "call" }.compactMap { $0.strike })
                let puts  = Set(options.filter { ($0.option_type ?? "").lowercased() == "put"  }.compactMap { $0.strike })
                callStrikes = calls.sorted()
                putStrikes  = puts.sorted()
            } catch is DecodingError {
                throw QuoteService.QuoteError.parse
            }
        }

        return OptionChainData(expirations: expirations, callStrikes: callStrikes, putStrikes: putStrikes)
    }

    /// Validate the current token by making a lightweight authorized request.
    /// Returns true if the token appears valid (HTTP 200), false otherwise.
    func validateToken() async -> Bool {
        do {
            let req = try makeRequest(path: "/v1/markets/quotes", queryItems: [
                URLQueryItem(name: "symbols", value: "AAPL"),
                URLQueryItem(name: "greeks", value: "false")
            ])
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    /// Convenience static helper to validate a token without constructing the provider elsewhere.
    static func validateToken(token: String, environment: Environment = .production) async -> Bool {
        let provider = TradierProvider(token: token, environment: environment)
        return await provider.validateToken()
    }
}

actor QuoteService {
    private let provider: QuoteDataProvider?

    init(provider: QuoteDataProvider? = nil) {
        self.provider = provider
    }

    enum QuoteError: Error, LocalizedError {
        case invalidSymbol
        case network
        case unauthorized
        case parse
        case noData

        var errorDescription: String? {
            switch self {
            case .invalidSymbol: return "Invalid symbol."
            case .network: return "Network error."
            case .unauthorized: return "Option chain unavailable (blocked by data source). Try again later or use manual strikes."
            case .parse: return "Failed to parse data."
            case .noData: return "No data available."
            }
        }
    }
    
    nonisolated private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        return request
    }

    nonisolated private func fetchPriceFromStooq(symbol: String) async throws -> Double {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteError.invalidSymbol }
        var s = trimmed.lowercased()
        if !s.contains(".") { s += ".us" }

        func numeric(_ v: String) -> Double? {
            let cleaned = v.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = cleaned.uppercased()
            if upper.isEmpty || upper == "N/D" || upper == "N/A" { return nil }
            return Double(cleaned)
        }

        func getPrice(from host: String) async -> Double? {
            let urlString = "\(host)/q/l/?s=\(s)&f=sd2t2ohlcv&h&e=csv"
            guard let url = URL(string: urlString) else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                guard let csv = String(data: data, encoding: .utf8) else { return nil }
                let lines = csv.split(separator: "\n").map(String.init)
                guard lines.count >= 2 else { return nil }
                let headers = lines[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let values  = lines[1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                func idx(_ name: String) -> Int? { headers.firstIndex(of: name) }
                var price: Double? = nil
                if let ci = idx("close"), ci < values.count { price = numeric(values[ci]) }
                if price == nil, let oi = idx("open"), oi < values.count { price = numeric(values[oi]) }
                return price
            } catch {
                return nil
            }
        }

        if let p = await getPrice(from: "https://stooq.com") { return p }
        if let p = await getPrice(from: "https://stooq.pl") { return p }
        throw QuoteError.noData
    }
    
    nonisolated private func fetchPriceFromYahooChart(symbol: String) async throws -> Double {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteError.invalidSymbol }
        var comps = URLComponents(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(trimmed.uppercased())")
        comps?.queryItems = [
            URLQueryItem(name: "range", value: "1d"),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US")
        ]
        guard let url = comps?.url else { throw QuoteError.invalidSymbol }
        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw QuoteError.unauthorized }
            guard http.statusCode == 200 else { throw QuoteError.network }
        }
        do {
            let decoded = try JSONDecoder().decode(YFChartRoot.self, from: data)
            if let result = decoded.chart.result?.first {
                if let p = result.meta?.regularMarketPrice { return p }
                if let closes = result.indicators?.quote?.first?.close?.compactMap({ $0 }), let last = closes.last { return last }
                if let prev = result.meta?.previousClose { return prev }
            }
            throw QuoteError.noData
        } catch is DecodingError {
            throw QuoteError.parse
        }
    }
    
    // MARK: - Public API

    func fetchDelayedPrice(symbol: String) async throws -> Double {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteError.invalidSymbol }

        // Try injected provider first
        if let provider {
            do {
                return try await provider.fetchDelayedPrice(symbol: trimmed)
            } catch {
                // fall back to Yahoo/Stooq
            }
        }

        var comps = URLComponents(string: "https://query2.finance.yahoo.com/v7/finance/quote")
        comps?.queryItems = [
            URLQueryItem(name: "symbols", value: trimmed.uppercased()),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US")
        ]
        guard let url = comps?.url else { throw QuoteError.invalidSymbol }

        // 1) Try Yahoo quote endpoint
         do {
            let request = makeRequest(url: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 { throw QuoteError.unauthorized }
                guard http.statusCode == 200 else { throw QuoteError.network }
            }
            let decoded = try JSONDecoder().decode(YFQuoteRoot.self, from: data)
            if let item = decoded.quoteResponse.result.first {
                if let p = item.regularMarketPrice
                    ?? item.postMarketPrice
                    ?? item.preMarketPrice
                    ?? item.regularMarketOpen
                    ?? item.regularMarketPreviousClose {
                    return p
                }
                if let bid = item.bid, let ask = item.ask, bid > 0, ask > 0 {
                    return (bid + ask) / 2.0
                }
            }
         } catch {
            // proceed to next fallback
         }

        // 2) Try Yahoo chart endpoint
         do {
            let p = try await fetchPriceFromYahooChart(symbol: trimmed)
            return p
         } catch {
            // proceed to next fallback
         }

        // 3) Fallback to Stooq CSV
         return try await fetchPriceFromStooq(symbol: trimmed)
    }

    func fetchOptionChain(symbol: String, expiration: Date? = nil) async throws -> OptionChainData {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuoteError.invalidSymbol }

        if let provider {
            do {
                return try await provider.fetchOptionChain(symbol: trimmed, expiration: expiration)
            } catch {
                // fall back to Yahoo Finance
            }
        }

        func parseChain(_ data: Data) throws -> (expirations: [Date], callStrikes: [Double], putStrikes: [Double]) {
            let decoded = try JSONDecoder().decode(YFOptionsRoot.self, from: data)
            guard let result = decoded.optionChain.result.first else {
                return ([], [], [])
            }
            let expirations: [Date] = (result.expirationDates ?? []).map { Date(timeIntervalSince1970: TimeInterval($0)) }.sorted()
            if let strikes = result.strikes, !strikes.isEmpty {
                let sorted = strikes.sorted()
                return (expirations, sorted, sorted)
            } else {
                let opts = result.options.first
                let callStrikes = (opts?.calls ?? []).compactMap { $0.strike?.raw ?? $0.strike?.double }.sorted()
                let putStrikes  = (opts?.puts  ?? []).compactMap { $0.strike?.raw ?? $0.strike?.double }.sorted()
                return (expirations, callStrikes, putStrikes)
            }
        }

        var components = URLComponents(string: "https://query2.finance.yahoo.com/v7/finance/options/\(trimmed.uppercased())")
        var qItems: [URLQueryItem] = [
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US")
        ]
        if let expiration {
            let unix = Int(expiration.timeIntervalSince1970)
            qItems.append(URLQueryItem(name: "date", value: String(unix)))
        }
        components?.queryItems = qItems
        guard let url = components?.url else { throw QuoteError.invalidSymbol }

        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw QuoteError.unauthorized }
            guard http.statusCode == 200 else { throw QuoteError.network }
        }

        do {
            let parsed = try parseChain(data)

            // If no specific expiration was requested and we got no strikes, try the nearest expiration explicitly.
            if expiration == nil && parsed.callStrikes.isEmpty && parsed.putStrikes.isEmpty, let firstExp = parsed.expirations.first {
                var c2 = URLComponents(string: "https://query2.finance.yahoo.com/v7/finance/options/\(trimmed.uppercased())")
                c2?.queryItems = [
                    URLQueryItem(name: "lang", value: "en-US"),
                    URLQueryItem(name: "region", value: "US"),
                    URLQueryItem(name: "date", value: String(Int(firstExp.timeIntervalSince1970)))
                ]
                if let url2 = c2?.url {
                    let req2 = makeRequest(url: url2)
                    let (data2, response2) = try await URLSession.shared.data(for: req2)
                    if let http2 = response2 as? HTTPURLResponse {
                        if http2.statusCode == 401 || http2.statusCode == 403 { throw QuoteError.unauthorized }
                        guard http2.statusCode == 200 else { throw QuoteError.network }
                    }
                    let parsed2 = try parseChain(data2)
                    let finalExpirations = parsed2.expirations.isEmpty ? parsed.expirations : parsed2.expirations
                    return OptionChainData(expirations: finalExpirations, callStrikes: parsed2.callStrikes, putStrikes: parsed2.putStrikes)
                }
            }

            // Return gracefully even if empty
            return OptionChainData(expirations: parsed.expirations, callStrikes: parsed.callStrikes, putStrikes: parsed.putStrikes)
        } catch is DecodingError {
            throw QuoteError.parse
        } catch {
            throw error
        }
    }
}

// MARK: - Yahoo Finance JSON models (minimal)

@preconcurrency private struct YFQuoteRoot: Decodable {
    let quoteResponse: YFQuoteResponse
}

@preconcurrency private struct YFQuoteResponse: Decodable {
    let result: [YFQuoteItem]
}

@preconcurrency private struct YFQuoteItem: Decodable {
    let regularMarketPrice: Double?
    let postMarketPrice: Double?
    let regularMarketOpen: Double?
    let regularMarketPreviousClose: Double?
    let preMarketPrice: Double?
    let bid: Double?
    let ask: Double?
}

@preconcurrency private struct YFOptionsRoot: Decodable {
    let optionChain: YFOptionChain
}

@preconcurrency private struct YFOptionChain: Decodable {
    let result: [YFChainResult]
}

@preconcurrency private struct YFChainResult: Decodable {
    let expirationDates: [Int]?
    let strikes: [Double]?
    let options: [YFChainOptions]
}

@preconcurrency private struct YFChainOptions: Decodable {
    let calls: [YFContract]?
    let puts: [YFContract]?
}

@preconcurrency private struct YFDoubleOrObject: Decodable {
    let raw: Double?
    let double: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            self.double = d
            self.raw = d
            return
        }
        if let obj = try? container.decode([String: Double].self), let r = obj["raw"] {
            self.raw = r
            self.double = r
            return
        }
        self.raw = nil
        self.double = nil
    }
}

@preconcurrency private struct YFContract: Decodable {
    let strike: YFDoubleOrObject?
}
@preconcurrency private struct YFChartRoot: Decodable {
    let chart: YFChart
}

@preconcurrency private struct YFChart: Decodable {
    let result: [YFChartResult]?
}

@preconcurrency private struct YFChartResult: Decodable {
    let meta: YFChartMeta?
    let indicators: YFChartIndicators?
}

@preconcurrency private struct YFChartMeta: Decodable {
    let regularMarketPrice: Double?
    let previousClose: Double?
}

@preconcurrency private struct YFChartIndicators: Decodable {
    let quote: [YFChartQuote]?
}

@preconcurrency private struct YFChartQuote: Decodable {
    let close: [Double?]?
}

// MARK: - Tradier JSON models (minimal)
@preconcurrency private struct TradierQuotesRoot: Decodable {
    let quotes: TradierQuotesInner?
}
@preconcurrency private struct TradierQuotesInner: Decodable {
    let quote: TradierQuoteEither
}

@preconcurrency private enum TradierQuoteEither: Decodable {
    case one(TradierQuote)
    case many([TradierQuote])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(TradierQuote.self) {
            self = .one(one)
            return
        }
        if let many = try? container.decode([TradierQuote].self) {
            self = .many(many)
            return
        }
        throw DecodingError.typeMismatch(TradierQuote.self, .init(codingPath: decoder.codingPath, debugDescription: "Unexpected quote shape"))
    }
}

@preconcurrency private struct TradierQuote: Decodable {
    let last: Double?
    let close: Double?
    let bid: Double?
    let ask: Double?
}

@preconcurrency private struct TradierExpirationsRoot: Decodable {
    let expirations: TradierExpirations?
}

@preconcurrency private struct TradierExpirations: Decodable {
    let date: [String]?
}

@preconcurrency private struct TradierChainsRoot: Decodable {
    let options: TradierOptions?
}

@preconcurrency private struct TradierOptions: Decodable {
    let option: [TradierOption]?
}

@preconcurrency private struct TradierOption: Decodable {
    let strike: Double?
    let option_type: String?
}

