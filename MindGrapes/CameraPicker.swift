// ABOUTME: A thin UIImagePickerController wrapper that hands back a captured photo as JPEG bytes.
// ABOUTME: ponytail: throwaway Slice-2 camera glue; Slice 7's real capture UI replaces it.

import SwiftUI
import UIKit

/// Presents the system camera and delivers the shot as `Data`.
///
/// Deliberately minimal: no editing, no front/back choice beyond the system
/// default, no album save. The bytes go straight to ``PhotoSpooler``, which
/// downscales them, so full-resolution JPEG at capture time is fine.
struct CameraPicker: UIViewControllerRepresentable {
    /// Called with the captured JPEG bytes. Not called if the user cancels.
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let dismiss: () -> Void

        init(onCapture: @escaping (Data) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // compressionQuality 1.0: PhotoSpooler does the real shrinking, so
            // there is no point lossily re-encoding twice here.
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 1.0) {
                onCapture(data)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
