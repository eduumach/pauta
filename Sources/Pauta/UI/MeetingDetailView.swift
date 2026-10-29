import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppState.self) private var app
    let meetingID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Resumo"
        case decisions = "Decisões"
        case tasks = "Tarefas"
        case transcript = "Transcrição"
        case chat = "Conversa"
        var id: Self { self }

        var icon: String {
            switch self {
            case .summary: "text.alignleft"
            case .decisions: "arrow.triangle.branch"
            case .tasks: "checklist"
            case .transcript: "quote.bubble"
            case .chat: "bubble.left.and.text.bubble.right"
            }
        }
    }

    @State private var tab: Tab = .summary
    @State private var player = AudioPlayer()

    var body: some View {
        if let meeting = app.store.meeting(meetingID) {
            content(meeting)
                .navigationTitle(meeting.title)
                .navigationSubtitle(subtitle(meeting))
                .toolbar { toolbar(meeting) }
                .onAppear { player.load(app.store.directory(for: meetingID).appending(path: "audio.m4a")) }
                .onChange(of: meeting.status) { _, status in
                    if status == .ready, !player.isLoaded {
                        player.load(app.store.directory(for: meetingID).appending(path: "audio.m4a"))
                    }
                }
                .onDisappear { player.stop() }
        }
    }

    private func subtitle(_ meeting: Meeting) -> String {
        var parts = [meeting.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if meeting.duration > 0 { parts.append(meeting.duration.clock) }
        if meeting.cost > 0 { parts.append(meeting.cost.formatted(.currency(code: "USD").precision(.fractionLength(3)))) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .recording:
            if app.currentMeetingID == meetingID, app.isLiveTranscribing {
                LiveMeetingView(meeting: meeting)
            } else {
                StatusView(icon: "record.circle", tint: .red, title: "Gravando…",
                           message: "O resumo fica pronto logo depois que você parar a gravação.")
            }
        case .transcribing, .analyzing:
            StatusView(icon: meeting.status == .transcribing ? "waveform" : "sparkles", tint: .accentColor,
                       title: meeting.status == .transcribing ? "Transcrevendo o áudio…" : "Analisando a reunião…",
                       message: "Isso costuma levar menos de um minuto.", progress: true)
        case .failed:
            StatusView(icon: "exclamationmark.triangle", tint: .orange, title: "Não foi possível processar",
                       message: meeting.errorMessage ?? "Erro desconhecido.") {
                HStack {
                    if meeting.transcript != nil {
                        Button("Analisar novamente") { app.retry(meetingID, reanalyzeOnly: true) }
                    }
                    Button("Tentar de novo") { app.retry(meetingID) }
                        .buttonStyle(.glassProminent)
                }
            }
        case .ready:
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)
                .padding(.vertical, 12)

                Group {
                    switch tab {
                    case .summary: SummaryTab(meeting: meeting, player: player)
                    case .decisions: DecisionsTab(meeting: meeting)
                    case .tasks: TasksTab(meeting: meeting)
                    case .transcript: TranscriptTab(meeting: meeting, player: player)
                    case .chat: MeetingChatTab(meeting: meeting)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                if player.isLoaded, tab != .chat {
                    PlayerBar(player: player).padding(14)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItemGroup {
            Button("Copiar resumo", systemImage: "doc.on.doc") {
                copy(MarkdownExport.summary(of: meeting))
            }
            .disabled(meeting.analysis == nil)
            .help("Copiar resumo em Markdown")

            Menu("Mais", systemImage: "ellipsis") {
                Button("Analisar novamente", systemImage: "sparkles") { app.retry(meetingID, reanalyzeOnly: true) }
                    .disabled(meeting.transcript == nil || meeting.isProcessing)
                Button("Transcrever no Mac (grátis)", systemImage: "laptopcomputer") { app.retry(meetingID, engine: .local) }
                    .disabled(meeting.isProcessing || meeting.status == .recording)
                Button("Refinar na nuvem (~US$ \(String(format: "%.2f", meeting.duration / 3600 * 0.22)))", systemImage: "cloud") {
                    app.retry(meetingID, engine: .cloud)
                }
                .disabled(meeting.isProcessing || meeting.status == .recording)
                Divider()
                Button("Mostrar no Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.store.directory(for: meetingID).appending(path: "audio.m4a")])
                }
                Divider()
                Button("Apagar reunião", systemImage: "trash", role: .destructive) {
                    app.selection = .memory
                    app.store.delete(meetingID)
                }
            }
        }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Status

private struct StatusView<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var progress = false
    @ViewBuilder var actions: () -> Actions

    init(icon: String, tint: Color, title: String, message: String, progress: Bool = false,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.progress = progress
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative, isActive: progress)
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    var tint: Color = .accentColor
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: icon ?? "circle")
                    .font(.headline)
                    .foregroundStyle(tint)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct Bullets: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(.tertiary).frame(width: 5, height: 5)
                    Text(item).textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Summary

private struct SummaryTab: View {
    let meeting: Meeting
    let player: AudioPlayer

    var body: some View {
        let a = meeting.analysis ?? MeetingAnalysis()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Resumo", icon: "text.alignleft") {
                    Text(a.summary).font(.body).lineSpacing(3).textSelection(.enabled)
                }

                HStack(alignment: .top, spacing: 16) {
                    StatTile(value: a.decisions.count, label: "decisões", icon: "checkmark.seal", tint: .green)
                    StatTile(value: a.actionItems.count, label: "tarefas", icon: "checklist", tint: .blue)
                    StatTile(value: a.openQuestions.count, label: "em aberto", icon: "questionmark.diamond", tint: .orange)
                }

                if !a.keyPoints.isEmpty {
                    Card(title: "Pontos principais", icon: "list.bullet") { Bullets(items: a.keyPoints) }
                }
                if !meeting.bookmarks.isEmpty {
                    Card(title: "Momentos marcados", icon: "bookmark.fill", tint: .yellow) {
                        ForEach(meeting.bookmarks) { mark in
                            Button {
                                player.seek(to: max(mark.time - 10, 0))
                            } label: {
                                HStack {
                                    Text(mark.time.clock).font(.callout.monospacedDigit()).foregroundStyle(.tint)
                                    Text(mark.note.isEmpty ? "Momento importante" : mark.note)
                                    Spacer()
                                    Image(systemName: "play.circle")
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !a.risks.isEmpty {
                    Card(title: "Pontos de atenção", icon: "exclamationmark.triangle", tint: .orange) { Bullets(items: a.risks) }
                }
                if !a.nextAgenda.isEmpty {
                    Card(title: "Para a próxima reunião", icon: "calendar.badge.clock", tint: .purple) { Bullets(items: a.nextAgenda) }
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(.title.weight(.semibold)).contentTransition(.numericText())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 16))
    }
}

// MARK: - Decisions

private struct DecisionsTab: View {
    let meeting: Meeting

    var body: some View {
        let a = meeting.analysis ?? MeetingAnalysis()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if a.decisions.isEmpty && a.openQuestions.isEmpty {
                    ContentUnavailableView("Nenhuma decisão identificada", systemImage: "arrow.triangle.branch")
                        .padding(.top, 60)
                }
                if !a.decisions.isEmpty {
                    Card(title: "Decidido", icon: "checkmark.seal.fill", tint: .green) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(a.decisions) { d in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(d.decision).font(.body.weight(.medium)).textSelection(.enabled)
                                    if let r = d.rationale, !r.isEmpty {
                                        Text(r).font(.callout).foregroundStyle(.secondary)
                                    }
                                    if let owner = d.owner, !owner.isEmpty {
                                        Label(owner, systemImage: "person.fill").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                ForEach(a.openQuestions) { q in
                    OpenQuestionCard(question: q)
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OpenQuestionCard: View {
    let question: MeetingAnalysis.OpenQuestion

    var body: some View {
        Card(title: "Em aberto", icon: "questionmark.diamond.fill", tint: .orange) {
            Text(question.question).font(.title3.weight(.semibold)).textSelection(.enabled)
            if let context = question.context, !context.isEmpty {
                Text(context).foregroundStyle(.secondary)
            }
            if !question.options.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(question.options) { option in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(option.option).font(.headline)
                            ForEach(option.pros, id: \.self) { Label($0, systemImage: "plus.circle.fill").foregroundStyle(.green) }
                            ForEach(option.cons, id: \.self) { Label($0, systemImage: "minus.circle.fill").foregroundStyle(.red) }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                        .background(.background.tertiary, in: .rect(cornerRadius: 14))
                    }
                }
            }
            if let rec = question.recommendation, !rec.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recomendação").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        Text(rec).textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 14))
            }
        }
    }
}

// MARK: - Tasks

private struct TasksTab: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    var body: some View {
        let items = meeting.analysis?.actionItems ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    ContentUnavailableView("Nenhuma tarefa identificada", systemImage: "checklist").padding(.top, 60)
                } else {
                    HStack {
                        Text("\(items.filter(\.done).count) de \(items.count) concluídas")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copiar tarefas", systemImage: "doc.on.doc") { copy(MarkdownExport.tasks(of: meeting)) }
                            .buttonStyle(.glass)
                        Button("Enviar ao TickTick", systemImage: "paperplane") {}
                            .buttonStyle(.glass)
                            .disabled(true)
                            .help("Em breve")
                    }
                    ForEach(items) { item in
                        TaskRow(item: item) { done in
                            app.store.update(meeting.id) { m in
                                guard let i = m.analysis?.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
                                m.analysis?.actionItems[i].done = done
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct TaskRow: View {
    let item: MeetingAnalysis.ActionItem
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.snappy) { toggle(!item.done) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let owner = item.owner, !owner.isEmpty { Chip(text: owner, icon: "person.fill", tint: .secondary) }
                    if let due = item.dueDate, !due.isEmpty { Chip(text: formatDue(due), icon: "calendar", tint: .blue) }
                    if let priority = item.priority, !priority.isEmpty { Chip(text: priority, icon: "flag.fill", tint: priorityColor(priority)) }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func formatDue(_ value: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return value }
        return date.formatted(.dateTime.day().month(.abbreviated).weekday(.abbreviated))
    }

    private func priorityColor(_ value: String) -> Color {
        switch value.lowercased() {
        case "alta": .red
        case "média", "media": .orange
        default: .gray
        }
    }
}

struct Chip: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

// MARK: - Transcript

private struct TranscriptTab: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    let player: AudioPlayer
    @State private var renaming: String?
    @State private var newName = ""

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown]

    var body: some View {
        let segments = meeting.transcript?.segments ?? []
        let labels = Array(Set(segments.compactMap(\.speaker))).sorted()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(segments) { seg in
                        let active = player.isPlaying && player.current >= seg.start && player.current < max(seg.end, seg.start + 1)
                        HStack(alignment: .top, spacing: 12) {
                            Button(seg.start.clock) { player.seek(to: seg.start) }
                                .buttonStyle(.plain)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                let color = seg.speaker.flatMap { labels.firstIndex(of: $0) }.map { Self.palette[$0 % Self.palette.count] } ?? .secondary
                                Text(meeting.displayName(forSpeaker: seg.speaker))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color)
                                    .onTapGesture {
                                        guard let label = seg.speaker else { return }
                                        newName = meeting.displayName(forSpeaker: label)
                                        renaming = label
                                    }
                                    .help("Clique para renomear")
                                Text(seg.text).textSelection(.enabled).lineSpacing(2)
                            }
                        }
                        .padding(8)
                        .background(active ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 10))
                        .id(seg.id)
                    }
                }
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: player.current) { _, time in
                guard player.isPlaying, let seg = segments.last(where: { $0.start <= time }) else { return }
                withAnimation { proxy.scrollTo(seg.id, anchor: .center) }
            }
        }
        .alert("Renomear participante", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Salvar") {
                if let label = renaming {
                    app.store.update(meeting.id) { $0.speakerNames[label] = newName.trimmingCharacters(in: .whitespaces) }
                }
                renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: - Player

private struct PlayerBar: View {
    let player: AudioPlayer
    @State private var scrub: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28, height: 28)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Text((scrub ?? player.current).clock).font(.caption.monospacedDigit()).frame(width: 52)
            Slider(
                value: Binding(get: { scrub ?? player.current }, set: { scrub = $0 }),
                in: 0...max(player.duration, 1)
            ) { editing in
                if !editing, let value = scrub {
                    player.seek(to: value, play: player.isPlaying)
                    scrub = nil
                }
            }
            .controlSize(.small)
            Text(player.duration.clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .glassEffect(in: .capsule)
    }
}

// MARK: - Live

/// Shown while recording: the transcript as it is spoken, and a chat to ask about it right away.
private struct LiveMeetingView: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 0) {
            LiveTranscriptView(meeting: meeting)
                .frame(maxWidth: .infinity)
            Divider()
            MeetingChatTab(meeting: meeting)
                .frame(width: 380)
        }
    }
}

private struct LiveTranscriptView: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        PulsingDot()
                        Text("Ao vivo").font(.headline)
                        ElapsedText(since: app.recordingStart).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Text("Transcrição local · grátis").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 8)

                    ForEach(app.liveSegments) { seg in
                        line(speaker: seg.speaker, time: seg.start, text: seg.text, volatile: false)
                    }
                    ForEach(app.liveVolatile.sorted(by: { $0.key < $1.key }), id: \.key) { speaker, text in
                        if !text.isEmpty {
                            line(speaker: speaker, time: nil, text: text, volatile: true)
                        }
                    }
                    if app.liveSegments.isEmpty && app.liveVolatile.values.allSatisfy(\.isEmpty) {
                        Text("Ouvindo… o texto aparece aqui enquanto as pessoas falam.")
                            .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(24)
            }
            .onChange(of: app.liveCaption) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func line(speaker: String?, time: TimeInterval?, text: String, volatile: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time?.clock ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.displayName(forSpeaker: speaker))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(speaker == LocalSpeech.meLabel ? Color.accentColor : .purple)
                Text(text)
                    .foregroundStyle(volatile ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
    }
}
