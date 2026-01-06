//
//  SettingsView.swift
//  PayoffPilot
//
//  Created by Assistant on 12/31/25.
//

import SwiftUI
import AuthenticationServices
import UIKit
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A simple Settings screen for managing a BYO-key Tradier provider.
/// Users can paste a token, validate it, and enable/disable the provider.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showToken: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var authInProgress: Bool = false
    @State private var authErrorMessage: String? = nil

    @State private var webAuthSession: ASWebAuthenticationSession? = nil
    @State private var pkceVerifier: String = ""
    @State private var authPresentationProvider = PresentationAnchorProvider()

    // Persisted settings
    @AppStorage("selectedProvider")
    private var selectedProviderRaw: String = SettingsViewModel.BYOProvider.tradier.rawValue

    @AppStorage("tradierEnvironment")
    private var tradierEnvironmentRaw: String = "production"

    // Bindings that bridge @AppStorage <-> ViewModel enums
    private var selectedProviderBinding: Binding<SettingsViewModel.BYOProvider> {
        Binding(
            get: { SettingsViewModel.BYOProvider(rawValue: selectedProviderRaw) ?? .tradier },
            set: { newValue in
                selectedProviderRaw = newValue.rawValue
                viewModel.selectedProvider = newValue
            }
        )
    }

    private var environmentBinding: Binding<TradierProvider.Environment> {
        Binding(
            get: { tradierEnvironmentRaw == "sandbox" ? .sandbox : .production },
            set: { newValue in
                tradierEnvironmentRaw = (newValue == .sandbox) ? "sandbox" : "production"
                viewModel.environment = newValue
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
//                Section("Provider") {
                    Picker("Provider", selection: selectedProviderBinding) {
                        ForEach(SettingsViewModel.BYOProvider.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
//                }

                if viewModel.selectedProvider == .tradier {
                    Section("Tradier (BYO key)") {
                        HStack(alignment: .firstTextBaseline) {
                            if showToken {
                                TextField("Paste OAuth token", text: $viewModel.tradierToken, axis: .vertical)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .lineLimit(1...4)
                            } else {
                                SecureField("Paste OAuth token", text: $viewModel.tradierToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .gray, endColor: .blue))
                        }

                        Picker("Environment", selection: environmentBinding) {
                            Text("Production").tag(TradierProvider.Environment.production)
                            Text("Sandbox").tag(TradierProvider.Environment.sandbox)
                        }
                        .pickerStyle(.segmented)
                        
                        HStack {
                            Button(authInProgress ? "Signing in…" : "Sign in with Tradier") {
                                startTradierSignIn()
                            }
                            .disabled(authInProgress)
                            .buttonStyle(GradientAdButtonStyle(startColor: .blue, endColor: .indigo))
                            Spacer()
                        }
                        Text("Use OAuth sign-in to retrieve an access token automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let authErrorMessage {
                            Text(authErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if viewModel.selectedProvider == .finnhub {
                    Section("Finnhub (BYO key)") {
                        HStack(alignment: .firstTextBaseline) {
                            if showToken {
                                TextField("Paste API token", text: $viewModel.finnhubToken, axis: .vertical)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .lineLimit(1...4)
                            } else {
                                SecureField("Paste API token", text: $viewModel.finnhubToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .gray, endColor: .blue))
                        }
                    }
                }

                if viewModel.selectedProvider == .polygon {
                    Section("Polygon (BYO key)") {
                        HStack(alignment: .firstTextBaseline) {
                            if showToken {
                                TextField("Paste API key", text: $viewModel.polygonToken, axis: .vertical)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .lineLimit(1...4)
                            } else {
                                SecureField("Paste API key", text: $viewModel.polygonToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .gray, endColor: .blue))
                        }
                    }
                }

                if viewModel.selectedProvider == .tradestation {
                    Section("TradeStation (BYO key)") {
                        HStack(alignment: .firstTextBaseline) {
                            if showToken {
                                TextField("Paste OAuth token", text: $viewModel.tradestationToken, axis: .vertical)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .lineLimit(1...4)
                            } else {
                                SecureField("Paste OAuth token", text: $viewModel.tradestationToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .gray, endColor: .blue))
                        }
                    }
                }

                Section("Actions") {
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Button("Save") { viewModel.saveSelected() }
                                .buttonStyle(GradientAdButtonStyle())
                            Spacer()
                            Button(viewModel.isValidating ? "Validating…" : "Validate") {
                                Task { await viewModel.validateSelected() }
                            }
                            .disabled(viewModel.isValidating)
                            .buttonStyle(GradientAdButtonStyle(startColor: .green, endColor: .mint))
                        }

                        GridRow {
                            Button("Enable") { viewModel.enableSelected() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .teal, endColor: .green))
                            Spacer()
                            Button("Disable") { viewModel.disableProvider() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .orange, endColor: .red))
                            Spacer()
                            Button("Clear Token", role: .destructive) { viewModel.clearSelected() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .red, endColor: .pink))
                        }
                    }
                }

                if let msg = viewModel.statusMessage, !msg.isEmpty {
                    Section("Status") {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("State") {
                    HStack {
                        Label(viewModel.validationSucceeded ? "Token validated" : "Not validated",
                              systemImage: viewModel.validationSucceeded ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(viewModel.validationSucceeded ? Color.green : .secondary)
                        Spacer()
                    }
                    HStack {
                        Label(viewModel.quoteService == nil ? "Provider disabled" : "Provider enabled (custom)",
                              systemImage: viewModel.quoteService == nil ? "bolt.slash" : "bolt.fill")
                        .foregroundStyle(viewModel.quoteService == nil ? .secondary : Color.green)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Ensure initial VM state matches persisted values
                viewModel.selectedProvider = SettingsViewModel.BYOProvider(rawValue: selectedProviderRaw) ?? .tradier
                viewModel.environment = (tradierEnvironmentRaw == "sandbox") ? .sandbox : .production
            }
        }
    }

    // MARK: - Tradier OAuth via ASWebAuthenticationSession
    private func startTradierSignIn() {
        // Replace the placeholders below with your actual values/configuration.
        // If you are using Authorization Code + PKCE, you would generate a codeVerifier/codeChallenge and later exchange the code for a token.
        // For simplicity, this example expects the provider to return an access_token in the callback URL (implicit-like flow). Adjust to your backend.

        // Client/app configuration
        let clientId = "YOUR_TRADIER_CLIENT_ID" // TODO: set your client ID
        let redirectScheme = "payoffpilot"       // e.g., your app URL scheme registered in Info.plist
        let redirectHost = "auth-callback"       // host/path component for callback
        let redirectURI = "\(redirectScheme)://\(redirectHost)"

        // Choose base URL by environment
        let isSandbox = (viewModel.environment == .sandbox)
        let authorizeBase = isSandbox ? "https://sandbox.tradier.com/oauth/authorize" : "https://api.tradier.com/oauth/authorize"

        // Scope depends on what you need. For quotes-only, read scope may suffice.
        let scope = "read"

        // Generate PKCE verifier & challenge
        let verifier = pkceCodeVerifier()
        self.pkceVerifier = verifier
        let challenge = pkceCodeChallenge(verifier: verifier)

        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]

        guard let authURL = comps.url, let callbackURLScheme = URL(string: redirectURI)?.scheme else {
            authErrorMessage = "Invalid OAuth configuration."
            return
        }

        authErrorMessage = nil
        authInProgress = true

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackURLScheme) { callbackURL, error in
            DispatchQueue.main.async {
                self.authInProgress = false
                if let error = error as? ASWebAuthenticationSessionError {
                    switch error.code {
                    case .canceledLogin:
                        self.authErrorMessage = "Sign-in canceled."
                    case .presentationContextInvalid:
                        self.authErrorMessage = "Unable to present sign-in. Please try again after the app is active."
                    case .presentationContextNotProvided:
                        self.authErrorMessage = "No presentation context available to show sign-in."
                    @unknown default:
                        self.authErrorMessage = error.localizedDescription
                    }
                    return
                } else if let error = error {
                    self.authErrorMessage = error.localizedDescription
                    return
                }
                guard let callbackURL = callbackURL else {
                    self.authErrorMessage = "No callback URL received."
                    return
                }
                handleTradierCallback(url: callbackURL)
            }
        }

        session.presentationContextProvider = authPresentationProvider

        session.prefersEphemeralWebBrowserSession = true
        self.webAuthSession = session
        _ = session.start()
    }

    private func handleTradierCallback(url: URL) {
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {
            // Exchange code for token
            exchangeTradierCodeForToken(code: code, redirectURI: "payoffpilot://auth-callback", verifier: pkceVerifier, isSandbox: (viewModel.environment == .sandbox))
        } else if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let errorDesc = comps.queryItems?.first(where: { $0.name == "error" })?.value {
            authErrorMessage = "Sign-in failed: \(errorDesc)"
        } else {
            authErrorMessage = "Unable to parse authentication response."
        }
    }

    private func exchangeTradierCodeForToken(code: String, redirectURI: String, verifier: String, isSandbox: Bool) {
        // NOTE: For production apps, keep client_secret on a secure backend. If Tradier requires client_secret, do not embed it in the app.
        let tokenURLString = isSandbox ? "https://sandbox.tradier.com/oauth/token" : "https://api.tradier.com/oauth/token"
        guard let tokenURL = URL(string: tokenURLString) else {
            self.authErrorMessage = "Invalid token URL"
            return
        }

        let clientId = "YOUR_TRADIER_CLIENT_ID" // TODO: set your client ID
        // If a client_secret is required, you should perform this exchange on your server.

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        let bodyItems: [URLQueryItem] = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        var bodyComps = URLComponents()
        bodyComps.queryItems = bodyItems
        request.httpBody = bodyComps.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        authInProgress = true
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode != 200 {
                    let msg = String(data: data, encoding: .utf8) ?? "(no body)"
                    await MainActor.run { self.authErrorMessage = "Token exchange failed (\(http.statusCode)). \(msg)"; self.authInProgress = false }
                    return
                }
                struct TokenResponse: Decodable { let access_token: String?; let token_type: String?; let expires_in: Int? }
                let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                guard let accessToken = token.access_token, !accessToken.isEmpty else {
                    await MainActor.run { self.authErrorMessage = "No access_token in response."; self.authInProgress = false }
                    return
                }
                // Save token to Keychain and update ViewModel
                try? KeychainHelper.save(value: accessToken, for: KeychainHelper.Keys.tradierToken)
                await MainActor.run {
                    self.viewModel.tradierToken = accessToken
                    self.authErrorMessage = nil
                    self.authInProgress = false
                }
            } catch {
                await MainActor.run { self.authErrorMessage = error.localizedDescription; self.authInProgress = false }
            }
        }
    }

    // MARK: - PKCE Utilities
    private func pkceCodeVerifier() -> String {
        // 43-128 chars, URL-safe
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var result = String()
        result.reserveCapacity(64)
        for _ in 0..<64 { result.append(chars.randomElement()!) }
        return result
    }

    private func pkceCodeChallenge(verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return verifier }
        var sha = sha256(data)
        let challenge = Data(bytes: &sha, count: sha.count).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return challenge
    }

    private func sha256(_ data: Data) -> [UInt8] {
        // Minimal SHA256 via CryptoKit if available; else fallback not provided.
        // Prefer CryptoKit in your project and import it at top if allowed.
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return Array(digest)
        #else
        // If CryptoKit is unavailable, this placeholder will break. Replace with CryptoKit or your own SHA256.
        fatalError("CryptoKit is required for PKCE sha256. Import CryptoKit.")
        #endif
    }

    // Helper to provide a presentation anchor
    private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            // Prefer a key window in a foreground active scene
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                return window
            }
            // Fallback to any visible window
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { !$0.isHidden }) {
                return window
            }
            return ASPresentationAnchor()
        }
    }
}

#Preview {
    SettingsView()
}

