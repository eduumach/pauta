import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            RecordButton()
            if app.isRecording, let id = app.currentMeetingID {
                Button("Ver transcrição ao vivo", systemImage: "text.bubble") { app.openMain(selecting: id) }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .disabled(!app.isLiveTranscribing)
            }
            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            recent
            Divider()
            HStack {
                Button("Abrir Pauta", systemImage: "macwindow") { app.openMain() }
                Spacer()
                Button("Ajustes", systemImage: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
                .labelStyle(.iconOnly)
                Button("Sair", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Pauta").font(.headline)
                Text(app.isRecording ? "Gravando reunião" : "Seu parceiro de reuniões")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("⌥⌘R").font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var recent: some View {
        let meetings = Array(app.store.meetings.filter { $0.status != .recording }.prefix(4))
        if !meetings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recentes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(meetings) { meeting in
                    Button {
                        app.openMain(selecting: meeting.id)
                    } label: {
                        HStack {
                            StatusIcon(status: meeting.status)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title).lineLimit(1)
                                Text(meeting.createdAt.formatted(.relative(presentation: .named)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(HoverRowStyle())
                }
            }
        }
    }
}

struct RecordButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button {
            app.toggleRecording()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: app.isRecording ? "stop.fill" : "record.circle")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.isRecording ? "Parar e resumir" : "Gravar reunião").font(.headline)
                    if app.isRecording {
                        ElapsedText(since: app.recordingStart).font(.caption.monospacedDigit())
                    } else {
                        Text("Microfone + áudio do sistema").font(.caption).opacity(0.8)
                    }
                }
                Spacer()
                if app.isRecording {
                    MiniWave(levels: Array(app.levels.suffix(8)))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(app.isRecording ? .red : .accentColor)
        .controlSize(.large)
        .disabled(app.phase == .starting || app.phase == .stopping)
    }
}

struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(hovering || configuration.isPressed ? 0.08 : 0), in: .rect(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

struct StatusIcon: View {
    let status: Meeting.Status

    var body: some View {
        switch status {
        case .recording:
            Image(systemName: "record.circle").foregroundStyle(.red)
        case .transcribing, .analyzing:
            ProgressView().controlSize(.mini).frame(width: 16)
        case .ready:
            Image(systemName: "text.document").foregroundStyle(.tint)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
