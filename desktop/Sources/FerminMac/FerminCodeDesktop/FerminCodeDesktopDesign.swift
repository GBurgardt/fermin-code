import AppKit
import SwiftUI

enum FerminCodeDesktopPalette {
    static let canvas = color(0x040507)
    static let canvasTop = color(0x0B0D11)
    static let sidebar = color(0x040507)
    static let surface = color(0x0B0D11)
    static let inset = color(0x08090D)
    static let raised = color(0x101319)
    static let selected = color(0x111520)
    static let pressed = color(0x1A1E26)
    static let composer = inset
    static let primary = color(0xFAFBFD)
    static let secondary = color(0xC9CED9)
    static let muted = color(0xA2A9B7)
    static let tertiary = color(0x7E8593)
    static let separator = Color.white.opacity(0.045)
    static let topLight = Color.white.opacity(0.045)
    static let topLightStrong = Color.white.opacity(0.085)
    static let accent = color(0x6068E9)
    static let accentPress = color(0x4F58D2)
    static let accentSoft = accent.opacity(0.16)
    static let positive = color(0x58DF94)
    static let warning = color(0xFFB040)
    static let danger = color(0xFF6E66)
    static let userSurface = color(0x4F58D2)
    static let codeSurface = color(0x0C0E13)
    static let bevel = FerminCodeDesktopMetrics.cornerRadius

    static var background: LinearGradient {
        LinearGradient(
            colors: [canvas, canvas],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum FerminCodeDesktopMetrics {
    static let cornerRadius: CGFloat = 5
    static let controlHeight: CGFloat = 30
    static let compactControlHeight: CGFloat = 26
    static let iconControlSize: CGFloat = 30
    static let sidebarWidth: CGFloat = 272
    static let appHeaderHeight: CGFloat = 48
    static let contentGutter: CGFloat = 22
    static let transcriptMaxWidth: CGFloat = 820
    static let sidebarRowGap: CGFloat = 2
    static let messageRowInset: CGFloat = 7
}

enum FerminCodeDesktopNativeTextEditorAppearance {
    static let textColor = NSColor(
        srgbRed: 250.0 / 255.0,
        green: 251.0 / 255.0,
        blue: 253.0 / 255.0,
        alpha: 1
    )
    static let backgroundColor = NSColor(
        srgbRed: 8.0 / 255.0,
        green: 9.0 / 255.0,
        blue: 13.0 / 255.0,
        alpha: 1
    )

    @discardableResult
    static func apply(
        to textView: NSTextView,
        textColor: NSColor = FerminCodeDesktopNativeTextEditorAppearance.textColor,
        backgroundColor: NSColor = FerminCodeDesktopNativeTextEditorAppearance.backgroundColor
    ) -> Bool {
        var changed = false
        if !colorsMatch(textView.textColor, textColor) {
            textView.textColor = textColor
            changed = true
        }
        if !textView.drawsBackground {
            textView.drawsBackground = true
            changed = true
        }
        if !colorsMatch(textView.backgroundColor, backgroundColor) {
            textView.backgroundColor = backgroundColor
            changed = true
        }

        guard let scrollView = textView.enclosingScrollView else { return changed }
        if !scrollView.drawsBackground {
            scrollView.drawsBackground = true
            changed = true
        }
        if !colorsMatch(scrollView.backgroundColor, backgroundColor) {
            scrollView.backgroundColor = backgroundColor
            changed = true
        }
        if !scrollView.contentView.drawsBackground {
            scrollView.contentView.drawsBackground = true
            changed = true
        }
        if !colorsMatch(scrollView.contentView.backgroundColor, backgroundColor) {
            scrollView.contentView.backgroundColor = backgroundColor
            changed = true
        }
        return changed
    }

    static func colorsMatch(_ actual: NSColor?, _ expected: NSColor) -> Bool {
        guard
            let actual = actual?.usingColorSpace(.sRGB),
            let expected = expected.usingColorSpace(.sRGB)
        else {
            return actual?.isEqual(expected) == true
        }
        let tolerance: CGFloat = 0.000_5
        return abs(actual.redComponent - expected.redComponent) <= tolerance
            && abs(actual.greenComponent - expected.greenComponent) <= tolerance
            && abs(actual.blueComponent - expected.blueComponent) <= tolerance
            && abs(actual.alphaComponent - expected.alphaComponent) <= tolerance
    }
}

private struct FerminCodeDesktopTextEditorAppearanceBridge: NSViewRepresentable {
    let textColor: NSColor
    let backgroundColor: NSColor

    func makeNSView(context: Context) -> FerminCodeDesktopTextEditorAppearanceProbe {
        let view = FerminCodeDesktopTextEditorAppearanceProbe()
        view.updateAppearance(textColor: textColor, backgroundColor: backgroundColor)
        return view
    }

    func updateNSView(
        _ view: FerminCodeDesktopTextEditorAppearanceProbe,
        context: Context
    ) {
        view.updateAppearance(textColor: textColor, backgroundColor: backgroundColor)
    }

    static func dismantleNSView(
        _ view: FerminCodeDesktopTextEditorAppearanceProbe,
        coordinator: Void
    ) {
        view.invalidatePendingUpdates()
    }
}

private final class FerminCodeDesktopTextEditorAppearanceProbe: NSView {
    private var updateIsScheduled = false
    private var remainingAttempts = 0
    private var updateGeneration: UInt = 0
    private weak var styledTextView: NSTextView?
    private var textColor = FerminCodeDesktopNativeTextEditorAppearance.textColor
    private var backgroundColor = FerminCodeDesktopNativeTextEditorAppearance.backgroundColor

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            invalidatePendingUpdates()
        } else {
            scheduleAppearanceUpdate()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            invalidatePendingUpdates()
        } else {
            scheduleAppearanceUpdate()
        }
    }

    func updateAppearance(textColor: NSColor, backgroundColor: NSColor) {
        let colorsChanged = !FerminCodeDesktopNativeTextEditorAppearance.colorsMatch(
            self.textColor,
            textColor
        ) || !FerminCodeDesktopNativeTextEditorAppearance.colorsMatch(
            self.backgroundColor,
            backgroundColor
        )
        self.textColor = textColor
        self.backgroundColor = backgroundColor

        guard superview != nil else { return }
        if let styledTextView {
            if styledTextView.window === window, overlapArea(with: styledTextView) > 0 {
                FerminCodeDesktopNativeTextEditorAppearance.apply(
                    to: styledTextView,
                    textColor: textColor,
                    backgroundColor: backgroundColor
                )
                return
            }
            self.styledTextView = nil
        }
        guard colorsChanged || styledTextView == nil else { return }
        scheduleAppearanceUpdate()
    }

    func invalidatePendingUpdates() {
        updateGeneration &+= 1
        remainingAttempts = 0
        styledTextView = nil
    }

    private func scheduleAppearanceUpdate() {
        updateGeneration &+= 1
        remainingAttempts = 3
        scheduleNextAttemptIfNeeded()
    }

    private func scheduleNextAttemptIfNeeded() {
        guard !updateIsScheduled, remainingAttempts > 0 else { return }
        updateIsScheduled = true
        let scheduledGeneration = updateGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateIsScheduled = false
            guard self.superview != nil else { return }
            guard scheduledGeneration == self.updateGeneration else {
                self.scheduleNextAttemptIfNeeded()
                return
            }
            self.remainingAttempts -= 1
            if let textView = self.closestTextView() {
                FerminCodeDesktopNativeTextEditorAppearance.apply(
                    to: textView,
                    textColor: self.textColor,
                    backgroundColor: self.backgroundColor
                )
                self.styledTextView = textView
                self.remainingAttempts = 0
            } else {
                self.scheduleNextAttemptIfNeeded()
            }
        }
    }

    private func closestTextView() -> NSTextView? {
        var ancestor = superview
        var inspectedLevels = 0
        while let candidate = ancestor, inspectedLevels < 10 {
            let textViews = textViewsOverlappingProbe(in: candidate)
            if !textViews.isEmpty {
                return textViews.max { overlapArea(with: $0) < overlapArea(with: $1) }
            }
            if candidate === window?.contentView { break }
            ancestor = candidate.superview
            inspectedLevels += 1
        }
        return nil
    }

    private func textViewsOverlappingProbe(in root: NSView) -> [NSTextView] {
        allTextViews(in: root).filter { overlapArea(with: $0) > 0 }
    }

    private func allTextViews(in root: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let textView = root as? NSTextView, !textView.isFieldEditor {
            result.append(textView)
        }
        for subview in root.subviews {
            result.append(contentsOf: allTextViews(in: subview))
        }
        return result
    }

    private func overlapArea(with view: NSView) -> CGFloat {
        let overlap = convert(bounds, to: nil).intersection(view.convert(view.bounds, to: nil))
        guard !overlap.isNull else { return 0 }
        return overlap.width * overlap.height
    }
}

extension View {
    func ferminDesktopTextEditorAppearance(
        textColor: NSColor = FerminCodeDesktopNativeTextEditorAppearance.textColor,
        backgroundColor: NSColor = FerminCodeDesktopNativeTextEditorAppearance.backgroundColor
    ) -> some View {
        background(
            FerminCodeDesktopTextEditorAppearanceBridge(
                textColor: textColor,
                backgroundColor: backgroundColor
            )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    func ferminCodeRaisedSurface(
        fill: Color = FerminCodeDesktopPalette.surface,
        radius: CGFloat = FerminCodeDesktopPalette.bevel,
        topLight: Color = FerminCodeDesktopPalette.topLight
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(topLight)
                .frame(height: 0.5)
                .padding(.horizontal, radius)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func ferminCodeInsetSurface(
        fill: Color = FerminCodeDesktopPalette.inset,
        radius: CGFloat = FerminCodeDesktopPalette.bevel
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .shadow(color: Color.black.opacity(0.28), radius: 1, x: 0, y: 1)
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(FerminCodeDesktopPalette.separator.opacity(0.62), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct FerminCodeDesktopButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    init(prominent: Bool = false) {
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(
                isEnabled
                    ? (prominent ? .white : FerminCodeDesktopPalette.primary)
                    : FerminCodeDesktopPalette.muted
            )
            .padding(.horizontal, 11)
            .frame(minHeight: FerminCodeDesktopMetrics.controlHeight)
            .ferminCodeRaisedSurface(
                fill:
                !isEnabled
                    ? FerminCodeDesktopPalette.raised.opacity(0.72)
                    : (prominent
                    ? (configuration.isPressed
                        ? FerminCodeDesktopPalette.accentPress
                        : FerminCodeDesktopPalette.accent)
                    : (configuration.isPressed
                        ? FerminCodeDesktopPalette.pressed
                        : FerminCodeDesktopPalette.raised)),
                topLight: prominent
                    ? FerminCodeDesktopPalette.topLightStrong
                    : FerminCodeDesktopPalette.topLight
            )
            .opacity(isEnabled ? 1 : 0.78)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .contentShape(Rectangle())
    }
}

struct FerminCodeDesktopIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FerminCodeDesktopPalette.primary)
            .frame(
                width: FerminCodeDesktopMetrics.iconControlSize,
                height: FerminCodeDesktopMetrics.iconControlSize
            )
            .ferminCodeRaisedSurface(
                fill: configuration.isPressed
                    ? FerminCodeDesktopPalette.pressed
                    : FerminCodeDesktopPalette.raised
            )
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .contentShape(Rectangle())
    }
}

struct FerminCodeDesktopFeatureButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isActive ? .white : FerminCodeDesktopPalette.secondary)
            .padding(.horizontal, 8)
            .frame(height: FerminCodeDesktopMetrics.compactControlHeight)
            .ferminCodeRaisedSurface(
                fill: isActive
                    ? FerminCodeDesktopPalette.accent
                    : (configuration.isPressed
                        ? FerminCodeDesktopPalette.pressed.opacity(0.72)
                        : Color.clear),
                topLight: isActive
                    ? FerminCodeDesktopPalette.topLightStrong
                    : Color.clear
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.54)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .contentShape(Rectangle())
    }
}

struct FerminCodeDesktopSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .tracking(1)
            .foregroundColor(FerminCodeDesktopPalette.muted)
    }
}

struct FerminCodeDesktopWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view, coordinator: context.coordinator)
    }

    private func configure(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard coordinator.configuredWindow !== window else { return }
            coordinator.configuredWindow = window

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.contentMinSize = NSSize(width: 920, height: 620)
            NSWindow.ButtonType.allCasesForFerminCode.forEach { buttonType in
                window.standardWindowButton(buttonType)?.isHidden = false
            }

            let current = window.contentLayoutRect.size
            if abs(current.width - 920) < 2, abs(current.height - 620) < 2 {
                window.setContentSize(NSSize(width: 1440, height: 900))
                window.center()
            }
        }
    }
}

private extension NSWindow.ButtonType {
    static let allCasesForFerminCode: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton,
    ]
}
