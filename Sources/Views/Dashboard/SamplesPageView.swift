import SwiftUI

struct SamplesPageView: View {
    let historyStore: UsageHistoryStore
    let accountStore: AccountStore

    @State private var sortOrder = [KeyPathComparator(\SampleRow.timestamp, order: .reverse)]
    @State private var selection: Set<SampleRow.ID> = []
    @State private var filter: FilterKind = .all

    enum FilterKind: String, CaseIterable {
        case all = "All"
        case snapshots = "Snapshots"
        case gaps = "Gaps"
    }

    private var rows: [SampleRow] {
        var result: [SampleRow] = []

        if filter != .gaps {
            for snapshot in historyStore.snapshots {
                let accountName = accountStore.accounts.first { $0.id == snapshot.accountID }?.displayName ?? "Unknown"
                result.append(SampleRow(
                    id: snapshot.id,
                    timestamp: snapshot.timestamp,
                    kind: .snapshot,
                    account: accountName,
                    fiveHour: snapshot.fiveHourUtilization,
                    sevenDay: snapshot.sevenDayUtilization,
                    duration: nil
                ))
            }
        }

        if filter != .snapshots {
            for gap in historyStore.gaps {
                let duration = gap.end.timeIntervalSince(gap.start)
                result.append(SampleRow(
                    id: gap.id,
                    timestamp: gap.start,
                    kind: .gap,
                    account: "—",
                    fiveHour: nil,
                    sevenDay: nil,
                    duration: duration
                ))
            }
        }

        return result.sorted(using: sortOrder)
    }

    private var snapshotCount: Int {
        historyStore.snapshots.count
    }

    private var gapCount: Int {
        historyStore.gaps.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    statBadge(value: snapshotCount, label: "Snapshots", icon: "circle.fill", color: .blue)
                    statBadge(value: gapCount, label: "Gaps", icon: "pause.circle.fill", color: .orange)
                }

                HStack {
                    Picker("Filter", selection: $filter) {
                        ForEach(FilterKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Spacer()

                    Text("\(rows.count) items")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Table
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Time", value: \.timestamp) { row in
                    Text(row.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                        .monospacedDigit()
                }
                .width(min: 140, ideal: 170)

                TableColumn("Type", value: \.kindLabel) { row in
                    Label(row.kindLabel, systemImage: row.kindIcon)
                        .foregroundStyle(row.kind == .gap ? .orange : .secondary)
                        .font(.callout)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Account", value: \.account)
                    .width(min: 100, ideal: 150)

                TableColumn("5H %") { row in
                    if let value = row.fiveHour {
                        Text(String(format: "%.0f%%", value))
                            .monospacedDigit()
                            .foregroundStyle(.blue)
                    }
                }
                .width(min: 50, ideal: 60)

                TableColumn("7D %") { row in
                    if let value = row.sevenDay {
                        Text(String(format: "%.0f%%", value))
                            .monospacedDigit()
                            .foregroundStyle(.purple)
                    }
                }
                .width(min: 50, ideal: 60)

                TableColumn("Duration") { row in
                    if let duration = row.duration {
                        Text(Self.formatDuration(duration))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }
                .width(min: 60, ideal: 80)
            }
        }
        .navigationTitle("Samples")
        .toolbarTitleDisplayMode(.inline)
    }

    private func statBadge(value: Int, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.title3.bold().monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else if seconds < 3600 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        } else {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "\(h)h \(m)m"
        }
    }
}

struct SampleRow: Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let account: String
    let fiveHour: Double?
    let sevenDay: Double?
    let duration: TimeInterval?

    enum Kind {
        case snapshot
        case gap
    }

    var kindLabel: String {
        switch kind {
        case .snapshot: "Snapshot"
        case .gap: "Gap"
        }
    }

    var kindIcon: String {
        switch kind {
        case .snapshot: "circle.fill"
        case .gap: "pause.circle.fill"
        }
    }
}
