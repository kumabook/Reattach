import UIKit

// Preserve tmux's SGR styles and OSC 8 hyperlinks, then detect plain URLs.
enum TerminalTextRenderer {
    nonisolated static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var foreground: UIColor = .label
        var usesDefaultForeground = true
        var background: UIColor?
        var bold = false
        var dim = false
        var reverse = false
        var link: URL?
        let pattern = "\u{1B}\\[([0-9;]*)m|\u{1B}\\]8;[^;]*;([^\u{1B}\u{7}]*)(?:\u{7}|\u{1B}\\\\)"
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        var offset = 0
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            let effectiveForeground = usesDefaultForeground
                ? background.map { contrastingText(on: $0) } ?? foreground
                : foreground
            let fg = reverse ? (background ?? .systemBackground) : effectiveForeground
            let bg = reverse ? effectiveForeground : background
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: dim ? fg.withAlphaComponent(0.6) : fg,
                .font: UIFont.monospacedSystemFont(ofSize: 8, weight: bold ? .bold : .regular)
            ]
            if let bg { attrs[.backgroundColor] = bg }
            if let link { attrs[.link] = link }
            result.append(NSAttributedString(string: source.substring(with: range), attributes: attrs))
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            append(NSRange(location: offset, length: match.range.location - offset))
            offset = NSMaxRange(match.range)
            if match.range(at: 2).location != NSNotFound {
                link = allowedURL(source.substring(with: match.range(at: 2)))
                continue
            }
            let codes = source.substring(with: match.range(at: 1)).components(separatedBy: ";").map { Int($0) ?? 0 }
            var i = 0
            while i < codes.count {
                let code = codes[i]
                switch code {
                case 0: foreground = .label; usesDefaultForeground = true; background = nil; bold = false; dim = false; reverse = false
                case 1: bold = true
                case 2: dim = true
                case 7: reverse = true
                case 22: bold = false; dim = false
                case 27: reverse = false
                case 30...37: foreground = palette(code - 30); usesDefaultForeground = false
                case 40...47: background = palette(code - 40)
                case 90...97: foreground = palette(code - 90 + 8); usesDefaultForeground = false
                case 100...107: background = palette(code - 100 + 8)
                case 39: foreground = .label; usesDefaultForeground = true
                case 49: background = nil
                case 38, 48:
                    var color: UIColor?
                    if i + 2 < codes.count, codes[i + 1] == 5 {
                        color = palette(codes[i + 2]); i += 2
                    } else if i + 4 < codes.count, codes[i + 1] == 2 {
                        color = UIColor(red: component(codes[i + 2]), green: component(codes[i + 3]), blue: component(codes[i + 4]), alpha: 1)
                        i += 4
                    }
                    if let color {
                        if code == 38 { foreground = color; usesDefaultForeground = false } else { background = color }
                    }
                default: break
                }
                i += 1
            }
        }
        append(NSRange(location: offset, length: source.length - offset))
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: result.length)
        for match in detector.matches(in: result.string, range: range) {
            guard let url = match.url, let safeURL = allowedURL(url.absoluteString),
                  result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            result.addAttribute(.link, value: safeURL, range: match.range)
        }
        return result
    }

    // Default text must remain legible on an explicit SGR background in either
    // appearance. Explicit foreground colours and the background are preserved.
    nonisolated private static func contrastingText(on background: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = background.resolvedColor(with: traits)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return UIColor.label.resolvedColor(with: traits)
            }
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            let whiteContrast = 1.05 / (luminance + 0.05)
            let blackContrast = (luminance + 0.05) / 0.05
            return whiteContrast > blackContrast ? .white : .black
        }
    }

    nonisolated private static func allowedURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    nonisolated private static func component(_ value: Int) -> CGFloat { CGFloat(min(255, max(0, value))) / 255 }

    nonisolated static func palette(_ index: Int) -> UIColor {
        let standard: [UIColor] = [.black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan, .lightGray,
                                   .gray, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemCyan, .white]
        if (0..<16).contains(index) { return standard[index] }
        if (16..<232).contains(index) {
            let n = index - 16
            let values = [0, 95, 135, 175, 215, 255]
            return UIColor(red: component(values[n / 36]), green: component(values[(n / 6) % 6]), blue: component(values[n % 6]), alpha: 1)
        }
        let gray = component(8 + (min(255, max(232, index)) - 232) * 10)
        return UIColor(white: gray, alpha: 1)
    }
}
