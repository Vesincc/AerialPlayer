import AppKit

@MainActor
final class PlaybackSpeedControl: NSView {
    private final class SpeedSlider: NSSlider {
        private(set) var isTrackingMouse = false

        override func mouseDown(with event: NSEvent) {
            isTrackingMouse = true
            defer { isTrackingMouse = false }
            super.mouseDown(with: event)
        }
    }

    private let slider: SpeedSlider
    private let valueLabel = NSTextField(labelWithString: "")
    var onRateChange: ((Float) -> Void)?

    init(rate: Float, range: ClosedRange<Float>) {
        slider = SpeedSlider(value: Double(rate), minValue: Double(range.lowerBound),
                             maxValue: Double(range.upperBound), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 64))
        autoresizingMask = [.width]

        let title = NSTextField(labelWithString: "播放速度")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 30, y: 40, width: 90, height: 18)
        addSubview(title)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 162, y: 40, width: 54, height: 18)
        valueLabel.autoresizingMask = [.minXMargin]
        addSubview(valueLabel)

        slider.target = self
        slider.action = #selector(changeRate)
        slider.controlSize = .small
        slider.frame = NSRect(x: 30, y: 10, width: 234, height: 20)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.setAccessibilityLabel("播放速度")
        addSubview(slider)

        let reset = NSButton(title: "1×", target: self, action: #selector(resetRate))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: 224, y: 36, width: 40, height: 24)
        reset.autoresizingMask = [.minXMargin]
        reset.toolTip = "恢复正常播放速度"
        addSubview(reset)
        update(rate: rate)
    }

    required init?(coder: NSCoder) { return nil }

    func update(rate: Float) {
        // AppKit owns the knob position throughout native mouse tracking.
        if !slider.isTrackingMouse, slider.doubleValue != Double(rate) {
            slider.doubleValue = Double(rate)
        }
        valueLabel.stringValue = String(format: "%.2f×", Double(rate))
    }

    @objc private func changeRate() {
        let rate = Float((slider.doubleValue * 100).rounded() / 100)
        onRateChange?(rate)
        update(rate: rate)
    }

    @objc private func resetRate() {
        onRateChange?(1)
        update(rate: 1)
    }
}
