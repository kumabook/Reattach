//
//  DirectInputView.swift
//  Reattach
//

import SwiftUI
import UIKit

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

    var body: some View {
        VStack(spacing: 0) {
            if composeEnabled {
                HStack(alignment: .bottom, spacing: 12) {
                    DirectInputDraftEditor(text: $draft, onSendAndEnter: { text in
                        guard !text.isEmpty else { return false }
                        onSendAndEnter(text)
                        return true
                    })
                        .frame(height: 88)
                        .accessibilityIdentifier("directInputDraft")
                    Button {
                        let text = draft
                        guard !text.isEmpty else { return }
                        onSendAndEnter(text)
                        draft = ""
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .accessibilityLabel("文章を送信")
                    .accessibilityIdentifier("directInputSendText")
                    .disabled(draft.isEmpty)

                }
                .padding()
                HStack {
                    Text("⌘＋Enterで送信 · Enterで改行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    inputModeMenu
                }
                .padding(.horizontal)
            } else {
                HStack(spacing: 0) {
                    immediateInput
                        .disabled(!isConnected)
                    inputModeMenu
                        .padding(.trailing, 12)
                }
            }
        }
        .background(.bar)
    }

    private var inputModeMenu: some View {
        Menu {
            Picker("入力モード", selection: $composeEnabled) {
                Label("直接入力", systemImage: "keyboard").tag(false)
                Label("文章入力", systemImage: "text.alignleft").tag(true)
            }
        } label: {
            HStack(spacing: 4) {
                Text(composeEnabled ? "文章入力" : "直接入力")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption)
            .fixedSize()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(isComposingText)
        .accessibilityLabel("入力モード：" + (composeEnabled ? "文章入力" : "直接入力"))
        .accessibilityHint("タップして入力モードを切り替えます")
        .accessibilityIdentifier("terminalInputMode")
    }

    private var immediateInput: some View {
        DirectInputTextViewRepresentable(
            onText: { text in
                showActivity("送信しました")
                onText(text)
            },
            onKey: { key, modifiers in
                showActivity(Self.activityLabel(for: key, modifiers: modifiers))
                onKey(key, modifiers)
            },
            onCompositionChanged: { isComposingText = $0 }
        )
            .overlay(alignment: .leading) {
                if !isComposingText {
                    HStack(spacing: 8) {
                        Image(systemName: activityLabel == nil ? "keyboard" : "checkmark.circle.fill")
                            .foregroundStyle(activityLabel == nil ? Color.secondary : Color.green)
                            .symbolEffect(.bounce, value: activityCount)
                        Text(activityLabel ?? (isConnected ? "直接入力中" : "接続待ち…"))
                            .contentTransition(.opacity)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 48, maxHeight: 48)
            .background(.bar)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        activityLabel == nil ? Color.clear : Color.accentColor.opacity(0.55),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
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
    @Binding var text: String
    var onSendAndEnter: (String) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> DirectInputDraftTextView {
        let view = DirectInputDraftTextView()
        view.onSendAndEnter = onSendAndEnter
        view.delegate = context.coordinator
        view.text = text
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textColor = .label
        view.autocapitalizationType = .none
        view.accessibilityLabel = "日本語を変換・確定して送信"
        DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: DirectInputDraftTextView, context: Context) {
        view.onSendAndEnter = onSendAndEnter
        context.coordinator.text = $text
        // Never replace marked text while the input method is composing it.
        if view.markedTextRange == nil, view.text != text {
            view.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
        }
    }
}

final class DirectInputDraftTextView: UITextView {
    var onSendAndEnter: ((String) -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(sendDraft))
        send.discoverabilityTitle = "送信・実行"
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
    let onText: (String) -> Void
    let onKey: (_ key: String, _ modifiers: [String]) -> Void
    let onCompositionChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onText: onText,
            onKey: onKey,
            onCompositionChanged: onCompositionChanged
        )
    }

    func makeUIView(context: Context) -> TerminalInputTextView {
        let textView = TerminalInputTextView()
        textView.delegate = context.coordinator
        textView.onKey = { [weak coordinator = context.coordinator, weak textView] key, modifiers in
            guard let textView else { return }
            coordinator?.sendKey(key, modifiers: modifiers, from: textView)
        }
        textView.onCompositionEnded = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.textViewDidChange(textView)
        }
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .none
        textView.accessibilityLabel = "Direct terminal input"

        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ textView: TerminalInputTextView, context: Context) {
        context.coordinator.onText = onText
        context.coordinator.onKey = onKey
        context.coordinator.onCompositionChanged = onCompositionChanged
    }

    final class Coordinator: NSObject, UITextViewDelegate {
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

#Preview {
    DirectInputView(onText: { _ in }, onKey: { _, _ in }, onSendAndEnter: { _ in }, draft: .constant(""))
}
