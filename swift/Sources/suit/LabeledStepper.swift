import Cocoa

// A stepper with its value label, the fontSizeStepper pattern factored out
// for the Autopilot section's many numeric settings.
final class LabeledStepper {
    let valueLabel = NSTextField(labelWithString: "")
    let stepper = NSStepper(frame: NSRect(x: 0, y: 0, width: 19, height: 27))
    private let suffix: String

    init(min: Double, max: Double, suffix: String) {
        self.suffix = suffix
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = 1
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.textColor = Theme.textPrimary
    }

    var intValue: Int {
        get { Int(stepper.doubleValue) }
        set {
            stepper.doubleValue = Double(newValue)
            refreshLabel()
        }
    }

    func refreshLabel() {
        valueLabel.stringValue = "\(Int(stepper.doubleValue))\(suffix)"
    }

    var isEnabled: Bool {
        get { stepper.isEnabled }
        set {
            stepper.isEnabled = newValue
            valueLabel.textColor = newValue ? Theme.textPrimary : Theme.textFaint
        }
    }

    var views: [NSView] { [valueLabel, stepper] }
}
