import SwiftUI

struct ContentView: View {
    @State private var config = GatewayConfig.load()
    @State private var client = GatewayClient()
    @State private var seen = SeenTurns()
    @State private var showingSettings = false
    @State private var showingNewSession = false
    @State private var path: [Session] = []
    /// The map of the tab's panes, shown while switching between them.
    @State private var paneHint: PaneTab?
    @State private var paneHintFade: Task<Void, Never>?
    /// A terminal just started from the phone; opened once the list has it.
    @State private var opening: String?
    /// Opened from a pairing QR code; fills in the pairing form.
    @State private var invite: PairingInvite?
    /// Opened while already paired; replaces the Gateway once confirmed.
    @State private var replacement: PairingInvite?
    #if DEBUG
    @State private var openedFromLaunch = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let _ = Perf.count("ContentView")
        NavigationStack(path: $path) {
            Group {
                if let config {
                    SessionListView(client: client, seen: seen, retry: { client.connect(config) }, reenter: forget,
                                    newSession: { showingNewSession = true })
                        .navigationTitle(String(localized: "home.title", defaultValue: "Agents"))
                        .navigationDestination(for: Session.self) { session in
                            ObserveView(session: session, config: config, client: client,
                                        open: { switchPane(from: session, to: $0) },
                                        showPanes: showPanes)
                            // A pane switch swaps the path's last session in place, and the
                            // stack keeps the destination at that spot, @State included; the
                            // page would go on showing the old session's streams under the
                            // new title. A new session is a new page.
                            .id(session.id)
                        }
                        .toolbar {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button("New", systemImage: "plus") { showingNewSession = true }
                                    .disabled(client.phase != .connected)
                                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                                    .accessibilityIdentifier("home.settings")
                            }
                        }
                        .sheet(isPresented: $showingNewSession) {
                            NewSessionView(client: client) { session in
                                opening = session
                                // The list may already carry it; otherwise its
                                // next change opens it.
                                openPending()
                            }
                        }
                } else {
                    PairingView(invite: invite) { config in
                        config.save()
                        invite = nil
                        self.config = config
                    }
                    .navigationTitle("Yochi")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(client: client, config: config, onForget: forget)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let paneHint {
                PaneMap(tab: paneHint)
                    .padding(.top, 56)
                    .padding(.trailing, 16)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
            }
        }
        .onOpenURL { url in
            guard let opened = PairingInvite(url: url) else { return }
            if config == nil {
                invite = opened
            } else {
                replacement = opened
            }
        }
        .confirmationDialog("Pair with a New Gateway?", isPresented: Binding(
            get: { replacement != nil },
            set: { if !$0 { replacement = nil } }
        ), titleVisibility: .visible, presenting: replacement) { opened in
            Button("Pair a New Gateway", role: .destructive) {
                showingSettings = false
                path = []
                forget()
                invite = opened
            }
            // iOS drops `.cancel` buttons from this popover, so keeping is a plain button.
            Button("Keep Current Pairing") {}
        } message: { _ in
            Text("This iPhone's pairing with \(config?.host ?? String(localized: "the current Gateway")) will be removed.")
        }
        .onChange(of: config, initial: true) { _, config in
            if let config { client.connect(config) }
        }
        .onAppear {
            client.onTailnet = { host in
                guard var config = self.config, config.host != host else { return }
                config.host = host
                config.save()
                self.config = config
            }
        }
        #if DEBUG
        // `simctl launch` can pair without tapping: SIMCTL_CHILD_COMPANION_PAIR=yochi://pair?….
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
        .onChange(of: client.sessions) { _, sessions in
            openPending(sessions)
            recordSeen()
            if client.phase == .connected && client.coreConnected { seen.keep(only: sessions) }
        }
        .onChange(of: path) {
            recordSeen()
            if path.isEmpty { paneHintFade?.cancel(); paneHint = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let config else { return }
            switch phase {
            case .active: if client.phase != .connected { client.connect(config) }
            case .background: client.disconnect()
            default: break
            }
        }
    }

    /// A terminal in the same tab takes this one's place at once, so Back
    /// still leads home however often the user switches.
    private func switchPane(from session: Session, to mate: Session) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            if path.last == session { path[path.count - 1] = mate } else { path.append(mate) }
        }
        showPanes(mate.id, holding: false)
    }

    /// Shows where `id` sits in its tab; once let go, the map fades.
    private func showPanes(_ id: String, holding: Bool) {
        paneHintFade?.cancel()
        let tab = PaneTab(of: id, sessions: client.sessions, spaces: client.spaces)
        withAnimation(.snappy(duration: 0.2)) { paneHint = tab }
        guard !holding, tab != nil else { return }
        paneHintFade = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { paneHint = nil }
        }
    }

    /// Opens a terminal just started from the phone, once the list has it.
    private func openPending(_ sessions: [Session]? = nil) {
        guard let opening, let session = (sessions ?? client.sessions).first(where: { $0.id == opening }) else { return }
        self.opening = nil
        path = [session]
    }

    /// An open conversation shows its newest turn, so that turn is seen.
    private func recordSeen() {
        for opened in path {
            if let session = client.sessions.first(where: { $0.id == opened.id }) { seen.record(session) }
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

    /// A scanned link pairs through the Relay while its address is untouched,
    /// so then neither the address nor the code has to be filled in.
    private var throughRelay: Bool {
        invite?.relay != nil && invite?.host == host.trimmingCharacters(in: .whitespaces)
    }

    private var canPair: Bool {
        let filled = !host.trimmingCharacters(in: .whitespaces).isEmpty && !code.trimmingCharacters(in: .whitespaces).isEmpty
        return (filled || throughRelay) && !pairing
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Address") {
                    TextField("Address", text: $host, prompt: Text(throughRelay ? "Relay only" : "100.x.y.z"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Pairing Code") {
                    TextField("Pairing Code", text: $code, prompt: Text("XXXX-XXXX"))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .monospaced()
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Gateway")
            } footer: {
                Text("Run yochi pair on the main Mac, then scan its QR code with the Camera, or enter the address and pairing code here.")
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
                        Text("Pair")
                        if pairing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canPair)
            } footer: {
                Text("Once paired, this iPhone can see and control every session terminal on the main Mac: it can run commands as your account on that Mac and the machines it connects to.")
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
        let host = host.trimmingCharacters(in: .whitespaces)
        // A scanned link's way through the Relay holds while its address does.
        let invite = PairingInvite(host: host, code: code.trimmingCharacters(in: .whitespaces),
                                   relay: self.invite?.host == host ? self.invite?.relay : nil)
        do {
            onPaired(try await invite.pair())
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
