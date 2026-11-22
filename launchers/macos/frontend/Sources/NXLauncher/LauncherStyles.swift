// Derived from NX2Apple (MIT; see frontend/NOTICE).
// S2Arm: shared theme metrics/materials, consistent controls, and keyboard/controller/accessibility actions.
import SwiftUI

package struct LauncherWindowChrome: NSViewRepresentable {
    package init() {}
    package final class ChromeView: NSView {
        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isMovableByWindowBackground = true
        }
    }
    package func makeNSView(context: Context) -> NSView { ChromeView() }
    package func updateNSView(_ nsView: NSView, context: Context) {}
}

/// What a double-click on the title bar does, as System Settings → Desktop & Dock sets it.
package enum TitlebarAction: Equatable {
    case zoom, minimize, none

    /// `AppleActionOnDoubleClick` ("Maximize", "Fill", "Minimize", "None") wins; the older `AppleMiniaturizeOnDoubleClick` bool is read only
    /// without it; with neither, macOS's default (zoom).
    package static func resolve(actionSetting: String?, miniaturizeFlag: Bool?) -> TitlebarAction {
        if let value = actionSetting?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty {
            switch value {
            case "minimize": return .minimize
            case "none", "do nothing", "nothing": return .none
            default: return .zoom   // Maximize, Fill, or a value a later macOS adds
            }
        }
        return miniaturizeFlag == true ? .minimize : .zoom
    }

    package static var current: TitlebarAction {
        let d = UserDefaults.standard   // the global domain is searched too
        return resolve(actionSetting: d.string(forKey: "AppleActionOnDoubleClick"),
                       miniaturizeFlag: d.object(forKey: "AppleMiniaturizeOnDoubleClick") as? Bool)
    }

    package func perform(on window: NSWindow?) {
        switch self {
        case .zoom: window?.zoom(nil)   // fills the screen, traffic lights kept; a second one restores
        case .minimize: window?.miniaturize(nil)
        case .none: break
        }
    }
}

/// Sits behind the top bar. Controls above it keep their clicks; on an empty part a double-click does the title bar's action
/// and a single press drags the window (the view takes the mouse-down, so it starts the drag itself).
package struct TitlebarDoubleClick: NSViewRepresentable {
    package init() {}
    package final class DragView: NSView {
        package override var mouseDownCanMoveWindow: Bool { false }
        package override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { TitlebarAction.current.perform(on: window) }
            else { window?.performDrag(with: event) }
        }
    }
    package func makeNSView(context: Context) -> NSView { DragView() }
    package func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The width of the button or dropdown at the trailing end of a setting row, the same on every page, so that these
/// controls stand in one column whatever their labels. A row hands it to its trailing controls (`launcherRowControls()`),
/// and LauncherSecondaryButtonStyle and LauncherDropdown take it from there. Outside a row they size to their label.
package enum LauncherControl {
    /// A single trailing column; a pair of short actions shares it through LauncherRowActions.
    package static let width: CGFloat = LauncherTheme.Metrics.controlWidth
    /// What the label of a button may take.
    package static let buttonLabelWidth: CGFloat = width - 2 * LauncherTheme.Space.large
    /// Buttons, dropdowns and input fields share one height, independent of label or language.
    package static let height: CGFloat = LauncherTheme.Metrics.controlHeight
    /// A label that is a little too long shrinks to this share of its size before it is cut.
    package static let minimumLabelScale: CGFloat = 0.85
    /// The room a dropdown's choice has beside its chevron and the gap to it.
    package static let choiceWidth: CGFloat = buttonLabelWidth - LauncherTheme.Space.small - 10
}

/// What one button or dropdown in a setting row measured when it was drawn: the width its label wants on a single line, the width
/// it has, and the size of the whole control. Only collected when `measuresLauncherControls` is set (LauncherControlWidthTests
/// renders the real pages in every language with it), so the check covers every control a page shows without a list of labels.
package struct LauncherControlSample: Equatable {
    package init(labelWidth: CGFloat, room: CGFloat, size: CGSize) { self.labelWidth = labelWidth; self.room = room; self.size = size }
    package var labelWidth: CGFloat
    package var room: CGFloat
    package var size: CGSize
}

package struct LauncherControlSamples: PreferenceKey {
    package static var defaultValue: [LauncherControlSample] = []
    package static func reduce(value: inout [LauncherControlSample], nextValue: () -> [LauncherControlSample]) { value += nextValue() }
}

private struct MeasuresLauncherControlsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    package var measuresLauncherControls: Bool {
        get { self[MeasuresLauncherControlsKey.self] }
        set { self[MeasuresLauncherControlsKey.self] = newValue }
    }
}

private struct LauncherControlMeasure<Label: View>: ViewModifier {
    let label: Label
    let room: CGFloat
    @Environment(\.measuresLauncherControls) private var measures
    @Environment(\.launcherControlWidth) private var width
    @ViewBuilder func body(content: Content) -> some View {
        if measures && width != nil {
            content.background(GeometryReader { box in
                label.fixedSize().hidden().background(GeometryReader { text in
                    Color.clear.preference(key: LauncherControlSamples.self,
                                           value: [LauncherControlSample(labelWidth: text.size.width,
                                               room: max(0, box.size.width - (LauncherControl.width - room)), size: box.size)])
                })
            })
        } else {
            content
        }
    }
}

extension View {
    /// Reports this control, when it stands in a setting row, and the width its `label` wants (see LauncherControlSample) when a test asks for it.
    package func launcherMeasured<Label: View>(label: Label, room: CGFloat) -> some View {
        modifier(LauncherControlMeasure(label: label, room: room))
    }
}

private struct LauncherControlWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// Set inside a setting row: every button and dropdown there is exactly this wide.
    package var launcherControlWidth: CGFloat? {
        get { self[LauncherControlWidthKey.self] }
        set { self[LauncherControlWidthKey.self] = newValue }
    }
}

extension View {
    /// The trailing controls of a setting row: buttons and dropdowns take LauncherControl.width.
    package func launcherRowControls() -> some View { environment(\.launcherControlWidth, LauncherControl.width) }

    /// This text as wide and as high as a button of a setting row, on one line (for a control drawn by hand, like the cream capsule).
    package func launcherRowControlFrame() -> some View { modifier(LauncherRowControlFrame()) }
}

private struct LauncherRowControlFrame: ViewModifier {
    @Environment(\.launcherControlWidth) private var width
    func body(content: Content) -> some View {
        content
            .lineLimit(1).minimumScaleFactor(width == nil ? 1 : LauncherControl.minimumLabelScale)
            .padding(.horizontal, LauncherTheme.Space.large)
            .frame(width: width, height: width == nil ? nil : LauncherControl.height)
            .launcherMeasured(label: content, room: LauncherControl.buttonLabelWidth)
    }
}

package struct LauncherSecondaryButtonStyle: ButtonStyle {
    package init(accent: Color? = nil, fill: Bool = false, prominent: Bool = false, capsule: Bool = false) {
        self.accent = accent; self.fill = fill; self.prominent = prominent; self.capsule = capsule
    }
    /// Text and border in this colour (the build bar's Stop); plain white otherwise.
    package var accent: Color? = nil
    package var fill = false
    package var prominent = false
    package var capsule = false
    /// Inside a setting row the button is exactly LauncherControl.width wide and LauncherControl.height high, its label centred on
    /// one line (a little smaller when it does not fit): the buttons of a page line up in one column and are equally high.
    @Environment(\.launcherControlWidth) private var width
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    package func makeBody(configuration: Configuration) -> some View {
        let shape = LauncherControlShape(capsule: capsule)
        configuration.label
            .font(prominent ? .manrope(16, .semibold) : LauncherTheme.TypeStyle.button)
            .labelStyle(LauncherLabelStyle())
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(width == nil ? 1 : LauncherControl.minimumLabelScale)
            .padding(.horizontal, LauncherTheme.Space.large)
            .frame(width: width, height: prominent ? LauncherTheme.Metrics.prominentControlHeight : LauncherControl.height)
            .frame(minWidth: width == nil ? LauncherTheme.Metrics.actionMinWidth : nil)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(configuration.isPressed ? LauncherTheme.Colors.pressed : hovered ? LauncherTheme.Colors.hover : LauncherTheme.Colors.control,
                        in: shape)
            .overlay(shape.strokeBorder(accent?.opacity(0.75) ?? LauncherTheme.Colors.border))
            .foregroundStyle(enabled ? (accent ?? Color.white.opacity(0.92)) : .gray)
            .opacity(enabled ? 1 : 0.55)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .launcherMeasured(label: configuration.label.font(prominent ? .manrope(16, .semibold) : LauncherTheme.TypeStyle.button), room: LauncherControl.buttonLabelWidth)
    }
}

/// A standalone radio option: the controller focus ring wraps only the circular radio indicator, not the label.
package struct LauncherRadioRow<Label: View>: View {
    package let selected: Bool
    package let action: () -> Void
    package let label: Label
    @Environment(\.isEnabled) private var enabled
    package init(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.selected = selected; self.action = action; self.label = label()
    }
    package var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(selected ? LauncherPalette.cream : .secondary)
            }
            .controllerButtonStyle(.plain)
            .controllerRingRadius(.infinity, outset: LauncherTheme.Focus.radioOutset)
            label
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { action() } }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// The launcher's switch: a cream track when on, a dim one when off.
package struct LauncherSwitchStyle: ToggleStyle {
    package init() {}
    @Environment(\.isEnabled) private var enabled
    package func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? LauncherPalette.cream : Color.white.opacity(0.14))
                Circle().fill(configuration.isOn ? LauncherPalette.background : Color.white.opacity(0.85))
                    .padding(3)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .frame(width: LauncherTheme.Metrics.switchWidth, height: LauncherTheme.Metrics.switchHeight)
            .contentShape(Capsule())
        }
        .controllerButtonStyle(.plain)
        .controllerRingRadius(.infinity, outset: LauncherTheme.Focus.creamOutset)   // 胶囊开关：焦点框也是胶囊，画在外侧（开着时整条奶油色，贴边的框看不见）
        .opacity(enabled ? 1 : 0.45)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}

/// The cream button of the library's hero (Play, Build game, Open on a device). It has one size in every state and language, so
/// the button does not change size when a game goes from not built to built. A long label shrinks, then ends in an ellipsis.
package enum LauncherHeroAction {
    package static let width: CGFloat = 200
    package static let height: CGFloat = 54
    package static let horizontalPadding: CGFloat = 24
    package static let iconSlot: CGFloat = 28
    package static let iconSpacing: CGFloat = 8
    package static let labelWidth = width - 2 * horizontalPadding - iconSlot - iconSpacing
}

package struct LauncherHeroActionLabel: View {
    package init(title: String, symbol: String) { self.title = title; self.symbol = symbol }
    package let title: String
    package let symbol: String

    package var body: some View {
        HStack(spacing: LauncherHeroAction.iconSpacing) {
            Image(systemName: symbol).frame(width: LauncherHeroAction.iconSlot)
            Text(title).lineLimit(1).fixedSize()
        }
        .font(.manrope(18, .bold))
        .foregroundStyle(.black)
        .padding(.horizontal, LauncherHeroAction.horizontalPadding)
        // 最小这么宽、字长就撑宽（11-14 加日 / 西 / 法：固定宽 + 缩字仍放不下，被截成「Installer sur l'iPh…」）
        .frame(minWidth: LauncherHeroAction.width, minHeight: LauncherHeroAction.height, maxHeight: LauncherHeroAction.height)
        .background(LauncherPalette.cream, in: Capsule())
    }
}

/// The width of a launch option's control (choices, list, slider with its value), so the controls of a card line up
/// in one column whatever their labels.
package enum LaunchControl {
    package static let width: CGFloat = LauncherTheme.Metrics.controlWidth
    /// A slider's value, in percent or in pixels: wide enough for "1920×1080" in 13 pt Manrope semibold with monospaced digits
    /// (71 pt), so every slider of the sheet is equally long and the reset arrows line up.
    package static let valueWidth: CGFloat = 72

    /// Characters the segments of one control share: a segment of 12.5 pt text, 24 pt of padding in 220 pt, takes about 10 with two
    /// choices and 6 with three.
    package static let segmentedCharacters = 20

    /// Segmented for two or three short labels, a menu otherwise. The game's language (DM_LANG) is always a menu, as on the iPhone.
    package static func isSegmented(env: String, labels: [String]) -> Bool {
        guard env != "DM_LANG", labels.count <= 3 else { return false }
        return labels.allSatisfy { $0.count <= segmentedCharacters / max(labels.count, 1) }
    }
}

/// Two or three choices side by side; the chosen one uses a cream fill. Each choice takes an equal share of the width
/// it is given.
package struct LauncherSegmented: View {
    package init(options: [(value: String, label: String)], selection: String, choose: @escaping (String) -> Void) {
        self.options = options; self.selection = selection; self.choose = choose
    }
    package let options: [(value: String, label: String)]
    package let selection: String
    package let choose: (String) -> Void
    package var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selection
                Button { withAnimation(.easeOut(duration: 0.15)) { choose(o.value) } } label: {
                    Text(o.label).font(.manrope(12.5, on ? .bold : .medium))
                        .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 12).frame(height: LauncherControl.height - 6)
                        .frame(maxWidth: .infinity)
                        .background(on ? LauncherPalette.cream : .clear, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius - 3))
                        .contentShape(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius - 3))
                }
                .controllerButtonStyle(.plain)
                .controllerRingRadius(LauncherTheme.Metrics.controlRadius - 3, outset: on ? LauncherTheme.Focus.creamOutset : 0)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: LauncherControl.height)
        .background(LauncherTheme.Colors.control, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius).strokeBorder(LauncherTheme.Colors.border))
    }
}

/// A slider without tick marks: a thin track, a cream fill and a round knob; snaps to its step.
package struct LauncherSlider: View {
    package init(value: Double, range: ClosedRange<Double>, step: Double, change: @escaping (Double) -> Void) {
        self.value = value; self.range = range; self.step = step; self.change = change
    }
    package let value: Double
    package let range: ClosedRange<Double>
    package let step: Double
    package let change: (Double) -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    package var body: some View {
        GeometryReader { g in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            let knob: CGFloat = 16, track = g.size.width - knob
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 4).padding(.horizontal, knob / 2)
                Capsule().fill(LauncherPalette.cream).frame(width: track * fraction + knob / 2, height: 4).padding(.leading, knob / 2)
                Circle().fill(LauncherPalette.cream).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: track * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard enabled else { return }
                let raw = range.lowerBound + Double(min(max(drag.location.x - knob / 2, 0), track) / max(track, 1)) * span
                let snapped = step > 0 ? (raw / step).rounded() * step : raw
                change(min(max(snapped, range.lowerBound), range.upperBound))
            })
        }
        .frame(height: LauncherControl.height)
        .focusable(enabled).focused($focused)
        .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous)
            .strokeBorder(focused ? LauncherPalette.cream.opacity(0.7) : .clear, lineWidth: LauncherTheme.Focus.lineWidth).allowsHitTesting(false))
        .onMoveCommand { direction in
            if direction == .left { adjust(-1) } else if direction == .right { adjust(1) }
        }
        .accessibilityRepresentation {
            if step > 0 { Slider(value: Binding(get: { value }, set: change), in: range, step: step).labelsHidden() }
            else { Slider(value: Binding(get: { value }, set: change), in: range).labelsHidden() }
        }
        .controllerControl(activate: { focused = true }, adjust: adjust)
        .controllerRingRadius(LauncherTheme.Metrics.controlRadius)
    }

    private func adjust(_ direction: Int) {
        guard enabled else { return }
        let increment = step > 0 ? step : (range.upperBound - range.lowerBound) / 100
        change(min(max(value + Double(direction) * increment, range.lowerBound), range.upperBound))
    }
}

extension LauncherSecondaryButtonStyle: PadRingShaped {
    package var padRingRadius: CGFloat { capsule ? .infinity : LauncherTheme.Metrics.controlRadius }
}
