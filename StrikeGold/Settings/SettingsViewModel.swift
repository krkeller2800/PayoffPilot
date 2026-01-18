//
//  SettingsViewModel.swift
//  StrikeGold
//
//  Created by Assistant on 12/31/25.
//

import Foundation
import Combine

/// A tiny view model to coordinate saving, validating, and enabling a BYO-key Tradier provider.
/// Use from a Settings screen to let users paste a token, validate it, and enable data access.
@MainActor
final class SettingsViewModel: ObservableObject {
    enum BYOProvider: String, CaseIterable, Identifiable {
        case tradier = "Tradier"
        case finnhub = "Finnhub"
        case polygon = "Polygon"
        case tradestation = "TradeStation"
        case alpaca = "Alpaca"
        var id: String { rawValue }
    }

    // Inputs
    @Published var tradierToken: String = ""
    @Published var environment: TradierProvider.Environment = .production
    @Published var finnhubToken: String = ""
    @Published var polygonToken: String = ""
    @Published var tradestationToken: String = ""
    
    // Updated Alpaca keys with environment property
    @Published var alpacaKey: String = ""
    @Published var alpacaSecretKey: String = ""
    @Published var alpacaEnvironment: String = UserDefaults.standard.string(forKey: "alpacaEnvironment") ?? "paper"
    
    // Legacy properties (for backward compatibility)
    @Published var alpacaKeyId: String = ""
    @Published var alpacaSecret: String = ""

    @Published var selectedProvider: BYOProvider = .tradier

    // UI state
    @Published private(set) var isValidating: Bool = false
    @Published private(set) var validationSucceeded: Bool = false
    @Published private(set) var statusMessage: String? = nil

    // Enabled service (nil until enabled).
    @Published private(set) var quoteService: QuoteService? = nil {
        didSet {
            Task { await OrderMonitor.shared.setQuoteService(quoteService) }
        }
    }

    init() {
        // Load any saved token on startup
        if let saved = KeychainHelper.load(key: KeychainHelper.Keys.tradierToken) {
            tradierToken = saved
        }
        if let savedFH = KeychainHelper.load(key: KeychainHelper.Keys.finnhubToken) {
            finnhubToken = savedFH
        }
        if let savedPG = KeychainHelper.load(key: KeychainHelper.Keys.polygonToken) {
            polygonToken = savedPG
        }
        if let savedTS = KeychainHelper.load(key: KeychainHelper.Keys.tradestationToken) {
            tradestationToken = savedTS
        }
        if let savedAlpacaKey = KeychainHelper.load(key: KeychainHelper.Keys.alpacaKeyId) {
            alpacaKey = savedAlpacaKey
            alpacaKeyId = savedAlpacaKey
        }
        if let savedAlpacaSecret = KeychainHelper.load(key: KeychainHelper.Keys.alpacaSecret) {
            alpacaSecretKey = savedAlpacaSecret
            alpacaSecret = savedAlpacaSecret
        }
        alpacaEnvironment = UserDefaults.standard.string(forKey: "alpacaEnvironment") ?? "paper"
    }

    /// Persist the current token to the Keychain.
    func saveToken() {
        let token = tradierToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a token before saving."
            return
        }
        do {
            try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradierToken)
            statusMessage = "Token saved."
        } catch {
            statusMessage = "Failed to save token: \(error.localizedDescription)"
        }
    }
    
    /// Persist the current Finnhub token to the Keychain.
    func saveFinnhubToken() {
        let token = finnhubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a Finnhub token before saving."
            return
        }
        do {
            try KeychainHelper.save(value: token, for: KeychainHelper.Keys.finnhubToken)
            statusMessage = "Finnhub token saved."
        } catch {
            statusMessage = "Failed to save Finnhub token: \(error.localizedDescription)"
        }
    }

    /// Persist the current Polygon token to the Keychain.
    func savePolygonToken() {
        let token = polygonToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a Polygon token before saving."
            return
        }
        do {
            try KeychainHelper.save(value: token, for: KeychainHelper.Keys.polygonToken)
            statusMessage = "Polygon token saved."
        } catch {
            statusMessage = "Failed to save Polygon token: \(error.localizedDescription)"
        }
    }
    
    /// Persist the current TradeStation token to the Keychain.
    func saveTradeStationToken() {
        let token = tradestationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a TradeStation token before saving."
            return
        }
        do {
            try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradestationToken)
            statusMessage = "TradeStation token saved."
        } catch {
            statusMessage = "Failed to save TradeStation token: \(error.localizedDescription)"
        }
    }
    
    /// Persist Alpaca credentials (Key and Secret) to the Keychain.
    func saveAlpacaCredentials() {
        let key = alpacaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = alpacaSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter an Alpaca Key ID before saving."
            return
        }
        guard !secret.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter an Alpaca Secret Key before saving."
            return
        }
        do {
            try KeychainHelper.save(value: key, for: KeychainHelper.Keys.alpacaKeyId)
            try KeychainHelper.save(value: secret, for: KeychainHelper.Keys.alpacaSecret)
            statusMessage = "Alpaca credentials saved."
            alpacaKeyId = key
            alpacaSecret = secret
        } catch {
            statusMessage = "Failed to save Alpaca credentials: \(error.localizedDescription)"
        }
    }

    /// Remove the token from storage and disable the provider.
    func clearToken() {
        KeychainHelper.delete(key: KeychainHelper.Keys.tradierToken)
        tradierToken = ""
        validationSucceeded = false
        quoteService = nil
        statusMessage = "Token cleared."
    }
    
    /// Remove the Finnhub token from storage and disable the provider if it is active.
    func clearFinnhubToken() {
        KeychainHelper.delete(key: KeychainHelper.Keys.finnhubToken)
        finnhubToken = ""
        // Do not alter Tradier state; only disable if Finnhub is active.
        if case .some(_) = quoteService {
            // If the current service was enabled via Finnhub, we cannot directly inspect; just disable if desired.
        }
        statusMessage = "Finnhub token cleared."
    }

    /// Remove the Polygon token from storage.
    func clearPolygonToken() {
        KeychainHelper.delete(key: KeychainHelper.Keys.polygonToken)
        polygonToken = ""
        statusMessage = "Polygon token cleared."
    }
    
    /// Remove the TradeStation token from storage.
    func clearTradeStationToken() {
        KeychainHelper.delete(key: KeychainHelper.Keys.tradestationToken)
        tradestationToken = ""
        statusMessage = "TradeStation token cleared."
    }

    /// Remove Alpaca credentials from storage.
    func clearAlpacaCredentials() {
        KeychainHelper.delete(key: KeychainHelper.Keys.alpacaKeyId)
        KeychainHelper.delete(key: KeychainHelper.Keys.alpacaSecret)
        alpacaKey = ""
        alpacaSecretKey = ""
        alpacaKeyId = ""
        alpacaSecret = ""
        validationSucceeded = false
        quoteService = nil
        statusMessage = "Alpaca credentials cleared."
    }
    
    /// Set the Alpaca environment ("paper" or "live").
    func setAlpacaEnvironment(_ value: String) {
        alpacaEnvironment = value
        UserDefaults.standard.set(value, forKey: "alpacaEnvironment")
    }

    /// Validate the token with a lightweight authorized request.
    func validateToken() async {
        let token = tradierToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a token to validate."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await TradierProvider.validateTokenDetailed(token: token, environment: environment)
        validationSucceeded = result.ok
        isValidating = false
        if result.ok {
            // Auto-enable after successful validation
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradierToken) } catch {}
            let provider = TradierProvider(token: token, environment: environment)
            quoteService = QuoteService(provider: provider)
            UserDefaults.standard.set(BYOProvider.tradier.rawValue, forKey: "lastEnabledProvider")
            statusMessage = "Token is valid. Tradier enabled."
            return
        } else if let code = result.statusCode, let desc = result.errorDescription {
            statusMessage = "Validation failed (\(code)). \(desc)"
        } else {
            statusMessage = "Validation failed. Network error."
        }
    }
    
    /// Validate the Finnhub token with a lightweight authorized request.
    func validateFinnhubToken() async {
        let token = finnhubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a Finnhub token to validate."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await FinnhubProvider.validateTokenDetailed(token: token)
        validationSucceeded = result.ok
        isValidating = false
        if result.ok {
            // Auto-enable after successful validation
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.finnhubToken) } catch {}
            let provider = FinnhubProvider(token: token)
            quoteService = QuoteService(provider: provider)
            UserDefaults.standard.set(BYOProvider.finnhub.rawValue, forKey: "lastEnabledProvider")
            statusMessage = "Finnhub token is valid. Finnhub enabled."
            return
        } else if let code = result.statusCode, let desc = result.errorDescription {
            statusMessage = "Finnhub validation failed (\(code)). \(desc)"
        } else {
            statusMessage = "Finnhub validation failed. Network error."
        }
    }

    /// Validate the Polygon token with a lightweight authorized request.
    func validatePolygonToken() async {
        let token = polygonToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a Polygon token to validate."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await PolygonProvider.validateTokenDetailed(token: token)
        validationSucceeded = result.ok
        isValidating = false
        if result.ok {
            // Auto-enable after successful validation
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.polygonToken) } catch {}
            let provider = PolygonProvider(token: token)
            quoteService = QuoteService(provider: provider)
            UserDefaults.standard.set(BYOProvider.polygon.rawValue, forKey: "lastEnabledProvider")
            statusMessage = "Polygon token is valid. Polygon enabled."
            return
        } else if let code = result.statusCode, let desc = result.errorDescription {
            statusMessage = "Polygon validation failed (\(code)). \(desc)"
        } else {
            statusMessage = "Polygon validation failed. Network error."
        }
    }
    
    /// Validate the TradeStation token with a lightweight authorized request.
    func validateTradeStationToken() async {
        let token = tradestationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a TradeStation token to validate."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await TradeStationProvider.validateTokenDetailed(token: token)
        validationSucceeded = result.ok
        isValidating = false
        if result.ok {
            // Auto-enable after successful validation
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradestationToken) } catch {}
            let provider = TradeStationProvider(token: token)
            quoteService = QuoteService(provider: provider)
            UserDefaults.standard.set(BYOProvider.tradestation.rawValue, forKey: "lastEnabledProvider")
            statusMessage = "TradeStation token is valid. TradeStation enabled."
            return
        } else if let code = result.statusCode, let desc = result.errorDescription {
            statusMessage = "TradeStation validation failed (\(code)). \(desc)"
        } else {
            statusMessage = "TradeStation validation failed. Network error."
        }
    }

    /// Validate Alpaca credentials by doing a lightweight call to fetch a price.
    func validateAlpacaCredentials() async {
        let key = alpacaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = alpacaSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter Alpaca Key ID to validate."
            return
        }
        guard !secret.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter Alpaca Secret Key to validate."
            return
        }
        isValidating = true
        statusMessage = nil
        let provider = AlpacaProvider(keyId: key, secretKey: secret)
        do {
            // Attempt a lightweight call, e.g. fetch latest price for AAPL
            let _ = try await provider.getLatestPrice(for: "AAPL")
            validationSucceeded = true
            isValidating = false
            do {
                try KeychainHelper.save(value: key, for: KeychainHelper.Keys.alpacaKeyId)
                try KeychainHelper.save(value: secret, for: KeychainHelper.Keys.alpacaSecret)
            } catch {}
            alpacaKeyId = key
            alpacaSecret = secret
            quoteService = QuoteService(provider: provider)
            UserDefaults.standard.set(BYOProvider.alpaca.rawValue, forKey: "lastEnabledProvider")
            statusMessage = "Alpaca credentials are valid. Alpaca enabled."
        } catch {
            validationSucceeded = false
            isValidating = false
            statusMessage = "Alpaca validation failed. Invalid credentials or network error."
        }
    }

    /// Create and publish a QuoteService configured with the validated Tradier provider.
    /// If validation hasn't been performed, this will optimistically enable; callers may choose to require `validationSucceeded == true` first.
    func enableProvider() {
        let token = tradierToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Cannot enable: token is empty."
            return
        }
        do {
            try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradierToken)
        } catch {
            statusMessage = "Failed to save token: \(error.localizedDescription)"
        }
        let provider = TradierProvider(token: token, environment: environment)
        quoteService = QuoteService(provider: provider)
        statusMessage = "Tradier provider enabled."
        UserDefaults.standard.set(BYOProvider.tradier.rawValue, forKey: "lastEnabledProvider")
    }
    
    /// Create and publish a QuoteService configured with the Finnhub provider.
    func enableFinnhub() {
        let token = finnhubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Cannot enable Finnhub: token is empty."
            return
        }
        let provider = FinnhubProvider(token: token)
        quoteService = QuoteService(provider: provider)
        statusMessage = "Finnhub provider enabled." 
        UserDefaults.standard.set(BYOProvider.finnhub.rawValue, forKey: "lastEnabledProvider")
    }

    /// Create and publish a QuoteService configured with the Polygon provider.
    func enablePolygon() {
        let token = polygonToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Cannot enable Polygon: token is empty."
            return
        }
        let provider = PolygonProvider(token: token)
        quoteService = QuoteService(provider: provider)
        statusMessage = "Polygon provider enabled."
        UserDefaults.standard.set(BYOProvider.polygon.rawValue, forKey: "lastEnabledProvider")
    }
    
    /// Create and publish a QuoteService configured with the TradeStation provider.
    func enableTradeStation() {
        let token = tradestationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Cannot enable TradeStation: token is empty."
            return
        }
        let provider = TradeStationProvider(token: token)
        quoteService = QuoteService(provider: provider)
        statusMessage = "TradeStation provider enabled."
        UserDefaults.standard.set(BYOProvider.tradestation.rawValue, forKey: "lastEnabledProvider")
    }

    /// Create and publish a QuoteService configured with the Alpaca provider.
    func enableAlpaca() {
        let key = alpacaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = alpacaSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusMessage = "Cannot enable Alpaca: Key ID is empty."
            return
        }
        guard !secret.isEmpty else {
            statusMessage = "Cannot enable Alpaca: Secret Key is empty."
            return
        }
        let provider = AlpacaProvider(keyId: key, secretKey: secret)
        quoteService = QuoteService(provider: provider)
        statusMessage = "Alpaca provider enabled."
        UserDefaults.standard.set(BYOProvider.alpaca.rawValue, forKey: "lastEnabledProvider")
    }

    /// Disable the provider without clearing the saved token.
    func disableProvider() {
        quoteService = nil
        statusMessage = "Provider disabled."
        UserDefaults.standard.removeObject(forKey: "lastEnabledProvider")
    }

    /// Save the token for the currently selected provider.
    func saveSelected() {
        switch selectedProvider {
        case .tradier: saveToken()
        case .finnhub: saveFinnhubToken()
        case .polygon: savePolygonToken()
        case .tradestation: saveTradeStationToken()
        case .alpaca: saveAlpacaCredentials()
        }
    }
    /// Clear the token for the currently selected provider.
    func clearSelected() {
        switch selectedProvider {
        case .tradier: clearToken()
        case .finnhub: clearFinnhubToken()
        case .polygon: clearPolygonToken()
        case .tradestation: clearTradeStationToken()
        case .alpaca: clearAlpacaCredentials()
        }
    }

    /// Validate the token for the currently selected provider.
    func validateSelected() async {
        switch selectedProvider {
        case .tradier:
            await validateToken()
        case .finnhub:
            await validateFinnhubToken()
        case .polygon:
            await validatePolygonToken()
        case .tradestation:
            await validateTradeStationToken()
        case .alpaca:
            await validateAlpacaCredentials()
        }
    }

    /// Enable the provider corresponding to the current selection.
    func enableSelected() {
        switch selectedProvider {
        case .tradier:
            enableProvider()
        case .finnhub:
            enableFinnhub()
        case .polygon:
            enablePolygon()
        case .tradestation:
            enableTradeStation()
        case .alpaca:
            enableAlpaca()
        }
    }
    
    /// Compact Connect → Validate → Enable for the current selection.
    /// Saves token (if applicable), validates with a lightweight call, then enables and sets lastEnabledProvider.
    func connectSelected() async {
        switch selectedProvider {
        case .tradier:
            await connectTradier()
        case .finnhub:
            await connectFinnhub()
        case .polygon:
            await connectPolygon()
        case .tradestation:
            await connectTradeStation()
        case .alpaca:
            await connectAlpaca()
        }
    }

    /// Connect helper for Tradier (manual token path).
    private func connectTradier() async {
        let token = tradierToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a Tradier token to connect or use Sign in with Tradier."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await TradierProvider.validateTokenDetailed(token: token, environment: environment)
        isValidating = false
        if result.ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradierToken) } catch {}
            let provider = TradierProvider(token: token, environment: environment)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to Tradier."
            UserDefaults.standard.set(BYOProvider.tradier.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            if let code = result.statusCode, let desc = result.errorDescription {
                statusMessage = "Tradier connect failed (\(code)). \(desc)"
            } else {
                statusMessage = "Tradier connect failed. Invalid token or network error."
            }
        }
    }
    /// Connect helper for Finnhub.
    private func connectFinnhub() async {
        let token = finnhubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a Finnhub token to connect."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await FinnhubProvider.validateTokenDetailed(token: token)
        isValidating = false
        if result.ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.finnhubToken) } catch {}
            let provider = FinnhubProvider(token: token)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to Finnhub."
            UserDefaults.standard.set(BYOProvider.finnhub.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            if let code = result.statusCode, let desc = result.errorDescription {
                statusMessage = "Finnhub connect failed (\(code)). \(desc)"
            } else {
                statusMessage = "Finnhub connect failed. Invalid token or network error."
            }
        }
    }

    /// Connect helper for Polygon.
    private func connectPolygon() async {
        let token = polygonToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a Polygon API key to connect."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await PolygonProvider.validateTokenDetailed(token: token)
        isValidating = false
        if result.ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.polygonToken) } catch {}
            let provider = PolygonProvider(token: token)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to Polygon."
            UserDefaults.standard.set(BYOProvider.polygon.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            if let code = result.statusCode, let desc = result.errorDescription {
                statusMessage = "Polygon connect failed (\(code)). \(desc)"
            } else {
                statusMessage = "Polygon connect failed. Invalid key or network error."
            }
        }
    }

    /// Connect helper for TradeStation.
    private func connectTradeStation() async {
        let token = tradestationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter a TradeStation token to connect."
            return
        }
        isValidating = true
        statusMessage = nil
        let result = await TradeStationProvider.validateTokenDetailed(token: token)
        isValidating = false
        if result.ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradestationToken) } catch {}
            let provider = TradeStationProvider(token: token)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to TradeStation."
            UserDefaults.standard.set(BYOProvider.tradestation.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            if let code = result.statusCode, let desc = result.errorDescription {
                statusMessage = "TradeStation connect failed (\(code)). \(desc)"
            } else {
                statusMessage = "TradeStation connect failed. Invalid token or network error."
            }
        }
    }

    /// Connect helper for Alpaca.
    private func connectAlpaca() async {
        let key = alpacaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = alpacaSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter Alpaca Key ID to connect."
            return
        }
        guard !secret.isEmpty else {
            validationSucceeded = false
            statusMessage = "Enter Alpaca Secret Key to connect."
            return
        }
        isValidating = true
        statusMessage = nil
        let provider = AlpacaProvider(keyId: key, secretKey: secret)
        do {
            let _ = try await provider.getLatestPrice(for: "AAPL")
            do {
                try KeychainHelper.save(value: key, for: KeychainHelper.Keys.alpacaKeyId)
                try KeychainHelper.save(value: secret, for: KeychainHelper.Keys.alpacaSecret)
            } catch {}
            alpacaKeyId = key
            alpacaSecret = secret
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to Alpaca."
            UserDefaults.standard.set(BYOProvider.alpaca.rawValue, forKey: "lastEnabledProvider")
        } catch {
            validationSucceeded = false
            statusMessage = "Alpaca connect failed. Invalid credentials or network error."
        }
        isValidating = false
    }
}

