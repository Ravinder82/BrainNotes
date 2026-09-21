import SwiftUI
import VisionKit

struct DocumentScannerView: UIViewControllerRepresentable {
    let onComplete: (VNDocumentCameraScan) -> Void
    let onCancel: () -> Void
    
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }
    
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: (VNDocumentCameraScan) -> Void
        let onCancel: () -> Void
        
        init(onComplete: @escaping (VNDocumentCameraScan) -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onComplete(scan)
        }
        
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

struct DocumentScannerPresenter: View {
    @Binding var isPresented: Bool
    let onScanComplete: (VNDocumentCameraScan) -> Void
    
    var body: some View {
        DocumentScannerView(
            onComplete: { scan in
                isPresented = false
                onScanComplete(scan)
            },
            onCancel: {
                isPresented = false
            }
        )
    }
}
