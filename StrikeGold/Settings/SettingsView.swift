//
//  SettingsView.swift
//  StrikeGold
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
    @State private var showAdvanced: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var authInProgress: Bool = false
    @State private var authErrorMessage: String? = nil
    @State private var diagRunning: Bool = false
    @State private var diagMessage: String? = nil
    @State private var diagSymbol: String = "AAPL"

    @State private var webAuthSession: ASWebAuthenticationSession? = nil
    @State private var pkceVerifier: String = ""
    private let authPresentationProvider = PresentationAnchorProvider()

#if DEBUG
    @State private var debugLogsEnabled: Bool = false
    private func dlog(_ message: @autoclosure () -> String) {
        if debugLogsEnabled { print(message()) }
    }
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Manual input") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Manual input")
                            .font(.headline)
                        if viewModel.isAlpacaActive {
                            Text("Alpaca is connected. You can switch back to manual mode.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Reset to Manual") {
                                viewModel.enableManual()
                            }
                            .buttonStyle(GradientAdButtonStyle(startColor: .teal, endColor: .green))
                        } else {
                            Text("Manual is the default. No setup required.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section("Manual Data") {
                    NavigationLink(destination: ManualDataEditorView()) {
                        Label("Edit Manual Data", systemImage: "pencil.and.list.clipboard")
                    }
                }

                Section("Alpaca (optional)") {
                    VStack(alignment: .leading, spacing: 8) {
//                        Text("Bring your own Alpaca Market Data key if you want automatic quotes as a backup to manual inputs.")
//                            .font(.caption)
//                            .foregroundStyle(.secondary)
                        DisclosureGroup("Why we use Alpaca") {
                            Text("We don’t receive compensation or referral fees. Among mainstream providers, Alpaca is the only one that permits free distribution of options data for apps like ours. To stay compliant, StrikeGold supports Alpaca (bring your own keys) for automatic option chains and quotes. Manual mode remains fully available.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                        
                        HStack(alignment: .top, spacing: 6) {
                           
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("To get real option data (option chains and quotes), you'll need an Alpaca account. Paste your API keys here after you sign up.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Link("Open an Alpaca account", destination: URL(string: "https://alpaca.markets/")!)
                                    .font(.caption2)
                            }
                        }
                        HStack(alignment: .firstTextBaseline) {
                            TextField("API Key ID", text: $viewModel.alpacaKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Paste") {
                                if let s = UIPasteboard.general.string { viewModel.alpacaKey = s }
                            }
                            .buttonStyle(GradientAdButtonStyle(startColor: .gray, endColor: .blue))
                        }
                        HStack(alignment: .firstTextBaseline) {
                            SecureField("API Secret Key", text: $viewModel.alpacaSecretKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Paste") {
                                if let s = UIPasteboard.general.string { viewModel.alpacaSecretKey = s }
                            }
                            .buttonStyle(GradientAdButtonStyle(startColor: .gray, endColor: .blue))
                        }
                        Picker("Environment", selection: Binding(
                            get: { viewModel.alpacaEnvironment },
                            set: { viewModel.setAlpacaEnvironment($0) }
                        )) {
                            Text("Paper").tag("paper")
                            Text("Live").tag("live")
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Button(viewModel.isValidating ? "Connecting…" : "Connect") {
                                Task { await viewModel.connectAlpaca() }
                            }
                            .disabled(viewModel.isValidating)
                            .buttonStyle(GradientAdButtonStyle(startColor: .teal, endColor: .green))
                            Spacer()
                            Button("Clear Credentials", role: .destructive) { viewModel.clearAlpacaCredentials() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .red, endColor: .pink))
                        }
                        if let msg = viewModel.statusMessage, !msg.isEmpty {
                            let looksLikeError = msg.localizedCaseInsensitiveContains("fail") ||
                                                 msg.localizedCaseInsensitiveContains("error") ||
                                                 msg.localizedCaseInsensitiveContains("invalid") ||
                                                 msg.localizedCaseInsensitiveContains("unauthor") ||
                                                 msg.localizedCaseInsensitiveContains("denied")
                            if looksLikeError {
                                let display: String = {
                                    if let name = viewModel.activeProviderName,
                                       !msg.localizedCaseInsensitiveContains(name) {
                                        return "\(name): \(msg)"
                                    }
                                    return msg
                                }()
                                Text(display)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                Section("State") {
                    HStack {
                        let providerName = viewModel.activeProviderName
                        let isManual = (viewModel.activeProvider == .manual)
                        let hasCreds = viewModel.activeProvider.flatMap { viewModel.hasStoredCredentials(for: $0) } ?? false
                        let validated = viewModel.isProviderEnabled && (isManual || viewModel.validationSucceeded || hasCreds)
                        let title: String = {
                            if validated {
                                if let name = providerName { return "\(name) validated" }
                                return "Validated"
                            } else {
                                if let name = providerName { return "\(name) not validated" }
                                return "Not validated"
                            }
                        }()
                        Label(title, systemImage: validated ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(validated ? Color.green : .secondary)
                        Spacer()
                    }
                    HStack {
                        Label(viewModel.isProviderEnabled ? "\(viewModel.activeProviderName ?? "Provider") enabled" : "Provider disabled",
                              systemImage: viewModel.isProviderEnabled ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(viewModel.isProviderEnabled ? Color.green : .secondary)
                        Spacer()
                    }
                }
#if DEBUG
                Section("Debug") {
                    Toggle(isOn: $debugLogsEnabled) {
                        Label("Debug Logs", systemImage: debugLogsEnabled ? "ladybug.fill" : "ladybug")
                    }
                }
#endif
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // Lazily create and start ASWebAuthenticationSession when needed.
    @MainActor
    private func startWebAuth(url: URL, callbackScheme: String, prefersEphemeral: Bool = true) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            Task { @MainActor in
                // Clear the session reference when complete
                self.webAuthSession = nil
                // Optionally surface an error message
                if let error = error {
                    self.authErrorMessage = error.localizedDescription
                } else {
                    self.authErrorMessage = nil
                }
            }
        }
        session.presentationContextProvider = authPresentationProvider
        session.prefersEphemeralWebBrowserSession = prefersEphemeral
        // Keep a strong reference for the duration of the flow
        self.webAuthSession = session
        _ = session.start()
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

