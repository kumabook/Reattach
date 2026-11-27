//
//  DirectInputView.swift
//  Reattach
//

import SwiftUI
import UIKit

private struct TerminalKeyboardFocusAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var terminalKeyboardFocusAllowed: Bool {
        get { self[TerminalKeyboardFocusAllowedKey.self] }
        set { self[TerminalKeyboardFocusAllowedKey.self] = newValue }
    }
}

struct DirectInputView: View {
    var isConnected = true
    let onText: (String) -> Void
    let onKey: (_ key: String, _ modifiers: [String]) -> Void
    let onSendAndEnter: (String) -> Void
    @State private var isComposingText = false
    @State private var activityLabel: String?
    @State private var activityCount = 0
    @State private var clearActivityTask: Task<Void, Never>?
    @AppStorage("direct_input_compose_enabled") private var composeEnabled = true
    @Binding var draft: String
    var onCompositionState: (Bool) -> Void = { _ in }
    var keyboardFocusRequest: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            if composeEnabled {
                HStack(alignment: .bottom, spacing: 12) {
                    DirectInputDraftEditor(text: $draft, onSendAndEnter: { text in
                        guard !text.isEmpty else { return false }
                        onSendAndEnter(text)
                        return true
                    }, keyboardFocusRequest: keyboardFocusRequest)
                        .accessibilityIdentifier("directInputDraft")
                    Button {
                        let text = draft
                        guard !text.isEmpty else { return }
                        onSendAndEnter(text)
                        draft = ""
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(String(localized: "Send Text"))
                    .accessibilityHint(String(localized: "You can also send with Command-Enter. Enter inserts a new line."))
                    .accessibilityIdentifier("directInputSendText")
                    .disabled(draft.isEmpty)

                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else {
                immediateInput
                    .disabled(!isConnected)
            }
        }
        .background(.bar)
    }

    private var immediateInput: some View {
        DirectInputTextViewRepresentable(
            onText: { text in
                showActivity(String(localized: "Sent"))
                onText(text)
            },
            onKey: { key, modifiers in
                showActivity(Self.activityLabel(for: key, modifiers: modifiers))
                onKey(key, modifiers)
            },
            onCompositionChanged: {
                isComposingText = $0
                onCompositionState($0)
            },
            keyboardFocusRequest: keyboardFocusRequest
        )
            // Keep the native responder mounted for hardware keyboards and IME.
            // Only marked text needs a visible editor; idle direct input takes no space.
            .frame(height: isComposingText ? 48 : 0)
            .clipped()
            .background(.bar)
            .onDisappear {
                clearActivityTask?.cancel()
            }
    }

    private func showActivity(_ label: String) {
        activityCount += 1
        activityLabel = label
        clearActivityTask?.cancel()
        clearActivityTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            activityLabel = nil
        }
    }

    static func activityLabel(for key: String, modifiers: [String]) -> String {
        let modifierLabel = modifiers.map {
            switch $0 {
            case "control": "Ctrl"
            case "alt": "Alt"
            case "shift": "Shift"
            default: $0.capitalized
            }
        }
        let keyLabel: String = switch key {
        case "enter": "Return"
        case "escape": "Esc"
        case "tab": "Tab"
        case "back_tab": "Shift-Tab"
        case "backspace": "Backspace"
        case "delete": "Delete"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "page_up": "Page Up"
        case "page_down": "Page Down"
        default: key.uppercased()
        }
        return (modifierLabel + [keyLabel]).joined(separator: "-")
    }
}

// A regular editor owns the IME transaction. Return only edits the draft;
// sending requires the send button or the explicit Command-Return shortcut.
struct DirectInputDraftEditor: UIViewRepresentable {
    @Environment(\.terminalKeyboardFocusAllowed) private var keyboardFocusAllowed
    @Binding var text: String
    var onSendAndEnter: (String) -> Bool = { _ in false }
    var keyboardFocusRequest: UUID? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> DirectInputDraftTextView {
        let view = DirectInputDraftTextView()
        view.keyboardFocusAllowed = keyboardFocusAllowed
        view.onSendAndEnter = onSendAndEnter
        view.delegate = context.coordinator
        view.text = text
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textColor = .label
        view.autocapitalizationType = .none
        view.accessibilityLabel = String(localized: "Compose text and confirm conversion before sending")
        DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: DirectInputDraftTextView, context: Context) {
        view.keyboardFocusAllowed = keyboardFocusAllowed
        view.onSendAndEnter = onSendAndEnter
        if let request = keyboardFocusRequest, context.coordinator.lastFocusRequest != request {
            context.coordinator.lastFocusRequest = request
            DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        }
        context.coordinator.text = $text
        // Never replace marked text while the input method is composing it.
        if view.markedTextRange == nil, view.text != text {
            view.text = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DirectInputDraftTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(lineHeight * 4 + insets, max(lineHeight + insets, measured.height))
        return CGSize(width: width, height: ceil(height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var lastFocusRequest: UUID?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
        }
    }
}

final class DirectInputDraftTextView: UITextView {
    var keyboardFocusAllowed = true {
        didSet { if !keyboardFocusAllowed && isFirstResponder { resignFirstResponder() } }
    }
    override var canBecomeFirstResponder: Bool { keyboardFocusAllowed && super.canBecomeFirstResponder }

    var onSendAndEnter: ((String) -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(sendDraft))
        send.discoverabilityTitle = String(localized: "Send and Run")
        return (super.keyCommands ?? []) + [send]
    }

    @objc func sendDraft() {
        // Conversion confirmation must never submit a command to the terminal.
        guard markedTextRange == nil, onSendAndEnter?(text ?? "") == true else { return }
        text = ""
        delegate?.textViewDidChange?(self)
    }
}

struct DirectInputTextViewRepresentable: UIViewRepresentable {
    @Environment(\.terminalKeyboardFocusAllowed) private var keyboardFocusAllowed
    let onText: (String) -> Void
    let onKey: (_ key: String, _ modifiers: [String]) -> Void
    let onCompositionChanged: (Bool) -> Void
    var keyboardFocusRequest: UUID? = nil
    var isInputEnabled = true
    var showsAccessoryKeys = true

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onText: onText,
            onKey: onKey,
            onCompositionChanged: onCompositionChanged
        )
    }

    func makeUIView(context: Context) -> TerminalInputTextView {
        let textView = TerminalInputTextView()
        textView.keyboardFocusAllowed = keyboardFocusAllowed
        textView.delegate = context.coordinator
        textView.onKey = { [weak coordinator = context.coordinator, weak textView] key, modifiers in
            guard let textView else { return }
            coordinator?.sendKey(key, modifiers: modifiers, from: textView)
        }
        textView.onCompositionEnded = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.textViewDidChange(textView)
        }
        // The hardware-keyboard candidate bar is anchored to the marked text,
        // not our outer border. Top padding would put that bar over the border.
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .none
        textView.accessibilityLabel = String(localized: "Direct terminal input")

        textView.isEditable = isInputEnabled
        textView.showsAccessoryKeys = showsAccessoryKeys
        textView.requestKeyboardFocus()
        return textView
    }

    func updateUIView(_ textView: TerminalInputTextView, context: Context) {
        textView.keyboardFocusAllowed = keyboardFocusAllowed
        textView.showsAccessoryKeys = showsAccessoryKeys
        let wasEnabled = textView.isEditable
        textView.isEditable = isInputEnabled
        if isInputEnabled && !wasEnabled { textView.requestKeyboardFocus() }
        if let request = keyboardFocusRequest, context.coordinator.lastFocusRequest != request {
            context.coordinator.lastFocusRequest = request
            textView.requestKeyboardFocus()
        }
        context.coordinator.onText = onText
        context.coordinator.onKey = onKey
        context.coordinator.onCompositionChanged = onCompositionChanged
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastFocusRequest: UUID?
        var onText: (String) -> Void
        var onKey: (_ key: String, _ modifiers: [String]) -> Void
        var onCompositionChanged: (Bool) -> Void
        private var pendingChange: Task<Void, Never>?

        init(
            onText: @escaping (String) -> Void,
            onKey: @escaping (_ key: String, _ modifiers: [String]) -> Void,
            onCompositionChanged: @escaping (Bool) -> Void
        ) {
            self.onText = onText
            self.onKey = onKey
            self.onCompositionChanged = onCompositionChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            // UIKit can notify the delegate before the IME updates markedTextRange.
            // Read and clear committed text only after the input transaction finishes.
            pendingChange?.cancel()
            pendingChange = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard !Task.isCancelled, let self, let textView else { return }
                self.sendCommittedText(textView)
            }
        }

        private func sendCommittedText(_ textView: UITextView) {
            if textView.markedTextRange != nil {
                onCompositionChanged(true)
                return
            }

            guard !textView.text.isEmpty else {
                onCompositionChanged(false)
                return
            }

            let committedText = textView.text ?? ""
            textView.text = ""
            onCompositionChanged(false)
            if let terminal = textView as? TerminalInputTextView, terminal.controlLatched {
                terminal.controlLatched = false
                if let key = TerminalAccessoryKeys.controlKey(for: committedText) {
                    onKey(key, ["control"])
                    return
                }
            }
            onText(committedText)
        }

        func sendKey(_ key: String, modifiers: [String], from textView: UITextView) {
            pendingChange?.cancel()
            sendCommittedText(textView)
            onKey(key, modifiers)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n", textView.markedTextRange == nil {
                sendKey("enter", modifiers: [], from: textView)
                return false
            }
            return true
        }
    }
}

enum DirectInputKeyMapper {
    static func modifiedCharacter(
        keyCode: UIKeyboardHIDUsage,
        charactersIgnoringModifiers: String,
        modifiers flags: UIKeyModifierFlags
    ) -> (key: String, modifiers: [String])? {
        // Reserve Control-Space (and Control-Shift-Space) for iOS input-source
        // switching. Match the physical key even when UIKit reports NUL or "".
        if keyCode == .keyboardSpacebar,
           flags.contains(.control),
           !flags.contains(.alternate),
           !flags.contains(.command) {
            return nil
        }

        guard flags.contains(.control) || flags.contains(.alternate) else {
            return nil
        }

        let normalized = normalizedCharacter(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            controlPressed: flags.contains(.control)
        )
        guard var character = normalized else { return nil }

        if character == " " {
            character = "space"
        } else if flags.contains(.shift) {
            character = character.uppercased()
        } else {
            character = character.lowercased()
        }

        return (character, modifierNames(from: flags, includingShift: false))
    }

    private static func normalizedCharacter(
        keyCode: UIKeyboardHIDUsage,
        charactersIgnoringModifiers: String,
        controlPressed: Bool
    ) -> String? {
        if charactersIgnoringModifiers.unicodeScalars.count == 1,
           let scalar = charactersIgnoringModifiers.unicodeScalars.first {
            if controlPressed, let character = character(forControlCode: scalar.value) {
                return character
            }
            if scalar.isASCII, scalar.value >= 0x20, scalar.value <= 0x7e {
                return String(scalar)
            }
        }

        // Some hardware keyboard layouts report an empty/control character for
        // Ctrl-letter. The HID usage remains stable, so use it as a fallback.
        let firstLetter = UIKeyboardHIDUsage.keyboardA.rawValue
        let offset = keyCode.rawValue - firstLetter
        guard (0..<26).contains(offset) else { return nil }
        return String(Array("abcdefghijklmnopqrstuvwxyz")[offset])
    }

    private static func character(forControlCode value: UInt32) -> String? {
        switch value {
        case 0:
            return " "
        case 1...26:
            return String(UnicodeScalar(value + 0x60)!)
        case 27:
            return "["
        case 28:
            return "\\"
        case 29:
            return "]"
        case 30:
            return "^"
        case 31:
            return "_"
        default:
            return nil
        }
    }

    private static func modifierNames(
        from flags: UIKeyModifierFlags,
        includingShift: Bool
    ) -> [String] {
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("control") }
        if flags.contains(.alternate) { modifiers.append("alt") }
        if includingShift && flags.contains(.shift) { modifiers.append("shift") }
        return modifiers
    }
}

final class TerminalInputTextView: UITextView {
    var onKey: ((_ key: String, _ modifiers: [String]) -> Void)?
    var onCompositionEnded: (() -> Void)?

    /// Set from the accessory bar's Ctrl key; applies to the next key or character.
    var controlLatched = false {
        didSet { accessoryBar?.setControlLatched(controlLatched) }
    }

    private var accessoryBar: TerminalAccessoryBar?

    var showsAccessoryKeys = false {
        didSet {
            guard showsAccessoryKeys != oldValue else { return }
            if showsAccessoryKeys {
                let bar = TerminalAccessoryBar()
                bar.onKey = { [weak self] key in
                    guard let self else { return }
                    let modifiers = self.controlLatched ? ["control"] : []
                    self.controlLatched = false
                    self.onKey?(key, modifiers)
                }
                bar.onText = { [weak self] text in self?.insertText(text) }
                bar.onControl = { [weak self] in self?.controlLatched.toggle() }
                accessoryBar = bar
                inputAccessoryView = bar
            } else {
                controlLatched = false
                accessoryBar = nil
                inputAccessoryView = nil
            }
            if isFirstResponder { reloadInputViews() }
        }
    }

    private var pendingKeyboardFocus = false
    var keyboardFocusAllowed = true {
        didSet {
            if !keyboardFocusAllowed {
                pendingKeyboardFocus = false
                if isFirstResponder { resignFirstResponder() }
            }
        }
    }
    override var canBecomeFirstResponder: Bool { keyboardFocusAllowed && super.canBecomeFirstResponder }

    func requestKeyboardFocus() {
        guard keyboardFocusAllowed else { return }
        pendingKeyboardFocus = true
        acquirePendingKeyboardFocus()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        acquirePendingKeyboardFocus()
    }

    private func acquirePendingKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keyboardFocusAllowed, self.pendingKeyboardFocus, self.window != nil, self.isEditable else { return }
            if self.becomeFirstResponder() { self.pendingKeyboardFocus = false }
        }
    }

    override func unmarkText() {
        super.unmarkText()
        // Confirming a candidate need not produce another textViewDidChange call.
        onCompositionEnded?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Let the input method handle candidate selection, editing, and confirmation.
        guard markedTextRange == nil else {
            super.pressesBegan(presses, with: event)
            return
        }

        guard presses.count == 1,
              let press = presses.first,
              let key = press.key,
              !key.modifierFlags.contains(.command) else {
            super.pressesBegan(presses, with: event)
            return
        }

        if let terminalKey = terminalKey(for: key) {
            // Let the navigation shortcut reach SwiftUI rather than sending C-Tab.
            if key.keyCode == .keyboardTab,
               key.modifierFlags.contains(.control),
               !key.modifierFlags.contains(.alternate) {
                super.pressesBegan(presses, with: event)
                return
            }
            onKey?(terminalKey.key, terminalKey.modifiers)
            return
        }

        if let modifiedCharacter = modifiedCharacter(for: key) {
            onKey?(modifiedCharacter.key, modifiedCharacter.modifiers)
            return
        }

        super.pressesBegan(presses, with: event)
    }

    override func deleteBackward() {
        if markedTextRange == nil && text.isEmpty {
            onKey?("backspace", [])
        } else {
            super.deleteBackward()
        }
    }

    private func terminalKey(for key: UIKey) -> (key: String, modifiers: [String])? {
        let name: String
        switch key.keyCode {
        case .keyboardReturnOrEnter: name = "enter"
        case .keyboardEscape: name = "escape"
        case .keyboardTab:
            if key.modifierFlags.contains(.shift) {
                return ("back_tab", modifierNames(from: key.modifierFlags, includingShift: false))
            }
            name = "tab"
        case .keyboardDeleteOrBackspace: name = "backspace"
        case .keyboardDeleteForward: name = "delete"
        case .keyboardUpArrow: name = "up"
        case .keyboardDownArrow: name = "down"
        case .keyboardLeftArrow: name = "left"
        case .keyboardRightArrow: name = "right"
        case .keyboardHome: name = "home"
        case .keyboardEnd: name = "end"
        case .keyboardPageUp: name = "page_up"
        case .keyboardPageDown: name = "page_down"
        default: return nil
        }

        return (name, modifierNames(from: key.modifierFlags, includingShift: true))
    }

    private func modifiedCharacter(for key: UIKey) -> (key: String, modifiers: [String])? {
        DirectInputKeyMapper.modifiedCharacter(
            keyCode: key.keyCode,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: key.modifierFlags
        )
    }

    private func modifierNames(
        from flags: UIKeyModifierFlags,
        includingShift: Bool
    ) -> [String] {
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("control") }
        if flags.contains(.alternate) { modifiers.append("alt") }
        if includingShift && flags.contains(.shift) { modifiers.append("shift") }
        return modifiers
    }
}

enum TerminalAccessoryKeys {
    /// The tmux key name for Ctrl plus a typed character, or nil when Ctrl does not apply.
    static func controlKey(for text: String) -> String? {
        guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.isASCII else { return nil }
        let character = String(scalar).lowercased()
        if character == " " { return "space" }
        return "abcdefghijklmnopqrstuvwxyz[\\]^_@".contains(character) ? character : nil
    }
}

final class TerminalAccessoryBar: UIInputView {
    var onKey: ((String) -> Void)?
    var onText: ((String) -> Void)?
    var onControl: (() -> Void)?

    private let controlButton = UIButton(configuration: .gray())

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(button(title: "esc", label: String(localized: "Escape")) { [weak self] in self?.onKey?("escape") })
        controlButton.configuration?.title = "ctrl"
        controlButton.accessibilityLabel = String(localized: "Control")
        controlButton.addAction(UIAction { [weak self] _ in self?.onControl?() }, for: .touchUpInside)
        stack.addArrangedSubview(controlButton)
        stack.addArrangedSubview(button(title: "tab", label: String(localized: "Tab")) { [weak self] in self?.onKey?("tab") })
        for (symbol, key, label) in [("arrow.left", "left", String(localized: "Left")),
                                     ("arrow.down", "down", String(localized: "Down")),
                                     ("arrow.up", "up", String(localized: "Up")),
                                     ("arrow.right", "right", String(localized: "Right"))] {
            let arrow = button(title: nil, label: label) { [weak self] in self?.onKey?(key) }
            arrow.configuration?.image = UIImage(systemName: symbol)
            stack.addArrangedSubview(arrow)
        }
        for symbol in ["|", "~", "/", "-"] {
            stack.addArrangedSubview(button(title: symbol, label: symbol) { [weak self] in self?.onText?(symbol) })
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 48),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setControlLatched(_ latched: Bool) {
        controlButton.configuration = latched ? .filled() : .gray()
        controlButton.configuration?.title = "ctrl"
        controlButton.isSelected = latched
    }

    private func button(title: String?, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

#Preview {
    DirectInputView(onText: { _ in }, onKey: { _, _ in }, onSendAndEnter: { _ in }, draft: .constant(""))
}
