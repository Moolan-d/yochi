import PhotosUI
import SwiftUI

/// One session on one page: a terminal started as Claude Code shows its
/// conversation; any other, an Agent typed into a shell included, its
/// terminal, taken over at the phone's grid while shown. Agent Messages,
/// key presses and answers never attach; only the terminal page resizes
/// the desktop's grid.
struct ObserveView: View {
    let session: Session
    let config: GatewayConfig
    let client: GatewayClient
    /// Switches to another session in the same tab, in this page's place.
    var open: (Session) -> Void
    /// Shows the map of this tab's panes: held while a swipe is on.
    var showPanes: (_ id: String, _ holding: Bool) -> Void

    /// The page's streams, kept by the client's cache for a while after the
    /// page leaves: coming back shows the last conversation and terminal at
    /// once and carries on from there.
    @State private var feeds: SessionFeeds
    @State private var grid: TerminalGrid?
    /// The page between the navigation bar and the bottom, keyboard excluded.
    @State private var pageHeight: CGFloat = 0
    @State private var draft: String
    @State private var confirmingBlocked = false
    @State private var keys = KeyPresser()
    @State private var stopping = false
    @State private var stopNotice: String?
    /// The mode a switch from the phone reached, shown until the transcript
    /// records a newer one with the next message.
    @State private var switchedMode: PermissionMode?
    @State private var seenModes: Set<PermissionMode> = []
    @State private var switchingMode = false
    @State private var modeFailure: String?
    @State private var attachments: [ImageAttachment] = []
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var takingPhoto = false
    /// This session's custom commands and skills, listed again each time the
    /// draft starts a slash command.
    @State private var customCommands: [SlashCommand] = []
    @State private var confirmingExit = false
    @State private var showingChanges = false
    @AppStorage(TerminalTextSize.key) private var terminalFontSize = TerminalTextSize.standard
    @FocusState private var composerFocused: Bool
    /// A terminal that types shows its command field while the user writes there.
    @State private var composing = false
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session, config: GatewayConfig, client: GatewayClient,
         open: @escaping (Session) -> Void, showPanes: @escaping (String, Bool) -> Void) {
        self.session = session
        self.config = config
        self.client = client
        self.open = open
        self.showPanes = showPanes
        _draft = State(initialValue: AgentMessageStore.draft(host: config.host, session: session.id))
        _feeds = State(initialValue: client.feedStore.feeds(host: config.host, session: session.id))
    }

    private var conversation: ConversationFeed { feeds.conversation }
    private var screen: ScreenFeed { feeds.screen }
    private var cacheKey: String { SessionFeedStore.key(host: config.host, session: session.id) }

    private var currentSession: Session {
        client.sessions.first { $0.id == session.id } ?? session
    }

    /// Lives in the client so a result that arrives after this view leaves is
    /// still there on return, and never resurrects the sent draft.
    private var delivery: AgentDelivery? {
        client.delivery(host: config.host, session: session.id)
    }

    private var isSending: Bool {
        guard let delivery else { return false }
        if case .sending = delivery { return true }
        return false
    }

    private var queued: QueuedMessage? {
        client.queuedMessage(session: session.id)
    }

    /// While the Agent works a message waits on the phone for the turn to end.
    /// A slash command goes straight to the Agent, which runs or queues it on
    /// its own, instead of joining the queued text (#4).
    private var queuesMessage: Bool {
        isConversation && currentSession.status?.state == "working" && !QueuedMessage.isCommand(draft)
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !attachments.contains { $0.state == .uploading }
    }

    /// The mode line when the screen shows it (the transcript has none
    /// before the first message); else the last switch, else the transcript.
    private var shownMode: PermissionMode? {
        screenMode ?? switchedMode ?? conversation.mode
    }

    /// What the mode line under Claude Code's prompt shows now.
    private var screenMode: PermissionMode? {
        screen.screen.flatMap(PermissionMode.read)
    }

    /// Each press is checked on the screen, which the Gateway doesn't send
    /// while the Agent works; a dialog hides the mode line too.
    private var canSwitchMode: Bool {
        currentSession.status?.state != "working" && !switchingMode && screenMode != nil
    }

    /// With nothing to send while the Agent works, the send button stops it.
    /// Not while it waits: Esc would cancel the dialog, which its card does.
    private var showsStop: Bool {
        isConversation && currentSession.status?.state == "working" && !isSending
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Claude Code draws some dialogs only on screen; they show on the
    /// conversation page from the screen read, not while the Agent works
    /// (the Gateway sends no screen then, so the last one is stale).
    private var screenResult: DialogParseResult {
        guard isConversation, currentSession.status?.state != "working" else { return .none }
        return screen.result
    }

    /// Claude Code has the conversation page, even before its first message:
    /// its dialogs show there from the screen. Anything else has its
    /// terminal. The More menu switches between them. Once Claude Code was
    /// seen here the page stays the conversation after it quits.
    private var isConversation: Bool {
        if let choice = client.pageChoices[session.id] { return choice == .conversation }
        return session.showsConversation || currentSession.showsConversation
    }

    /// Whether the page can be the conversation at all.
    private var hasConversation: Bool {
        client.pageChoices[session.id] != nil || session.showsConversation || currentSession.showsConversation
    }

    // The page is built in three stages, in modifier order: one chain of
    // all of them takes the compiler seconds to type-check, and an older
    // Xcode gives up on it.
    var body: some View {
        let _ = Perf.count("ObserveView")
        following(attaching(page))
    }

    /// The conversation or the terminal, with its gestures, bars and prompts.
    private var page: some View {
        Group {
            if isConversation {
                ConversationPane(feed: conversation, status: currentSession.status,
                                 keyboardShown: composerFocused) {
                    conversation.start(config, session: session.id)
                }
            } else {
                TerminalPane(session: session.id, config: config, model: feeds.terminal, grid: $grid)
            }
        }
        // Tapping the conversation or the terminal puts the keyboard away, as
        // do dragging and the keyboard's 收起 button above it.
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
        // A sideways swipe away from the left edge goes to the next or the
        // previous terminal in the Agent's Herdr tab.
        .gesture(PaneSwipeGesture(enabled: paneTab != nil,
                                  began: { showPanes(session.id, true) },
                                  ended: swiped))
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .navigationDestination(isPresented: $showingChanges) { changesPage }
        .confirmationDialog("Send the Message Anyway?", isPresented: $confirmingBlocked, titleVisibility: .visible) {
            Button("Send Anyway") { send(force: true) }
            // iOS 26 can drop `.cancel` here; an explicit plain button remains.
            Button("Don't Send") {}
        } message: {
            Text("The Agent is waiting for a confirmation; your message may be taken as the answer")
        }
        .confirmationDialog("Sending /exit ends this session", isPresented: $confirmingExit, titleVisibility: .visible) {
            Button("Insert /exit", role: .destructive) { draft = "/exit" }
            Button("Cancel") {}
        } message: {
            Text("Once Claude Code quits, the program in the terminal ends")
        }
    }

    /// The draft, photos and Permission Mode as they change.
    private func attaching(_ page: some View) -> some View {
        page
        .onChange(of: draft) { _, draft in
            AgentMessageStore.saveDraft(draft, host: config.host, session: session.id)
        }
        .onChange(of: slashQuery != nil) { _, started in
            if started && isConversation { loadCommands() }
        }
        .onChange(of: currentSession.turn, initial: true) { _, _ in updateResponse() }
        .onChange(of: currentSession.status?.state) { _, state in
            if state != "working" { stopNotice = nil }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $pickedPhotos,
                      maxSelectionCount: max(1, ImageAttachment.limit - attachments.count), matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        attach(image)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { attach($0) }.ignoresSafeArea()
        }
        .onChange(of: conversation.mode) { _, mode in
            switchedMode = nil
            if let mode { seenModes.insert(mode) }
        }
        .onChange(of: screenMode) { _, mode in
            if let mode { seenModes.insert(mode) }
        }
    }

    /// Delivery, dialogs, app state and the page's streams.
    private func following(_ page: some View) -> some View {
        page
        // Returning while a send was in flight restores the draft from before the
        // send; once it is accepted, this view clears it too.
        .onChange(of: delivery) { _, delivery in
            if case .sent(let text, _, _, _) = delivery, draft == text { draft = "" }
        }
        // A dialog card needs the room the keyboard takes. The composer can
        // take the keyboard back once sending enables it again, which can
        // be after the card appeared, so both moments count.
        .onChange(of: screenResult.fingerprint) { _, _ in makeRoomForDialog() }
        .onChange(of: isSending) { _, _ in makeRoomForDialog() }
        .onChange(of: scenePhase) { _, phase in
            if isConversation, phase == .active, case .failed = conversation.phase {
                conversation.start(config, session: session.id)
            }
        }
        .onAppear {
            client.feedStore.cache.acquire(cacheKey, feeds)
            // Kept streams carry on; the Gateway sends a kept conversation
            // whole again on a new connection, which replaces it in place.
            startConversation()
        }
        // Switched in the More menu, or Claude Code started in the shell.
        .onChange(of: isConversation) { _, _ in
            composerFocused = false
            startConversation()
        }
        .onDisappear {
            // The streams stay open while the cache keeps them.
            client.feedStore.cache.release(cacheKey, feeds)
        }
    }

    private func startConversation() {
        guard isConversation else { return }
        if conversation.needsStart { conversation.start(config, session: session.id) }
        if screen.needsStart { screen.start(config, session: session.id) }
    }

    /// Disabling the composer while it sends clears the focus state but
    /// keeps the keyboard up, so the first responder is resigned as well.
    private func makeRoomForDialog() {
        guard screenResult.fingerprint != nil, !isSending else { return }
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Status stays above the composer; safeAreaInset also gives the software
    /// keyboard room instead of covering the content.
    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if let dialog = screenResult.dialog {
                // Under half the page keeps the card under the navigation bar and
                // some of the conversation in view, whatever the text size.
                DialogCard(dialog: dialog, maxBodyHeight: pageHeight > 0 ? max(120, pageHeight * 0.45) : 300,
                           run: { plan, dialog in await dialogRunner.run(plan, on: dialog) })
                .id(dialog.fingerprint.value)
            } else if isConversation, let pending = conversation.pending,
                      screenResult.excerpt == nil || PendingCard.answers(pending, tool: conversation.pendingTool) {
                // What the screen shows beats a card that only says to
                // answer at the desk.
                PendingCard(pending: pending, tool: conversation.pendingTool,
                            answer: { choice in
                                await client.answer(session: session.id, choice: choice, expect: pending.message)
                            })
            } else if let excerpt = screenResult.excerpt {
                GenericDialogCard(excerpt: excerpt, press: { await press($0, on: excerpt) })
                    .id(excerpt.fingerprint.value)
            }
            if !isConversation, let failure = keys.failure {
                BannerLabel(text: failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let modeFailure {
                BannerLabel(text: modeFailure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("modeFailure")
            }
            if let stopNotice {
                BannerLabel(text: stopNotice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("stopNotice")
            }
            if let delivery { DeliveryBanner(delivery: delivery, shell: !isConversation) }
            if let queued {
                QueuedBanner(message: queued,
                             release: queued.release(state: currentSession.status?.state, turn: currentSession.turn),
                             send: { client.sendQueued(session: session.id) },
                             withdraw: withdrawQueued)
            }
            if isConversation, shownMode != nil || conversation.todoProgress != nil {
                HStack(spacing: 10) {
                    if let shownMode { modeChip(shownMode).layoutPriority(1) }
                    if let progress = conversation.todoProgress { TodoProgressLine(progress: progress) }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if !slashMatches.isEmpty {
                SlashSuggestions(commands: slashMatches, pick: pickCommand)
            }
            if !isConversation {
                // A takeover that types gets the keyboard on the terminal
                // itself; otherwise the composer is the only text input.
                let terminal = feeds.terminal
                if terminal.canType {
                    TerminalTypingBar(model: terminal, composing: composing, composerFocused: composerFocused,
                                      press: { key in
                                          guard case .press(let press) = key.action else { return }
                                          if terminal.press(press) { return }
                                          if let name = key.fallbackName {
                                              keys.press(name, session: session.id, client: client)
                                          }
                                      },
                                      toggleKeyboard: {
                                          if composerFocused {
                                              composerFocused = false
                                          } else {
                                              terminal.setKeyboard(!terminal.keyboardShown)
                                          }
                                      },
                                      toggleComposer: toggleComposer)
                } else {
                    TerminalKeyBar(keyboardShown: composerFocused,
                                   toggleKeyboard: { composerFocused.toggle() }) { key in
                        keys.press(key.id, session: session.id, client: client)
                    }
                }
            }
            if showsComposer { composer }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(feeds.terminal.canType && !isConversation ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
    }

    /// A terminal that types shows its command field only when asked to.
    private var showsComposer: Bool { isConversation || !feeds.terminal.canType || composing }

    /// The pencil: write a command in the field, or go back to typing.
    private func toggleComposer() {
        if composing {
            composing = false
            composerFocused = false
        } else {
            composing = true
            // The field exists only from the next update.
            Task { composerFocused = true }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // Images and quick phrases are for the Agent.
            if isConversation { composerMenu }

            VStack(alignment: .leading, spacing: 0) {
                // Attachments sit inside the field, as in Messages, so the
                // field keeps its width.
                if !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments, remove: removeAttachment, retry: upload)
                        .padding(.horizontal, 6)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(isConversation ? "Message the Agent" : "Enter a command", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.body)
                        .padding(.leading, 14)
                        .padding(.vertical, 10)
                        .disabled(isSending)
                        .focused($composerFocused)
                        .textInputAutocapitalization(isConversation ? .sentences : .never)
                        .autocorrectionDisabled(!isConversation)
                        .accessibilityIdentifier(isConversation ? "agentMessageField" : "terminalCommandField")
                    Group {
                        if showsStop {
                            Button { stop() } label: {
                                Group {
                                    if stopping {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "stop.circle.fill")
                                            .font(.system(size: 30))
                                    }
                                }
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle().inset(by: -5))
                            }
                            .disabled(stopping)
                            .accessibilityLabel("Stop Agent")
                            .accessibilityIdentifier("stopAgent")
                        } else {
                            Button { send() } label: {
                                Group {
                                    if isSending {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.system(size: 30))
                                    }
                                }
                                .frame(width: 34, height: 34)
                                // A 44-point target around the smaller visible button.
                                .contentShape(Rectangle().inset(by: -5))
                            }
                            .disabled(!canSend)
                            .accessibilityLabel(isConversation ? (queuesMessage ? "Queue Message" : "Send Message") : "Send Command")
                            .accessibilityHint(queuesMessage ? "Sends when this turn ends" : "")
                            .accessibilityIdentifier("sendAgentMessage")
                        }
                    }
                    .padding(.trailing, 5)
                    .padding(.bottom, 5)
                }
            }
            .background(Color.homeCard, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(.separator))
            }
        }
    }

    /// The terminal's text size is a per-install preference; a taken-over
    /// terminal is attached again at the grid the new size fits. The menu
    /// stays open so the size can be stepped and read off the header.
    @ViewBuilder private var textSizeControls: some View {
        ControlGroup {
            Button("Smaller Text", systemImage: "minus") {
                terminalFontSize = TerminalTextSize.clamped(terminalFontSize - 1)
            }
            .disabled(terminalFontSize <= TerminalTextSize.range.lowerBound)
            Button("Default Text Size", systemImage: "arrow.counterclockwise") {
                terminalFontSize = TerminalTextSize.standard
            }
            .disabled(terminalFontSize == TerminalTextSize.standard)
            Button("Larger Text", systemImage: "plus") {
                terminalFontSize = TerminalTextSize.clamped(terminalFontSize + 1)
            }
            .disabled(terminalFontSize >= TerminalTextSize.range.upperBound)
        } label: {
            Text("Text Size · \(Int(terminalFontSize)) pt")
        }
        .controlGroupStyle(.compactMenu)
        .menuActionDismissBehavior(.disabled)
    }

    private func subtitle(at now: Date) -> String {
        let place = currentSession.machine ?? String(localized: "This Mac")
        if let working = currentSession.working(at: now) { return "\(working) · \(place)" }
        if isConversation { return String(localized: "Conversation · \(place)") }
        var parts = [String(localized: "Terminal"), place]
        if let grid { parts.append("\(grid.cols)×\(grid.rows)") }
        return parts.joined(separator: " · ")
    }

    private var dialogRunner: DialogRunner {
        DialogRunner(
            session: session.id, feed: screen,
            press: { keys in await client.pressKeys(session: session.id, keys: keys) },
            agentWorking: { currentSession.status?.state == "working" })
    }

    /// Esc for a dialog the phone can't read, if the screen still shows it.
    private func press(_ key: String, on excerpt: GenericDialogExcerpt) async -> String? {
        guard screen.result.fingerprint?.matches(excerpt.fingerprint) == true else {
            return String(localized: "The dialog in the terminal changed. Check what it shows now")
        }
        switch await client.pressKeys(session: session.id, keys: [key]) {
        case .pressed: return nil
        case .failed(_, let message): return message
        case .unknown: return String(localized: "Not sure the key went through")
        }
    }

    private func send(force: Bool = false) {
        guard canSend else { return }
        let text = draft
        if queuesMessage {
            client.enqueue(text, session: session.id, turn: currentSession.turn)
            AgentMessageStore.clearDraft(host: config.host, session: session.id)
            draft = ""
            attachments = []
            return
        }
        // Marked before the task starts, so a second tap can't send it twice.
        client.remember(.sending(text: text), host: config.host, session: session.id)
        Task {
            switch await client.submit(text, host: config.host, session: session.id, force: force) {
            case .accepted:
                // Clear the persisted draft before any view teardown: leaving
                // while sending must not make the sent text reappear as a draft.
                AgentMessageStore.clearDraft(host: config.host, session: session.id)
                draft = ""
                // Their paths went with the text.
                attachments.removeAll { $0.state != .uploading }
                updateResponse()
                if composing {
                    // Sent: back to typing into the terminal.
                    composing = false
                    composerFocused = false
                    feeds.terminal.setKeyboard(true)
                }
            case .failed(let kind, _):
                confirmingBlocked = isConversation && kind == "blocked"
            case .unknown:
                break
            }
        }
    }

    /// One "+" for everything that goes into the message, as in Messages:
    /// images and the quick phrases.
    private var composerMenu: some View {
        Menu {
            Section {
                Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                    .disabled(!CameraPicker.isAvailable)
            }
            .disabled(attachments.count >= ImageAttachment.limit)
            Section("Insert into Message") {
                ForEach(QuickCommand.phrases, id: \.self) { phrase in
                    Button(phrase) { draft = QuickCommand.insert(phrase, into: draft) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.secondary)
        .frame(width: 44, height: 44)
        .disabled(isSending)
        .accessibilityLabel("Add Image or Phrase")
        .accessibilityIdentifier("composerMenu")
    }

    private func attach(_ image: UIImage) {
        guard attachments.count < ImageAttachment.limit else { return }
        let name = ImageShrinker.name(at: .now, index: attachments.count + 1)
        Task {
            let (jpeg, thumbnail) = await Task.detached(priority: .userInitiated) {
                (ImageShrinker.jpeg(from: image), ImageShrinker.thumbnail(from: image))
            }.value
            guard let jpeg, attachments.count < ImageAttachment.limit else { return }
            let attachment = ImageAttachment(thumbnail: thumbnail, jpeg: jpeg, name: name)
            attachments.append(attachment)
            upload(attachment.id)
        }
    }

    private func upload(_ id: ImageAttachment.ID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = .uploading
        let attachment = attachments[index]
        Task {
            let state: ImageAttachment.State = switch await client.put(
                session: session.id, name: attachment.name, data: attachment.jpeg) {
            case .done(let path): .uploaded(path: path)
            case .failed(_, let message): .failed(message)
            case .unknown: .failed(String(localized: "Result unknown"))
            }
            // Removed while it uploaded: its path stays out of the draft.
            guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
            attachments[index].state = state
            if case .uploaded(let path) = state { draft = DraftPaths.insert(path, into: draft) }
        }
    }

    private func removeAttachment(_ id: ImageAttachment.ID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        if case .uploaded(let path) = attachments[index].state { draft = DraftPaths.remove(path, from: draft) }
        attachments.remove(at: index)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(currentSession.title).font(.headline).lineLimit(1)
                if currentSession.working(at: .now) != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(subtitle(at: context.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text(subtitle(at: .now)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(isConversation
                ? "Read the conversation, approve or answer the Agent, and send whole messages, all without taking over the terminal or resizing it on the desktop."
                : "View the terminal, run shell commands and press common keys. While you look, the terminal is laid out at phone size and shrinks on the desktop until you leave.")
        }
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
    }

    /// Everything that is not the page itself sits behind one button, one
    /// kind per section: the terminals in the Agent's Herdr tab to switch
    /// to, conversation or terminal, the changes, and the terminal's text size.
    private var moreMenu: some View {
        let panes = tabPanes
        return Menu {
            if panes.count > 1 {
                Section {
                    Menu {
                        Picker("Switch Pane", selection: Binding(get: { session.id }, set: switchPane(to:))) {
                            ForEach(panes) { pane in
                                // System menus wrap titles over lines; one line each, cut to fit.
                                Button {} label: {
                                    Label(MenuLine.fit(pane.title), systemImage: pane.isAgent ? "sparkles" : "terminal")
                                    Text(MenuLine.fit(paneDetail(pane), style: .subheadline))
                                }
                                .tag(pane.id)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Switch Pane", systemImage: "rectangle.split.2x1")
                    }
                }
            }
            if hasConversation {
                Section {
                    Picker("Show", selection: Binding(get: { isConversation ? SessionPage.conversation : .terminal },
                                                      set: { client.pageChoices[session.id] = $0 })) {
                        Label("Conversation", systemImage: "bubble.left.and.text.bubble.right").tag(SessionPage.conversation)
                        Label("Terminal", systemImage: "terminal").tag(SessionPage.terminal)
                    }
                    .pickerStyle(.inline)
                }
            }
            Section {
                Button("Changes", systemImage: "plusminus") { showingChanges = true }
            }
            if !isConversation {
                Section { textSizeControls }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("moreMenu")
    }

    /// This terminal and the others in its Herdr tab, in pane order.
    private var tabPanes: [Session] {
        let mates = tabMates(of: session.id, sessions: client.sessions, spaces: client.spaces)
        guard !mates.isEmpty else { return [] }
        let order = client.spaces.lazy.flatMap(\.tabs).first(where: { $0.sessions.contains(session.id) })?.sessions ?? []
        let byID = Dictionary((mates + [session]).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    private func paneDetail(_ pane: Session) -> String {
        [pane.program, pane.folder].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func switchPane(to id: String) {
        guard id != session.id, let pane = client.sessions.first(where: { $0.id == id }) else { return }
        open(pane)
    }

    private var paneTab: PaneTab? {
        PaneTab(of: session.id, sessions: client.sessions, spaces: client.spaces)
    }

    private func swiped(_ step: Int?) {
        if let step, let next = paneTab?.neighbor(step), let mate = client.sessions.first(where: { $0.id == next }) {
            open(mate)
        } else {
            showPanes(session.id, false)
        }
    }

    private var changesPage: some View {
        let ask: (() -> Void)? = isConversation ? { askToCommit() } : nil
        return ChangesView(session: session.id, client: client, askToCommit: ask)
    }

    /// Fills the request into the draft and comes back; the user sends it.
    private func askToCommit() {
        draft = QuickCommand.insert(ChangesView.commitRequest, into: draft)
        showingChanges = false
    }

    private var slashQuery: String? { SlashCompletion.query(in: draft) }

    private var slashMatches: [SlashCommand] {
        guard isConversation, let slashQuery else { return [] }
        return SlashCompletion.matches(slashQuery, custom: customCommands)
    }

    private func loadCommands() {
        Task {
            // A failure keeps the last list; the built-in ones show anyway.
            if let commands = await client.commands(session: session.id) { customCommands = commands }
        }
    }

    private func pickCommand(_ command: SlashCommand) {
        if command.endsSession {
            confirmingExit = true
        } else {
            draft = SlashCompletion.fill(command)
        }
    }

    /// The queued text goes back ahead of whatever the draft holds now.
    private func withdrawQueued() {
        guard let text = client.withdrawQueued(session: session.id) else { return }
        draft = draft.isEmpty ? text : text + "\n\n" + draft
    }

    /// A pop-up button: the system menu marks the current mode, and picking
    /// another one starts the switch; the chip changes once the screen agrees.
    private func modeChip(_ mode: PermissionMode) -> some View {
        Menu {
            Picker("Permission Mode", selection: Binding(get: { mode }, set: switchMode(to:))) {
                ForEach(PermissionMode.targets(including: seenModes), id: \.self) { target in
                    Label(target.title, systemImage: target.symbol).tag(target)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                if switchingMode {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: mode.symbol)
                }
                Text(mode.title)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(mode == .bypassPermissions ? .red : .secondary)
        .disabled(!canSwitchMode)
        .accessibilityLabel("Permission Mode")
        .accessibilityValue(mode.title)
        .accessibilityHint(canSwitchMode ? "Switches with Shift+Tab, checking the terminal after each press" : "Can't switch while the Agent is working or a dialog is open")
        .accessibilityIdentifier("permissionMode")
    }

    private func switchMode(to target: PermissionMode) {
        guard canSwitchMode, target != screenMode else { return }
        switchingMode = true
        modeFailure = nil
        let switcher = PermissionModeSwitcher(
            feed: screen,
            press: { keys in await client.pressKeys(session: session.id, keys: keys) },
            agentWorking: { currentSession.status?.state == "working" })
        Task {
            if case .failed(let reason) = await switcher.run(to: target) { modeFailure = reason }
            // The screen says where it ended, even after a failure.
            if let reached = screenMode { switchedMode = reached }
            switchingMode = false
        }
    }

    /// No confirmation: Esc only ends this turn. A second press is the
    /// user's choice; core never escalates on its own.
    private func stop() {
        guard !stopping else { return }
        stopping = true
        stopNotice = nil
        Task {
            stopNotice = AgentMessagePresentation.stopped(await client.interrupt(session: session.id))
            stopping = false
        }
    }

    private func updateResponse() {
        guard isConversation, let delivery, case .sent(let text, let sentTurn, let status, _) = delivery,
              currentSession.turn > sentTurn else { return }
        client.remember(.turnCompleted(text: text, status: status), host: config.host, session: session.id)
    }
}

private struct QueuedBanner: View {
    let message: QueuedMessage
    let release: QueuedMessage.Release
    let send: () -> Void
    let withdraw: () -> Void

    private var title: String {
        if let failure = message.failure { return String(localized: "Not sent: \(failure)") }
        return release == .ask ? String(localized: "This turn ended a while ago. Send it now?") : String(localized: "Queued · sends when this turn ends")
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(message.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: message.failure == nil ? "clock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(message.failure == nil ? Color.secondary : Color.red)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("queuedMessage")
            if release == .ask {
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sendQueued")
            }
            Button("Withdraw", action: withdraw)
                .buttonStyle(.bordered)
                .accessibilityHint("Move Back to Message")
                .accessibilityIdentifier("withdrawQueued")
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        .padding(.horizontal, 4)
    }
}

private struct DeliveryBanner: View {
    let delivery: AgentDelivery
    /// A shell command: delivered or not, with no Agent turn to follow.
    let shell: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(shell ? delivery.shellState : delivery.state, systemImage: delivery.symbol)
                .foregroundStyle(delivery.color)
                .layoutPriority(1)
            Text(delivery.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One line of a system menu item. Menus wrap a long title over up to three
/// lines and ignore `lineLimit`, so the text is cut to the width a menu row
/// gives it, at the current Dynamic Type size, with an ellipsis.
enum MenuLine {
    /// What a row of a phone's menu leaves for text beside a checkmark and an icon.
    static let width: CGFloat = 145

    static func fit(_ text: String, style: UIFont.TextStyle = .body, width: CGFloat = width) -> String {
        let font = UIFont.preferredFont(forTextStyle: style)
        func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        guard measure(text) > width else { return text }
        let characters = Array(text)
        var low = 0, high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(characters[..<mid]) + "…") <= width { low = mid } else { high = mid - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
