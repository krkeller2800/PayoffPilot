//
//  SettingsViewModel.swift
//  PayoffPilot
//
//  Created by Assistant on 12/31/25.
//

import Foundation
import Combine

/// A tiny view model to coordinate saving, validating, and enabling a BYO-key Tradier provider.
/// Use from a Settings screen to let users paste a token, validate it, and enable data access.
@MainActor
final class SettingsViewModel: ObservableObject {
    // Inputs
    @Published var tradierToken: String = ""
    @Published var environment: TradierProvider.Environment = .production

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

    /// Remove the token from storage and disable the provider.
    func clearToken() {
        KeychainHelper.delete(key: KeychainHelper.Keys.tradierToken)
        tradierToken = ""
        validationSucceeded = false
        quoteService = nil
        statusMessage = "Token cleared."
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

    /// Create and publish a QuoteService configured with the validated Tradier provider.
    /// If validation hasn't been performed, this will optimistically enable; callers may choose to require `validationSucceeded == true` first.
    func enableProvider() {
        let token = tradierToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Cannot enable: token is empty."
            return
        }
        let provider = TradierProvider(token: token, environment: environment)
        quoteService = QuoteService(provider: provider)
        statusMessage = "Tradier provider enabled."
    }

    /// Disable the provider without clearing the saved token.
    func disableProvider() {
        quoteService = nil
        statusMessage = "Provider disabled."
    }
}

