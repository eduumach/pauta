import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(Pref.sttModel) private var sttModel = Pref.defaultSTTModel
    @AppStorage(Pref.llmModel) private var llmModel = Pref.defaultLLMModel
    @AppStorage(Pref.language) private var language = "pt"
    @AppStorage(Pref.userName) private var userName = ""
    @AppStorage(Pref.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(Pref.diarize) private var diarize = true
    @AppStorage(Pref.showIsland) private var showIsland = true
    @AppStorage(Pref.showLiveCaption) private var showLiveCaption = false
    @AppStorage(Pref.transcriptionMode) private var mode = TranscriptionMode.local.rawValue

    @State private var modelStatus: LocalSpeech.ModelStatus?
    @State private var downloadProgress: Double?

    @State private var apiKey = Pref.apiKey
    @State private var keyStatus: KeyStatus = .idle
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum KeyStatus: Equatable {
        case idle, checking, ok, failed(String)
    }

    var body: some View {
        Form {
            Section {
                SecureField("Chave da API", text: $apiKey, prompt: Text("sk-or-v1-…"))
                    .onChange(of: apiKey) { _, value in
                        Pref.apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        keyStatus = .idle
                    }
                HStack {
                    Link("Criar uma chave no OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                        .font(.callout)
                    Spacer()
                    switch keyStatus {
                    case .idle: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .ok: Label("Funcionando", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let message): Text(message).foregroundStyle(.red).lineLimit(2).font(.caption)
                    }
                    Button("Testar") { Task { await testKey() } }
                        .disabled(apiKey.isEmpty || keyStatus == .checking)
                }
            } header: {
                Text("OpenRouter")
            } footer: {
                Text("A chave fica guardada no Keychain do macOS.").foregroundStyle(.secondary)
            }

            Section {
                Picker("Modo", selection: $mode) {
                    Text("Local (Apple) — grátis, ao vivo").tag(TranscriptionMode.local.rawValue)
                    Text("Nuvem (OpenRouter) — ~US$ 0,22/h").tag(TranscriptionMode.cloud.rawValue)
                    Text("Híbrido — ao vivo + refinado na nuvem").tag(TranscriptionMode.hybrid.rawValue)
                }
                Picker("Idioma das reuniões", selection: $language) {
                    Text("Português").tag("pt")
                    Text("Inglês").tag("en")
                    Text("Espanhol").tag("es")
                    Text("Idioma do sistema").tag("")
                }
                if mode != TranscriptionMode.cloud.rawValue {
                    LabeledContent("Modelo local") { modelStatusView }
                }
                if mode != TranscriptionMode.local.rawValue {
                    TextField("Modelo na nuvem", text: $sttModel)
                    Toggle("Identificar quem está falando", isOn: $diarize)
                }
            } header: {
                Text("Transcrição")
            } footer: {
                Text(modeDescription).foregroundStyle(.secondary)
            }
            .task(id: language) { modelStatus = await LocalSpeech.modelStatus() }

            Section("Análise") {
                TextField("Modelo de análise e conversa", text: $llmModel)
                Button("Restaurar modelos padrão") {
                    sttModel = Pref.defaultSTTModel
                    llmModel = Pref.defaultLLMModel
                }
            }

            Section("Gravação") {
                Toggle("Gravar áudio do sistema (participantes da chamada)", isOn: $captureSystemAudio)
                TextField("Seu nome", text: $userName, prompt: Text("Ajuda a IA a saber quem é você"))
                LabeledContent("Atalho global") { Text("⌥⌘R").monospaced() }
            }

            Section("Aparência") {
                Toggle("Mostrar ilha no notch", isOn: $showIsland)
                Toggle("Legenda ao vivo na ilha", isOn: $showLiveCaption)
                    .disabled(!showIsland || mode == TranscriptionMode.cloud.rawValue)
                Toggle("Abrir ao iniciar sessão", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Integrações") {
                LabeledContent("TickTick") { Text("Em breve").foregroundStyle(.secondary) }
                LabeledContent("Todoist") { Text("Em breve").foregroundStyle(.secondary) }
            }

            Section {
                Button("Abrir pasta das reuniões") { NSWorkspace.shared.open(app.store.root) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 700)
    }

    private var modeDescription: String {
        switch TranscriptionMode(rawValue: mode) ?? .local {
        case .local:
            "Transcreve no próprio Mac enquanto você fala, sem custo e sem enviar o áudio. Separa \"Você\" (microfone) de \"Participantes\" (áudio do sistema). Use fones para evitar eco."
        case .cloud:
            "Envia o áudio ao OpenRouter no fim da reunião. Mais preciso com nomes e identifica cada participante."
        case .hybrid:
            "Mostra o texto ao vivo durante a reunião e, no fim, refina com o modelo na nuvem. Se a nuvem falhar, usa a versão local."
        }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        if let downloadProgress {
            ProgressView(value: downloadProgress).frame(width: 140)
        } else {
            switch modelStatus {
            case nil:
                ProgressView().controlSize(.small)
            case .installed:
                Label("Instalado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .downloading:
                Label("Baixando…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
            case .notInstalled:
                Button("Baixar modelo") { Task { await download() } }
            case .unsupported:
                Text("Idioma não suportado").foregroundStyle(.orange)
            }
        }
    }

    private func download() async {
        downloadProgress = 0
        do {
            try await LocalSpeech.installModel { value in
                Task { @MainActor in downloadProgress = value }
            }
        } catch {
            keyStatus = .failed(error.localizedDescription)
        }
        downloadProgress = nil
        modelStatus = await LocalSpeech.modelStatus()
    }

    private func testKey() async {
        keyStatus = .checking
        do {
            let client = try OpenRouterClient(apiKey: apiKey)
            _ = try await client.complete(model: llmModel, messages: [.init(role: "user", content: "Responda apenas: ok")])
            keyStatus = .ok
        } catch {
            keyStatus = .failed(error.localizedDescription)
        }
    }
}
