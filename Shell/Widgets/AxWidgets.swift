#if canImport(ActivityKit)
import WidgetKit
import SwiftUI
import ActivityKit

/* Lock Screen + Dynamic Island layouts for the download Live Activity.
   Data comes ONLY from real native URLSession callbacks (AxActivity.update) - never timers,
   never JavaScript, never estimated percentages. */
struct AxLockScreenView: View {
    let ctx: ActivityViewContext<DownloadActivityAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ctx.attributes.brand)
                .font(.caption2.weight(.semibold)).opacity(0.8)
            Text(ctx.state.title)
                .font(.footnote.weight(.semibold)).lineLimit(1)
            ProgressView(value: min(max(ctx.state.pct, 0), 100), total: 100)
                .progressViewStyle(.linear)
            HStack {
                Text("\(Int(ctx.state.pct))%").font(.caption2.weight(.bold))
                if ctx.state.total > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(ctx.state.got), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(ctx.state.total), countStyle: .file))")
                        .font(.caption2).opacity(0.8)
                }
                Spacer()
                Text(ctx.state.status).font(.caption2).opacity(0.8)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { ctx in
            AxLockScreenView(ctx: ctx)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    AxLockScreenView(ctx: ctx)
                }
            } compactLeading: {
                Text("\(Int(ctx.state.pct))%").font(.caption2.weight(.bold))
            } compactTrailing: {
                Image(systemName: "arrow.down.circle.fill").font(.caption2)
            } minimal: {
                Text("\(Int(ctx.state.pct))%").font(.caption2.weight(.bold))
            }
        }
    }
}

@main
struct AxWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DownloadActivityWidget()
    }
}
#endif
