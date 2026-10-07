import SwiftUI

@main
struct LauncherApp: App {
    @State private var store = LibraryStore()
    @State private var ingest = IngestServer()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .task {
                    // Ingest runs only while the library is open, so the
                    // listener is not sitting on the network unattended.
                    ingest.start { store.load() }
                }
        }
        .defaultSize(width: 1080, height: 720)

        // One immersive space at a time. The library window is dismissed on
        // handoff; re-rendering it inside the immersive scene would make it
        // custom-drawn content, which forfeits system hover entirely.
        ImmersiveSpace(id: "title") {
            TitleHost()
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// Placeholder for the compat runtime's render target.
struct TitleHost: View {
    var body: some View { EmptyView() }
}
