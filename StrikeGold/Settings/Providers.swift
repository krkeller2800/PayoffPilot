import Foundation

public struct TokenValidationResult {
    public let ok: Bool
    public let statusCode: Int?
    public let errorDescription: String?

    public init(ok: Bool, statusCode: Int?, errorDescription: String?) {
        self.ok = ok
        self.statusCode = statusCode
        self.errorDescription = errorDescription
    }
}

public struct TradierProvider: QuoteDataProvider {
    public enum Environment {
        case production
        case sandbox

        var baseURL: URL {
            switch self {
            case .production:
                return URL(string: "https://api.tradier.com")!
            case .sandbox:
                return URL(string: "https://sandbox.tradier.com")!
            }
        }
    }

    public let token: String
    public let environment: Environment

    public init(token: String, environment: Environment = .production) {
        self.token = token
        self.environment = environment
    }

    public static func validateTokenDetailed(token: String, environment: Environment) async -> TokenValidationResult {
        let url = environment.baseURL.appendingPathComponent("/v1/markets/quotes")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "symbols", value: "AAPL")]

        guard let requestURL = components.url else {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid URL")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return TokenValidationResult(ok: true, statusCode: 200, errorDescription: nil)
                } else {
                    let body = String(data: data, encoding: .utf8)
                    return TokenValidationResult(ok: false, statusCode: httpResponse.statusCode, errorDescription: body)
                }
            } else {
                return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid response")
            }
        } catch {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: error.localizedDescription)
        }
    }

    func fetchDelayedPrice(symbol: String) async throws -> Double {
        // TODO: implement fetchDelayedPrice
        throw QuoteService.QuoteError.network
    }

    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        // TODO: implement fetchOptionChain
        throw QuoteService.QuoteError.network
    }
}

public struct FinnhubProvider: QuoteDataProvider {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public static func validateTokenDetailed(token: String) async -> TokenValidationResult {
        guard var components = URLComponents(string: "https://finnhub.io/api/v1/quote") else {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "symbol", value: "AAPL"),
            URLQueryItem(name: "token", value: token)
        ]

        guard let url = components.url else {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return TokenValidationResult(ok: true, statusCode: 200, errorDescription: nil)
                } else {
                    let body = String(data: data, encoding: .utf8)
                    return TokenValidationResult(ok: false, statusCode: httpResponse.statusCode, errorDescription: body)
                }
            } else {
                return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid response")
            }
        } catch {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: error.localizedDescription)
        }
    }

    func fetchDelayedPrice(symbol: String) async throws -> Double {
        // TODO: implement fetchDelayedPrice
        throw QuoteService.QuoteError.network
    }

    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        // TODO: implement fetchOptionChain
        throw QuoteService.QuoteError.network
    }
}

public struct PolygonProvider: QuoteDataProvider {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public static func validateTokenDetailed(token: String) async -> TokenValidationResult {
        guard var components = URLComponents(string: "https://api.polygon.io/v1/marketstatus/now") else {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "apiKey", value: token)
        ]

        guard let url = components.url else {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return TokenValidationResult(ok: true, statusCode: 200, errorDescription: nil)
                } else {
                    let body = String(data: data, encoding: .utf8)
                    return TokenValidationResult(ok: false, statusCode: httpResponse.statusCode, errorDescription: body)
                }
            } else {
                return TokenValidationResult(ok: false, statusCode: nil, errorDescription: "Invalid response")
            }
        } catch {
            return TokenValidationResult(ok: false, statusCode: nil, errorDescription: error.localizedDescription)
        }
    }

    func fetchDelayedPrice(symbol: String) async throws -> Double {
        // TODO: implement fetchDelayedPrice
        throw QuoteService.QuoteError.network
    }

    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        // TODO: implement fetchOptionChain
        throw QuoteService.QuoteError.network
    }
}

public struct TradeStationProvider: QuoteDataProvider {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public static func validateTokenDetailed(token: String) async -> TokenValidationResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !trimmed.isEmpty
        // Placeholder until real API is wired
        return TokenValidationResult(ok: ok, statusCode: nil, errorDescription: nil)
    }

    func fetchDelayedPrice(symbol: String) async throws -> Double {
        // TODO: implement fetchDelayedPrice
        throw QuoteService.QuoteError.network
    }

    func fetchOptionChain(symbol: String, expiration: Date) async throws -> OptionChainData {
        // TODO: implement fetchOptionChain
        throw QuoteService.QuoteError.network
    }
}
// Convenience bridge used by SettingsViewModel.validateAlpacaCredentials()
extension AlpacaProvider {
    func getLatestPrice(for symbol: String) async throws -> Double {
        return try await fetchDelayedPrice(symbol: symbol)
    }
}

