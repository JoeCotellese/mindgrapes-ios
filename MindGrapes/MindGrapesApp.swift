// ABOUTME: App entry point for the MindGrapes iOS capture app.
// ABOUTME: Placeholder shell until the capture screen lands (breakdown issue 17).

import MindGrapesKit
import SwiftUI

@main
struct MindGrapesApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

/// Stands in for the capture screen so the target builds and runs from issue 1.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("MindGrapes")
                .font(.largeTitle.bold())
            Text(AppGroup.identifier)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    PlaceholderView()
}
