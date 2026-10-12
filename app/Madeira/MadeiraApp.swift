import SwiftUI

@main
struct MadeiraApp: App {
    init() {
        madeira_startup_log("startup-v2: SwiftUI App init begin")
        // ml1172: read the screen on the main thread; library entries, whose
        // default Resolution comes from it, are also made on other threads.
        _ = ResolutionChoices.screen
        madeira_startup_log("startup-v2: SwiftUI App init complete")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
                .onAppear {
                    madeira_startup_log("startup-v2: ContentView appeared")
                    GamepadInput.shared.start()
                    madeira_startup_log("startup-v2: gamepad input started")
                    HardwareInput.shared.start()
                    madeira_startup_log("startup-v2: hardware input started")
                    JITNetworkShortcut.shared.restoreLeftover()   // also starts its network path monitor
                    madeira_startup_log("startup-v2: network shortcut restored")
                }
                // madeira://jit-network/... (the Madeira JIT shortcut returning, JITNetwork.swift),
                // else madeira://play?exe=... (Home Screen shortcuts, SavesAndShortcuts.swift).
                .onOpenURL { url in if !JITNetworkShortcut.shared.handle(url) { ShortcutRouter.shared.handle(url) } }
        }
    }
}
