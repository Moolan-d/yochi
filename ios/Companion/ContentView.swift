import SwiftUI

struct ContentView: View {
    @State private var config = GatewayConfig.load()
    @State private var client = GatewayClient()
    @State private var showingSettings = false
    @State private var path: [Session] = []
    /// Opened from a pairing QR code; fills in the pairing form.
    @State private var invite: PairingInvite?
    /// Opened while already paired; replaces the Gateway once confirmed.
    @State private var replacement: PairingInvite?
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
                            GatewaySettingsView(client: client, config: config, onForget: forget)
                        }
                } else {
                    PairingView(invite: invite) { config in
                        config.save()
                        invite = nil
                        self.config = config
                    }
                }
            }
            .navigationTitle("Companion")
        }
        .onOpenURL { url in
            guard let opened = PairingInvite(url: url) else { return }
            if config == nil {
                invite = opened
            } else {
                replacement = opened
            }
        }
        .confirmationDialog("与新的 Gateway 配对？", isPresented: Binding(
            get: { replacement != nil },
            set: { if !$0 { replacement = nil } }
        ), titleVisibility: .visible, presenting: replacement) { opened in
            Button("配对新的 Gateway", role: .destructive) {
                showingSettings = false
                path = []
                forget()
                invite = opened
            }
        } message: { _ in
            Text("此 iPhone 与 \(config?.host ?? "当前 Gateway") 的配对将被删除。")
        }
        .onChange(of: config, initial: true) { _, config in
            if let config { client.connect(config) }
        }
        #if DEBUG
        // `simctl launch` can pair without tapping: SIMCTL_CHILD_COMPANION_PAIR=companion://pair?….
        .task {
            guard config == nil, let raw = ProcessInfo.processInfo.environment["COMPANION_PAIR"],
                  let url = URL(string: raw), let opened = PairingInvite(url: url) else { return }
            do {
                let paired = try await opened.pair()
                paired.save()
                config = paired
            } catch {
                print("COMPANION_PAIR failed: \(error)")
            }
        }
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
        GatewayConfig.clear()
        config = nil
        Task { await client.unpair() }
    }
}

struct PairingView: View {
    var invite: PairingInvite?
    var onPaired: (GatewayConfig) -> Void
    @State private var host = ""
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?

    private var canPair: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !code.trimmingCharacters(in: .whitespaces).isEmpty && !pairing
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
                LabeledContent("配对码") {
                    TextField("配对码", text: $code, prompt: Text("XXXX-XXXX"))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .monospaced()
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Gateway")
            } footer: {
                Text("在主 Mac 上运行 companion-gateway pair，用相机扫描显示的二维码，或在此填写地址和配对码。")
            }
            Section {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Button {
                    Task { await pair() }
                } label: {
                    HStack {
                        Text("配对")
                        if pairing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canPair)
            } footer: {
                Text("配对后，此 iPhone 可以查看并操作主 Mac 上的全部会话终端，相当于用你的账户在该 Mac 及其连接的机器上执行命令。")
            }
        }
        .onSubmit { if canPair { Task { await pair() } } }
        .onChange(of: invite, initial: true) { _, invite in
            guard let invite else { return }
            host = invite.host
            code = invite.code
            error = nil
        }
    }

    private func pair() async {
        pairing = true
        error = nil
        defer { pairing = false }
        let invite = PairingInvite(host: host.trimmingCharacters(in: .whitespaces),
                                   code: code.trimmingCharacters(in: .whitespaces))
        do {
            onPaired(try await invite.pair())
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GatewaySettingsView: View {
    let client: GatewayClient
    let config: GatewayConfig
    var onForget: () -> Void
    @State private var confirmingForget = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    LabeledContent("地址", value: config.host)
                    LabeledContent("状态", value: client.statusText)
                    if let core = client.coreName {
                        LabeledContent("主 Mac", value: core)
                    }
                }
                if let device = config.device {
                    Section {
                        LabeledContent("设备 ID", value: device)
                            .textSelection(.enabled)
                    } footer: {
                        Text("在主 Mac 上运行 companion-gateway devices 可查看所有已配对的设备。")
                    }
                }
                Section {
                    Button("取消配对", role: .destructive) { confirmingForget = true }
                } footer: {
                    Text("此 iPhone 将删除与该 Gateway 的配对。已连接时 Gateway 会同时移除这台设备，否则请在主 Mac 上运行 companion-gateway revoke。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("取消与此 Gateway 的配对？", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("取消配对", role: .destructive) {
                    dismiss()
                    onForget()
                }
                } message: {
                Text("之后需要在主 Mac 上重新运行 companion-gateway pair 才能再次连接。")
            }
        }
    }
}

#Preview {
    ContentView()
}
