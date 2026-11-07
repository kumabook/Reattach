import SwiftUI

// Geometry is in tmux character cells, including the one-cell pane separators.
// Older daemons omit it; their panes continue to use the single-pane view.
enum WindowLayout {
    static func frames(for window: Window, in size: CGSize) -> [String: CGRect]? {
        guard let width = window.width, let height = window.height,
              width > 0, height > 0, !window.panes.isEmpty else { return nil }
        if window.zoomed == true {
            guard let active = window.panes.first(where: \.active) else { return nil }
            return [active.target: CGRect(origin: .zero, size: size)]
        }
        var frames: [String: CGRect] = [:]
        for pane in window.panes {
            guard let g = pane.geometry, g.left >= 0, g.top >= 0, g.width > 0, g.height > 0,
                  g.left <= width, g.top <= height,
                  g.width <= width - g.left, g.height <= height - g.top else { return nil }
            let rect = CGRect(x: CGFloat(g.left) / CGFloat(width) * size.width,
                              y: CGFloat(g.top) / CGFloat(height) * size.height,
                              width: CGFloat(g.width) / CGFloat(width) * size.width,
                              height: CGFloat(g.height) / CGFloat(height) * size.height)
            guard !frames.values.contains(where: { $0.intersects(rect) }) else { return nil }
            frames[pane.target] = rect
        }
        return frames
    }
}

// Support literal colours first; tmux format expressions and style attributes
// fall back as a whole rather than being partially misinterpreted.
struct PaneBorderStyle {
    var foreground: UIColor?
    var background: UIColor?

    static func parse(_ value: String?) -> Self? {
        guard let value, !value.isEmpty else { return nil }
        var style = Self()
        for token in value.split(separator: ",", omittingEmptySubsequences: false) {
            if token == "default" { style = Self(); continue }
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == "fg" || pair[0] == "bg" else { return nil }
            let color: UIColor?
            if pair[1] == "default" { color = nil }
            else {
                guard let parsed = parseColor(String(pair[1])) else { return nil }
                color = parsed
            }
            if pair[0] == "fg" { style.foreground = color }
            else { style.background = color }
        }
        return style
    }

    static func parseColor(_ value: String) -> UIColor? {
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                     "brightblack", "brightred", "brightgreen", "brightyellow", "brightblue", "brightmagenta", "brightcyan", "brightwhite"]
        if let index = names.firstIndex(of: value) { return TerminalTextRenderer.palette(index) }
        if value.hasPrefix("colour"), let index = Int(value.dropFirst(6)), (0...255).contains(index) {
            return TerminalTextRenderer.palette(index)
        }
        if value.count == 7, value.first == "#", let rgb = UInt32(value.dropFirst(), radix: 16) {
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        return nil
    }

    static func usesHalfBorder(_ window: Window) -> Bool {
        guard window.panes.count == 2 else { return false }
        switch window.borders?.indicators {
        case "off", "arrows": return false
        default: return true
        }
    }
}

struct WindowLayoutView<SelectedContent: View>: View {
    let window: Window
    let selectedTarget: String
    let autoRefresh: Bool
    let selectionEnabled: Bool
    let onSelect: (Pane) -> Void
    @ViewBuilder let selectedContent: () -> SelectedContent

    var body: some View {
        GeometryReader { geometry in
            let frames = WindowLayout.frames(for: window, in: geometry.size) ?? [:]
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                ForEach(window.panes) { pane in
                    if let frame = frames[pane.target] {
                        let selected = pane.target == selectedTarget
                        VStack(spacing: 0) {
                            if selected {
                                selectedContent()
                            } else {
                                PaneLayoutPreview(pane: pane, autoRefresh: autoRefresh)
                                    .simultaneousGesture(TapGesture().onEnded {
                                        if selectionEnabled { onSelect(pane) }
                                    })
                            }
                        }
                        .background(Color(uiColor: .systemBackground))
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(String(localized: "Pane \(pane.index)"))
                        .accessibilityIdentifier("layoutPane-\(pane.target)")
                        .accessibilityValue(selected ? String(localized: "Selected") : "")
                        .accessibilityAction {
                            if selectionEnabled && !selected { onSelect(pane) }
                        }
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .overlay {
                Canvas { context, size in
                    let panes = window.panes
                    let normalStyle = PaneBorderStyle.parse(window.borders?.style)
                    let activeStyle = PaneBorderStyle.parse(window.borders?.activeStyle)
                    for i in panes.indices {
                        for j in panes.indices where j > i {
                            guard let a = frames[panes[i].target], let b = frames[panes[j].target] else { continue }
                            let gapX = size.width / CGFloat(max(1, window.width ?? 1))
                            let gapY = size.height / CGFloat(max(1, window.height ?? 1))
                            let leftIndex = a.minX < b.minX ? i : j
                            let rightIndex = leftIndex == i ? j : i
                            let topIndex = a.minY < b.minY ? i : j
                            let bottomIndex = topIndex == i ? j : i
                            let left = leftIndex == i ? a : b
                            let right = rightIndex == i ? a : b
                            let top = topIndex == i ? a : b
                            let bottom = bottomIndex == i ? a : b
                            var start: CGPoint
                            var end: CGPoint
                            let firstTarget: String
                            let secondTarget: String
                            if abs(right.minX - left.maxX - gapX) < 0.5,
                               min(a.maxY, b.maxY) > max(a.minY, b.minY) {
                                let x = (left.maxX + right.minX) / 2
                                start = CGPoint(x: x, y: max(a.minY, b.minY) - gapY / 2)
                                end = CGPoint(x: x, y: min(a.maxY, b.maxY) + gapY / 2)
                                firstTarget = panes[leftIndex].target
                                secondTarget = panes[rightIndex].target
                            } else if abs(bottom.minY - top.maxY - gapY) < 0.5,
                                      min(a.maxX, b.maxX) > max(a.minX, b.minX) {
                                let y = (top.maxY + bottom.minY) / 2
                                start = CGPoint(x: max(a.minX, b.minX) - gapX / 2, y: y)
                                end = CGPoint(x: min(a.maxX, b.maxX) + gapX / 2, y: y)
                                firstTarget = panes[topIndex].target
                                secondTarget = panes[bottomIndex].target
                            } else { continue }
                            var separator = Path()
                            separator.move(to: start)
                            separator.addLine(to: end)
                            if let background = normalStyle?.background {
                                context.stroke(separator, with: .color(Color(uiColor: background)), lineWidth: 3)
                            }
                            context.stroke(separator, with: .color(Color(uiColor: normalStyle?.foreground ?? .separator)), lineWidth: 0.5)
                            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                            guard selectedTarget == firstTarget || selectedTarget == secondTarget else { continue }
                            if PaneBorderStyle.usesHalfBorder(window) {
                                if selectedTarget == firstTarget { end = middle }
                                else { start = middle }
                            }
                            var activeSegment = Path()
                            activeSegment.move(to: start)
                            activeSegment.addLine(to: end)
                            if let background = activeStyle?.background {
                                context.stroke(activeSegment, with: .color(Color(uiColor: background)), lineWidth: 3)
                            }
                            context.stroke(activeSegment, with: .color(activeStyle?.foreground.map { Color(uiColor: $0) } ?? Color.accentColor), lineWidth: 1)

                        }
                    }
                }
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct PaneLayoutPreview: View {
    @Environment(\.scenePhase) private var scenePhase
    let pane: Pane
    let autoRefresh: Bool
    @State private var output = NSAttributedString()
    @State private var version = UUID()
    @State private var failed = false
    @State private var scrollToBottom = false

    var body: some View {
        ZoomableTextView(attributedText: output, contentVersion: version,
                         cursor: PaneCursorState(x: 0, rowFromBottom: 0,
                                               paneWidth: pane.geometry?.width ?? 80, visible: false),
                         scrollToBottom: $scrollToBottom)
            .overlay(alignment: .topLeading) {
                if failed {
                    Text(String(localized: "Reconnecting…"))
                        .font(.caption).foregroundStyle(.red)
                        .padding(6).background(.regularMaterial)
                        .allowsHitTesting(false)
                }
            }
            .task(id: "\(pane.target)|\(scenePhase == .active)|\(autoRefresh)|\(pane.geometry?.height ?? 0)") {
                guard scenePhase == .active else { return }
                repeat {
                    do {
                        let text = try await ReattachAPI.shared.getOutput(target: pane.target, lines: 0)
                        guard !Task.isCancelled else { return }
                        // Previews show the visible pane, rather than the full scrollback.
                        let visible = text.hasSuffix("\n") ? String(text.dropLast()) : text
                        let rendered = TerminalTextRenderer.render(visible)
                        if !output.isEqual(to: rendered) { output = rendered; version = UUID() }
                        failed = false
                    } catch {
                        guard !Task.isCancelled else { return }
                        failed = true
                    }
                    guard autoRefresh else { return }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                } while !Task.isCancelled
            }
    }
}
