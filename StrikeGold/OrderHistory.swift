import Foundation

struct SavedOrder: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case working
        case filled
        case failed
        case canceled
    }

    var id: String
    var placedAt: Date
    var symbol: String
    var expiration: Date?
    var right: String // "call" or "put"
    var strike: Double
    var side: String // "buy" or "sell"
    var quantity: Int
    var limit: Double?
    var tif: String // "DAY" or "GTC"
    var status: Status
    var fillPrice: Double?
    var fillQuantity: Int?
    var note: String?
}

final class OrderStore {
    static let shared = OrderStore()
    private let key = "saved_orders_v1"

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
    }

    func update(id: String, mutate: (inout SavedOrder) -> Void) {
        var all = load()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            mutate(&all[idx])
            save(all)
        }
    }

    func remove(id: String) {
        var all = load()
        all.removeAll { $0.id == id }
        save(all)
    }

    func clear() {
        save([])
    }
}
