import SwiftUI

/// How the app draws itself: light, dark, or as the system does.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system

    static let key = "appearance"

    var id: Self { self }

    /// nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    var title: String {
        switch self {
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .system: String(localized: "Match System")
        }
    }
}

/// Settings, open whether or not this iPhone is paired: the Gateway it is
/// paired with (one level down), how the app looks, and its language.
struct SettingsView: View {
    let client: GatewayClient
    /// nil until this iPhone is paired.
    let config: GatewayConfig?
    var onForget: () -> Void
    @AppStorage(Appearance.key) private var appearance: Appearance = .system
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            HomeForm {
                Section {
                    if let config {
                        NavigationLink {
                            GatewayDetailView(client: client, config: config, close: { dismiss() }, onForget: onForget)
                        } label: {
                            GatewayCard(title: client.coreName ?? String(localized: "Gateway"),
                                        subtitle: connectionSummary, symbol: "desktopcomputer", tint: tint)
                        }
                        .accessibilityIdentifier("settings.gateway")
                    } else {
                        GatewayCard(title: String(localized: "Not Paired"),
                                    subtitle: String(localized: "Run yochi pair on the main Mac"),
                                    symbol: "desktopcomputer", tint: .gray)
                    }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        // Spelled out: a Button tints LabeledContent's label.
                        HStack(spacing: 4) {
                            Text("Language")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Text(currentLanguage)
                            Image(systemName: "arrow.up.forward.app")
                                .imageScale(.small)
                        }
                        .foregroundStyle(Color.secondary)
                        .contentShape(.rect)
                    }
                    .accessibilityIdentifier("settings.language")
                } footer: {
                    Text("Choose Yochi's language in the Settings app.")
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The Gateway's state and, once connected, which way it is reached.
    private var connectionSummary: String {
        guard client.phase == .connected, let path = client.path else { return client.statusText }
        return "\(client.statusText) · \(path == .relay ? "Relay" : "Tailnet")"
    }

    private var tint: Color {
        switch client.phase {
        case .connected: client.coreConnected ? .green : .orange
        case .connecting, .disconnected: .orange
        case .failed, .unauthorized: .red
        }
    }

    /// The language the app is showing, in that language.
    private var currentLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
}

/// The top row of Settings: which Gateway, and how it is doing.
private struct GatewayCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The pairing with the Gateway: where it is, how it is reached, this
/// device's ID, and unpairing.
struct GatewayDetailView: View {
    let client: GatewayClient
    let config: GatewayConfig
    /// Closes Settings, from this page as from the top.
    var close: () -> Void
    var onForget: () -> Void
    @State private var confirmingForget = false

    var body: some View {
        HomeForm {
            Section("Connection") {
                LabeledContent("Address", value: config.host.isEmpty ? String(localized: "Relay only") : config.host)
                    .accessibilityIdentifier("gateway.host")
                LabeledContent("Status", value: client.statusText)
                if let path = client.path {
                    LabeledContent("Connection", value: path == .relay ? String(localized: "Relay (end-to-end encrypted)") : "Tailnet")
                        .accessibilityIdentifier("gateway.path")
                }
                if let core = client.coreName {
                    LabeledContent("Main Mac", value: core)
                }
            }
            if let device = config.device {
                Section {
                    LabeledContent("Device ID", value: device)
                        .textSelection(.enabled)
                } footer: {
                    Text("Run yochi devices on the main Mac to see every paired device.")
                }
            }
            Section {
                Button("Unpair", role: .destructive) { confirmingForget = true }
            } footer: {
                Text("This iPhone will remove its pairing with that Gateway. If connected, the Gateway removes this device too; otherwise run yochi revoke on the main Mac.")
            }
        }
        .navigationTitle("Gateway")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: close)
            }
        }
        .confirmationDialog("Unpair from This Gateway?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                close()
                onForget()
            }
            Button("Keep Pairing") {}
        } message: {
            Text("To connect again, run yochi pair on the main Mac.")
        }
    }
}
