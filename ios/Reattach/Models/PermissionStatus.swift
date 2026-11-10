import Foundation
import Observation

struct PermissionAttention: Decodable, Equatable, Identifiable {
    let target: String
    let tool: String
    let receivedAt: Int64
    var id: String { target }
    enum CodingKeys: String, CodingKey {
        case target, tool
        case receivedAt = "received_at"
    }
}

@MainActor
@Observable
class PermissionStatus {
    static let shared = PermissionStatus()

    static var usesUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-permission-ui-fixture")
        #else
        false
        #endif
    }

    static var uiTestEntries: [PermissionAttention] {
        guard usesUITestFixture else { return [] }
        return [
            PermissionAttention(target: "myproject:0.0", tool: "Bash", receivedAt: 1),
            PermissionAttention(target: "claude-demo:0.0", tool: "Edit", receivedAt: 2)
        ]
    }
    private(set) var entries: [PermissionAttention] = []
    private var serverID: String?

    func reset(serverID: String?) {
        self.serverID = serverID
        entries = []
    }

    func update(_ entries: [PermissionAttention], serverID: String?) {
        guard self.serverID == serverID else { return }
        self.entries = entries
    }

    func isWaiting(_ target: String) -> Bool {
        entries.contains { $0.target == target }
    }
}

/// Only offer numbered choices actually shown by a terminal selection menu.
struct PermissionChoice: Equatable, Identifiable {
    let number: String
    let label: String
    let selected: Bool
    var id: String { number }

    static func parse(_ output: String) -> [Self] {
        let text = TerminalTextRenderer.render(output).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^\s*([❯›>▶▸])?\s*([1-9][0-9]*)[.)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var groups: [[Self]] = []
        var current: [Self] = []
        for line in text.components(separatedBy: .newlines).suffix(80) {
            if line.trimmingCharacters(in: .whitespaces) == "Press enter to confirm or esc to cancel" {
                break
            }
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let numberRange = Range(match.range(at: 2), in: line),
               let labelRange = Range(match.range(at: 3), in: line) {
                let number = String(line[numberRange])
                if number == "1", !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                current.append(Self(number: number,
                                    label: String(line[labelRange]).trimmingCharacters(in: .whitespaces),
                                    selected: match.range(at: 1).location != NSNotFound))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !current.isEmpty {
                if line.hasPrefix("  "), let previous = current.popLast() {
                    current.append(Self(number: previous.number,
                                        label: previous.label + " " + line.trimmingCharacters(in: .whitespaces),
                                        selected: previous.selected))
                } else {
                    groups.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty { groups.append(current) }
        guard let choices = groups.last, choices.count >= 2,
              choices.filter(\.selected).count == 1,
              choices.enumerated().allSatisfy({ $0.element.number == String($0.offset + 1) }) else {
            return []
        }
        return choices
    }
}

/// Preserve the current request on inserts; advance to its neighbor on removal.
enum PermissionPaging {
    static func swipeStep(translation: CGFloat, predicted: CGFloat, height: CGFloat) -> Int {
        guard height > 0, abs(translation) >= 20 else { return 0 }
        let committed = abs(translation) > min(height * 0.14, 90)
            || (abs(predicted) > height * 0.35 && translation * predicted > 0)
        guard committed else { return 0 }
        return translation < 0 ? 1 : -1
    }

    static func selection(current: String?, old: [String], new: [String]) -> String? {
        guard !new.isEmpty else { return nil }
        if let current, new.contains(current) { return current }
        let index = current.flatMap { old.firstIndex(of: $0) } ?? 0
        return new[min(index, new.count - 1)]
    }
}
