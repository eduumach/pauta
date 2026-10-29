import SwiftUI

enum SidebarItem: Hashable {
    case memory
    case meeting(UUID)
}

struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var search = ""

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                Label("Perguntar às reuniões", systemImage: "sparkles")
                    .tag(SidebarItem.memory)

                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(SidebarItem.meeting(meeting.id))
                                .contextMenu {
                                    Button("Apagar", systemImage: "trash", role: .destructive) {
                                        if app.selection == .meeting(meeting.id) { app.selection = .memory }
                                        app.store.delete(meeting.id)
                                    }
                                }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Buscar reuniões")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .safeAreaInset(edge: .bottom) {
                RecordButton().padding(12)
            }
        } detail: {
            switch app.selection {
            case .meeting(let id) where app.store.meeting(id) != nil:
                MeetingDetailView(meetingID: id).id(id)
            default:
                MemoryView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private struct Group {
        let title: String
        let meetings: [Meeting]
    }

    private var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = app.store.meetings.filter { meeting in
            guard !query.isEmpty else { return true }
            return meeting.title.localizedStandardContains(query)
                || (meeting.analysis?.summary.localizedStandardContains(query) ?? false)
                || (meeting.transcript?.text.localizedStandardContains(query) ?? false)
        }
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Meeting]] = [:]
        for meeting in filtered {
            let date = meeting.createdAt
            let title: String
            if calendar.isDateInToday(date) {
                title = "Hoje"
            } else if calendar.isDateInYesterday(date) {
                title = "Ontem"
            } else if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
                title = "Últimos 7 dias"
            } else {
                title = date.formatted(.dateTime.month(.wide).year()).capitalized
            }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(meeting)
        }
        return order.map { Group(title: $0, meetings: buckets[$0] ?? []) }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(status: meeting.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(meeting.createdAt.formatted(date: .omitted, time: .shortened))
                    if meeting.duration > 0 {
                        Text("·")
                        Text(meeting.duration.clock)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
