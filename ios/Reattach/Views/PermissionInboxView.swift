import SwiftUI

/// One request per screen; paging never submits a reply or selects a tmux pane.
struct PermissionInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var status = PermissionStatus.shared
    @State private var config = ServerConfigManager.shared
    @State private var selectedTarget: String?
    @State private var context: PermissionContext?
    @State private var dragOffset: CGFloat = 0
    @State private var previewFrames: [String: CGRect] = [:]
    let sessions: [Session]
    let openPane: (String) -> Void

    private var targets: [String] { status.entries.map(\.target) }
    private var selectedIndex: Int { targets.firstIndex(of: selectedTarget ?? "") ?? 0 }

    var body: some View {
        ZStack {
            NavigationStack {
                Group {
                    if status.entries.isEmpty {
                        ContentUnavailableView(String(localized: "No Pending Requests"),
                                               systemImage: "checkmark.circle")
                    } else {
                        GeometryReader { geometry in
                            ZStack {
                                ForEach(status.entries) { entry in
                                    PermissionRequestCard(
                                        entry: entry,
                                        minimumHeight: max(0, geometry.size.height - 48),
                                        title: PaneNavigationItem.matching(target: entry.target, in: sessions)?.windowName ?? entry.target,
                                        isActive: entry.target == (selectedTarget ?? targets.first),
                                        openPane: openPane,
                                        close: { dismiss() },
                                        onDrag: { translation in
                                            guard entry.target == selectedTarget, context == nil else { return }
                                            let atEdge = (selectedIndex == 0 && translation > 0)
                                                || (selectedIndex == targets.count - 1 && translation < 0)
                                            dragOffset = atEdge ? translation * 0.2 : translation
                                        },
                                        onDragEnd: { translation, predicted in
                                            let step = PermissionPaging.swipeStep(translation: translation,
                                                predicted: predicted, height: geometry.size.width - 40)
                                            settle(by: step)
                                        },
                                        onDragCancel: { settle(by: 0) },
                                        showContext: { output in
                                            dragOffset = 0
                                            context = PermissionContext(target: entry.target,
                                                                        output: TerminalTextRenderer.render(output).string.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                        origin: previewFrames[entry.target] ?? .zero)
                                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        }
                                    )
                                    .frame(width: max(0, geometry.size.width - 52), height: geometry.size.height)
                                    .id("\(config.activeServer?.id ?? "demo")|\(entry.target)|\(entry.receivedAt)")
                                    .offset(x: CGFloat((targets.firstIndex(of: entry.target) ?? 0) - selectedIndex) * (geometry.size.width - 40) + dragOffset)
                                    .allowsHitTesting(entry.target == (selectedTarget ?? targets.first))
                                    .accessibilityHidden(entry.target != (selectedTarget ?? targets.first))
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            // Keep the active card inside the safe area while allowing neighboring
                            // cards to continue behind the system's side bar.
                            .padding(.leading, geometry.safeAreaInsets.leading)
                            .padding(.trailing, geometry.safeAreaInsets.trailing)
                            .clipped()
                            .padding(.leading, -geometry.safeAreaInsets.leading)
                            .padding(.trailing, -geometry.safeAreaInsets.trailing)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("permissionPager")
                        .accessibilityValue("\(selectedIndex + 1) / \(targets.count)")
                        .accessibilityScrollAction { edge in
                            if edge == .trailing { move(by: 1) }
                            if edge == .leading { move(by: -1) }
                        }

                    }
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .toolbar(.hidden, for: .navigationBar)
            }
            .accessibilityHidden(context != nil)
            .allowsHitTesting(context == nil)
            if let context {
                PermissionContextOverlay(context: context) { self.context = nil }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onPreferenceChange(PermissionPreviewFrames.self) { previewFrames = $0 }
        .onAppear { selectedTarget = targets.first }
        .onChange(of: targets) { old, new in
            dragOffset = 0
            selectedTarget = PermissionPaging.selection(current: selectedTarget, old: old, new: new)
        }
        .onChange(of: config.activeServer?.id) { _, _ in dismiss() }
    }

    private var settleAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    private func settle(by step: Int) {
        let index = selectedIndex + step
        let changesPage = step != 0 && targets.indices.contains(index)
        withAnimation(settleAnimation) {
            if changesPage { selectedTarget = targets[index] }
            dragOffset = 0
        }
        if changesPage { UISelectionFeedbackGenerator().selectionChanged() }
    }

    private func move(by offset: Int) { settle(by: offset) }

}

private struct PermissionContext {
    let target: String
    let output: String
    let origin: CGRect
}

private struct PermissionPreviewFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// An overlay keeps the current request and paging position intact.
private struct PermissionContextOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var dismissDrag: CGFloat = 0
    @State private var closing = false
    let context: PermissionContext
    let close: () -> Void

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.88)
    }

    var body: some View {
        GeometryReader { geometry in
            let global = geometry.frame(in: .global)
            let origin = context.origin.isEmpty || reduceMotion
                ? CGRect(origin: .zero, size: geometry.size)
                : context.origin.offsetBy(dx: -global.minX, dy: -global.minY)
            let progress = min(dismissDrag / max(geometry.size.height, 1), 1)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(expanded ? 0.2 * (1 - progress) : 0)
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(.secondary.opacity(0.4)).frame(width: 32, height: 4)
                                .padding(.bottom, 6)
                            Text(String(localized: "Pane Context")).font(.headline)
                            Text(context.target).font(.caption).foregroundStyle(.secondary)
                        }
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(coordinateSpace: .global).onChanged { value in
                            guard !closing else { return }
                            dismissDrag = max(0, value.translation.height)
                        }.onEnded { value in
                            if value.translation.height > 80 || value.predictedEndTranslation.height > 160 {
                                dismissPreview()
                            } else {
                                withAnimation(animation) { dismissDrag = 0 }
                            }
                        }
                    )
                        Spacer()
                        Button(String(localized: "Close Preview"), systemImage: "xmark") { dismissPreview() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("closePermissionContext")
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(context.output)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(12)
                    }
                    .defaultScrollAnchor(.bottomLeading)
                    .defaultScrollAnchor(.topLeading, for: .alignment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(20)
                .frame(width: expanded ? geometry.size.width : origin.width,
                       height: expanded ? geometry.size.height : origin.height)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: expanded ? 24 : 18))
                .shadow(color: .black.opacity(expanded ? 0.12 : 0), radius: 24, y: 8)
                .opacity(expanded ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : 1 - progress * 0.08)
                .offset(x: expanded ? 0 : origin.minX,
                        y: (expanded ? 0 : origin.minY) + dismissDrag)
            }
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled, !closing else { return }
            withAnimation(animation) { expanded = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("permissionContextOverlay")
        .accessibilityAction(.escape) { dismissPreview() }
    }

    private func dismissPreview() {
        guard !closing else { return }
        closing = true
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            expanded = false
            dismissDrag = 0
        } completion: { close() }
    }
}

private struct PermissionRequestCard: View {
    let entry: PermissionAttention
    let minimumHeight: CGFloat
    let title: String
    let isActive: Bool
    let openPane: (String) -> Void
    let close: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDragEnd: (CGFloat, CGFloat) -> Void
    let onDragCancel: () -> Void
    @State private var dragging = false
    @State private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showContext: (String) -> Void
    @State private var output: String?
    @State private var previewText = ""
    @State private var detectedChoices: [PermissionChoice] = []
    @State private var reply = ""
    @State private var busy = false
    @State private var sent = false
    @State private var message: String?
    @State private var serverID: String?
    @State private var showManualReply = false
    @State private var lastDragTime = -Double.infinity

    private var choices: [PermissionChoice] { detectedChoices }

    var body: some View {
        ScrollView(.vertical) {
            cardContent
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(.primary.opacity(0.06)))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await refresh() }
        .onChange(of: output) { _, value in
            // Keep terminal parsing out of the per-frame drag/layout path.
            detectedChoices = value.map(PermissionChoice.parse) ?? []
            previewText = value.map {
                TerminalTextRenderer.render($0).string.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines).suffix(14).joined(separator: "\n")
            } ?? ""
        }
        .task(id: isActive) {
            guard isActive, output == nil else { return }
            serverID = ServerConfigManager.shared.activeServer?.id
            await refresh()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String(localized: "Close"))
                    .accessibilityIdentifier("closePermissionInbox-\(entry.target)")
                    .modifier(PermissionGlassControl())
                    Spacer()
                    Button {
                        openPane(entry.target)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String(localized: "Open Pane"))
                    .accessibilityIdentifier(entry.target)
                    .modifier(PermissionGlassControl())
                }
                .tint(.primary)
                .buttonStyle(.plain)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(entry.tool.isEmpty ? String(localized: "Permission Required") : entry.tool,
                              systemImage: "hand.raised.fill")
                            .font(.subheadline).foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                        Text(title).font(.title2.bold()).lineLimit(2)
                        Text(entry.target).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                // Horizontal swipes page the card; its entire content scrolls vertically.
                // Long press (or the expand button) opens the same frozen output over the feed.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Button(String(localized: "Expand Pane Context"), systemImage: "arrow.up.left.and.arrow.down.right") {
                            if let output { showContext(output) }
                        }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .semibold))
                        .tint(.primary)
                        .frame(width: 32, height: 32)
                        .background(.thinMaterial, in: Circle())
                        .disabled(output == nil)
                    }
                    if output != nil {
                        Text(previewText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(busy ? 1 : 0)
                    }
                }
                .padding(14)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(pressing ? 0.22 : 0.10)))
                .shadow(color: .black.opacity(pressing ? 0.02 : 0.07), radius: pressing ? 2 : 6, y: pressing ? 1 : 3)
                .contentShape(RoundedRectangle(cornerRadius: 18))
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PermissionPreviewFrames.self,
                                           value: [entry.target: proxy.frame(in: .global)])
                })
                .scaleEffect(pressing && !dragging && !reduceMotion ? 0.975 : 1)
                .animation(.easeOut(duration: 0.12), value: pressing)
                .gesture(PermissionContextPress(pressingChanged: { pressing = $0 }) {
                    if let output { showContext(output) }
                })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("permissionPreview-\(entry.target)")
                .accessibilityAction(named: String(localized: "Expand Pane Context")) {
                    if let output { showContext(output) }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                        ForEach(choices) { choice in
                            Button {
                                respond(escape: false, text: choice.number)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(choice.number + ".").monospacedDigit()
                                    Text(choice.label)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    if choice.selected { Image(systemName: "chevron.right") }
                                }
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 16))
                            .disabled(busy || sent)
                            .accessibilityIdentifier("permissionChoice-\(entry.target)-\(choice.number)")
                        }
                        if choices.isEmpty {
                            manualReply
                        } else {
                            DisclosureGroup(String(localized: "Other Controls"), isExpanded: $showManualReply) {
                                manualReply.padding(.top, 8)
                            }
                            .font(.subheadline)
                        }
                }
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .contentShape(Rectangle())
        .gesture(PermissionHorizontalPan(
            verticalChanged: {
                lastDragTime = ProcessInfo.processInfo.systemUptime
            },
            changed: { translation in
                dragging = true
                lastDragTime = ProcessInfo.processInfo.systemUptime
                onDrag(translation)
            },
            ended: { translation, predicted in
                dragging = false
                lastDragTime = ProcessInfo.processInfo.systemUptime
                onDragEnd(translation, predicted)
            },
            cancelled: {
                dragging = false
                lastDragTime = ProcessInfo.processInfo.systemUptime
                onDragCancel()
            }
        ))
        .buttonStyle(.borderless)
    }

    private var manualReply: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Enter", systemImage: "return") { respond(escape: false) }
                    .accessibilityIdentifier("permissionInboxEnter-\(entry.target)")
                Button("Esc", systemImage: "escape") { respond(escape: true) }
                    .accessibilityIdentifier("permissionInboxEscape-\(entry.target)")
                Spacer()
            }
            .buttonStyle(.bordered)
            .disabled(busy || output == nil || sent)
            HStack {
                TextField(String(localized: "Reply or option number"), text: $reply)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Send"), systemImage: "paperplane") {
                    respond(escape: false, text: reply)
                }
                .disabled(reply.isEmpty)
            }
            .disabled(busy || output == nil || sent)
        }
    }
    @MainActor
    private func refresh() async {
        guard isActive, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let latest = try await ReattachAPI.shared.getOutput(target: entry.target, lines: 200)
            guard !Task.isCancelled, serverID == ServerConfigManager.shared.activeServer?.id else { return }
            output = latest
            sent = false
            message = nil
        } catch {
            output = nil
            message = error.localizedDescription
        }
    }

    private func respond(escape: Bool, text: String = "") {
        // A horizontal drag over a button must never submit its choice on release.
        guard !dragging, ProcessInfo.processInfo.systemUptime - lastDragTime > 0.3 else { return }
        guard !busy, !sent, let reviewedOutput = output,
              serverID == ServerConfigManager.shared.activeServer?.id else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let api = ReattachAPI.shared
                let entries = try await api.permissionAttention()
                guard serverID == ServerConfigManager.shared.activeServer?.id else { return }
                guard entries.contains(entry) else {
                    output = nil
                    message = String(localized: "This request is no longer pending.")
                    return
                }
                let latest = try await api.getOutput(target: entry.target, lines: 200)
                guard serverID == ServerConfigManager.shared.activeServer?.id else { return }
                guard latest == reviewedOutput else {
                    output = latest
                    message = String(localized: "The request changed. Review it before replying.")
                    return
                }
                if escape {
                    try await api.sendEscape(target: entry.target)
                } else {
                    try await api.sendInput(target: entry.target, text: text)
                }
                sent = true
                reply = ""
                message = String(localized: "Sent. Waiting for the agent…")
            } catch {
                // A failed response can still have reached the terminal. Require a refresh.
                output = nil
                message = error.localizedDescription
            }
        }
    }
}

/// Share vertical drags with the scroll view; only horizontal drags move pages.
private struct PermissionHorizontalPan: UIGestureRecognizerRepresentable {
    var verticalChanged: () -> Void
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void
    var cancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard context.coordinator.isHorizontal else {
            verticalChanged()
            return
        }
        let translation = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began, .changed:
            changed(translation)
        case .ended:
            ended(translation, translation + recognizer.velocity(in: nil).x * 0.2)
        case .cancelled, .failed:
            cancelled()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isHorizontal = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            isHorizontal = abs(velocity.x) > abs(velocity.y)
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            !isHorizontal
        }
    }
}

private struct PermissionContextPress: UIGestureRecognizerRepresentable {
    var pressingChanged: (Bool) -> Void
    var activate: () -> Void

    func makeUIGestureRecognizer(context: Context) -> PreviewPressRecognizer {
        let recognizer = PreviewPressRecognizer()
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 8
        recognizer.pressingChanged = pressingChanged
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PreviewPressRecognizer, context: Context) {
        recognizer.pressingChanged = pressingChanged
    }

    func handleUIGestureRecognizerAction(_ recognizer: PreviewPressRecognizer, context: Context) {
        if recognizer.state == .began { activate() }
    }

    final class PreviewPressRecognizer: UILongPressGestureRecognizer {
        var pressingChanged: (Bool) -> Void = { _ in }
        private var isPressing = false

        private func setPressing(_ value: Bool) {
            guard value != isPressing else { return }
            isPressing = value
            pressingChanged(value)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            setPressing(true)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesMoved(touches, with: event)
            if state == .failed || state == .cancelled { setPressing(false) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            setPressing(false)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            setPressing(false)
        }

        override func reset() {
            super.reset()
            setPressing(false)
        }
    }
}

private struct PermissionGlassControl: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.thinMaterial, in: Capsule())
        }
    }
}
