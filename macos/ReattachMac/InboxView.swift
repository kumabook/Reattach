import SwiftUI
import AppKit

struct InboxView: View {
    @Bindable var store: InboxStore
    let close: () -> Void
    let settings: () -> Void
    let showWork: () -> Void
    let showWelcome: () -> Void
    let confirmInTerminal: () async -> Void
    @AppStorage("backgroundTransparency") private var backgroundTransparency = 0.65
    @AppStorage("backgroundBlurStrength") private var backgroundBlurStrength: Double =
        UserDefaults.standard.object(forKey: "backgroundBlurEnabled") as? Bool == false ? 0 : 1
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selection: String?
    @State private var numberBuffer = ""
    @State private var lastNumberTime = -Double.infinity
    @State private var expanded = false
    @State private var showingShortcuts = false
    @State private var showingReplyFeedback = false
    @FocusState private var focusedTarget: String?
    @FocusState private var keyboardFocused: Bool
    private var typing: Bool { focusedTarget != nil }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var draft: Binding<String> { draft(for: store.selected ?? "") }

    private func draft(for target: String) -> Binding<String> {
        Binding(get: { store.drafts[target, default: ""] },
                set: { store.drafts[target] = $0 })
    }

    private var transparency: Double { reduceTransparency ? 0 : min(1, max(0, backgroundTransparency)) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(String(localized: "Pending requests: \(store.entries.count)"), systemImage: "hand.raised.fill")
                PanelDragHandle()
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .help(String(localized: "Drag to move the window"))
                Button(String(localized: "All Work"), systemImage: "rectangle.3.group", action: showWork)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help(String(localized: "Browse all tmux windows and panes"))
                Button { settings() } label: { Image(systemName: "gearshape") }.help(String(localized: "Settings (⌘,)"))
                Button { close() } label: { Image(systemName: "xmark") }.help(String(localized: "Close (Esc)"))
            }
            if let error = store.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let message = store.responseMessage {
                Text(message).foregroundStyle(.orange)
            }
            if store.entry != nil {
                GeometryReader { geometry in
                    let stride = geometry.size.width + 24
                    let index = store.entries.firstIndex { $0.target == store.selected } ?? 0
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(store.entries.enumerated()), id: \.element.target) { position, item in
                            if abs(position - index) <= 1 {
                                requestCard(item)
                                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .offset(x: CGFloat(position - index) * stride + (reduceMotion ? 0 : store.swipeOffset))
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .onAppear { store.pageWidth = stride }
                    .onChange(of: stride) { _, width in store.cancelSwipe(); store.pageWidth = width }
                }
                HStack {
                    Button(String(localized: "Previous"), systemImage: "chevron.left") { store.move(-1) }
                        .disabled(store.selected == store.entries.first?.target)
                    Spacer()
                    Text("\((store.entries.firstIndex { $0.target == store.selected } ?? 0) + 1) / \(store.entries.count)").monospacedDigit()
                    Spacer()
                    Button(String(localized: "Next"), systemImage: "chevron.right") { store.move(1) }
                        .disabled(store.selected == store.entries.last?.target)
                }
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView(store.error == nil ? String(localized: "No Pending Requests") : String(localized: "Check Your Connection"), systemImage: store.error == nil ? "checkmark.circle" : "network.slash")
                        .fixedSize(horizontal: false, vertical: true)
                    if store.error != nil {
                        Button(String(localized: "Open Settings"), systemImage: "gearshape", action: settings)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if store.busy { ProgressView().controlSize(.small) }
            HStack {
                Spacer()
                Button { showingShortcuts.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Keyboard shortcuts"))
                .accessibilityLabel(String(localized: "Keyboard shortcuts"))
                .popover(isPresented: $showingShortcuts, arrowEdge: .bottom) {
                    shortcutHelp
                }
            }
        }
        .allowsHitTesting(!store.welcome.active)
        .disabled(showingReplyFeedback)
        .padding(20)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .background {
            ZStack {
                if backgroundBlurStrength > 0 && !reduceTransparency {
                    Rectangle().fill(.ultraThinMaterial)
                        .opacity(min(1, max(0, backgroundBlurStrength)))
                }
                Color(nsColor: .windowBackgroundColor).opacity(1 - transparency)
            }
        }
        .overlay {
            if showingReplyFeedback {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                        .opacity(reduceTransparency ? 1 : 0.65)
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 76, weight: .medium))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text(String(localized: "Reply sent"))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                    }
                    .padding(32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { /* Consume clicks until the confirmation fades. */ }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(reduceMotion ? nil : .spring(response: 0.3), value: store.selected)
        .focusable().focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.title == "Reattach",
                  !typing, !expanded, !showingShortcuts else { return }
            keyboardFocused = true
        }
        .onKeyPress { press in
            if store.welcome.active { return .handled }
            if press.key == KeyEquivalent("a"), press.modifiers == [.command, .shift] {
                showWork()
                return .handled
            }
            if showingReplyFeedback || store.isShowingReplyFeedback {
                if press.key == .escape { close() }
                return .handled
            }
            if showingShortcuts {
                if press.key == .escape { showingShortcuts = false }
                return .handled
            }
            // Let the input method commit/cancel marked text before interpreting shortcuts.
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
                return .ignored
            }
            if press.key == KeyEquivalent(","), press.modifiers == .command {
                settings()
                return .handled
            }
            if press.key == .escape { if expanded { expanded = false } else { close() }; return .handled }
            guard !expanded else { return .ignored }
            if press.key == KeyEquivalent("r"), press.modifiers == .command {
                Task { await store.refresh() }
                return .handled
            }
            if press.key == KeyEquivalent("o"), press.modifiers == .command {
                Task { await confirmInTerminal() }
                return .handled
            }
            if press.key == .return, press.modifiers.contains(.command) { sendDraft(); return .handled }
            guard !typing else { return .ignored }
            if press.modifiers.isEmpty, press.characters.count == 1,
               press.characters.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                if press.phase == .down { selectNumber(press.characters) }
                return .handled
            }
            numberBuffer = ""
            if press.modifiers == .control {
                switch press.key {
                case KeyEquivalent("n"): moveChoice(1)
                case KeyEquivalent("p"): moveChoice(-1)
                case KeyEquivalent("f"): store.move(1)
                case KeyEquivalent("b"): store.move(-1)
                default: return .ignored
                }
                return .handled
            }
            switch press.key {
            case .leftArrow: store.move(-1)
            case .rightArrow: store.move(1)
            case .upArrow: moveChoice(-1)
            case .downArrow: moveChoice(1)
            case .tab: focusedTarget = store.selected
            case .return:
                if let selection, store.choices.contains(where: { $0.number == selection }) {
                    Task { await store.respond(selection) }
                }
            default: return .ignored
            }
            return .handled
        }
        .task(id: store.replyReceipt) {
            let remaining = store.replyFeedbackRemaining()
            guard store.replyReceipt != nil, remaining > 0 else { showingReplyFeedback = false; return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showingReplyFeedback = true }
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showingReplyFeedback = false }
        }
        .task(id: store.selected) {
            selection = nil
            numberBuffer = ""
            focusedTarget = nil
            keyboardFocused = true
            if !store.requiresReload.contains(store.selected ?? ""), !store.sent.contains(store.selected ?? "") { await store.refresh() }
            await store.prefetchNeighbors()
        }
        .onChange(of: store.output) { _, _ in selection = nil; numberBuffer = "" }
        .sheet(isPresented: $expanded) {
            VStack {
                HStack { Text(String(localized: "Pane Context")).font(.headline); Spacer(); Button(String(localized: "Close")) { expanded = false }.keyboardShortcut(.cancelAction) }
                ScrollView([.horizontal, .vertical]) {
                    Text(TerminalTextRenderer.render(store.output ?? "").string)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled).padding()
                }
            }.padding(20).frame(width: 700, height: 550)
        }
    }

    private var shortcutHelp: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(String(localized: "Shortcuts"), systemImage: "keyboard").font(.headline)
                Spacer()
                Button { showingShortcuts = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close keyboard shortcuts"))
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                shortcutRow(String(localized: "Switch cards"), "← → ／ ⌃B ⌃F")
                shortcutRow(String(localized: "Move between options"), "↑ ↓ ／ ⌃P ⌃N")
                shortcutRow(String(localized: "Select by number"), String(localized: "Number keys"))
                shortcutRow(String(localized: "Send selected option"), "Return")
                shortcutRow(String(localized: "Focus reply field"), "Tab")
                shortcutRow(String(localized: "Send reply text"), "⌘Return")
                shortcutRow(String(localized: "Refresh"), "⌘R")
                shortcutRow(String(localized: "View in tmux"), "⌘O")
                shortcutRow(String(localized: "All Work"), "⌘⇧A")
                shortcutRow(String(localized: "Settings"), "⌘,")
                shortcutRow(String(localized: "Close"), "Esc")
            }
            Divider()
            Button(String(localized: "Practice the controls"), systemImage: "play.circle") {
                showingShortcuts = false
                showWelcome()
            }
            Text(String(localized: "Swipe horizontally with two fingers to switch cards. In the reply field, number and arrow keys work normally for typing and editing."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340)
    }

    private func shortcutRow(_ label: String, _ keys: String) -> some View {
        GridRow {
            Text(label)
            Text(keys).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func requestCard(_ entry: PermissionAttention) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(entry.tool.isEmpty ? String(localized: "Permission Required") : entry.tool, systemImage: "hand.raised").foregroundStyle(.orange)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.workTitles[entry.target] ?? String(localized: "Permission Required"))
                                .font(.title2.bold()).textSelection(.enabled)
                            Label(entry.target, systemImage: "rectangle.split.2x2")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(String(localized: "View in tmux"), systemImage: "terminal") {
                            Task { await confirmInTerminal() }
                        }
                        .disabled(store.busy)
                        .help(String(localized: "Select this tmux window and pane, then close the panel (⌘O)"))
                    }
                    if let preview = store.previews[entry.target] {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(String(localized: "Recent terminal output")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(String(localized: "Expand"), systemImage: "arrow.up.left.and.arrow.down.right") { expanded = true }
                            }
                            ScrollView {
                                Text(preview)
                                    .font(.system(size: 13, design: .monospaced)).lineSpacing(4)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .defaultScrollAnchor(.bottom)
                            .frame(height: min(240, CGFloat(max(1, preview.components(separatedBy: "\n").count)) * 20))
                        }
                        .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !(store.parsedChoices[entry.target] ?? []).isEmpty {
                        Text(String(localized: "Choose your reply")).font(.headline)
                    }
                    ForEach(store.parsedChoices[entry.target] ?? []) { choice in
                        Button {
                            selection = choice.number
                            Task { await store.respond(choice.number) }
                        } label: {
                            HStack {
                                Text(choice.number)
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    .frame(minWidth: 28, minHeight: 28)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                Text(choice.label).multilineTextAlignment(.leading)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer()
                                if selection == choice.number { Image(systemName: "arrow.turn.down.left") }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == choice.number ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(PermissionChoiceButtonStyle()).disabled(!store.canReply)
                        .id("choice-\(entry.target)-\(choice.number)")
                    }
                    TextField(String(localized: "Type a reply…"), text: draft(for: entry.target), axis: .vertical)
                        .lineLimit(2...6).textFieldStyle(.roundedBorder).focused($focusedTarget, equals: entry.target)
                        .disabled(store.entry == nil || store.sent.contains(entry.target))
                    HStack {
                        Button(String(localized: "Send ⌘↩"), systemImage: "paperplane") { sendDraft() }.disabled(!store.canReply || draft(for: entry.target).wrappedValue.isEmpty)
                        Menu {
                            Button(String(localized: "Send Enter to Terminal"), systemImage: "return") { Task { await store.respond("") } }
                            Button(String(localized: "Send Esc to Terminal"), systemImage: "escape") { Task { await store.respond("", escape: true) } }
                        } label: {
                            Label(String(localized: "Other Controls"), systemImage: "ellipsis.circle")
                        }.disabled(!store.canReply)
                        Spacer()
                        Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") { Task { await store.refresh() } }.disabled(store.busy)
                        .help(String(localized: "Refresh the current card (⌘R)"))
                    }
                    if store.sent.contains(entry.target) { Label(String(localized: "Sent — Waiting for the agent"), systemImage: "checkmark.circle") }
                }
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor).opacity(1 - transparency),
                            in: RoundedRectangle(cornerRadius: 24))
                .id(entry.target)
            }
            .allowsHitTesting(entry.target == store.selected && !store.isSwiping)
            .disabled(entry.target != store.selected || store.isSwiping)
            .accessibilityHidden(entry.target != store.selected)
            .onChange(of: selection) { _, selected in
                guard entry.target == store.selected, let selected else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    proxy.scrollTo("choice-\(entry.target)-\(selected)", anchor: .center)
                }
            }
        }
    }

    private func selectNumber(_ digit: String) {
        guard !store.isSwiping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let candidate = (now - lastNumberTime < 0.8 ? numberBuffer : "") + digit
        numberBuffer = store.choices.contains { $0.number.hasPrefix(candidate) } ? candidate : digit
        lastNumberTime = now
        selection = store.choices.first { $0.number == numberBuffer }?.number
    }

    private func sendDraft() {
        guard !draft.wrappedValue.isEmpty else { return }
        let text = draft.wrappedValue
        Task { await store.respond(text) }
    }

    private func moveChoice(_ step: Int) {
        let choices = store.choices
        guard !choices.isEmpty else { return }
        let index = selection.flatMap { selected in choices.firstIndex { $0.number == selected } }
        selection = choices[min(max((index ?? (step > 0 ? -1 : choices.count)) + step, 0), choices.count - 1)].number
    }
}

// Limit window dragging to the header gap so text selection and controls keep
// their normal mouse behavior. AppKit handles movement across displays.
protocol PanelDragNotifying: AnyObject {
    var didFinishDragging: () -> Void { get }
}

private struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let panel = window, let observer = panel as? PanelDragNotifying else { return }
            let originalFrame = panel.frame
            panel.performDrag(with: event)
            if panel.frame != originalFrame { observer.didFinishDragging() }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

// The native bordered style can force a single-line label on macOS. Keep menu
// choices multiline while retaining press and disabled feedback.
private struct PermissionChoiceButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.12)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}

// This practice view has no store or networking access.
struct MacWelcomeView: View {
    @Bindable var practice: MacWelcomeState
    let hotkey: String
    let connectionSettings: () -> Void
    let finish: () -> Void
    @State private var practiceSelection: Int?
    @FocusState private var keyboardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(String(localized: "A quick introduction"), systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Text("\(practice.step + 1) / 4").monospacedDigit().foregroundStyle(.secondary)
            }
            if practice.step == 0 {
                Text(String(localized: "Connect your workspace first.")).font(.title2.bold())
                Text(String(localized: "Reattach connects to reattachd running on your computer. Set the server address and device token to bring your requests here."))
                Label(String(localized: "Local default: http://127.0.0.1:8787"), systemImage: "desktopcomputer")
                    .font(.callout.monospaced())
                Button(String(localized: "Set up connection"), systemImage: "network", action: connectionSettings)
                Text(String(localized: "Once connected, this guide continues automatically. If you are already connected, setup is skipped."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if practice.step == 1 {
                Text(String(localized: "Your next reply, a shortcut away.")).font(.title2.bold())
                Text(practice.panelHidden
                     ? String(localized: "The panel is hidden. Press the same hotkey again to bring it back.")
                     : String(localized: "Press this hotkey to hide the panel behind this guide. This guide stays open so you can find your way back."))
                Text(hotkey).font(.system(.title, design: .monospaced).weight(.semibold))
                    .padding().frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text(String(localized: "You can change this shortcut in Settings."))
                    .font(.caption).foregroundStyle(.secondary)
                Label(practice.panelHidden ? String(localized: "Next: bring the panel back") : String(localized: "First: hide the panel"), systemImage: practice.panelHidden ? "arrow.up.forward.app" : "rectangle.dashed")
                    .font(.callout).foregroundStyle(.secondary)
                Button(String(localized: "Continue without trying"), systemImage: "arrow.right") { practice.step = 2 }
            } else if practice.step == 2 {
                Text(String(localized: "Choose a number. Press Return.")).font(.title2.bold())
                Label(String(localized: "Practice only — nothing is sent."), systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
                Text(String(localized: "Press 1 or 2 to select an option, then Return to confirm. Arrow keys work too."))
                practiceOption(1, String(localized: "Allow once"))
                practiceOption(2, String(localized: "Skip this request"))
                Button(String(localized: "Confirm practice choice"), systemImage: "return") { practice.step = 3 }
                    .disabled(practiceSelection == nil)
            } else {
                Label(String(localized: "Ready to get back to work."), systemImage: "checkmark.circle.fill")
                    .font(.title2.bold()).foregroundStyle(.green)
                Text(String(localized: "Use the arrow keys or a two-finger swipe to move between requests. Tab lets you type a reply; Command–Return sends it."))
                Text(String(localized: "Need a reminder? Open the question mark for shortcuts or to practice again."))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Start using Reattach"), systemImage: "arrow.right", action: finish)
            }
            Spacer(minLength: 0)
            HStack {
                Button(String(localized: "Skip introduction"), action: finish)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 440, height: 480)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: practice.step)
        .focusable().focusEffectDisabled().focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress { press in
            if press.key == .escape { finish(); return .handled }
            if press.key == .tab { return .ignored }
            guard press.phase == .down, press.modifiers.isEmpty else { return .handled }
            if practice.step == 0 {
                if press.key == .return { connectionSettings() }
            } else if practice.step == 1 {
                if press.key == .return { practice.step = 2 }
            } else if practice.step == 2 {
                if press.characters == "1" { practiceSelection = 1 }
                if press.characters == "2" { practiceSelection = 2 }
                if press.key == .downArrow { practiceSelection = 2 }
                if press.key == .upArrow { practiceSelection = 1 }
                if press.key == .return, practiceSelection != nil { practice.step = 3 }
            } else if press.key == .return { finish() }
            return .handled
        }
    }

    private func practiceOption(_ number: Int, _ title: String) -> some View {
        Button {
            practiceSelection = number
            keyboardFocused = true
        } label: {
            HStack {
                Text(String(number)).font(.system(.body, design: .monospaced).bold())
                Text(title)
                Spacer()
                if practiceSelection == number { Image(systemName: "arrow.turn.down.left") }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(practiceSelection == number ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
