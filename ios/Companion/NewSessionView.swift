import SwiftUI

/// Starts a terminal on the Gateway's core, or on a connected machine: an
/// Agent or the machine's shell, in a chosen directory. The Gateway runs it
/// with `terminal.run`; the phone is not a Takeover and never sizes it.
struct NewSessionView: View {
    let client: GatewayClient
    /// The new terminal's id in the session list; the list opens it.
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var machine: String?
    @State private var program = Program.agent
    @State private var directory = ""
    @State private var creating = false
    @State private var failure: String?

    enum Program: String, CaseIterable, Identifiable {
        case agent = "Claude Code"
        case shell = "终端"

        var id: String { rawValue }
        /// Empty argv is the machine's own shell.
        var argv: [String] { self == .agent ? ["claude"] : [] }
    }

    /// Machines with a live session; a machine with none can't be chosen yet.
    private var machines: [String] {
        Array(Set(client.sessions.compactMap(\.machine) + client.spaces.compactMap(\.machine))).sorted()
    }

    private var connected: Bool { client.phase == .connected }

    var body: some View {
        NavigationStack {
            Form {
                if !machines.isEmpty {
                    Section("机器") {
                        Picker("机器", selection: $machine) {
                            Text("本机").tag(String?.none)
                            ForEach(machines, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .accessibilityIdentifier("newSessionMachine")
                    }
                }
                Section("程序") {
                    Picker("程序", selection: $program) {
                        ForEach(Program.allCases) { program in
                            Text(program.rawValue).tag(program)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newSessionProgram")
                }
                Section {
                    TextField("目录", text: $directory, prompt: Text("/Users/you/project"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                        .accessibilityIdentifier("newSessionDirectory")
                } footer: {
                    Text(directoryHint)
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) {
                        if creating {
                            ProgressView()
                        } else {
                            Text("创建")
                        }
                    }
                    .disabled(creating || !connected)
                    .accessibilityIdentifier("createSession")
                }
            }
        }
        .interactiveDismissDisabled(creating)
    }

    private var directoryHint: String {
        let fallback = machine == nil ? "herdr-core 的当前目录" : "该机器的 home 目录"
        let trust = program == .agent ? "Claude Code 第一次进入新目录时可能在终端里询问是否信任。" : ""
        return "留空则使用\(fallback)。\(trust)"
    }

    private func create() {
        creating = true
        failure = nil
        Task {
            defer { creating = false }
            switch await client.runSession(machine: machine, cwd: directory, argv: program.argv) {
            case .created(let session):
                onCreated(session)
                dismiss()
            case .failed(_, let message):
                failure = message
            case .unknown:
                failure = "结果未知，请返回列表查看是否已创建"
            }
        }
    }
}
