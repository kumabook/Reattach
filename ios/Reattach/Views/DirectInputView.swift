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

    var body: some View {
        DirectInputTextViewRepresentable(
            onText: onText,
            onKey: onKey,
            onCompositionChanged: { isComposingText = $0 }
        )
            .overlay(alignment: .leading) {
                if !isComposingText {
                    Label("Direct Input — type to terminal", systemImage: "keyboard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 48, maxHeight: 48)
            .background(.bar)
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
        let flags = key.modifierFlags
        guard flags.contains(.control) || flags.contains(.alternate) else {
            return nil
        }

        var character = key.charactersIgnoringModifiers
        guard character.count == 1, character.unicodeScalars.allSatisfy(\.isASCII) else {
            return nil
        }

        if character == " " {
            character = "space"
        } else if flags.contains(.shift) {
            character = character.uppercased()
        } else {
            character = character.lowercased()
        }

        return (character, modifierNames(from: flags, includingShift: false))
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
