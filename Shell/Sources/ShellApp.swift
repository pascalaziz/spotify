import SwiftUI
import UIKit

@main
struct ShellApp: App {
    @UIApplicationDelegateAdaptor(AxAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ShellView()
                .ignoresSafeArea()
        }
    }
}

/* Background URLSession launch hook (2026-11-15). When a background download finishes (or fails)
   while the app is SUSPENDED, iOS relaunches the app and calls exactly this method; the session's
   delegate events only start flowing after we hand back the completion handler. Without it, a
   download that completed in the background would be delivered to a dead session and lost. */
final class AxAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) -> Bool {
        AxDownloads.shared.handleBackgroundEvents(completionHandler)
        return true
    }
}
