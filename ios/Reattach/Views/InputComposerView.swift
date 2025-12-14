//
//  InputComposerView.swift
//  Reattach
//

import SwiftUI

struct InputComposerView: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        TextField("Enter message...", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isFocused)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
    }
}

#Preview {
    @Previewable @State var text = ""
    @Previewable @FocusState var isFocused: Bool

    VStack {
        Spacer()
        InputComposerView(text: $text, isFocused: $isFocused)
    }
}
