import Foundation

extension L10n.Dispatch {
    static let deliveryGate = String(localized: "delivery.gate", defaultValue: "Node Delivery", table: "DispatchDelivery")
    static let deliveryInspectorMessage = String(localized: "delivery.inspector-message",
        defaultValue: "Delivered nodes still require overall goal verification.", table: "DispatchDelivery")
    static let deliveryByTask = String(localized: "delivery.by-task", defaultValue: "Delivery by task", table: "DispatchDelivery")
    static func deliveryProgress(_ completed: Int, _ total: Int) -> String {
        String(localized: "delivery.progress", defaultValue: "\(completed) of \(total) tasks delivered", table: "DispatchDelivery")
    }
}
