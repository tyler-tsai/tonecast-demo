import UIKit

/// Hero circular mic button. Combines the mic icon, recording state
/// indicator, and radial waveform into one focal element.
///
/// Sizing:
///   - Outer hit area: 140x140
///   - Inner disc: 100pt diameter
///   - Icon: 40pt SF Symbol
///
/// States:
///   - .idle       — slate disc, faint breathing animation
///   - .recording  — red disc, stronger pulse, 24 radial waveform bars
///   - .processing — gray disc, no animation
final class CircularMicButton: UIControl {

    enum Mode { case idle, recording, processing }

    // Layout
    private let barCount = 24
    private let buttonRadius: CGFloat = 50          // half of 100pt visible disc
    private let barInnerInset: CGFloat = 8           // gap between disc edge and bars
    private let barOuterMax: CGFloat = 18            // longest bar length
    private let barWidth: CGFloat = 3

    // State
    private var amplitudeHistory: [Float]

    // Layers
    private let discLayer = CAShapeLayer()
    private let iconLayer = CALayer()

    // Colors (resolved dynamically so they adapt to dark mode where
    // appropriate). Deep indigo for idle gives the button real presence
    // without the alarm-red intensity of the recording state — distinctive
    // enough to read as a brand color, calm enough to not feel like an
    // emergency button when it's just waiting for input.
    private var idleDiscColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.49, green: 0.46, blue: 0.74, alpha: 1.0)  // brighter indigo for dark
                : UIColor(red: 0.34, green: 0.30, blue: 0.62, alpha: 1.0)  // deep indigo for light
        }
    }
    private let recordingDiscColor = UIColor(red: 0.92, green: 0.27, blue: 0.27, alpha: 1.0)
    private let processingDiscColor = UIColor.systemGray3
    private let barColor = UIColor(red: 0.95, green: 0.35, blue: 0.35, alpha: 1.0)

    var mode: Mode = .idle {
        didSet {
            guard oldValue != mode else { return }
            applyMode()
        }
    }

    override init(frame: CGRect) {
        self.amplitudeHistory = Array(repeating: 0, count: barCount)
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(discLayer)
        layer.addSublayer(iconLayer)
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 140, height: 140)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let discRect = CGRect(x: center.x - buttonRadius,
                              y: center.y - buttonRadius,
                              width: buttonRadius * 2,
                              height: buttonRadius * 2)
        discLayer.path = UIBezierPath(ovalIn: discRect).cgPath

        // Subtle inner shadow for depth — a 2pt inset stroke that fades
        // gives the disc a tactile feel.
        discLayer.shadowColor = UIColor.black.cgColor
        discLayer.shadowOpacity = 0.18
        discLayer.shadowOffset = CGSize(width: 0, height: 2)
        discLayer.shadowRadius = 6

        let iconSize: CGFloat = 44
        iconLayer.frame = CGRect(x: center.x - iconSize / 2,
                                 y: center.y - iconSize / 2,
                                 width: iconSize,
                                 height: iconSize)
        iconLayer.contentsGravity = .resizeAspect
        setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Refresh dynamic disc color on light/dark switch
        if mode == .idle {
            discLayer.fillColor = idleDiscColor.resolvedColor(with: traitCollection).cgColor
        }
    }

    /// Push a new amplitude sample (0…1). Shifts the history buffer left
    /// and triggers a redraw.
    func pushAmplitude(_ amp: Float) {
        amplitudeHistory.removeFirst()
        amplitudeHistory.append(max(0, min(1, amp)))
        setNeedsDisplay()
    }

    private func applyMode() {
        switch mode {
        case .idle:
            discLayer.fillColor = idleDiscColor.resolvedColor(with: traitCollection).cgColor
            setIconSymbol("mic.fill", weight: .medium)
            removeAllAnimations()
            startBreathing()
            amplitudeHistory = Array(repeating: 0, count: barCount)

        case .recording:
            discLayer.fillColor = recordingDiscColor.cgColor
            setIconSymbol("stop.fill", weight: .semibold)
            removeAllAnimations()
            startRecordingPulse()

        case .processing:
            discLayer.fillColor = processingDiscColor.cgColor
            setIconSymbol("waveform", weight: .medium)
            removeAllAnimations()
            startProcessingPulse()
        }
        setNeedsDisplay()
    }

    private func setIconSymbol(_ name: String, weight: UIImage.SymbolWeight) {
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: weight)
        let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        iconLayer.contents = image?.cgImage
        iconLayer.contentsScale = image?.scale ?? UIScreen.main.scale
    }

    private func startBreathing() {
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1.0
        breathe.toValue = 1.015
        breathe.duration = 2.4
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        discLayer.add(breathe, forKey: "breathe")
    }

    private func startRecordingPulse() {
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.05
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        discLayer.add(pulse, forKey: "pulse")
    }

    private func startProcessingPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.85
        pulse.toValue = 0.55
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        discLayer.add(pulse, forKey: "processing")
    }

    private func removeAllAnimations() {
        discLayer.removeAllAnimations()
    }

    override func draw(_ rect: CGRect) {
        guard mode == .recording else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = buttonRadius + barInnerInset

        for i in 0..<barCount {
            let angle = (CGFloat(i) / CGFloat(barCount)) * 2 * .pi - .pi / 2  // start at top
            let amp = CGFloat(amplitudeHistory[i])

            // Even silence shows a small tick so the ring is always visible
            let length = 3 + amp * barOuterMax

            // Slight gradient feel via alpha — newer samples (top, going right)
            // are slightly more opaque
            let alpha: CGFloat = 0.65 + 0.35 * amp

            let inner = CGPoint(x: center.x + cos(angle) * baseRadius,
                                y: center.y + sin(angle) * baseRadius)
            let outer = CGPoint(x: center.x + cos(angle) * (baseRadius + length),
                                y: center.y + sin(angle) * (baseRadius + length))

            ctx.setStrokeColor(barColor.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(barWidth)
            ctx.setLineCap(.round)
            ctx.move(to: inner)
            ctx.addLine(to: outer)
            ctx.strokePath()
        }
    }
}
