import SwiftUI

struct OrderHistoryView: View {
    @State private var orders: [SavedOrder] = OrderStore.shared.load().sorted(by: { $0.placedAt > $1.placedAt })
    @State private var showExpiringSoonOnly: Bool = false

    private var filteredOrders: [SavedOrder] {
        guard showExpiringSoonOnly else { return orders }
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        return orders.filter { ord in
            if let exp = ord.expiration {
                return exp >= now && exp <= horizon
            }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredOrders.isEmpty {
                    Section {
                        Text("No orders yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(filteredOrders) { order in
                        NavigationLink(value: order) {
                            OrderRow(order: order)
                        }
                    }
                    .onDelete { idx in
                        // Map deletions from filtered view to actual orders
                        let toDelete = idx.map { filteredOrders[$0].id }
                        for id in toDelete { OrderStore.shared.remove(id: id) }
                        orders = OrderStore.shared.load().sorted(by: { $0.placedAt > $1.placedAt })
                    }
                }
            }
            .navigationTitle("Orders")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle(isOn: $showExpiringSoonOnly) {
                        Text("Expiring soon")
                    }
                    .toggleStyle(.switch)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        orders = OrderStore.shared.load().sorted(by: { $0.placedAt > $1.placedAt })
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .navigationDestination(for: SavedOrder.self) { order in
                OrderDetailView(order: order)
            }
        }
        .onAppear {
            orders = OrderStore.shared.load().sorted(by: { $0.placedAt > $1.placedAt })
        }
    }
}

private struct OrderRow: View {
    let order: SavedOrder
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(order.symbol)  \(order.right.uppercased())  \(OptionsFormat.number(order.strike))")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(order.side.capitalized)  •  Qty \(order.quantity)  •  \(order.tif)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(order.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(order.placedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch order.status {
        case .working: return .orange
        case .filled: return .green
        case .failed: return .red
        case .canceled: return .secondary
        }
    }
}

private struct OrderDetailView: View {
    let order: SavedOrder
    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Symbol", value: order.symbol)
                LabeledContent("Right", value: order.right.capitalized)
                LabeledContent("Strike", value: OptionsFormat.number(order.strike))
                LabeledContent("Side", value: order.side.capitalized)
                LabeledContent("Quantity", value: String(order.quantity))
                LabeledContent("TIF", value: order.tif)
                if let exp = order.expiration {
                    LabeledContent("Expiration", value: exp.formatted(date: .abbreviated, time: .omitted))
                }
            }
            Section("Status") {
                LabeledContent("State", value: order.status.rawValue.capitalized)
                if let px = order.fillPrice { LabeledContent("Fill Price", value: OptionsFormat.money(px)) }
                if let qty = order.fillQuantity { LabeledContent("Fill Qty", value: String(qty)) }
                LabeledContent("Placed", value: order.placedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let note = order.note, !note.isEmpty {
                Section("Note") { Text(note) }
            }
        }
        .navigationTitle("Order \(order.id)")
    }
}
