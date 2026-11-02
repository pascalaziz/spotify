import SwiftUI

@main
struct AurorixApp: App {
    var body: some Scene {
        WindowGroup {
            WebShell()
                .ignoresSafeArea()
        }
    }
}
