import Foundation

struct SavedOrder: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case working
        case filled
        case failed
        case canceled
    }
    
    enum Right: String, Codable, Hashable, CaseIterable {
        case call = "call"
        case put = "put"
    }
    
    enum Side: String, Codable, Hashable, CaseIterable {
        case buy = "buy"
        case sell = "sell"
    }
    
    enum TIF: String, Codable, Hashable, CaseIterable {
        case day = "DAY"
        case gtc = "GTC"
    }

    var id: String
    var placedAt: Date
    var symbol: String
    var expiration: Date?
    var right: Right
    var strike: Double
    var side: Side
    var quantity: Int
    var limit: Double?
    var tif: TIF
    var status: Status
    var fillPrice: Double?
    var fillQuantity: Int?
    var note: String?
}

actor OrderStore {
    static let shared = OrderStore()
    private let key = "saved_orders_v1"
    static let didChange = Notification.Name("OrderStore.orderStoreDidChange")

    func load() -> [SavedOrder] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedOrder].self, from: data)) ?? []
    }

    func save(_ orders: [SavedOrder]) {
        if let data = try? JSONEncoder().encode(orders) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func append(_ order: SavedOrder) {
        var all = load()
        if let idx = all.firstIndex(where: { $0.id == order.id }) {
            all[idx] = order
        } else {
            all.append(order)
        }
        save(all)
        Task { @MainActor in
            NotificationCenter.default.post(name: OrderStore.didChange, object: nil)
        }
    }

    func update(id: String, mutate: (inout SavedOrder) -> Void) {
        var all = load()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            mutate(&all[idx])
            save(all)
            Task { @MainActor in
                NotificationCenter.default.post(name: OrderStore.didChange, object: nil)
            }
        }
    }

    func remove(id: String) {
        var all = load()
        all.removeAll { $0.id == id }
        save(all)
        Task { @MainActor in
            NotificationCenter.default.post(name: OrderStore.didChange, object: nil)
        }
    }

    func clear() {
        save([])
        Task { @MainActor in
            NotificationCenter.default.post(name: OrderStore.didChange, object: nil)
        }
    }
}
