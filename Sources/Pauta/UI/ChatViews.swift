import SwiftUI

/// Shared conversation UI: message list, suggestion chips and a glass input bar.
struct ChatView<Header: View>: View {
    let messages: [ChatMessage]
    let suggestions: [String]
    let isThinking: Bool
    let send: (String) -> Void
    @ViewBuilder var header: () -> Header

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header()
                    if messages.isEmpty {
                        FlowSuggestions(suggestions: suggestions, pick: submit)
                    }
                    ForEach(messages) { message in
                        Bubble(message: message).id(message.id)
                    }
                    if isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Pensando…").foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                }
                .padding(24)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.count) {
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: isThinking) {
                if isThinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                TextField("Pergunte qualquer coisa sobre as reuniões…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { submit(draft) }
                Button {
                    submit(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
            .frame(maxWidth: 720)
            .padding(16)
        }
        .onAppear { focused = true }
    }

    private func submit(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        draft = ""
        send(question)
    }
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }
            Text(markdown)
                .textSelection(.enabled)
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.role == .user ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.background.secondary),
                    in: .rect(cornerRadius: 16)
                )
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }
}

private struct FlowSuggestions: View {
    let suggestions: [String]
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    pick(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
            }
        }
    }
}

// MARK: - Per meeting

struct MeetingChatTab: View {
    @Environment(AppState.self) private var app
    let meeting: Meeting
    @State private var thinking = false

    var body: some View {
        ChatView(
            messages: meeting.chat,
            suggestions: [
                "Qual foi a decisão mais importante?",
                "O que ficou pendente para mim?",
                "Me ajude a decidir o que ficou em aberto",
                "Escreva um e-mail de follow-up",
            ],
            isThinking: thinking,
            send: { question in
                thinking = true
                Task {
                    await app.ask(question, in: meeting.id)
                    thinking = false
                }
            },
            header: { EmptyView() }
        )
    }
}

// MARK: - Across all meetings

struct MemoryView: View {
    @Environment(AppState.self) private var app
    @State private var messages: [ChatMessage] = []
    @State private var thinking = false

    var body: some View {
        ChatView(
            messages: messages,
            suggestions: [
                "O que decidimos nas reuniões desta semana?",
                "Quais tarefas estão comigo?",
                "Quais assuntos continuam sem decisão?",
                "Prepare uma pauta para a próxima reunião",
            ],
            isThinking: thinking,
            send: send,
            header: {
                if messages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 34))
                            .foregroundStyle(.tint)
                            .symbolEffect(.breathe)
                        Text("Pergunte às suas reuniões").font(.largeTitle.weight(.bold))
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 8)
                }
            }
        )
        .navigationTitle("Pauta")
        .toolbar {
            if !messages.isEmpty {
                Button("Nova conversa", systemImage: "square.and.pencil") { messages = [] }
            }
        }
    }

    private var subtitle: String {
        let count = app.store.meetings.filter { $0.status == .ready }.count
        return count == 0
            ? "Grave sua primeira reunião com ⌥⌘R ou pelo ícone na barra de menus."
            : "O Pauta lembra de \(count) \(count == 1 ? "reunião" : "reuniões") e ajuda você a decidir com base nelas."
    }

    private func send(_ question: String) {
        let history = messages
        messages.append(ChatMessage(role: .user, text: question))
        thinking = true
        Task {
            let answer = await app.askMemory(question, history: history)
            messages.append(ChatMessage(role: .assistant, text: answer))
            thinking = false
        }
    }
}
