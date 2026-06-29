import SwiftUI

@main
struct StreamTalkApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environmentObject(Config.shared)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}   // we provide our own "new chat"
        }

        Settings {
            SettingsView()
                .environmentObject(Config.shared)
                .frame(width: 460)
        }
    }
}

/// Owns the ChatViewModel (bound to the app-level SessionStore).
struct RootView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var vm: ChatViewModel

    init(store: SessionStore) {
        self.store = store
        _vm = StateObject(wrappedValue: ChatViewModel(store: store))
    }

    var body: some View {
        MainView()
            .environmentObject(vm)
            .environmentObject(store)
    }
}
