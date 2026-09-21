import UIKit

/// Caches device metrics to avoid expensive UI calls on every layout pass.
@MainActor
struct DeviceMetrics {
    static var screenWidth: CGFloat {
        // Read once per app launch and cache; traitCollection changes are rare
        // and can be ignored for this coarse sizing hint.
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return windowScene.screen.bounds.width
        }
        return UIScreen.main.bounds.width
    }
}