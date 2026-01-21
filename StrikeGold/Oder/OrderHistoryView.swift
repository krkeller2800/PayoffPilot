import SwiftUI
import Combine

struct OrderHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var orders: [SavedOrder] = []
    @State private var showExpiringSoonOnly: Bool = false
    @State private var lastHeartbeat: Date? = nil
    @State private var monitoringStale: Bool = false
    @State private var nowTick: Date = Date()
#if DEBUG
    @State private var debugLogsEnabled: Bool = false
    private func dlog(_ message: @autoclosure () -> String) {
        if debugLogsEnabled { print(message()) }
    }
#endif

    private var totalNetPremium: Double {
        let multiplier = 100.0
        return filteredOrders.reduce(0.0) { sum, ord in
            guard ord.status == .filled, let fill = ord.fillPrice else { return sum }
            let isBuy = ord.side == .buy
            let filledQty = Double(ord.fillQuantity ?? ord.quantity)
            let gross = fill * filledQty * multiplier
            let signed = isBuy ? -gross : gross
            return sum + signed
        }
    }

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

    private func agoString(from date: Date?) -> String {
        guard let hb = date else { return "unknown" }
        let interval = Date().timeIntervalSince(hb)
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(fromTimeInterval: -abs(interval))
    }

    var body: some View {
        NavigationStack {
            List {
                Toggle(isOn: $showExpiringSoonOnly) {
                    ExpiringSoonToggleLabel()
                }
                if monitoringStale && orders.contains(where: { $0.status == .working }) {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Monitoring was inactive recently.").font(.footnote).bold()
                                let ago = agoString(from: lastHeartbeat)
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task {
                                    await OrderStore.shared.remove(id: order.id)
                                    let loaded = await OrderStore.shared.load()
                                    orders = loaded.sorted(by: { $0.placedAt > $1.placedAt })
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { idx in
                        Task {
                            let toDelete = idx.map { filteredOrders[$0].id }
                            for id in toDelete { await OrderStore.shared.remove(id: id) }
                            let loaded = await OrderStore.shared.load()
                            orders = loaded.sorted(by: { $0.placedAt > $1.placedAt })
                        }
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
            .refreshable {
                let loaded = await OrderStore.shared.load()
                await MainActor.run {
                    orders = loaded.sorted(by: { $0.placedAt > $1.placedAt })
                }
                refreshHeartbeat()
            }
            .navigationTitle("Orders")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                OrderStatusFooter(orders: orders, monitoringStale: monitoringStale, lastHeartbeat: lastHeartbeat, totalNetPremium: totalNetPremium)
            }
            .navigationDestination(for: SavedOrder.self) { order in
                OrderDetailView(order: order)
            }
        }
        .onAppear {
            Task {
                let loaded = await OrderStore.shared.load()
                orders = loaded.sorted(by: { $0.placedAt > $1.placedAt })
                refreshHeartbeat()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orderStoreDidChange)) { _ in
            Task {
                let loaded = await OrderStore.shared.load()
                orders = loaded.sorted(by: { $0.placedAt > $1.placedAt })
            }
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
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            nowTick = date
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshHeartbeat()
        }
#endif
    }
}

private struct ExpiringSoonToggleLabel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
//            Text("Expiring Soon")
            Text("Show only orders expiring in the next 14 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OrderStatusFooter: View {
    let orders: [SavedOrder]
    let monitoringStale: Bool
    let lastHeartbeat: Date?
    let totalNetPremium: Double

    @State private var pulse = false

    private func agoString(from date: Date?) -> String {
        guard let hb = date else { return "unknown" }
        let interval = Date().timeIntervalSince(hb)
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(fromTimeInterval: -abs(interval))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Status & P&L")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary).underline()
                HStack(spacing: 8) {
                    Text("Net Premium:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let absText = OptionsFormat.money(abs(totalNetPremium))
                    let valueText = (totalNetPremium >= 0 ? "+" : "-") + absText
                    let valueColor: Color = (totalNetPremium >= 0 ? .green : .red)
                    Text(valueText)
                        .font(.caption)
                        .foregroundStyle(valueColor)
                        .monospacedDigit()
                    Spacer()
                }
                if orders.contains(where: { $0.status == .working }) {
                    HStack(spacing: 6) {
                        Image(systemName: monitoringStale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(monitoringStale ? .yellow : .green)
                        Text(monitoringStale ? "Order Monitoring inactive recently." : "Order Monitoring active.")
                            .font(.footnote)
                            .scaleEffect(!monitoringStale && pulse ? 1.10 : 1.0)
                            .opacity(!monitoringStale && pulse ? 0.65 : 1.0)
                            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        if !monitoringStale {
                            pulse = true
                        }
                    }
                    .onChange(of: monitoringStale) { _, isStale in
                        // Start pulsing when active; stop when stale
                        if isStale {
                            pulse = false
                        } else {
                            pulse = true
                        }
                    }

                    let ago = agoString(from: lastHeartbeat)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text("Last check: \(ago)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text("Monitoring runs only while the app is active. To keep status current open the app periodically.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 16)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text("Monitoring runs only while the app is active. To keep status current open the app periodically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct OrderRow: View {
    let order: SavedOrder
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(order.symbol)  \(order.right.rawValue.uppercased())  \(OptionsFormat.number(order.strike))")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(order.side.rawValue.capitalized)  •  Qty \(order.quantity)  •  \(order.tif.rawValue)")
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
    
    @State private var showCloseSheet: Bool = false
    @State private var closeContract: OptionContract? = nil
    @State private var closeExpirations: [Date] = []
    @State private var isLoadingClose: Bool = false
    @State private var loadError: String? = nil

    @State private var marketBid: Double? = nil
    @State private var marketAsk: Double? = nil
    @State private var marketMid: Double? = nil
    @State private var underlyingPrice: Double? = nil
    @State private var showScenarioSheet = false

    private func oppositeSide(for side: String) -> PlaceOrderSheet.OrderSide {
        return side.lowercased() == "buy" ? .sell : .buy
    }

    private func loadCloseContract() {
        guard let exp = order.expiration else {
            loadError = "Missing expiration for this contract."
            return
        }
        isLoadingClose = true
        loadError = nil
        Task {
            do {
                let service = QuoteService()
                let data = try await service.fetchOptionChain(symbol: order.symbol, expiration: exp)
                let isCall = order.right == .call
                let candidates = isCall ? data.callContracts : data.putContracts
                if let c = candidates.first(where: { abs($0.strike - order.strike) < 0.0001 }) {
                    await MainActor.run {
                        self.closeContract = c
                        self.closeExpirations = data.expirations
                        self.showCloseSheet = true
                        self.isLoadingClose = false
                    }
                } else {
                    await MainActor.run {
                        self.loadError = "Could not find matching contract in the chain."
                        self.isLoadingClose = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoadingClose = false
                }
            }
        }
    }

    private func loadMarketQuotes() {
        guard let exp = order.expiration else { return }
        Task {
            do {
                let isCall = order.right == .call
                let (bid, ask, mid) = try await OrderMonitor.shared.fetchMarketReferences(symbol: order.symbol, expiration: exp, isCall: isCall, strike: order.strike)
                var underlying: Double? = nil
                // Try an underlying fetch if available; ignore if not supported
                if let u = try? await OrderMonitor.shared.fetchUnderlyingPrice(symbol: order.symbol) {
                    underlying = u
                }
                await MainActor.run {
                    self.marketBid = bid
                    self.marketAsk = ask
                    self.marketMid = mid
                    self.underlyingPrice = underlying
                }
            } catch {
                // Ignore errors for market quotes
            }
        }
    }

    @MainActor
    private func formatMoney(_ value: Double) -> String {
        return OptionsFormat.money(value)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Limit price and current option data
                let bidText = marketBid.map { formatMoney($0) } ?? "—"
                let askText = marketAsk.map { formatMoney($0) } ?? "—"
                let midComputed: Double? = {
                    if let b = marketBid, let a = marketAsk, b > 0, a > 0 { return (b + a) / 2 }
                    if let b = marketBid { return b }
                    if let a = marketAsk { return a }
                    return marketMid
                }()
                let midText = midComputed.map { formatMoney($0) } ?? "—"

                GroupBox("\(order.symbol)  \(order.right.rawValue.uppercased())  \(OptionsFormat.number(order.strike))") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Symbol", value: order.symbol)
                        LabeledContent("Right", value: order.right.rawValue.capitalized)
                        LabeledContent("Strike", value: OptionsFormat.number(order.strike))
                        LabeledContent("Side", value: order.side.rawValue.capitalized)
                        LabeledContent("Quantity", value: String(order.quantity))
                        LabeledContent("TIF", value: order.tif.rawValue)
                        if let exp = order.expiration {
                            LabeledContent("Expiration", value: exp.formatted(date: .abbreviated, time: .omitted))
                        }

                        if let lim = order.limit {
                            LabeledContent("Limit") {
                                Text(OptionsFormat.money(lim))
                                    .monospacedDigit()
                            }
                        } else {
                            LabeledContent("Limit") {
                                Text("—")
                            }
                            Text("A limit is required for auto-fill.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Current Prices") {
                            let underlyingText = underlyingPrice.map { formatMoney($0) } ?? "—"
                            Text("B \(bidText)  A \(askText)  M \(midText)  UL \(underlyingText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .allowsTightening(true)
                        }

                        let criteriaText = (order.side == .buy)
                        ? "Fills when ask ≤ limit (or mid ≤ limit)"
                        : "Fills when bid ≥ limit (or mid ≥ limit)"
                        LabeledContent("Fill criteria") {
                            Text(criteriaText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        // Position hint based on side (long/short) and option type, with expiration and "until" phrasing
                        let strikeText = OptionsFormat.number(order.strike)
                        let expirationSuffix: String = {
                            guard let exp = order.expiration else { return "" }
                            let preposition = (order.side == .buy) ? " until " : " before "
                            return "\(preposition)\(exp.formatted(date: .abbreviated, time: .omitted))"
                        }()
                        let hintText: String = {
                            switch (order.side, order.right) {
                            case (.buy, .call):
                                return "You have the right to buy \(order.symbol) at $\(strikeText)\(expirationSuffix)."
                            case (.buy, .put):
                                return "You have the right to sell \(order.symbol) at $\(strikeText)\(expirationSuffix)."
                            case (.sell, .call):
                                return "You may be obligated to sell \(order.symbol) at $\(strikeText) if assigned\(expirationSuffix)."
                            case (.sell, .put):
                                return "You may be obligated to buy \(order.symbol) at $\(strikeText) if assigned\(expirationSuffix)."
                            }
                        }()
                        Text(hintText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("State", value: order.status.rawValue.capitalized)
                        if let px = order.fillPrice { LabeledContent("Fill Price", value: OptionsFormat.money(px)) }
                        if let qty = order.fillQuantity { LabeledContent("Fill Qty", value: String(qty)) }
                        LabeledContent("Placed", value: order.placedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                GroupBox("Cash Flow & P/L") {
                    VStack(alignment: .leading, spacing: 8) {
                        // Net premium (so far) is the cash flow at fill time.
                        // Buy = debit (negative), Sell = credit (positive).
                        let multiplier = 100.0
                        let isBuy = order.side == .buy
                        let filledQty = Double(order.fillQuantity ?? order.quantity)

                        if let fill = order.fillPrice, order.status == .filled {
                            let gross = fill * filledQty * multiplier
                            let signed = isBuy ? -gross : gross

                            // Format with sign and color
                            let absText = OptionsFormat.money(abs(signed))
                            let valueText = (signed >= 0 ? "+" : "-") + absText
                            let valueColor: Color = (signed >= 0 ? .green : .red)

                            LabeledContent("Net Premium (so far)") {
                                Text(valueText)
                                    .foregroundStyle(valueColor)
                                    .monospacedDigit()
                            }

                            // Short, always-visible caveat
                            Text("This reflects cash received/paid when your order filled. Final profit or loss depends on how you close the position or what happens at expiration.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)

                            // Optional: expandable details
                            DisclosureGroup("How this is calculated") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("We compute net premium as:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("fill price × contracts × 100, with a positive sign for sell-to-open, negative for buy-to-open.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(nil)
                                    if let exp = order.expiration {
                                        Text("Because options can change in value until expiration (\(exp.formatted(date: .abbreviated, time: .omitted))), this is not your final P&L.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(nil)
                                    } else {
                                        Text("Because options can change in value until expiration, this is not your final P&L.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(nil)
                                    }
                                    Text("Note: Fees and commissions are not included.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(nil)
                                }
                                .padding(.top, 4)
                            }
                        } else if order.status == .working {
                            LabeledContent("Net Premium (so far)", value: "—")
                            Text("No fill yet. Your cash flow will be determined when the order fills.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Net Premium (so far)", value: "—")
                            Text("Order not filled. No cash flow occurred.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if order.status == .filled, let exp = order.expiration, exp >= Date() {
                    GroupBox("Actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(isLoadingClose ? "Loading…" : "Close Trade") {
                                loadCloseContract()
                            }
                            .disabled(isLoadingClose)
                            if let err = loadError {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                
                if order.status == .working {
                    GroupBox("Actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(role: .destructive) {
                                Task {
                                    await OrderStore.shared.update(id: order.id) { ord in
                                        ord.status = .canceled
                                    }
                                }
                            } label: {
                                Text("Cancel Order")
                            }
                        }
                    }
                }

                if let note = order.note, !order.note!.isEmpty {
                    GroupBox("Note") {
                        Text(note)
                    }
                }
            }
            .font(.subheadline)
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .navigationTitle("Summary")
//        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScenarioSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .imageScale(.small)
                        Text("Scenarios")
                    }                }
            }
        }
        .onAppear { loadMarketQuotes() }
        .onReceive(NotificationCenter.default.publisher(for: .orderMonitorHeartbeatDidUpdate)) { _ in
            loadMarketQuotes()
        }
        .sheet(isPresented: $showCloseSheet) {
            if let c = closeContract {
                let side = oppositeSide(for: order.side.rawValue)
                let qty = order.fillQuantity ?? order.quantity
                let initialLimit = c.mid ?? c.bid ?? c.ask ?? c.last

                PlaceOrderSheet(
                    contract: c,
                    prefilledSide: side,
                    initialQuantity: max(1, qty),
                    initialLimit: initialLimit,
                    expirations: closeExpirations,
                    preselectedExpiration: order.expiration
                ) { limit, tif, quantity, _ in
                    let new = SavedOrder(
                        id: UUID().uuidString,
                        placedAt: Date(),
                        symbol: order.symbol,
                        expiration: order.expiration,
                        right: order.right,
                        strike: order.strike,
                        side: SavedOrder.Side(rawValue: side.rawValue) ?? .buy,
                        quantity: quantity,
                        limit: limit,
                        tif: SavedOrder.TIF(rawValue: tif.rawValue) ?? .day,
                        status: .working,
                        fillPrice: nil,
                        fillQuantity: nil,
                        note: "Close of \(order.id.prefix(6))"
                    )
                    Task {
                        await OrderStore.shared.append(new)
                        await MainActor.run { showCloseSheet = false }
                    }
                } onCancel: {
                    showCloseSheet = false
                }
                .presentationDetents([.medium, .large])
            } else {
                Text("Unable to load contract to close.")
                    .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showScenarioSheet) {
            if let view = ScenarioSheetView(order: order, underlyingCenter: underlyingPrice, marketMid: marketMid) {
                view
                    .presentationDetents([.large, .large])
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Need more info to compute scenarios.")
                        .font(.headline)
                    Text("Provide a fill price or limit, or ensure a market mid is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
    }
}

