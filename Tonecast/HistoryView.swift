import SwiftUI
import UIKit

struct HistoryView: View {
    @State private var entries: [SharedDefaults.HistoryEntry] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Recent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                SharedDefaults.clearHistory()
                                entries = []
                            } label: {
                                Label("Clear all", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .onAppear {
            entries = SharedDefaults.recentHistory()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Your last \(SharedDefaults.historyLimit) transcriptions will appear here.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(entries) { entry in
                row(for: entry)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for entry: SharedDefaults.HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.tone)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(.tint)

                if entry.translate != "No translate" {
                    Text(entry.translate)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                        .foregroundStyle(.green)
                }

                Spacer()
                Text(relativeDate(entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.final)
                .font(.body)

            DisclosureGroup {
                Text(entry.original)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } label: {
                Text("Original transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = entry.final
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copy result", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    UIPasteboard.general.string = entry.original
                } label: {
                    Label("Copy original", systemImage: "doc.on.doc.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    /// Granular relative-date formatting:
    ///   < 1 min          → "just now"
    ///   < 1 hour         → "23 min ago"
    ///   < same day       → "3 hr ago"
    ///   yesterday        → "Yesterday 14:32"
    ///   < 7 days same yr → "Mon 14:32"
    ///   otherwise        → "May 18 14:32"
    private func relativeDate(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "\(Int(interval / 3600)) hr ago"
        }
        if calendar.isDateInYesterday(date) {
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH:mm"
            return "Yesterday \(timeFmt.string(from: date))"
        }

        let weekdayFmt = DateFormatter()
        if interval < 86400 * 7,
           calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            weekdayFmt.dateFormat = "EEE HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            weekdayFmt.dateFormat = "MMM d HH:mm"
        } else {
            weekdayFmt.dateFormat = "MMM d, yyyy HH:mm"
        }
        return weekdayFmt.string(from: date)
    }
}

#Preview {
    HistoryView()
}
