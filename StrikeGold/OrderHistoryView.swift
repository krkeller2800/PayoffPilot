import SwiftUI
import Combine

private extension Notification.Name {
    static let orderStoreDidChange = Notification.Name("OrderStoreDidChange")
    static let orderMonitorHeartbeatDidUpdate = Notification.Name("OrderMonitorHeartbeatDidUpdate")
}

struct OrderHistoryView: View {
    @State private var orders: [SavedOrder] = OrderStore.shared.load().sorted(by: { $0.placedAt > $1.placedAt })
    @State private var showExpiringSoonOnly: Bool = false
    @State private var lastHeartbeat: Date? = nil
    @State private var monitoringStale: Bool = false

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

    private func refreshHeartbeat() {
        Task {
            let hb = await OrderMonitor.shared.getLastHeartbeat()
            await MainActor.run {
                self.lastHeartbeat = hb
                let threshold: TimeInterval = 180 // 3 minutes
                if let hb = hb {
                    self.monitoringStale = Date().timeIntervalSince(hb) > threshold
                } else {
                    self.monitoringStale = true
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Toggle(isOn: $showExpiringSoonOnly) {
                    VStack(alignment: .leading, spacing: 2) {
//                        Text("Expiring Soon")
                        Text("Show only orders expiring in the next 14 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if monitoringStale && OrderStore.shared.load().contains(where: { $0.status == .working }) {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Monitoring was inactive recently.").font(.footnote).bold()
                                let ago: String = {
                                    guard let hb = lastHeartbeat else { return "unknown" }
                                    let interval = Date().timeIntervalSince(hb)
                                    let formatter = RelativeDateTimeFormatter()
                                    return formatter.localizedString(fromTimeInterval: -abs(interval))
                                }()
                                Text("Last check: \(ago)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
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
//                ToolbarItem(placement: .topBarLeading) {
//                    Toggle(isOn: $showExpiringSoonOnly) {
//                        Text("Expiring soon")
//                    }
//                    .toggleStyle(.switch)
//                }
            }
            .navigationDestination(for: SavedOrder.self) { order in
                OrderDetailView(order: order)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if !monitoringStale && OrderStore.shared.load().contains(where: { $0.status == .working }) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Order Monitoring active.").font(.footnote).bold()
                            }
                            let ago: String = {
                                guard let hb = lastHeartbeat else { return "unknown" }
                                let interval = Date().timeIntervalSince(hb)
                                let formatter = RelativeDateTimeFormatter()
                                return formatter.localizedString(fromTimeInterval: -abs(interval))
                            }()
                            Text("Last check: \(ago)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 30)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Monitoring runs only while the app is active. To keep status current open the app periodically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary).padding(.top,8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .onAppear {
            orders = OrderStore.shared.load().sorted(by: { $0.placedAt > $1.placedAt })
            refreshHeartbeat()
        }
        .onReceive(NotificationCenter.default.publisher(for: .orderStoreDidChange)) { _ in
            orders = OrderStore.shared.load().sorted(by: { $0.placedAt > $1.placedAt })
        }
        .onReceive(NotificationCenter.default.publisher(for: .orderMonitorHeartbeatDidUpdate)) { notification in
            let hb: Date? = {
                if let date = notification.object as? Date { return date }
                if let date = notification.userInfo?["date"] as? Date { return date }
                return nil
            }()
            lastHeartbeat = hb
            let threshold: TimeInterval = 180
            if let hb = hb {
                monitoringStale = Date().timeIntervalSince(hb) > threshold
            } else {
                monitoringStale = true
            }
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshHeartbeat()
        }
#endif
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

