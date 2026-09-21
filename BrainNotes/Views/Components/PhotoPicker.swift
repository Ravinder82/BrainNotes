import SwiftUI
import PhotosUI

/// Wraps the system photo library picker and hands back a ready-to-send
/// attachment. Loading and downscaling happen off the main thread so a large
/// library photo never stalls the chat.
struct PhotoPicker: View {
    var onPick: (MessageAttachment) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if isLoading {
                    ProgressView("Preparing photo…")
                        .padding(.top, 40)
                } else {
                    PhotosPicker(
                        selection: $selection,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 40))
                                .foregroundStyle(Theme.accent)
                            Text("Choose a photo")
                                .font(.headline)
                            Text("Pick an image to send to this bot. "
                                 + "Vision-capable models can describe, read "
                                 + "and reason about it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    }
                    .accessibilityIdentifier("photo-picker")
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .navigationTitle("Send Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let attachment = MessageAttachment.from(image)
            else {
                errorText = "That image could not be read."
                return
            }
            onPick(attachment)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}