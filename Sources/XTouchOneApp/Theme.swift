#if os(macOS)
import SwiftUI
import XTouchOneAdapter
import XTouchOnePanel

/// The same palette and chrome as the XTouchCompactDev and BCR2000Dev consoles.
enum Theme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.072)
    static let surface = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.08)
    static let chassisTop = Color(red: 0.15, green: 0.155, blue: 0.17)
    static let chassisBottom = Color(red: 0.085, green: 0.09, blue: 0.105)
    static let slot = Color.black.opacity(0.55)
    static let ring = Color(red: 1.0, green: 0.62, blue: 0.16)
    static let ledOff = Color.white.opacity(0.09)
    static let value = Color(red: 0.25, green: 0.82, blue: 0.78)
    static let touch = Color(red: 0.98, green: 0.82, blue: 0.3)
    static let observed = Color(red: 0.62, green: 0.72, blue: 1.0)
    static let selection = Color(red: 0.42, green: 0.62, blue: 1.0)

    static func led(_ light: XTouchOnePanelLight) -> Color {
        switch light {
        case .amber: Color(red: 1.0, green: 0.78, blue: 0.25)
        case .green: Color(red: 0.36, green: 0.9, blue: 0.42)
        case .red: Color(red: 1.0, green: 0.27, blue: 0.2)
        case .blue: Color(red: 0.3, green: 0.8, blue: 1.0)
        case .white: Color(white: 0.95)
        }
    }

    static func lcd(_ color: XTouchOneLCDColor) -> Color {
        switch color {
        case .black: Color(white: 0.12)
        case .red: Color(red: 0.94, green: 0.33, blue: 0.31)
        case .green: Color(red: 0.36, green: 0.8, blue: 0.42)
        case .yellow: Color(red: 0.95, green: 0.83, blue: 0.27)
        case .blue: Color(red: 0.36, green: 0.58, blue: 0.98)
        case .magenta: Color(red: 0.85, green: 0.4, blue: 0.9)
        case .cyan: Color(red: 0.24, green: 0.78, blue: 0.76)
        case .white: Color(white: 0.92)
        }
    }
}

enum BarMetrics {
    static let height: CGFloat = 28
    static let radius: CGFloat = 7
    static let segmentInset: CGFloat = 3
}

/// Flat button for the mode strip and header. A tint marks the one action that matters now.
struct BarButtonStyle: ButtonStyle {
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: BarMetrics.height)
            .foregroundStyle(tint == nil ? Color.primary.opacity(0.9) : Color.black)
            .background(tint ?? Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: BarMetrics.radius))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct PanelStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke) }
    }
}

extension View {
    func panelStyle(padding: CGFloat = 14) -> some View { modifier(PanelStyle(padding: padding)) }
}

extension View {
    /// A darker block inside a panel, for one group of related rows.
    func insetStyle() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A vertical scroll view that shows when part of its content is out of view: the cut edge fades, and a
/// "更多" chip at the bottom scrolls to the end. It also reports the full content height.
struct OverflowScrollView<Content: View>: View {
    var onContentHeight: (CGFloat) -> Void = { _ in }
    @ViewBuilder var content: Content
    @State private var frame = CGRect.zero
    @State private var viewport: CGFloat = 0

    private static var bottomID: String { "overflow.bottom" }

    var body: some View {
        let hiddenAbove = -frame.minY > 1
        let hiddenBelow = frame.maxY - viewport > 1
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                    Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .onGeometryChange(for: CGRect.self, of: overflowContentFrame) { value in
                    frame = value
                    onContentHeight(value.height)
                }
            }
            .coordinateSpace(.named(overflowSpace))
            .onGeometryChange(for: CGFloat.self, of: overflowViewportHeight) { viewport = $0 }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(hiddenAbove ? 0 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(hiddenBelow ? 0.15 : 1)], startPoint: .top, endPoint: .bottom).frame(height: 36)
                }
            }
            .overlay(alignment: .bottom) {
                if hiddenBelow {
                    Button { withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } } label: {
                        Label("更多", systemImage: "chevron.down")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .foregroundStyle(Color.black)
                            .background(Theme.value, in: Capsule())
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .help("下面还有内容，点击滚动到底部")
                    .transition(.opacity)
                    .accessibilityIdentifier("overflow.more")
                }
            }
            .animation(.easeOut(duration: 0.15), value: hiddenBelow)
        }
    }
}

// Free functions, so the geometry transforms capture nothing from the generic view.
private let overflowSpace = "overflow.scroll"
private func overflowContentFrame(_ geometry: GeometryProxy) -> CGRect { geometry.frame(in: .named(overflowSpace)) }
private func overflowViewportHeight(_ geometry: GeometryProxy) -> CGFloat { geometry.size.height }

struct SectionTitle: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon).font(.caption.bold()).foregroundStyle(.secondary).tracking(0.8)
    }
}

/// A monospaced readout with a small caption, as in the control inspector of the other consoles.
struct Readout: View {
    let title: String
    let value: String
    var color = Theme.value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).bold()).foregroundStyle(color)
        }
    }
}
#endif
