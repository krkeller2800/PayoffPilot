import SwiftUI

struct PlaceOrderSheet: View {
    enum OrderSide: String, CaseIterable, Identifiable {
        case buy, sell
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
        var systemImage: String { self == .buy ? "arrow.up.circle" : "arrow.down.circle" }
        var tint: Color { self == .buy ? .green : .red }
    }

    enum TimeInForce: String, CaseIterable, Identifiable {
        case day = "DAY"
        case gtc = "GTC"
        var id: String { rawValue }
        var displayName: String { self == .day ? "Day" : "GTC" }
    }

    let contract: OptionContract
    let prefilledSide: OrderSide
    let initialQuantity: Int
    let initialLimit: Double?
    let expirations: [Date]
    let preselectedExpiration: Date?
    let onConfirm: (Double, TimeInForce, Int, Date?) -> Void
    let onCancel: () -> Void

    // State
    @State private var limitText: String
    @State private var tif: TimeInForce = .day
    @State private var quantity: Int
    @State private var side: OrderSide
    @State private var note: String = ""
    @State private var selectedExpiration: Date?

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "America/New_York")
        df.dateFormat = "MMM d, yyyy"
        return df
    }()

    init(
        contract: OptionContract,
        prefilledSide: OrderSide,
        initialQuantity: Int,
        initialLimit: Double?,
        expirations: [Date],
        preselectedExpiration: Date?,
        onConfirm: @escaping (Double, TimeInForce, Int, Date?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.contract = contract
        self.prefilledSide = prefilledSide
        self.initialQuantity = initialQuantity
        self.initialLimit = initialLimit
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.expirations = expirations
        self.preselectedExpiration = preselectedExpiration

        _quantity = State(initialValue: initialQuantity)
        _limitText = State(initialValue: initialLimit.map(OptionsFormat.number) ?? "")
        _side = State(initialValue: prefilledSide)
        _selectedExpiration = State(initialValue: preselectedExpiration)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Summary") {
                    // Read-only combined summary: Expiration • Strike • Price
                    let expText: String = {
                        if let sel = selectedExpiration {
                            return Self.dateFormatter.string(from: sel)
                        }
                        return expirationText() ?? "—"
                    }()
                    HStack {
                        Text(expText)
                        Spacer()
                        Text("\(strikeText()) • \(displayedPriceText())")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onCancel()
                    } label: {
                        Label("Edit in Chain", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)

                    Text("To change expiration or contract, edit in the Option Chain.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("Contract") {
                    HStack {
                        Text(contractRightText())
                        Spacer()
                        Text(strikeText())
                            .monospacedDigit()
                    }
                    if let exp = expirationText(), !exp.isEmpty {
                        LabeledContent("Expiration", value: exp)
                    }
                }

                Section("Order") {
                    Picker("Side", selection: $side) {
                        ForEach(OrderSide.allCases) { s in
                            Label(s.displayName, systemImage: s.systemImage)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(s.tint)
                                .tag(s)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $quantity, in: 1...50) {
                        LabeledContent("Quantity") { Text("\(quantity)") }
                    }

                    TextField("Limit Price", text: $limitText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)

                    Picker("Time in Force", selection: $tif) {
                        ForEach(TimeInForce.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notes (optional)") {
                    TextField("Add a note for this order", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .navigationTitle("Place Order")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmTitle) {
                        guard let limit = Double(limitText) else { return }
                        // Use current sheet state for side/qty/limit/TIF and selected expiration.
                        onConfirm(limit, tif, quantity, selectedExpiration)
                    }
                    .disabled(Double(limitText) == nil)
                    .tint(side.tint)
                }
            }
        }
    }

    private var confirmTitle: String {
        let action = side == .buy ? "Buy" : "Sell"
        return "\(action) \(quantity)"
    }

    // Safe dynamic lookup using Mirror (avoids KVC on pure Swift types)
    private func value<T>(for key: String, in object: Any) -> T? {
        let mirror = Mirror(reflecting: object)
        for child in mirror.children {
            if let label = child.label, label == key {
                return child.value as? T
            }
        }
        return nil
    }

    private func contractRightText() -> String {
        if let rightStr: String = value(for: "right", in: contract) {
            return rightStr.capitalized
        }
        if let anyRR: any RawRepresentable = value(for: "right", in: contract),
           let raw = anyRR.rawValue as? String {
            return raw.capitalized
        }
        // Fallback to OptionContract.Kind if present
        if let kindRR: any RawRepresentable = value(for: "kind", in: contract),
           let raw = kindRR.rawValue as? String {
            return raw.capitalized
        }
        return ""
    }

    private func strikeText() -> String {
        if let strike: Double = value(for: "strike", in: contract) {
            return OptionsFormat.number(strike)
        }
        return ""
    }

    private func expirationText() -> String? {
        if let date: Date = value(for: "expiration", in: contract) {
            return Self.dateFormatter.string(from: date)
        }
        return nil
    }

    private func displayedPriceText() -> String {
        let price: Double? = {
            switch side {
            case .buy:
                return contract.ask ?? contract.mid ?? contract.last
            case .sell:
                return contract.bid ?? contract.mid ?? contract.last
            }
        }()
        if let p = price { return OptionsFormat.number(p) }
        return "—"
    }
}

