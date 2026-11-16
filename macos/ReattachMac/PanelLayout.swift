import Foundation

struct PanelLayout {
    var width: Double
    var height: Double
    var horizontal: Double
    var vertical: Double

    init(defaults: UserDefaults = .standard) {
        let preset = defaults.object(forKey: "panelSizeFraction") as? Double ?? 0.94
        width = defaults.object(forKey: "panelWidthFraction") as? Double ?? preset
        height = defaults.object(forKey: "panelHeightFraction") as? Double ?? preset
        horizontal = defaults.object(forKey: "panelHorizontalPosition") as? Double ?? 0.5
        vertical = defaults.object(forKey: "panelVerticalPosition") as? Double ?? 0.5
    }

    init(frame: CGRect, in visible: CGRect, defaults: UserDefaults = .standard) {
        self.init(defaults: defaults)
        guard visible.width > 0, visible.height > 0 else { return }
        width = min(1, max(0.01, frame.width / visible.width))
        height = min(1, max(0.01, frame.height / visible.height))
        let horizontalTravel = visible.width - frame.width
        let verticalTravel = visible.height - frame.height
        if horizontalTravel > 0 {
            horizontal = min(1, max(0, (frame.minX - visible.minX) / horizontalTravel))
        }
        if verticalTravel > 0 {
            vertical = min(1, max(0, (visible.maxY - frame.maxY) / verticalTravel))
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(width, forKey: "panelWidthFraction")
        defaults.set(height, forKey: "panelHeightFraction")
        defaults.set(horizontal, forKey: "panelHorizontalPosition")
        defaults.set(vertical, forKey: "panelVerticalPosition")
    }

    func frame(in visible: CGRect) -> CGRect {
        let w = min(visible.width, max(460, visible.width * min(1, max(0.01, width))))
        let h = min(visible.height, max(520, visible.height * min(1, max(0.01, height))))
        return CGRect(x: visible.minX + (visible.width - w) * min(1, max(0, horizontal)),
                      y: visible.maxY - h - (visible.height - h) * min(1, max(0, vertical)),
                      width: w, height: h)
    }
}
