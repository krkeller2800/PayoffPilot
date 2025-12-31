//
//  SettingsView.swift
//  PayoffPilot
//
//  Created by Assistant on 12/31/25.
//

import SwiftUI

/// A simple Settings screen for managing a BYO-key Tradier provider.
/// Users can paste a token, validate it, and enable/disable the provider.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var showToken: Bool = false

    var body: some View {
        NavigationStack {
            Form {
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
                        Button(showToken ? "Hide" : "Show") {
                            showToken.toggle()
                        }
                        .buttonStyle(GradientAdButtonStyle(startColor: .gray, endColor: .blue))
                    }

                    Picker("Environment", selection: $viewModel.environment) {
                        Text("Production").tag(TradierProvider.Environment.production)
                        Text("Sandbox").tag(TradierProvider.Environment.sandbox)
                    }
                }

                Section("Actions") {
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Button("Save") { viewModel.saveToken() }
                                .buttonStyle(GradientAdButtonStyle())
                            Spacer()
                            Button(viewModel.isValidating ? "Validating…" : "Validate") {
                                Task { await viewModel.validateToken() }
                            }
                            .disabled(viewModel.isValidating)
                            .buttonStyle(GradientAdButtonStyle(startColor: .green, endColor: .mint))
                        }

                        GridRow {
                            Button("Enable") { viewModel.enableProvider() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .teal, endColor: .green))
                            Spacer()
                            Button("Disable") { viewModel.disableProvider() }
                                .buttonStyle(GradientAdButtonStyle(startColor: .orange, endColor: .red))
                            Spacer()
                            Button("Clear Token", role: .destructive) { viewModel.clearToken() }
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
                        Label(viewModel.quoteService == nil ? "Provider disabled" : "Provider enabled",
                              systemImage: viewModel.quoteService == nil ? "bolt.slash" : "bolt.fill")
                        .foregroundStyle(viewModel.quoteService == nil ? .secondary : Color.green)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}

