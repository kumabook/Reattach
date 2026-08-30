//
//  DirectInputView.swift
//  Reattach
//

import SwiftUI
import UIKit

struct DirectInputView: View {
    let onText: (String) -> Void
    let onKey: (_ key: String, _ modifiers: [String]) -> Void
    @State private var isComposingText = false
    @State private var activityLabel: String?
    @State private var activityCount = 0
    @State private var clearActivityTask: Task<Void, Never>?

    var body: some View {
        DirectInputTextViewRepresentable(
            onText: { text in
                showActivity("Input sent")
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
                        Text(activityLabel ?? "Direct Input active")
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

private struct DirectInputTextViewRepresentable: UIViewRepresentable {
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
        textView.onKey = context.coordinator.onKey
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
        textView.onKey = onKey
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onText: (String) -> Void
        var onKey: (_ key: String, _ modifiers: [String]) -> Void
        var onCompositionChanged: (Bool) -> Void

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

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n" {
                onKey("enter", [])
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

private final class TerminalInputTextView: UITextView {
    var onKey: ((_ key: String, _ modifiers: [String]) -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.count == 1,
              let press = presses.first,
              let key = press.key,
              !key.modifierFlags.contains(.command) else {
            super.pressesBegan(presses, with: event)
            return
        }

        if let terminalKey = terminalKey(for: key) {
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
    DirectInputView(onText: { _ in }, onKey: { _, _ in })
}
