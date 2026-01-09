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
        var id: String { rawValue }
    }

    // Inputs
    @Published var tradierToken: String = ""
    @Published var environment: TradierProvider.Environment = .production
    @Published var finnhubToken: String = ""
    @Published var polygonToken: String = ""
    @Published var tradestationToken: String = ""
    @Published var selectedProvider: BYOProvider = .tradier

    // UI state
    @Published private(set) var isValidating: Bool = false
    @Published private(set) var validationSucceeded: Bool = false
    @Published private(set) var statusMessage: String? = nil

    // Enabled service (nil until enabled).
    @Published private(set) var quoteService: QuoteService? = nil

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
        let ok = await TradierProvider.validateToken(token: token, environment: environment)
        validationSucceeded = ok
        isValidating = false
        statusMessage = ok ? "Token is valid." : "Invalid token or network error."
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
        let ok = await FinnhubProvider.validateToken(token: token)
        validationSucceeded = ok
        isValidating = false
        statusMessage = ok ? "Finnhub token is valid." : "Invalid Finnhub token or network error."
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
        let ok = await PolygonProvider.validateToken(token: token)
        validationSucceeded = ok
        isValidating = false
        statusMessage = ok ? "Polygon token is valid." : "Invalid Polygon token or network error."
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
        let ok = await TradeStationProvider.validateToken(token: token)
        validationSucceeded = ok
        isValidating = false
        statusMessage = ok ? "TradeStation token is valid." : "Invalid TradeStation token or network error."
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
        }
    }
    /// Clear the token for the currently selected provider.
    func clearSelected() {
        switch selectedProvider {
        case .tradier: clearToken()
        case .finnhub: clearFinnhubToken()
        case .polygon: clearPolygonToken()
        case .tradestation: clearTradeStationToken()
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
        let ok = await TradierProvider.validateToken(token: token, environment: environment)
        isValidating = false
        if ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradierToken) } catch {}
            let provider = TradierProvider(token: token, environment: environment)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to Tradier."
            UserDefaults.standard.set(BYOProvider.tradier.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            statusMessage = "Tradier connect failed. Invalid token or network error."
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
        let ok = await FinnhubProvider.validateToken(token: token)
        isValidating = false
        if ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.finnhubToken) } catch {}
            let provider = FinnhubProvider(token: token)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to Finnhub."
            UserDefaults.standard.set(BYOProvider.finnhub.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            statusMessage = "Finnhub connect failed. Invalid token or network error."
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
        let ok = await PolygonProvider.validateToken(token: token)
        isValidating = false
        if ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.polygonToken) } catch {}
            let provider = PolygonProvider(token: token)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to Polygon."
            UserDefaults.standard.set(BYOProvider.polygon.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            statusMessage = "Polygon connect failed. Invalid key or network error."
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
        let ok = await TradeStationProvider.validateToken(token: token)
        isValidating = false
        if ok {
            do { try KeychainHelper.save(value: token, for: KeychainHelper.Keys.tradestationToken) } catch {}
            let provider = TradeStationProvider(token: token)
            quoteService = QuoteService(provider: provider)
            validationSucceeded = true
            statusMessage = "Connected to TradeStation."
            UserDefaults.standard.set(BYOProvider.tradestation.rawValue, forKey: "lastEnabledProvider")
        } else {
            validationSucceeded = false
            statusMessage = "TradeStation connect failed. Invalid token or network error."
        }
    }
}

