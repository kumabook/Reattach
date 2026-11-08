//
//  PaneDetailView.swift
//  Reattach
//

import SwiftUI
import Observation
import GameController

// MARK: - ZoomableTextView

struct TerminalZoomRequest {
    let id = UUID()
    // nil restores the original scale.
    var multiplier: CGFloat? = nil
    var scale: CGFloat? = nil
}

final class TerminalScrollView: UIScrollView {
    var onViewportChange: ((UIScrollView) -> Void)?
    private var previousSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize, bounds.width > 0, bounds.height > 0 else { return }
        previousSize = bounds.size
        onViewportChange?(self)
    }
}

struct ZoomableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let contentVersion: UUID
    let cursor: PaneCursorState?
    @Binding var scrollToBottom: Bool
    var columns: Int? = nil
    var zoomRequest: TerminalZoomRequest? = nil
    var onCursorRectChanged: ((CGRect?) -> Void)? = nil
    var onZoomChanged: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        context.coordinator.lastContentVersion = nil
        let scrollView = TerminalScrollView()
        scrollView.onViewportChange = { [weak coordinator = context.coordinator] view in
            coordinator?.viewportChanged(in: view)
        }
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.backgroundColor = .systemBackground

        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = [.link]
        textView.linkTextAttributes = [.foregroundColor: UIColor.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.textContainer.lineBreakMode = .byClipping
        textView.tag = 100
        scrollView.addSubview(textView)

        let cursorView = UIView()
        cursorView.backgroundColor = UIColor.tintColor.withAlphaComponent(0.8)
        cursorView.isUserInteractionEnabled = false
        cursorView.isHidden = true
        textView.addSubview(cursorView)
        context.coordinator.cursorView = cursorView

        let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)

        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onCursorRectChanged = onCursorRectChanged
        context.coordinator.onZoomChanged = onZoomChanged
        guard let textView = scrollView.viewWithTag(100) as? UITextView else { return }

        let contentChanged = context.coordinator.lastContentVersion != contentVersion
        let cellWidth = context.coordinator.terminalCellWidth
        let paneColumns = cursor?.paneWidth ?? columns
        let terminalWidth = CGFloat(paneColumns ?? 80) * cellWidth + 26
        let maxWidth = max(scrollView.bounds.width, terminalWidth, 300)
        let layoutChanged = contentChanged || abs(textView.bounds.width - maxWidth) > 0.5
        if layoutChanged {
            context.coordinator.lastContentVersion = contentVersion

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            if contentChanged {
                textView.attributedText = attributedText
            }

            var size = textView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            size.width = maxWidth
            // A zoomed view has a transform: assigning frame would alter its
            // unscaled geometry and make subsequent output updates jump.
            textView.bounds = CGRect(origin: .zero, size: size)
            textView.center = CGPoint(
                x: size.width * scrollView.zoomScale / 2,
                y: size.height * scrollView.zoomScale / 2
            )
            scrollView.contentSize = CGSize(
                width: size.width * scrollView.zoomScale,
                height: size.height * scrollView.zoomScale
            )

            CATransaction.commit()
        }

        context.coordinator.updateCursor(cursor, in: textView, force: layoutChanged)
        if layoutChanged {
            context.coordinator.updateLatestContentBottom(in: textView)
        }

        if let zoomRequest, context.coordinator.lastZoomRequestID != zoomRequest.id {
            context.coordinator.lastZoomRequestID = zoomRequest.id
            context.coordinator.applyZoom(zoomRequest, in: scrollView)
        }

        if (layoutChanged || cursor != nil) && cursor?.copyMode != true {
            context.coordinator.scrollToLatest(in: scrollView)
        }
        if scrollToBottom {
            context.coordinator.scrollToLatest(in: scrollView, force: true)
            DispatchQueue.main.async { scrollToBottom = false }
        }
        context.coordinator.publishCursorRect()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var lastContentVersion: UUID?
        var lastZoomRequestID: UUID?
        var lastCursor: PaneCursorState?
        weak var scrollView: UIScrollView?
        weak var cursorView: UIView?
        private var selectionViews: [UIView] = []
        var onCursorRectChanged: ((CGRect?) -> Void)?
        var onZoomChanged: ((CGFloat) -> Void)?
        private var publishedCursorRect: CGRect?
        private var isUserScrolling = false
        private var isUserZooming = false
        private var followsLatestOutput = true

        private var latestContentBottom: CGFloat?

        func updateLatestContentBottom(in textView: UITextView) {
            let text = textView.attributedText.string
            var lines = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { lines.removeLast() }
            guard let index = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                latestContentBottom = 0
                return
            }
            let row = PaneCursorState(x: 0, rowFromBottom: lines.count - 1 - index,
                                      paneWidth: lastCursor?.paneWidth ?? 80, visible: false)
            latestContentBottom = cursorFrame(row, in: textView).map { $0.maxY + textView.textContainerInset.bottom }
        }

        private func latestOffset(in scrollView: UIScrollView) -> CGFloat {
            var bottom = latestContentBottom.map { $0 * scrollView.zoomScale } ?? scrollView.contentSize.height
            if let cursorView, !cursorView.isHidden {
                bottom = max(bottom, cursorView.frame.maxY * scrollView.zoomScale + 8)
            }
            return max(-scrollView.adjustedContentInset.top,
                       min(bottom, scrollView.contentSize.height) - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        }

        func viewportChanged(in scrollView: UIScrollView) {
            guard !isUserScrolling, !isUserZooming, !scrollView.isDragging,
                  !scrollView.isDecelerating, !scrollView.isZooming else { return }
            if followsLatestOutput && lastCursor?.copyMode != true {
                scrollToLatest(in: scrollView)
            } else {
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                scrollView.contentOffset = CGPoint(x: min(max(0, scrollView.contentOffset.x), maxX),
                                                   y: min(max(0, scrollView.contentOffset.y), maxY))
            }
            publishCursorRect()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishUserScroll(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserScroll(scrollView)
        }

        private func finishUserScroll(_ scrollView: UIScrollView) {
            isUserScrolling = false
            let bottom = latestOffset(in: scrollView)
            followsLatestOutput = bottom - scrollView.contentOffset.y <= 24
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isUserZooming = true
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isUserZooming = false
        }

        func scrollToLatest(in scrollView: UIScrollView, force: Bool = false) {
            guard !isUserScrolling, !isUserZooming,
                  !scrollView.isTracking, !scrollView.isDragging,
                  !scrollView.isDecelerating, !scrollView.isZooming else { return }
            guard force || followsLatestOutput else { return }
            followsLatestOutput = true
            let bottom = latestOffset(in: scrollView)
            let offset = CGPoint(x: scrollView.contentOffset.x, y: bottom)
            if abs(scrollView.contentOffset.y - bottom) > 0.5 {
                scrollView.setContentOffset(offset, animated: false)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { publishCursorRect() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            publishCursorRect()
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let scrollView else { return }
                self?.onZoomChanged?(scrollView.zoomScale)
            }
        }

        func publishCursorRect() {
            var rect: CGRect?
            if let scrollView, let cursorView, !cursorView.isHidden {
                let converted = cursorView.convert(cursorView.bounds, to: scrollView)
                    .offsetBy(dx: -scrollView.bounds.minX, dy: -scrollView.bounds.minY)
                if CGRect(origin: .zero, size: scrollView.bounds.size).intersects(converted) {
                    rect = converted
                }
            }
            guard rect != publishedCursorRect else { return }
            publishedCursorRect = rect
            DispatchQueue.main.async { [weak self] in
                guard let self, self.publishedCursorRect == rect else { return }
                self.onCursorRectChanged?(rect)
            }
        }
        let terminalCellWidth = (
            ("M" as NSString).size(withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 8, weight: .regular)
            ]).width
        )

        func updateCursor(
            _ cursor: PaneCursorState?,
            in textView: UITextView,
            force: Bool
        ) {
            guard force || cursor != lastCursor else { return }
            lastCursor = cursor
            updateSelection(cursor, in: textView)
            cursorView?.layer.removeAllAnimations()

            guard let cursor,
                  cursor.visible,
                  let frame = cursorFrame(cursor, in: textView) else {
                cursorView?.isHidden = true
                return
            }

            if cursor.copyMode == true, let scrollView, !isUserScrolling, !isUserZooming {
                scrollView.scrollRectToVisible(textView.convert(frame.insetBy(dx: -8, dy: -8), to: scrollView), animated: false)
            }
            cursorView?.frame = frame
            cursorView?.alpha = 0.9
            cursorView?.isHidden = false
            UIView.animate(
                withDuration: 0.55,
                delay: 0,
                options: [.autoreverse, .repeat, .allowUserInteraction]
            ) {
                self.cursorView?.alpha = 0.15
            }
        }

        private func updateSelection(_ cursor: PaneCursorState?, in textView: UITextView) {
            selectionViews.forEach { $0.removeFromSuperview() }
            selectionViews.removeAll()
            guard let cursor, cursor.copyMode == true else { return }
            for span in cursor.selection ?? [] {
                let start = PaneCursorState(x: span.startX, rowFromBottom: span.rowFromBottom, paneWidth: cursor.paneWidth, visible: true)
                let end = PaneCursorState(x: span.endX, rowFromBottom: span.rowFromBottom, paneWidth: cursor.paneWidth, visible: true)
                guard let left = cursorFrame(start, in: textView), let right = cursorFrame(end, in: textView), right.minX > left.minX else { continue }
                let highlight = UIView(frame: CGRect(x: left.minX, y: left.minY, width: right.minX - left.minX, height: left.height))
                highlight.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
                highlight.isUserInteractionEnabled = false
                textView.addSubview(highlight)
                selectionViews.append(highlight)
            }
            if let cursorView { textView.bringSubviewToFront(cursorView) }
        }

        func cursorFrame(
            _ cursor: PaneCursorState,
            in textView: UITextView
        ) -> CGRect? {
            let text = textView.attributedText.string
            let lines = text.components(separatedBy: "\n")
            let lineCount = max(0, lines.count - (text.hasSuffix("\n") ? 1 : 0))
            let lineIndex = lineCount - 1 - cursor.rowFromBottom
            guard lineIndex >= 0, lineIndex < lineCount else { return nil }

            let lineStart = lines[..<lineIndex].reduce(0) {
                $0 + $1.utf16.count + 1
            }
            let location = TerminalColumns.location(in: lines[lineIndex], column: min(cursor.x, cursor.paneWidth))
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            guard let position = textView.position(
                from: textView.beginningOfDocument,
                offset: lineStart + location.utf16Offset
            ) else { return nil }
            let caret = textView.caretRect(for: position)
            var cellWidth = terminalCellWidth
            if location.characterLength > 0,
               let next = textView.position(from: position, offset: location.characterLength) {
                let nextCaret = textView.caretRect(for: next)
                if abs(nextCaret.minY - caret.minY) < 1, nextCaret.minX > caret.minX {
                    cellWidth = (nextCaret.minX - caret.minX) / CGFloat(location.characterColumns)
                }
            }
            return CGRect(
                x: caret.minX + CGFloat(location.extraColumns) * cellWidth,
                y: caret.minY,
                width: cellWidth,
                height: max(caret.height, 10)
            )
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.subviews.first { $0 is UITextView }
        }

        func applyZoom(_ request: TerminalZoomRequest, in scrollView: UIScrollView) {
            let scale = request.scale ?? request.multiplier.map { scrollView.zoomScale * $0 } ?? 1
            let clampedScale = min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, scale))
            guard let textView = viewForZooming(in: scrollView) else { return }
            // Keep the visible insertion point stationary. When reading history,
            // preserve the top-left text instead of zooming around the screen center.
            var anchor = textView.convert(scrollView.bounds.origin, from: scrollView)
            if let cursorView, !cursorView.isHidden {
                let cursorCenter = CGPoint(x: cursorView.frame.midX, y: cursorView.frame.midY)
                if scrollView.bounds.contains(textView.convert(cursorCenter, to: scrollView)) {
                    anchor = cursorCenter
                }
            }
            let before = textView.convert(anchor, to: scrollView)
            let viewportPosition = CGPoint(
                x: before.x - scrollView.contentOffset.x,
                y: before.y - scrollView.contentOffset.y
            )
            scrollView.setZoomScale(clampedScale, animated: false)
            scrollView.layoutIfNeeded()
            let after = textView.convert(anchor, to: scrollView)
            let inset = scrollView.adjustedContentInset
            let minX = -inset.left
            let minY = -inset.top
            let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            scrollView.setContentOffset(CGPoint(
                x: min(maxX, max(minX, after.x - viewportPosition.x)),
                y: min(maxY, max(minY, after.y - viewportPosition.y))
            ), animated: false)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView,
                  let textView = scrollView.subviews.first(where: { $0 is UITextView }) else { return }

            let currentZoom = scrollView.zoomScale
            let tapPoint = gesture.location(in: textView)

            let newZoom: CGFloat
            if currentZoom < 1.5 {
                newZoom = 2.0
            } else if currentZoom < 3.0 {
                newZoom = 4.0
            } else {
                newZoom = 1.0
            }

            let zoomRect = zoomRectForScale(scrollView: scrollView, scale: newZoom, center: tapPoint)
            UIView.animate(withDuration: 0.3) {
                scrollView.zoom(to: zoomRect, animated: false)
            }
        }

        private func zoomRectForScale(scrollView: UIScrollView, scale: CGFloat, center: CGPoint) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            let origin = CGPoint(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2
            )
            return CGRect(origin: origin, size: size)
        }
    }
}

// tmux reports terminal columns, whereas UIKit positions text using UTF-16 offsets.
// Wide/fullwidth Unicode scalars consume two terminal cells; combining marks consume none.
enum TerminalColumns {
    private static let wideScalar = try! NSRegularExpression(pattern: "[\\p{ea=W}\\p{ea=F}]")

    static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
            return 2
        }
        return scalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format, .control:
                return 0
            default:
                let text = String(scalar)
                let range = NSRange(location: 0, length: text.utf16.count)
                return wideScalar.firstMatch(in: text, range: range) == nil ? 1 : 2
            }
        }.max() ?? 0
    }

    static func location(in line: String, column: Int) -> (
        utf16Offset: Int, extraColumns: Int, characterLength: Int, characterColumns: Int
    ) {
        var offset = 0
        var columns = 0
        for character in line {
            let length = String(character).utf16.count
            let width = width(of: character)
            if width > 0, columns + width > column {
                return (offset, max(0, column - columns), length, width)
            }
            columns += width
            offset += length
        }
        // capture-pane trims trailing spaces; extrapolate only that empty area.
        return (offset, max(0, column - columns), 0, 1)
    }
}

// Keep native IME text and its candidate anchor close to the terminal cursor.
enum CompositionPlacement {
    static func frame(cursor: CGRect?, viewport: CGSize) -> CGRect {
        let margin: CGFloat = 8
        let width = max(0, min(360, viewport.width - margin * 2))
        let height = min(CGFloat(44), max(0, viewport.height - margin * 2))
        let anchor = cursor ?? CGRect(x: margin, y: viewport.height - height - margin, width: 0, height: 0)
        let x = max(margin, min(anchor.minX, viewport.width - width - margin))
        // iOS shows conversion candidates above the editor, so prefer keeping
        // the whole composition UI above the terminal insertion point.
        let gap = max(CGFloat(12), anchor.height)
        let above = anchor.minY - height - gap
        let y = above >= margin ? above : anchor.maxY + gap
        return CGRect(x: x, y: max(margin, min(y, viewport.height - height - margin)), width: width, height: height)
    }
}

// MARK: - PaneDetailView

struct PaneDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionStatus = PermissionStatus.shared
    let pane: Pane
    let windowName: String
    var onTmuxNavigation: ((TmuxNavigationState) -> Void)?
    var onSelectPane: ((Pane) -> Void)?
    @AppStorage("show_tmux_window_layout") private var showWindowLayout = false
    @State private var layoutWindow: Window?
    @State private var configManager = ServerConfigManager.shared
    @State private var viewModel: PaneDetailViewModel
    @State private var scrollToBottom = false
    @State private var zoomRequest: TerminalZoomRequest?
    @State private var showTextSize = false
    @State private var displayedZoom: CGFloat = 1
    @State private var inputText = ""
    @State private var keyboardFocusRequest: UUID?
    @State private var keyboardVisible = false
    @State private var hardwareKeyboardConnected = GCKeyboard.coalesced != nil
    @State private var isDirectCompositionActive = false
    @State private var visibleCursorRect: CGRect?
    @State private var showCommandEditor = false
    @State private var showCommandPicker = false
    @AppStorage("direct_input_compose_enabled") private var composeEnabled = true

    init(pane: Pane, windowName: String, onSelectPane: ((Pane) -> Void)? = nil, onTmuxNavigation: ((TmuxNavigationState) -> Void)? = nil) {
        self.onSelectPane = onSelectPane
        self.onTmuxNavigation = onTmuxNavigation
        self.pane = pane
        self.windowName = windowName
        _viewModel = State(wrappedValue: PaneDetailViewModel(target: pane.target))
    }

    @ViewBuilder
    private var inputModeMenuItems: some View {
        Picker(String(localized: "Input Mode"), selection: $composeEnabled) {
            Label(String(localized: "Direct Input"), systemImage: "keyboard").tag(false)
            Label(String(localized: "Compose"), systemImage: "text.alignleft").tag(true)
        }
        if !composeEnabled {
            Button(String(localized: "Send Escape")) { viewModel.queueDirectKey("escape") }
        }
    }

    private var isWaitingForPermission: Bool {
        permissionStatus.isWaiting(viewModel.tmuxNavigation?.target ?? pane.target)
    }

    private var hasQuickAction: Bool {
        if isWaitingForPermission { return true }
        switch viewModel.quickAction {
        case .options, .suggestions, .yesNo:
            return true
        case .none:
            return false
        }
    }

    @ToolbarContentBuilder
    private var paneToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(String(localized: "Display Mode"), selection: $showWindowLayout) {
                    Label(String(localized: "Selected Pane Only"), systemImage: "rectangle")
                        .tag(false)
                    Label(String(localized: "Match tmux Layout"), systemImage: "rectangle.split.2x2")
                        .tag(true)
                }
            } label: {
                Label(String(localized: "Display Mode"), systemImage: "rectangle.split.2x2")
            }
            .disabled(isDirectCompositionActive)
            .accessibilityIdentifier("windowLayoutMenu")
        }
        ToolbarItem(placement: .primaryAction) {
            if keyboardVisible || hardwareKeyboardConnected {
                Menu {
                    inputModeMenuItems
                } label: {
                    Label(composeEnabled ? String(localized: "Compose") : String(localized: "Direct Input"), systemImage: composeEnabled ? "text.alignleft" : "keyboard")
                }
                .disabled(isDirectCompositionActive)
                .accessibilityLabel(composeEnabled ? String(localized: "Compose") : String(localized: "Direct Input"))
            } else {
                Menu {
                    inputModeMenuItems
                } label: {
                    Label(String(localized: "Show Keyboard"), systemImage: "keyboard")
                } primaryAction: {
                    keyboardFocusRequest = UUID()
                }
                .accessibilityLabel(String(localized: "Show Keyboard"))
                .accessibilityHint(String(localized: "Touch and hold to switch input modes"))
                .accessibilityIdentifier("showKeyboardButton")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(String(localized: "Pane Selection"), selection: Binding(
                    get: { configManager.synchronizesSelection },
                    set: { configManager.synchronizesSelection = $0 }
                )) {
                    Label(String(localized: "Sync with Other Devices"), systemImage: "rectangle").tag(true)
                    Label(String(localized: "Switch on This Device Only"), systemImage: "rectangle.on.rectangle").tag(false)
                }
                Text(String(localized: "Input is shared in either mode."))
            } label: {
                Label(String(localized: "Pane Selection"), systemImage: configManager.synchronizesSelection ? "rectangle" : "rectangle.on.rectangle")
            }
            .accessibilityLabel(String(localized: "Pane Selection"))
            .accessibilityValue(configManager.synchronizesSelection ? String(localized: "Sync with Other Devices") : String(localized: "Switch on This Device Only"))
            .disabled(isDirectCompositionActive || configManager.isDemoMode)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(String(localized: "Refresh Now"), systemImage: "arrow.clockwise") {
                    Task { await viewModel.refreshLive() }
                }
                .disabled(viewModel.isLoading)
                Toggle(String(localized: "Auto Refresh"), isOn: $viewModel.autoRefresh)
            } label: {
                Label(String(localized: "Refresh Display"), systemImage: "arrow.clockwise")
            }
            .accessibilityLabel(String(localized: "Refresh Display"))
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(String(localized: "Copy tmux Selection"), systemImage: "doc.on.doc") {
                    viewModel.copyTmuxSelection()
                }
                .disabled(!viewModel.isStreamConnected || !viewModel.supportsClipboard)
                PasteButton(payloadType: String.self) { strings in
                    inputText += strings.joined(separator: "\n")
                    composeEnabled = true
                    keyboardFocusRequest = UUID()
                }
                .disabled(isDirectCompositionActive)
            } label: {
                Label(String(localized: "Copy and Paste"), systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("clipboardMenu")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showTextSize.toggle()
            } label: {
                Label(String(localized: "Text Size"), systemImage: "textformat.size")
            }
            .popover(isPresented: $showTextSize) {
                VStack(spacing: 16) {
                    HStack {
                        Text(String(localized: "Text Size")).font(.headline)
                        Spacer()
                        Text(verbatim: "\(Int((displayedZoom * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { displayedZoom },
                        set: {
                            displayedZoom = $0
                            zoomRequest = TerminalZoomRequest(scale: $0)
                        }
                    ), in: 1...4, step: 0.05) {
                        Text(String(localized: "Text Size"))
                    }
                    Button(String(localized: "Reset to Default")) {
                        zoomRequest = TerminalZoomRequest(multiplier: nil)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
                .frame(width: 280)
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityIdentifier("textSizeButton")
        }

    }

    private var zoomShortcuts: some View {

            // Keep shortcuts registered even while the popover is closed.
            Group {
                Button(String(localized: "Increase Text Size")) { zoomRequest = TerminalZoomRequest(multiplier: 1.25) }
                    .keyboardShortcut("+", modifiers: .command)
                Button(String(localized: "Decrease Text Size")) { zoomRequest = TerminalZoomRequest(multiplier: 1 / 1.25) }
                    .keyboardShortcut("-", modifiers: .command)
                Button(String(localized: "Reset Text Size")) { zoomRequest = TerminalZoomRequest(multiplier: nil) }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .hidden()

    }

    private var activeLayoutTarget: String { viewModel.tmuxNavigation?.target ?? pane.target }

    private var usesWindowLayout: Bool {
        guard showWindowLayout, let window = layoutWindow,
              let frames = WindowLayout.frames(for: window, in: CGSize(width: 1, height: 1)) else { return false }
        return frames[activeLayoutTarget] != nil
    }

    private var selectedTerminal: some View {
        ZoomableTextView(
            attributedText: viewModel.output,
            contentVersion: viewModel.contentVersion,
            cursor: viewModel.cursor,
            scrollToBottom: $scrollToBottom,
            columns: layoutWindow?.panes.first(where: { $0.target == activeLayoutTarget })?.geometry?.width,
            zoomRequest: zoomRequest,
            onCursorRectChanged: { visibleCursorRect = $0 },
            onZoomChanged: { displayedZoom = $0 }
        )
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.isReconnecting || viewModel.isConnectionSlow {
                    Text(viewModel.isReconnecting ? String(localized: "Reconnecting…") : String(localized: "Server response is slow…"))
                        .font(.caption)
                        .foregroundStyle(viewModel.isReconnecting ? .red : .orange)
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier(viewModel.isReconnecting ? "streamReconnectingStatus" : "streamSlowStatus")
                }
                if !composeEnabled, let state = viewModel.tmuxNavigation, state.keyTable != "root" {
                    Text(String(localized: "tmux · Enter the next key (\(state.prefix))"))
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(8)
            .allowsHitTesting(false)
        }

        .onChange(of: viewModel.isSending) { _, isSending in
            if !isSending {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollToBottom = true
                }
            }
        }
        .overlay {
            if viewModel.isSending {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text(String(localized: "Sending..."))
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // Keep the keyboard responder mounted while pane cells and layout change.
    private var terminalDisplay: some View {
        ZStack {
            if usesWindowLayout, let window = layoutWindow {
                WindowLayoutView(window: window, selectedTarget: activeLayoutTarget,
                                 autoRefresh: viewModel.autoRefresh,
                                 selectionEnabled: !isDirectCompositionActive && !viewModel.isSending,
                                 onSelect: { selected in
                    guard selected.target != activeLayoutTarget else { return }
                    onSelectPane?(selected)
                }) {
                    selectedTerminal
                }
            } else {
                selectedTerminal
            }
        }
        .overlay(alignment: .topLeading) {
            if !composeEnabled {
                GeometryReader { geometry in
                    let paneFrame = usesWindowLayout ? layoutWindow.flatMap {
                        WindowLayout.frames(for: $0, in: geometry.size)?[activeLayoutTarget]
                    } : nil
                    let cursor = visibleCursorRect.map {
                        $0.offsetBy(dx: paneFrame?.minX ?? 0, dy: paneFrame?.minY ?? 0)
                    }
                    let frame = CompositionPlacement.frame(cursor: cursor, viewport: geometry.size)
                    DirectInputTextViewRepresentable(
                        onText: { viewModel.queueDirectText($0) },
                        onKey: { viewModel.queueDirectKey($0, modifiers: $1) },
                        onCompositionChanged: { isDirectCompositionActive = $0 },
                        keyboardFocusRequest: keyboardFocusRequest,
                        isInputEnabled: viewModel.isStreamConnected
                    )
                    .frame(width: frame.width, height: frame.height)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .opacity(isDirectCompositionActive ? 1 : 0)
                    .allowsHitTesting(isDirectCompositionActive)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            terminalDisplay

            if isWaitingForPermission {
                Divider()
                HStack(spacing: 8) {
                    Label(String(localized: "Permission Required — Review the Request"), systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        viewModel.queueDirectKey("enter")
                    } label: {
                        Label(String(localized: "Enter"), systemImage: "return")
                            .font(.caption)
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isStreamConnected || viewModel.isSending || isDirectCompositionActive)
                    .accessibilityLabel(String(localized: "Send Enter"))
                    .accessibilityIdentifier("permissionEnterButton")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            } else if composeEnabled {
                Divider()

                switch viewModel.quickAction {
                case .options(let options):
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(options, id: \.number) { option in
                                Button {
                                    Task {
                                        await viewModel.sendInput(option.number)
                                    }
                                } label: {
                                    Text(verbatim: "\(option.number). \(option.label)")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .tint(.accentColor)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                    .background(.bar)
                    Divider()

                case .yesNo:
                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await viewModel.sendInput("y")
                            }
                        } label: {
                            Label(String(localized: "Yes"), systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)

                        Button {
                            Task {
                                await viewModel.sendInput("n")
                            }
                        } label: {
                            Label(String(localized: "No"), systemImage: "xmark.circle.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    Divider()

                case .suggestions(let suggestions):
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button {
                                    Task {
                                        await viewModel.sendInput(suggestion)
                                    }
                                } label: {
                                    Text(suggestion)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                    .background(.bar)
                    Divider()

                case .none:
                    EmptyView()
                }

            }

            if composeEnabled {
                ZStack(alignment: .topTrailing) {
                    if composeEnabled {
                        DirectInputView(
                            isConnected: viewModel.isStreamConnected,
                            onText: { viewModel.queueDirectText($0) },
                            onKey: { key, modifiers in
                                viewModel.queueDirectKey(key, modifiers: modifiers)
                            },
                            onSendAndEnter: { text in
                                Task { await viewModel.sendInput(text) }
                            },
                            draft: $inputText,
                            onCompositionState: { isDirectCompositionActive = $0 },
                            keyboardFocusRequest: keyboardFocusRequest
                        )
                    }

                    HStack(spacing: 8) {
                        if composeEnabled {
                            GlassButton {
                                showCommandPicker = true
                            } label: {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.purple)
                            }
                            .disabled(viewModel.isSending)
                        }

                        GlassButton {
                            if !composeEnabled {
                                viewModel.queueDirectKey("escape")
                            } else {
                                Task {
                                    await viewModel.sendEscape()
                                }
                            }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        .disabled(viewModel.isSending)

                    }
                    .opacity(composeEnabled ? 1 : 0)
                    .allowsHitTesting(composeEnabled)
                    .offset(x: -12, y: hasQuickAction ? -96 : -52)
                    .animation(.easeInOut(duration: 0.2), value: hasQuickAction)
                }
            }
        }
    }

    private var decoratedPane: some View {
        terminalContent
        .navigationTitle(viewModel.tmuxNavigation?.windowName ?? windowName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hardwareKeyboardConnected = GCKeyboard.coalesced != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            hardwareKeyboardConnected = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hardwareKeyboardConnected = GCKeyboard.coalesced != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            hardwareKeyboardConnected = GCKeyboard.coalesced != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .toolbar { paneToolbar }
        .background { zoomShortcuts }
    }

    private var presentedPane: some View {
        decoratedPane
        .alert(String(localized: "Error"), isPresented: $viewModel.showError) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .sheet(isPresented: $showCommandEditor) {
            CommandEditorView()
                .modifier(iPadPagePresentationModifier())
        }
        .sheet(isPresented: $showCommandPicker) {
            CommandPickerView(
                onCommandSelected: { command in
                    Task {
                        await viewModel.sendInput(command)
                    }
                },
                onCommandInsert: { command in
                    inputText = command
                },
                onEditCommands: {
                    showCommandPicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showCommandEditor = true
                    }
                }
            )
            .modifier(iPadPagePresentationModifier())
        }
    }

    var body: some View {
        presentedPane
        .task(id: pane.target + "|" + String(configManager.synchronizesSelection)) {
            viewModel.setDirectMode(!composeEnabled)
            await viewModel.openPane(pane.target, synchronize: configManager.synchronizesSelection)
            if !Task.isCancelled { scrollToBottom = true }
        }
        .task(id: "\(showWindowLayout)|\(scenePhase == .active)|\(activeLayoutTarget)|\(viewModel.autoRefresh)") {
            guard showWindowLayout, scenePhase == .active else { return }
            repeat {
                do {
                    let sessions = try await ReattachAPI.shared.listSessions()
                    guard !Task.isCancelled else { return }
                    layoutWindow = sessions.flatMap(\.windows).first { window in
                        window.panes.contains { $0.target == activeLayoutTarget }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    // Keep the current terminal visible and retry on the next refresh.
                }
                guard viewModel.autoRefresh else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear {
            viewModel.stopStreaming()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { viewModel.stopStreaming() }
            if phase == .active { Task { await viewModel.startStreaming() } }
        }
        .onChange(of: viewModel.autoRefresh) { _, enabled in
            if enabled {
                Task {
                    await viewModel.resumeAutoRefresh()
                }
            }
        }
        .onChange(of: composeEnabled) { _, enabled in
            viewModel.setDirectMode(!enabled)
        }
        .onChange(of: viewModel.tmuxNavigation) { _, state in
            if let state { onTmuxNavigation?(state) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .unreadPanesChanged)) { _ in
            if let deviceId = ServerConfigManager.shared.activeServer?.deviceId {
                AppDelegate.shared?.markPaneAsRead(deviceId: deviceId, paneTarget: pane.target)
            }
        }
    }
}

// MARK: - iPadPagePresentationModifier

struct iPadPagePresentationModifier: ViewModifier {
    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    func body(content: Content) -> some View {
        if isIPad {
            content.presentationDetents([.large])
        } else {
            content.presentationDetents([.medium, .large])
        }
    }
}

// MARK: - QuickAction

struct DetectedOption {
    let number: String
    let label: String
}

enum QuickAction {
    case options([DetectedOption])
    case suggestions([String])
    case yesNo
    case none
}

private struct SendableAttributedString: @unchecked Sendable {
    let value: NSAttributedString
}

// The transport boundary lets recovery tests simulate a connection that stops
// responding without relying on a real network or the user's daemon.
@MainActor
protocol PaneStreamSocket: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: PaneStreamSocket {}

// MARK: - PaneDetailViewModel

@MainActor
@Observable
class PaneDetailViewModel {
    var output: NSAttributedString = NSAttributedString()
    var contentVersion: UUID = UUID()
    var isLoading = false
    var isSending = false
    var showError = false
    var errorMessage = ""
    var autoRefresh = true
    var quickAction: QuickAction = .none
    var isStreamConnected = false
    private(set) var isReconnecting = false
    private(set) var isConnectionSlow = false
    var cursor: PaneCursorState?

    var tmuxNavigation: TmuxNavigationState?
    private var target: String
    private var directMode = false
    private var synchronizesSelection = true
    private var supportsTmuxKeys = false
    var supportsClipboard = false
    private let api = ReattachAPI.shared
    @ObservationIgnored private var streamGeneration = UUID()
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var webSocketTask: (any PaneStreamSocket)?
    @ObservationIgnored private var connectionID = UUID()
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var awaitingPong = false
    @ObservationIgnored private var slowResponseTask: Task<Void, Never>?
    @ObservationIgnored private var rawOutput: String = ""
    @ObservationIgnored private var directTextBuffer = ""
    @ObservationIgnored private var directTextFlushTask: Task<Void, Never>?
    @ObservationIgnored private var directSendTail: Task<Void, Never>?

    @ObservationIgnored private let socketFactory: ((String, Bool) throws -> any PaneStreamSocket)?
    private let slowResponseThreshold: Duration
    private let heartbeatInterval: Duration
    private let retryInterval: Duration

    init(target: String,
         heartbeatInterval: Duration = .seconds(10),
         retryInterval: Duration = .seconds(2),
         slowResponseThreshold: Duration = .seconds(2),
         socketFactory: ((String, Bool) throws -> any PaneStreamSocket)? = nil) {
        self.target = target
        self.slowResponseThreshold = slowResponseThreshold
        self.heartbeatInterval = heartbeatInterval
        self.retryInterval = retryInterval
        self.socketFactory = socketFactory
    }

    nonisolated private static func detectQuickAction(from text: String) -> QuickAction {
        if detectYesNoPrompt(from: text) {
            return .yesNo
        }
        let options = parseOptions(from: text)
        if !options.isEmpty {
            return .options(options)
        }
        let suggestions = parseSuggestions(from: text)
        if !suggestions.isEmpty {
            return .suggestions(suggestions)
        }
        return .none
    }

    nonisolated private static func parseSuggestions(from text: String) -> [String] {
        let lines = text.components(separatedBy: "\n").suffix(20)
        var suggestions: [String] = []
        let prefixes = ["❯", "›", "▶", "▸", "➤", "⟩"]
        let trailingPattern = #"\s*↵\s*\w*\s*$"#

        for line in lines {
            var cleanLine = line.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)

            // Remove trailing "↵ send" or similar
            cleanLine = cleanLine.replacingOccurrences(
                of: trailingPattern,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)

            for prefix in prefixes {
                if cleanLine.hasPrefix(prefix) {
                    let suggestion = String(cleanLine.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if !suggestion.isEmpty && suggestion.count < 100 {
                        suggestions.append(suggestion)
                    }
                    break
                }
            }
        }

        return suggestions
    }

    nonisolated private static func detectYesNoPrompt(from text: String) -> Bool {
        let lastLines = text.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
        let cleanText = lastLines.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        ).lowercased()

        let patterns = [
            "(y/n)",
            "(yes/no)",
            "allow?",
            "proceed?",
            "continue?",
            "confirm?",
            "do you want to",
            "would you like to"
        ]

        return patterns.contains { cleanText.contains($0) }
    }

    nonisolated private static func parseOptions(from text: String) -> [DetectedOption] {
        let lines = text.components(separatedBy: "\n").suffix(30)
        let pattern = #"^\s*([❯>])?\s*(\d+)[.\)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        var options: [DetectedOption] = []
        var hasSelector = false

        for line in lines {
            let cleanLine = line.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            )

            let range = NSRange(cleanLine.startIndex..., in: cleanLine)
            if let match = regex.firstMatch(in: cleanLine, options: [], range: range) {
                if let selectorRange = Range(match.range(at: 1), in: cleanLine) {
                    let selector = String(cleanLine[selectorRange])
                    if selector == "❯" || selector == ">" {
                        hasSelector = true
                    }
                }

                if let numRange = Range(match.range(at: 2), in: cleanLine),
                   let labelRange = Range(match.range(at: 3), in: cleanLine) {
                    let number = String(cleanLine[numRange])
                    let label = String(cleanLine[labelRange]).trimmingCharacters(in: .whitespaces)
                    if label.count < 100 {
                        options.append(DetectedOption(number: number, label: label))
                    }
                }
            }
        }

        return (options.count >= 2 && hasSelector) ? options : []
    }

    func stopStreaming() {
        streamGeneration = UUID()
        streamingTask?.cancel()
        streamingTask = nil
        if let socket = webSocketTask { disconnect(socket) }
        isReconnecting = false
        isConnectionSlow = false
        slowResponseTask?.cancel()
        slowResponseTask = nil
        clearPendingInput()
        cursor = nil
    }

    private func clearPendingInput() {
        connectionID = UUID()
        directTextFlushTask?.cancel()
        directTextFlushTask = nil
        directSendTail?.cancel()
        directSendTail = nil
        directTextBuffer = ""
        cursor = nil
    }

    private func disconnect(_ socket: any PaneStreamSocket) {
        socket.cancel(with: .goingAway, reason: nil)
        guard webSocketTask === socket else { return }
        webSocketTask = nil
        isStreamConnected = false
        isReconnecting = true
        supportsTmuxKeys = false
        supportsClipboard = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        awaitingPong = false
        isConnectionSlow = false
        slowResponseTask?.cancel()
        slowResponseTask = nil
        clearPendingInput()
    }

    private func monitorConnection(_ socket: any PaneStreamSocket) {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.webSocketTask === socket else { return }
                // Also bounds the initial handshake. A silent connection must
                // not leave receive() and queued sends waiting indefinitely.
                guard self.isStreamConnected, !self.awaitingPong else {
                    self.disconnect(socket)
                    return
                }
                self.awaitingPong = true
                let started = ContinuousClock.now
                let threshold = self.slowResponseThreshold
                self.slowResponseTask?.cancel()
                self.slowResponseTask = Task { [weak self] in
                    do { try await Task.sleep(for: threshold) } catch { return }
                    guard let self, self.webSocketTask === socket, self.awaitingPong else { return }
                    self.isConnectionSlow = true
                }
                socket.sendPing { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.webSocketTask === socket else { return }
                        if error != nil { self.disconnect(socket) }
                        else {
                            self.awaitingPong = false
                            self.slowResponseTask?.cancel()
                            self.slowResponseTask = nil
                            // Clear the warning only after a prompt reply, not a late pong.
                            self.isConnectionSlow = started.duration(to: .now) >= threshold
                        }
                    }
                }
            }
        }
    }

    func openPane(_ selectedTarget: String, synchronize: Bool = true) async {
        // A navigation notification already changed the live stream's pane.
        if isStreamConnected, tmuxNavigation?.target == selectedTarget, synchronizesSelection == synchronize { return }
        synchronizesSelection = synchronize
        stopStreaming()
        target = selectedTarget
        tmuxNavigation = nil
        rawOutput = ""
        output = NSAttributedString()
        contentVersion = UUID()
        do {
            if synchronize { try await api.selectPane(target: selectedTarget) }
            try Task.checkCancellation()
            await startStreaming()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func startStreaming() async {
        stopStreaming()

        if api.isDemoMode && socketFactory == nil {
            await refresh()
            return
        }

        let generation = streamGeneration
        streamingTask = Task { [weak self] in
            await self?.runStreamLoop(generation: generation)
        }
    }

    private func runStreamLoop(generation: UUID) async {
        while !Task.isCancelled && generation == streamGeneration {
            do {
                let connectionTarget = tmuxNavigation?.target ?? target
                let socket: any PaneStreamSocket
                if let socketFactory {
                    socket = try socketFactory(connectionTarget, !synchronizesSelection)
                } else {
                    socket = try api.makePaneWebSocket(target: connectionTarget, lines: 500, independent: !synchronizesSelection)
                }
                webSocketTask = socket
                clearPendingInput()
                socket.resume()
                monitorConnection(socket)

                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard generation == streamGeneration, !Task.isCancelled else { return }
                    guard webSocketTask === socket else { throw URLError(.networkConnectionLost) }
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8) else {
                        continue
                    }

                    let response = try JSONDecoder().decode(PaneStreamResponse.self, from: data)
                    switch response.type {
                    case "ready":
                        if !synchronizesSelection && response.independentSelection != true {
                            stopStreaming()
                            showDirectInputError(String(localized: "Independent mode requires a newer daemon. Please update the daemon."))
                            return
                        }
                        supportsTmuxKeys = response.tmuxKeys == true
                        supportsClipboard = response.clipboard == true
                        // Restore mode before accepting user input on this socket.
                        if supportsTmuxKeys {
                            try await sendStreamMessage(.directMode(directMode), over: socket)
                        }
                        guard webSocketTask === socket else { throw URLError(.networkConnectionLost) }
                        isStreamConnected = true
                        isReconnecting = false
                    case "clipboard":
                        if let text = response.text {
                            UIPasteboard.general.string = text
                        } else {
                            showDirectInputError(response.error ?? String(localized: "Could not copy the selection."))
                        }
                    case "navigation":
                        if let state = response.state {
                            if target != state.paneId {
                                target = state.paneId
                                rawOutput = ""
                                cursor = nil
                            }
                            tmuxNavigation = state
                        }
                    case "output":
                        if autoRefresh {
                            cursor = response.cursor
                            if let output = response.output {
                                await applyOutput(output)
                            }
                        }
                    case "patch":
                        if autoRefresh {
                            cursor = response.cursor
                            await applyPatch(response)
                        }
                    case "cursor":
                        if autoRefresh {
                            cursor = response.cursor
                        }
                    case "error":
                        throw APIError.serverError(response.error ?? String(localized: "Pane stream failed"))
                    default:
                        continue
                    }
                }
            } catch {
                guard generation == streamGeneration else { return }
                if let socket = webSocketTask { disconnect(socket) }

                guard !Task.isCancelled else { return }
                isReconnecting = true

                do {
                    try await Task.sleep(for: retryInterval)
                } catch {
                    return
                }
            }
        }
    }

    func resumeAutoRefresh() async {
        guard let socket = webSocketTask else {
            await refresh()
            return
        }

        do {
            try await sendStreamMessage(.refresh, over: socket)
        } catch {
            disconnect(socket)
            await refresh()
        }
    }

    func refreshLive() async {
        guard let socket = webSocketTask else {
            await refresh()
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            try await sendStreamMessage(.refresh, over: socket)
        } catch {
            disconnect(socket)
            await refresh()
        }
    }

    private func refreshSilently() async {
        do {
            let newRawOutput = try await api.getOutput(target: target, lines: 500)
            await applyOutput(newRawOutput)
        } catch {
            // Silently ignore errors during polling
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let newRawOutput = try await api.getOutput(target: target, lines: 500)
            await applyOutput(newRawOutput)
        } catch let error as APIError {
            if case .unauthorized = error {
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func sendInput(_ text: String) async {
        isSending = true
        defer { isSending = false }

        do {
            if let socket = webSocketTask {
                do {
                    try await sendStreamMessage(.input(text), over: socket)
                } catch {
                    disconnect(socket)
                    throw error
                }
            } else {
                try await api.sendInput(target: target, text: text)
            }
            CommandHistoryManager.shared.add(text)
            if webSocketTask == nil {
                await refreshSilently()
            }
        } catch let error as APIError {
            if case .unauthorized = error {
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func sendEscape() async {
        isSending = true
        defer { isSending = false }

        do {
            if let socket = webSocketTask {
                do {
                    try await sendStreamMessage(.escape, over: socket)
                } catch {
                    disconnect(socket)
                    throw error
                }
            } else {
                try await api.sendEscape(target: target)
            }
            if webSocketTask == nil {
                await refreshSilently()
            }
        } catch let error as APIError {
            if case .unauthorized = error {
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func copyTmuxSelection() {
        flushDirectInput()
        enqueueDirectRequest(.copySelection)
    }

    func setDirectMode(_ enabled: Bool) {
        flushDirectInput()
        directMode = enabled
        if supportsTmuxKeys && isStreamConnected {
            enqueueDirectRequest(.directMode(enabled))
        }
    }

    func queueDirectText(_ text: String) {
        guard !text.isEmpty else { return }
        guard isStreamConnected else {
            showDirectInputError(String(localized: "Reconnecting. Please wait before typing."))
            return
        }
        directTextBuffer.append(text)
        guard directTextFlushTask == nil else { return }

        directTextFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            self?.flushDirectInput()
        }
    }

    func queueDirectKey(_ key: String, modifiers: [String] = []) {
        flushDirectInput()
        enqueueDirectRequest(.key(key, modifiers: modifiers))
    }

    func flushDirectInput() {
        directTextFlushTask?.cancel()
        directTextFlushTask = nil
        guard !directTextBuffer.isEmpty else { return }

        let text = directTextBuffer
        directTextBuffer = ""
        enqueueDirectRequest(.directText(text))
    }

    private func enqueueDirectRequest(_ request: PaneStreamRequest) {
        guard let socket = webSocketTask, isStreamConnected else {
            showDirectInputError(String(localized: "Reconnecting. Please wait before typing."))
            return
        }
        let previous = directSendTail
        let connection = connectionID
        directSendTail = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled,
                  self.connectionID == connection, self.webSocketTask === socket else { return }
            do {
                try await self.sendStreamMessage(request, over: socket)
            } catch {
                guard self.webSocketTask === socket else { return }
                self.disconnect(socket)
                self.showDirectInputError(String(localized: "Disconnected. Check whether your last input was received."))
            }
        }
    }

    private func showDirectInputError(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func sendStreamMessage(
        _ request: PaneStreamRequest,
        over socket: any PaneStreamSocket
    ) async throws {
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError(
                NSError(domain: "PaneStream", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Failed to encode pane stream message")
                ])
            )
        }
        try await socket.send(.string(text))
    }

    private func applyOutput(_ newRawOutput: String) async {
        rawOutput = newRawOutput
        let generation = streamGeneration

        async let parsedOutput = Task.detached(priority: .userInitiated) {
            SendableAttributedString(
                value: TerminalTextRenderer.render(newRawOutput)
            )
        }.value

        async let detectedAction = Task.detached(priority: .utility) {
            Self.detectQuickAction(from: newRawOutput)
        }.value

        let (newOutput, newAction) = await (parsedOutput, detectedAction)
        guard generation == streamGeneration, rawOutput == newRawOutput else { return }
        output = newOutput.value
        quickAction = newAction
        contentVersion = UUID()
    }

    private func applyPatch(_ response: PaneStreamResponse) async {
        guard let startLine = response.startLine,
              let deleteCount = response.deleteCount,
              let replacementLines = response.lines else {
            return
        }

        var lines = rawOutput.components(separatedBy: "\n")
        guard startLine >= 0,
              deleteCount >= 0,
              startLine <= lines.count,
              startLine + deleteCount <= lines.count else {
            await resumeAutoRefresh()
            return
        }

        lines.replaceSubrange(
            startLine..<(startLine + deleteCount),
            with: replacementLines
        )
        await applyOutput(lines.joined(separator: "\n"))
    }
}

#Preview {
    NavigationStack {
        PaneDetailView(
            pane: Pane(index: 0, active: true, target: "test:0.0", currentPath: "/Users/test"),
            windowName: "bash"
        )
    }
}
