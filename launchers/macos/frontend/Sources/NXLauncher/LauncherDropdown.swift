// Derived from NX2Apple (MIT; see frontend/NOTICE).
// S2Arm: one themed control face, window-local menus, controller actions and isolated dropdown focus.
import SwiftUI

/// Where the list of an open dropdown goes and how big it is. Pure, so the rules are tested (LauncherDropdownTests).
package enum LauncherDropdownLayout {
    package static let rowHeight: CGFloat = 34
    package static let rowSpacing: CGFloat = 2
    package static let padding: CGFloat = 6
    package static let gap: CGFloat = 6        // between the button and its list
    package static let margin: CGFloat = 8     // kept free at the edges of the window
    package static let maxHeight: CGFloat = 320
    package static let minWidth: CGFloat = 180
    package static let maxWidth: CGFloat = 360

    package static func contentHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing + padding * 2
    }

    /// As wide as the longest label needs (plus room for the checkmark), never narrower than the button.
    package static func width(labels: [String], button: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let widest = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width * 1.1) }.max() ?? 0
        return min(max(widest + 12 * 2 + 16 + 12 + padding * 2, button, minWidth), maxWidth)
    }

    /// The list opens below the button, above it when there is no room below, and takes the bigger side when it fits on
    /// neither (then it scrolls). A button in the right half of the window gets its list aligned to its right edge.
    package static func place(button: CGRect, container: CGSize, rows: Int, width: CGFloat) -> (origin: CGPoint, size: CGSize) {
        let wanted = min(contentHeight(rows: rows), maxHeight)
        let below = container.height - margin - (button.maxY + gap)
        let above = button.minY - gap - margin
        let opensBelow = below >= wanted || below >= above
        let height = max(min(wanted, opensBelow ? below : above), rowHeight + padding * 2)
        let y = opensBelow ? button.maxY + gap : button.minY - gap - height
        let preferredX = button.midX > container.width / 2 ? button.maxX - width : button.minX
        let x = min(max(preferredX, margin), max(margin, container.width - width - margin))
        return (CGPoint(x: x, y: max(y, margin)), CGSize(width: width, height: height))
    }

    /// The row an arrow key lands on, wrapping at the ends. Without a highlighted row Down takes the first, Up the last.
    package static func step(from current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return (current + delta % count + count) % count
    }
}

/// One dropdown being open: what its list shows and what a pick does.
package struct LauncherDropdownRequest {
    package init(id: UUID, options: [(value: String, label: String)], selection: String, label: String,
                 artwork: ((String) -> AnyView)? = nil, disabledOptions: Set<String> = [], choose: @escaping (String) -> Void) {
        self.id = id; self.options = options; self.selection = selection; self.label = label; self.choose = choose
        self.artwork = artwork; self.disabledOptions = disabledOptions
    }
    package let id: UUID
    package let options: [(value: String, label: String)]
    package let selection: String
    package let label: String
    package let artwork: ((String) -> AnyView)?
    package let disabledOptions: Set<String>
    package let choose: (String) -> Void
}

/// The open dropdown of one window or sheet, shared by the host (which draws the list) and the buttons (which open it).
package final class LauncherDropdownState: ObservableObject {
    @Published package var request: LauncherDropdownRequest?
    package func close() { withAnimation(.easeOut(duration: 0.12)) { request = nil } }
}

private struct LauncherDropdownHostKey: EnvironmentKey { static let defaultValue: LauncherDropdownState? = nil }

extension EnvironmentValues {
    package var launcherDropdownHost: LauncherDropdownState? {
        get { self[LauncherDropdownHostKey.self] }
        set { self[LauncherDropdownHostKey.self] = newValue }
    }
}

/// Each dropdown button reports its frame here, so the list opens against it and follows it when the page scrolls.
package struct LauncherDropdownAnchorKey: PreferenceKey {
    package static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    package static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Draws the open LauncherDropdown's list over this view, outside the clipping of the scroll view the button sits in.
    /// Every window and sheet with dropdowns needs one at its root, because a sheet is a window of its own.
    /// A dropdown without a host opens its list as a popover.
    package func launcherDropdownHost() -> some View { modifier(LauncherDropdownHost()) }
}

extension View {
    /// The list's own surface: the app's dark card with its border, radius and shadow.
    package func launcherDropdownSurface() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius).strokeBorder(LauncherTheme.Colors.border))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }
}

private struct LauncherDropdownHost: ViewModifier {
    @StateObject private var state = LauncherDropdownState()
    func body(content: Content) -> some View {
        content
            .environment(\.launcherDropdownHost, state)
            .overlayPreferenceValue(LauncherDropdownAnchorKey.self) { anchors in
                LauncherDropdownLayer(state: state, anchors: anchors)
            }
    }
}

private struct LauncherDropdownLayer: View {
    @ObservedObject var state: LauncherDropdownState
    let anchors: [UUID: Anchor<CGRect>]
    var body: some View {
        GeometryReader { g in
            if let request = state.request, let anchor = anchors[request.id] {
                let button = g[anchor]
                let width = LauncherDropdownLayout.width(labels: request.options.map(\.label), button: button.width)
                let spot = LauncherDropdownLayout.place(button: button, container: g.size, rows: request.options.count, width: width)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).contentShape(Rectangle())
                        .onTapGesture { state.close() }
                        .accessibilityHidden(true)
                    LauncherDropdownList(options: request.options, selection: request.selection, label: request.label, artwork: request.artwork, disabledOptions: request.disabledOptions,
                                         choose: { value in request.choose(value); state.close() }, close: { state.close() })
                        .frame(width: spot.size.width, height: spot.size.height)
                        .launcherDropdownSurface()
                        .offset(x: spot.origin.x, y: spot.origin.y)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// The rows of an open dropdown: the chosen one with a checkmark, the one under the pointer or the arrow keys lit.
/// Arrow keys move, Return or Space pick, Esc closes (a local key monitor while it is open, as in the Manage menu).
package extension Notification.Name {
    /// 手柄 B：收起这个窗口里开着的下拉选单（object = 窗口；只关选单，不关底下的面板）
    static let launcherDropdownClose = Notification.Name("S2ALauncherDropdownClose")
}

package struct LauncherDropdownList: View {
    package init(options: [(value: String, label: String)], selection: String, label: String, artwork: ((String) -> AnyView)? = nil, disabledOptions: Set<String> = [],
                 choose: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.options = options; self.selection = selection; self.label = label; self.choose = choose; self.close = close
        self.artwork = artwork; self.disabledOptions = disabledOptions
    }
    package let options: [(value: String, label: String)]
    package let selection: String
    package let label: String
    package let artwork: ((String) -> AnyView)?
    package let disabledOptions: Set<String>
    package let choose: (String) -> Void
    package let close: () -> Void
    @State private var highlighted: Int?
    @State private var monitor: Any?
    @AccessibilityFocusState private var spoken: Int?

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LauncherDropdownLayout.rowSpacing) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in row(option, index: index).id(index) }
                }
                .padding(LauncherDropdownLayout.padding)
            }
            .onChange(of: highlighted) { index in if let index { proxy.scrollTo(index) } }
            .onAppear {
                let at = options.firstIndex { $0.value == selection }
                highlighted = at
                if let at { proxy.scrollTo(at, anchor: .center) }
                spoken = at ?? 0
                startKeys()
            }
        }
        .onDisappear(perform: stopKeys)
        .onReceive(NotificationCenter.default.publisher(for: .launcherDropdownClose)) { _ in close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("launcher.dropdown")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .controllerScope("dropdown")
    }

    private func row(_ option: (value: String, label: String), index: Int) -> some View {
        let selected = option.value == selection
        return Button { choose(option.value) } label: {
            HStack(spacing: 10) {
                if let artwork { artwork(option.value) }
                else { Text(option.label).font(.manrope(13, selected ? .bold : .medium)).lineLimit(1) }
                Spacer(minLength: 16)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(LauncherPalette.cream)
                    .opacity(selected ? 1 : 0)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12).frame(height: LauncherDropdownLayout.rowHeight)
            .background(highlighted == index ? Color.white.opacity(0.09) : (selected ? Color.white.opacity(0.045) : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .controllerButtonStyle(.plain)
        .controllerRingRadius(8)
        .disabled(disabledOptions.contains(option.value))
        .opacity(disabledOptions.contains(option.value) ? 0.45 : 1)
        .onHover { inside in
            if inside { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityFocused($spoken, equals: index)
        .controllerID("dropdown." + option.value)
        .controllerPreferredFocus(selected)
    }

    private func startKeys() {
        stopKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: highlighted = LauncherDropdownLayout.step(from: highlighted, by: 1, count: options.count)
            case 126: highlighted = LauncherDropdownLayout.step(from: highlighted, by: -1, count: options.count)
            case 36, 76, 49: if let i = highlighted, options.indices.contains(i), !disabledOptions.contains(options[i].value) { choose(options[i].value) }
            case 53: close()
            case 48: close(); return event
            default: return event
            }
            return nil
        }
    }

    private func stopKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The launcher's dropdown: a button with the current choice that opens a list drawn in the app's own style
/// (its dark surface, Manrope, a checkmark on the chosen row). It never cuts the label short unless it is given
/// `fill` (the width of its container). Inside a setting row it is exactly LauncherControl.width wide and LauncherControl.height high, its choice at
/// the left and the chevron at the right, the choice a little smaller when it does not fit.
/// `label` names the setting for VoiceOver, which then reads the choice as the value.
package struct LauncherDropdown: View {
    package init(options: [(value: String, label: String)], selection: String, label: String = "",
                  fill: Bool = false, artwork: ((String) -> AnyView)? = nil, disabledOptions: Set<String> = [], choose: @escaping (String) -> Void) {
        self.options = options; self.selection = selection; self.label = label; self.fill = fill
        self.artwork = artwork; self.disabledOptions = disabledOptions
        self.choose = choose
    }
    package let options: [(value: String, label: String)]
    package let selection: String
    package var label = ""
    package var fill = false
    package let artwork: ((String) -> AnyView)?
    package let disabledOptions: Set<String>
    package let choose: (String) -> Void
    @Environment(\.launcherDropdownHost) private var host
    @State private var id = UUID()

    package var body: some View {
        if let host {
            Hosted(host: host, dropdown: self)
        } else {
            Popped(dropdown: self)
        }
    }

    fileprivate var current: String { options.first { $0.value == selection }?.label ?? selection }

    @ViewBuilder private var choiceLabel: some View {
        if let artwork { artwork(selection) }
        else { Text(current).font(LauncherTheme.TypeStyle.button) }
    }

    fileprivate func face(open: Bool, rowWidth: CGFloat?) -> some View {
        let shape = RoundedRectangle(cornerRadius: LauncherTheme.Metrics.controlRadius, style: .continuous)
        let width = fill ? nil : rowWidth
        return HStack(spacing: LauncherTheme.Space.small) {
            choiceLabel.lineLimit(1)
                .minimumScaleFactor(width == nil ? 1 : 0.85)
                .fixedSize(horizontal: !fill && width == nil, vertical: false)
                .frame(maxWidth: fill || width != nil ? .infinity : nil, alignment: .leading)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 10).rotationEffect(.degrees(open ? 180 : 0)).accessibilityHidden(true)
        }
        .padding(.horizontal, LauncherTheme.Space.large)
        .frame(width: width, height: LauncherControl.height)
        .frame(maxWidth: fill ? .infinity : nil)
        .background(open ? LauncherTheme.Colors.pressed : LauncherTheme.Colors.control, in: shape)
        .overlay(shape.strokeBorder(open ? LauncherPalette.cream.opacity(0.4) : LauncherTheme.Colors.border))
        .foregroundStyle(LauncherTheme.Colors.text)
        .help(current)
        .contentShape(shape)
        .launcherMeasured(label: choiceLabel, room: LauncherControl.choiceWidth)
    }

    fileprivate func accessible<V: View>(_ view: V) -> some View {
        view.accessibilityLabel(label.isEmpty ? current : label).accessibilityValue(label.isEmpty ? "" : current)
    }

    private struct Hosted: View {
        @ObservedObject var host: LauncherDropdownState
        let dropdown: LauncherDropdown
        @Environment(\.isEnabled) private var enabled
        @Environment(\.launcherControlWidth) private var rowWidth
        var body: some View {
            let open = host.request?.id == dropdown.id
            dropdown.accessible(
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        host.request = open ? nil : LauncherDropdownRequest(id: dropdown.id, options: dropdown.options, selection: dropdown.selection,
                                                                            label: dropdown.label, artwork: dropdown.artwork, disabledOptions: dropdown.disabledOptions, choose: dropdown.choose)
                    }
                } label: { dropdown.face(open: open, rowWidth: rowWidth) }
                .controllerButtonStyle(.plain)
                .controllerRingRadius(LauncherTheme.Metrics.controlRadius)
                .opacity(enabled ? 1 : 0.55)
                .anchorPreference(key: LauncherDropdownAnchorKey.self, value: .bounds) { [dropdown.id: $0] }
            )
        }
    }

    /// Without a host the same list opens in a popover.
    private struct Popped: View {
        let dropdown: LauncherDropdown
        @State private var open = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.launcherControlWidth) private var rowWidth
        var body: some View {
            dropdown.accessible(
                Button { open.toggle() } label: { dropdown.face(open: open, rowWidth: rowWidth) }
                    .controllerButtonStyle(.plain)
                    .controllerRingRadius(LauncherTheme.Metrics.controlRadius)
                    .opacity(enabled ? 1 : 0.55)
                    .popover(isPresented: $open, arrowEdge: .bottom) {
                        LauncherDropdownList(options: dropdown.options, selection: dropdown.selection, label: dropdown.label, artwork: dropdown.artwork, disabledOptions: dropdown.disabledOptions,
                                             choose: { dropdown.choose($0); open = false }, close: { open = false })
                            .frame(width: LauncherDropdownLayout.width(labels: dropdown.options.map(\.label), button: 0),
                                   height: min(LauncherDropdownLayout.contentHeight(rows: dropdown.options.count), LauncherDropdownLayout.maxHeight))
                            .preferredColorScheme(.dark)
                            .controllerBackAction("dropdown.pop.close") { open = false }
                    }
            )
        }
    }
}
