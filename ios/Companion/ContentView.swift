import SwiftUI

struct ContentView: View {
    @State private var config = GatewayConfig.load()
    @State private var client = GatewayClient()
    @State private var showingSettings = false
    @State private var path: [Session] = []
    #if DEBUG
    @State private var openedFromLaunch = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let config {
                    SessionListView(client: client, retry: { client.connect(config) }, reenter: forget)
                        .navigationDestination(for: Session.self) { session in
                            ObserveView(session: session, config: config)
                        }
                        .toolbar {
                            Button("设置", systemImage: "gearshape") { showingSettings = true }
                        }
                        .sheet(isPresented: $showingSettings) {
                            GatewaySettingsView(client: client, host: config.host, onForget: forget)
                        }
                } else {
                    SetupView { config in
                        config.save()
                        self.config = config
                    }
                }
            }
            .navigationTitle("Companion")
        }
        .onChange(of: config, initial: true) { _, config in
            if let config { client.connect(config) }
        }
        #if DEBUG
        // `simctl launch` can open a session directly: SIMCTL_CHILD_COMPANION_OBSERVE=<id>.
        .onChange(of: client.sessions) { _, sessions in
            guard !openedFromLaunch, let id = ProcessInfo.processInfo.environment["COMPANION_OBSERVE"],
                  let session = sessions.first(where: { $0.id == id }) else { return }
            openedFromLaunch = true
            path = [session]
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            guard let config else { return }
            switch phase {
            case .active: if client.phase != .connected { client.connect(config) }
            case .background: client.disconnect()
            default: break
            }
        }
    }

    private func forget() {
        client.disconnect()
        GatewayConfig.clear()
        config = nil
    }
}

struct SetupView: View {
    var onSave: (GatewayConfig) -> Void
    @State private var host = ""
    @State private var token = ""

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("地址") {
                    TextField("地址", text: $host, prompt: Text("100.x.y.z"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Token") {
                    SecureField("Token", text: $token, prompt: Text("必填"))
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Gateway")
            } footer: {
                Text("填写主 Mac 的 Tailscale 地址，以及 Gateway 启动时显示的 Token。")
            }
            Section {
                Button("连接", action: save)
                    .disabled(!canConnect)
            }
        }
        .onSubmit { if canConnect { save() } }
    }

    private func save() {
        onSave(GatewayConfig(host: host.trimmingCharacters(in: .whitespaces),
                             token: token.trimmingCharacters(in: .whitespaces)))
    }
}

struct GatewaySettingsView: View {
    let client: GatewayClient
    let host: String
    var onForget: () -> Void
    @State private var confirmingForget = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    LabeledContent("地址", value: host)
                    LabeledContent("状态", value: client.statusText)
                    if let core = client.coreName {
                        LabeledContent("主 Mac", value: core)
                    }
                }
                Section {
                    Button("忘记此 Gateway", role: .destructive) { confirmingForget = true }
                } footer: {
                    Text("将删除此设备上保存的地址和 Token。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("忘记此 Gateway？", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("忘记 Gateway", role: .destructive) {
                    dismiss()
                    onForget()
                }
            } message: {
                Text("需要重新填写地址和 Token 才能再次连接。")
            }
        }
    }
}

#Preview {
    ContentView()
}
