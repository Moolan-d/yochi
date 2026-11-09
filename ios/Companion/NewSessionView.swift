import SwiftUI

/// Starts a terminal on the Gateway's core, or on a connected machine: an
/// Agent or the machine's shell, in a chosen directory and Herdr space. The
/// Gateway runs it with `terminal.run`; the phone is not a Takeover and never
/// sizes it.
struct NewSessionView: View {
    let client: GatewayClient
    /// The new terminal's id in the session list; the list opens it.
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var machine: String?
    @State private var program = Program.agent
    @State private var directory = ""
    /// The space the user picked; nil follows the directory. "" is a new space.
    @State private var pickedSpace: String?
    @State private var creating = false
    @State private var failure: String?

    enum Program: String, CaseIterable, Identifiable {
        case agent = "Claude Code"
        case shell = "Terminal"

        var id: String { rawValue }
        var title: String { self == .agent ? rawValue : String(localized: "Terminal") }
        /// Empty argv is the machine's own shell.
        var argv: [String] { self == .agent ? ["claude"] : [] }
    }

    /// Directories of the chosen machine's live sessions, newest first as the
    /// list orders them. Picking one beats typing a path that may not exist.
    private var recentDirectories: [String] {
        var seen = Set<String>()
        return client.sessions
            .filter { $0.machine == machine }
            .map(\.cwd)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(4)
            .map { $0 }
    }

    /// Machines with a live session; a machine with none can't be chosen yet.
    private var machines: [String] {
        Array(Set(client.sessions.compactMap(\.machine) + client.spaces.compactMap(\.machine))).sorted()
    }

    private var connected: Bool { client.phase == .connected }

    private var machineSpaces: [Space] { client.spaces.filter { $0.machine == machine } }

    /// The chosen space's id; "" for a new one.
    private var space: Binding<String> {
        Binding {
            if let pickedSpace, pickedSpace.isEmpty || machineSpaces.contains(where: { $0.id == pickedSpace }) {
                return pickedSpace
            }
            return spaceHolding(directory, in: machineSpaces)?.id ?? ""
        } set: {
            pickedSpace = $0
        }
    }

    var body: some View {
        NavigationStack {
            HomeForm {
                if !machines.isEmpty {
                    Section("Machine") {
                        Picker("Machine", selection: $machine) {
                            Text("This Mac").tag(String?.none)
                            ForEach(machines, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .accessibilityIdentifier("newSessionMachine")
                        .onChange(of: machine) { _, _ in pickedSpace = nil }
                    }
                }
                Section("Program") {
                    Picker("Program", selection: $program) {
                        ForEach(Program.allCases) { program in
                            Text(program.title).tag(program)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newSessionProgram")
                }
                Section {
                    TextField("Directory", text: $directory, prompt: Text("/Users/you/project"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                        .accessibilityIdentifier("newSessionDirectory")
                } footer: {
                    Text(directoryHint)
                }
                if !recentDirectories.isEmpty {
                    Section("Recent Directories") {
                        ForEach(recentDirectories, id: \.self) { path in
                            Button {
                                directory = path
                            } label: {
                                HStack {
                                    Text(path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    if directory == path {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityIdentifier("recentDirectory")
                        }
                    }
                }
                Section {
                    Picker("Space", selection: space) {
                        Text("New Space").tag("")
                        ForEach(machineSpaces) { space in
                            Text(space.name).tag(space.id)
                        }
                    }
                    .accessibilityIdentifier("newSessionSpace")
                } footer: {
                    Text(space.wrappedValue.isEmpty
                         ? "Herdr desktop creates a Space for it, named after the directory."
                         : "Herdr desktop opens a new tab for it in this Space.")
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) {
                        if creating {
                            ProgressView()
                        } else {
                            Text("Create")
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
        let fallback = machine == nil ? String(localized: "herdr-core's current directory") : String(localized: "the machine's home directory")
        let trust = program == .agent ? String(localized: "The first time Claude Code opens a directory, it may ask in the terminal whether to trust it.") : ""
        return String(localized: "Leave empty to use \(fallback). \(trust)")
    }

    private func create() {
        creating = true
        failure = nil
        Task {
            defer { creating = false }
            let space = space.wrappedValue
            switch await client.runSession(machine: machine, cwd: directory, argv: program.argv,
                                           space: space.isEmpty ? nil : space) {
            case .created(let session):
                // Claude Code is typed into the new shell; its conversation
                // shows from the start rather than once it is up.
                if program == .agent { client.pageChoices[session] = .conversation }
                onCreated(session)
                dismiss()
            case .failed(_, let message):
                // Name the directory that was actually sent: a stray invisible
                // character makes the core report a missing program instead.
                let sent = directory.trimmingCharacters(in: .whitespacesAndNewlines)
                failure = sent.isEmpty ? message : String(localized: "Couldn't start in “\(sent)”: \(message)")
            case .unknown:
                failure = String(localized: "Result unknown. Go back to the list to see whether it was created")
            }
        }
    }
}

/// The space whose folder holds `directory`, the innermost one if several do:
/// a session started there belongs with that space's terminals.
func spaceHolding(_ directory: String, in spaces: [Space]) -> Space? {
    let path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else { return nil }
    let trimmed = { (path: String) in path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
    let target = trimmed(path)
    return spaces
        .compactMap { space in space.folder.map { (space, trimmed($0)) } }
        .filter { _, folder in
            folder.hasPrefix("/") && (target == folder || target.hasPrefix(folder == "/" ? "/" : folder + "/"))
        }
        .max { $0.1.count < $1.1.count }?
        .0
}
