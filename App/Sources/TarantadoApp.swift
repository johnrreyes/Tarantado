import SwiftUI
import DAPUI

/// The entire app target: one `App` that shows `DAPUI.RootView`.
///
/// Everything else — state, screens, engine access — lives in the
/// `DAPUI` package library so it stays buildable and testable with
/// `swift build` / `swift test`, with no Xcode project required. Keeping
/// this file down to an entry point is what lets iOS, iPadOS and macOS
/// share a single target rather than maintaining per-platform sources.
@main
struct TarantadoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
