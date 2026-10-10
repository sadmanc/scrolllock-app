import DeviceActivity
import ExtensionKit
import ManagedSettings
import SwiftUI

private struct ScrollLockReportItem: Identifiable {
    let id: String
    let name: String
    let duration: TimeInterval
    let pickups: Int
    let notifications: Int
}

private struct ScrollLockReportConfiguration {
    let items: [ScrollLockReportItem]
    let refreshedAt: Date?
}

@main
@MainActor
struct ScrollLockReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        ScrollLockSummaryReport()
    }
}

@MainActor
private struct ScrollLockSummaryReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .scrollLockSummary

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> ScrollLockReportConfiguration {
        var byApplication: [String: ScrollLockReportItem] = [:]
        var refreshedAt: Date?

        for await datum in data {
            refreshedAt = max(refreshedAt ?? .distantPast, datum.lastUpdatedDate)
            for await segment in datum.activitySegments {
                for await category in segment.categories {
                    for await activity in category.applications {
                        let application = activity.application
                        let id = String(describing: application.token)
                        let name = application.localizedDisplayName ?? "Unnamed app"
                        let previous = byApplication[id]
                        byApplication[id] = ScrollLockReportItem(
                            id: id,
                            name: previous?.name ?? name,
                            duration: (previous?.duration ?? 0) + activity.totalActivityDuration,
                            pickups: (previous?.pickups ?? 0) + activity.numberOfPickups,
                            notifications: (previous?.notifications ?? 0) + activity.numberOfNotifications
                        )
                    }
                }
            }
        }

        return ScrollLockReportConfiguration(
            items: byApplication.values.sorted {
                if $0.duration == $1.duration { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.duration > $1.duration
            },
            refreshedAt: refreshedAt
        )
    }

    @ViewBuilder
    var content: (ScrollLockReportConfiguration) -> some View {
        { configuration in
            ScrollLockReportView(configuration: configuration)
        }
    }
}

private struct ScrollLockReportView: View {
    let configuration: ScrollLockReportConfiguration

    var body: some View {
        if configuration.items.isEmpty {
            ContentUnavailableView(
                "No Screen Time data yet",
                systemImage: "chart.bar.xaxis",
                description: Text("Use an app for a moment, then return to Analytics.")
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(configuration.items) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(formatDuration(item.duration))
                                .font(.headline.monospacedDigit())
                        }
                        HStack(spacing: 14) {
                            Label("\(item.pickups) pickups", systemImage: "hand.tap")
                            Label("\(item.notifications) notifications", systemImage: "bell")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                if let refreshedAt = configuration.refreshedAt {
                    Text("Last updated \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration.rounded(.down)) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

extension DeviceActivityReport.Context {
    static let scrollLockSummary = Self("ScrollLockSummary")
}
