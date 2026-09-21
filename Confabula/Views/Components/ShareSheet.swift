import SwiftUI
import UIKit

/// Bridges UIKit's activity controller into SwiftUI, so a message can be sent
/// to any app the user has installed.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
