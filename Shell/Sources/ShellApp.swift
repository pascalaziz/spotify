import SwiftUI

@main
struct ShellApp: App {
    var body: some Scene {
        WindowGroup {
            ShellView()
                .ignoresSafeArea()
        }
    }
}
