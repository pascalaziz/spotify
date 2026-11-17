#if canImport(ActivityKit)
import ActivityKit
import Foundation

/* LIVE ACTIVITY ATTRIBUTES - shared by the app target and the widget extension.
   This single file is compiled into BOTH targets (the extension lists it in its sources), so the
   definition cannot drift. */
struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var pct: Double
        var got: Int
        var total: Int
        var status: String
    }
    var brand: String
}
#endif
