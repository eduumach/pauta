import SwiftUI

struct IslandView: View {
    @Environment(AppState.self) private var app
    @AppStorage(Pref.showIsland) private var showIsland = true
    // Read here so toggling the caption re-renders the island right away.
    @AppStorage(Pref.showLiveCaption) private var showLiveCaption = false
    let model: IslandModel

    var body: some View {
        let size = model.size
        let expanded = size.height > model.notch.height + 1
        VStack(spacing: 0) {
            if showIsland, model.content != .hidden {
                ZStack(alignment: .top) {
                    NotchShape(topRadius: expanded ? 12 : 6, bottomRadius: expanded ? 22 : 10)
                        .fill(.black)
                        .shadow(color: .black.opacity(expanded ? 0.4 : 0), radius: 12, y: 6)
                    content(expanded: expanded)
                        .padding(.horizontal, expanded ? 24 : 14)
                }
                .frame(width: size.width, height: size.height)
                .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(width: IslandController.canvas.width, height: IslandController.canvas.height, alignment: .top)
        .animation(.snappy(duration: 0.22), value: size)
        .animation(.snappy(duration: 0.22), value: model.content)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(expanded: Bool) -> some View {
        switch model.content {
        case .hidden:
            EmptyView()
        case .starting:
            wings {
                ProgressView().controlSize(.mini).scaleEffect(0.7).tint(.white)
            } trailing: {
                Image(systemName: "mic.fill").font(.caption2).foregroundStyle(.secondary)
            }
        case .recording:
            if model.expanded {
                RecordingPanel(notchHeight: model.notch.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else {
                VStack(spacing: 0) {
                    wings {
                        HStack(spacing: 5) {
                            PulsingDot()
                            MiniWave(levels: Array(app.levels.suffix(4)))
                        }
                    } trailing: {
                        ElapsedText(since: app.recordingStart)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    if model.showsCaption && showLiveCaption {
                        CaptionLine()
                            .frame(height: 22, alignment: .top)
                            .transition(.opacity)
                    }
                }
            }
        case .processing(let step):
            if expanded {
                VStack(spacing: 0) {
                    Spacer().frame(height: model.notch.height)
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(step) a reunião…").font(.caption.weight(.semibold))
                            Text("Avisaremos quando o resumo estiver pronto")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                }
                .foregroundStyle(.white)
            } else {
                wings {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).tint(.white)
                } trailing: {
                    Image(systemName: step == "Analisando" ? "sparkles" : "waveform")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative)
                }
            }
        case .finished(let id):
            FinishedPanel(meetingID: id, notchHeight: model.notch.height)
        }
    }

    /// Lays content out on both sides of the physical notch.
    private func wings<L: View, T: View>(@ViewBuilder leading: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 0) {
            leading().frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notch.width)
            trailing().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: model.notch.height)
        .foregroundStyle(.white)
    }
}

// MARK: - Expanded panels

private struct RecordingPanel: View {
    @Environment(AppState.self) private var app
    @AppStorage(Pref.showLiveCaption) private var showLiveCaption = false
    let notchHeight: CGFloat
    @State private var note = ""
    @State private var flash = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: notchHeight - 4)
            HStack(spacing: 10) {
                PulsingDot()
                Waveform(levels: Array(app.levels.suffix(20)))
                    .frame(height: 20)
                ElapsedText(since: app.recordingStart)
                    .font(.callout.monospacedDigit().weight(.semibold))
            }

            if app.isLiveTranscribing {
                CaptionLine(lines: 2)
            }

            HStack(spacing: 6) {
                IslandButton(systemImage: flash ? "checkmark" : "bookmark.fill", title: nil) {
                    app.addBookmark()
                    flash = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        flash = false
                    }
                }
                .help("Marcar este momento como importante")

                TextField("Nota rápida… ↩", text: $note)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.white.opacity(0.1), in: .capsule)
                    .focused($noteFocused)
                    .onSubmit {
                        let text = note.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        app.addBookmark(note: text)
                        note = ""
                        noteFocused = false
                    }

                if app.isLiveTranscribing {
                    IslandButton(systemImage: showLiveCaption ? "captions.bubble.fill" : "captions.bubble", title: nil) {
                        showLiveCaption.toggle()
                    }
                    .help(showLiveCaption ? "Ocultar legenda fixa" : "Mostrar legenda fixa")
                }

                IslandButton(systemImage: "stop.fill", title: nil, tint: .red) {
                    app.toggleRecording()
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.bottom, 12)
    }
}

private struct FinishedPanel: View {
    @Environment(AppState.self) private var app
    let meetingID: UUID
    let notchHeight: CGFloat

    var body: some View {
        let meeting = app.store.meeting(meetingID)
        VStack(spacing: 8) {
            Spacer().frame(height: notchHeight - 4)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: meetingID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting?.title ?? "Reunião").font(.caption.weight(.semibold)).lineLimit(1)
                    Text("\(meeting?.analysis?.decisions.count ?? 0) decisões · \(meeting?.analysis?.actionItems.count ?? 0) tarefas")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                IslandButton(systemImage: "xmark", title: nil) { app.dismissFinished() }
                IslandButton(systemImage: "arrow.up.forward", title: "Abrir", tint: .accentColor) {
                    app.dismissFinished()
                    app.openMain(selecting: meetingID)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .padding(.bottom, 10)
    }
}

// MARK: - Pieces

/// Latest live speech, newest words kept visible.
struct CaptionLine: View {
    @Environment(AppState.self) private var app
    var lines = 1

    var body: some View {
        let speaker = app.liveCaptionSpeaker
        let isMe = speaker == LocalSpeech.meLabel
        let name = Text(speaker.map { Transcript.fallbackName(for: $0) + "  " } ?? "")
            .foregroundStyle(isMe ? Color.accentColor : Color.purple.mix(with: .white, by: 0.35))
            .fontWeight(.semibold)
        let words = Text(app.liveCaption ?? "Ouvindo…")
            .foregroundStyle(.white.opacity(app.liveCaption == nil ? 0.4 : 0.85))
        Text("\(name)\(words)")
            .font(.caption)
            .lineLimit(lines, reservesSpace: lines > 1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: app.liveCaption)
    }
}

struct IslandButton: View {
    let systemImage: String
    let title: String?
    var tint: Color = .white.opacity(0.14)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).contentTransition(.symbolEffect(.replace))
                if let title { Text(title) }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(minWidth: 26, minHeight: 26)
            .background(tint.opacity(hovering ? 1 : 0.85), in: .capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .shadow(color: .red.opacity(0.8), radius: pulse ? 4 : 1)
            .scaleEffect(pulse ? 1 : 0.8)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

struct ElapsedText: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text((since.map { context.date.timeIntervalSince($0) } ?? 0).clock)
        }
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 3
            let barWidth = max((geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [.red, .orange], startPoint: .bottom, endPoint: .top))
                        .frame(width: barWidth, height: max(CGFloat(levels[i]) * geo.size.height, 3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: levels)
        }
    }
}

struct MiniWave: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.red.opacity(0.9))
                    .frame(width: 2, height: max(CGFloat(levels[i]) * 12, 2))
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// Black shape whose top corners flare outward like the MacBook notch.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
