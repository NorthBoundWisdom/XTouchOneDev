#if os(macOS)
import SwiftUI
import XTouchOneAdapter
import XTouchOnePanel
import XTouchOneSimulator

enum Palette {
    static let body = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let well = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let cap = Color(red: 0.42, green: 0.42, blue: 0.44)
    static let rail = Color(red: 0.72, green: 0.73, blue: 0.75)
    static let legend = Color(white: 0.82)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.12)

    static func light(_ light: XTouchOnePanelLight) -> Color {
        switch light {
        case .amber: Color(red: 1.0, green: 0.86, blue: 0.35)
        case .green: Color(red: 0.45, green: 1.0, blue: 0.45)
        case .red: Color(red: 1.0, green: 0.4, blue: 0.38)
        case .blue: Color(red: 0.4, green: 0.9, blue: 1.0)
        case .white: Color(white: 0.96)
        }
    }

    static func lcd(_ color: XTouchOneLCDColor) -> Color {
        switch color {
        case .black: Color(white: 0.12)
        case .red: Color(red: 0.9, green: 0.2, blue: 0.2)
        case .green: Color(red: 0.2, green: 0.8, blue: 0.3)
        case .yellow: Color(red: 0.95, green: 0.85, blue: 0.2)
        case .blue: Color(red: 0.25, green: 0.45, blue: 0.95)
        case .magenta: Color(red: 0.85, green: 0.3, blue: 0.85)
        case .cyan: Color(red: 0.25, green: 0.85, blue: 0.9)
        case .white: Color(white: 0.92)
        }
    }
}

/// The device face, drawn at a fixed 600 × 730 design size.
struct PanelView: View {
    let model: AppModel
    static let size = CGSize(width: 600, height: 730)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                EncoderView(model: model).frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("UNIVERSAL CONTROL SURFACE").font(.system(size: 13, weight: .medium)).kerning(3)
                        .foregroundStyle(Palette.legend)
                    SegmentDisplayView(device: model.console.shown)
                }
            }
            HStack(alignment: .bottom, spacing: 14) {
                LCDView(lcd: model.console.shown.lcd).frame(width: 96, height: 58)
                Spacer(minLength: 0)
                KeyRow(model: model, title: "CHANNEL", group: .channel)
            }
            HStack(alignment: .bottom, spacing: 14) {
                Text("X TOUCH ONE").font(.system(size: 17, weight: .semibold)).kerning(2).foregroundStyle(Palette.legend)
                    .frame(width: 150, alignment: .leading)
                Spacer(minLength: 0)
                KeyRow(model: model, title: "FUNCTION", group: .function)
            }
            HStack(alignment: .top, spacing: 18) {
                HStack(alignment: .top, spacing: 10) {
                    FaderView(model: model).frame(width: 70)
                    MeterView(value: model.console.shown.meter).frame(width: 16).padding(.top, 30)
                }
                .frame(width: 110)
                VStack(alignment: .leading, spacing: 12) {
                    KeyRow(model: model, title: "TRANSPORT", group: .transportModes)
                    HStack(spacing: 8) {
                        ForEach(XTouchOnePanelLayout.keys(in: .transport)) { key in
                            KeyView(model: model, key: key, width: 70, height: 34, symbol: Self.transportSymbols[key.label])
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            BankView(model: model)
                            NavigationView(model: model)
                        }
                        VStack(alignment: .trailing, spacing: 6) {
                            if let scrub = XTouchOnePanelLayout.keys(in: .scrub).first {
                                KeyView(model: model, key: scrub, width: 34, height: 34, showLabel: true)
                            }
                            JogView(model: model).frame(width: 210, height: 210)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 34).padding(.vertical, 22)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Palette.rail)
                RoundedRectangle(cornerRadius: 14).fill(Palette.body).padding(.horizontal, 16).padding(.vertical, 4)
            }
        }
    }

    static let transportSymbols = ["REW": "backward.fill", "FWD": "forward.fill", "STOP": "stop.fill",
                                   "PLAY": "play.fill", "RECORD": "circle.fill"]
}

struct KeyRow: View {
    let model: AppModel
    let title: String
    let group: XTouchOnePanelGroup

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).kerning(1.5).foregroundStyle(Palette.legend)
            HStack(alignment: .top, spacing: 8) {
                ForEach(XTouchOnePanelLayout.keys(in: group)) { key in
                    KeyView(model: model, key: key, width: 34, height: 34, showLabel: true)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.well))
    }
}

/// One key. Press and release follow the pointer; a secondary click cycles the key's light through the display path.
struct KeyView: View {
    let model: AppModel
    let key: XTouchOnePanelKey
    var width: CGFloat
    var height: CGFloat
    var showLabel = false
    var symbol: String?
    @State private var held = false

    private var state: XTouchOneButtonLED { model.console.shown.buttonLEDs[key.address] ?? .off }
    private var lit: Bool { state == .on || (state == .flash && model.blink) }
    private var down: Bool { model.console.pressed.contains(key.button.elementID) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(lit ? Palette.light(key.light) : Palette.cap)
                    .shadow(color: lit ? Palette.light(key.light).opacity(0.8) : .clear, radius: 6)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.6), lineWidth: 1))
                    .brightness(down ? -0.22 : 0)
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.black.opacity(0.65))
                }
                if model.showAddresses {
                    Text("\(key.address)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.black.opacity(0.75))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(2)
                }
            }
            .frame(width: width, height: height)
            .scaleEffect(down ? 0.95 : 1)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !held { held = true; model.act(.button(key.address, pressed: true)) }
                }
                .onEnded { _ in
                    held = false
                    model.act(.button(key.address, pressed: false))
                })
            .contextMenu {
                Button("灯：下一个状态") { model.cycleLight(key) }
                ForEach([("熄灭", XTouchOneButtonLED.off), ("常亮", .on), ("闪烁", .flash)], id: \.0) { name, state in
                    Button(name) { model.show(.buttonLED(key.button, state)) }
                }
            }
            .accessibilityIdentifier("key.\(key.address)")
            .accessibilityLabel(key.label)
            if showLabel {
                Text(key.label).font(.system(size: 7.5, weight: .medium)).foregroundStyle(Palette.legend)
                    .lineLimit(1).fixedSize()
                    .frame(width: width)
            }
        }
    }
}

struct BankView: View {
    let model: AppModel
    var body: some View {
        let keys = XTouchOnePanelLayout.keys(in: .bank)
        VStack(spacing: 4) {
            Text("FADER BANK").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.legend)
            HStack(spacing: 14) { ForEach(keys.prefix(2)) { KeyView(model: model, key: $0, width: 36, height: 30) } }
            Text("CHANNEL").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.legend)
            HStack(spacing: 14) { ForEach(keys.suffix(2)) { KeyView(model: model, key: $0, width: 36, height: 30) } }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.well))
    }
}

struct NavigationView: View {
    let model: AppModel
    var body: some View {
        let keys = Dictionary(uniqueKeysWithValues: XTouchOnePanelLayout.keys(in: .navigation).map { ($0.label, $0) })
        VStack(spacing: 4) {
            KeyView(model: model, key: keys["UP"]!, width: 32, height: 28)
            HStack(spacing: 4) {
                KeyView(model: model, key: keys["LEFT"]!, width: 32, height: 28)
                KeyView(model: model, key: keys["ZOOM"]!, width: 32, height: 28)
                KeyView(model: model, key: keys["RIGHT"]!, width: 32, height: 28)
            }
            KeyView(model: model, key: keys["DOWN"]!, width: 32, height: 28)
        }
    }
}

/// Twelve seven-segment digits with dots, drawn from the masks last sent.
struct SegmentDisplayView: View {
    let device: XTouchOneSimulatedDevice

    var body: some View {
        let masks = device.segments ?? Array(repeating: 0, count: 12)
        let dots = device.segmentDots ?? [0, 0]
        HStack(spacing: 5) {
            ForEach(0..<12, id: \.self) { index in
                let dot = index < 7 ? dots[0] >> UInt8(index) & 1 : dots[1] >> UInt8(index - 7) & 1
                SegmentDigit(mask: masks[index], dot: dot == 1).frame(width: 24, height: 40)
                if index == 1 { Spacer().frame(width: 18) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 6).fill(.black))
        .accessibilityIdentifier("segments")
    }
}

struct SegmentDigit: View {
    let mask: UInt8
    let dot: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width * 0.78, h = size.height, t = max(2.5, w * 0.16), half = h / 2
            let bars: [CGRect] = [
                CGRect(x: t, y: 0, width: w - 2 * t, height: t),                      // a
                CGRect(x: w - t, y: t, width: t, height: half - t * 1.5),              // b
                CGRect(x: w - t, y: half + t * 0.5, width: t, height: half - t * 1.5), // c
                CGRect(x: t, y: h - t, width: w - 2 * t, height: t),                  // d
                CGRect(x: 0, y: half + t * 0.5, width: t, height: half - t * 1.5),     // e
                CGRect(x: 0, y: t, width: t, height: half - t * 1.5),                  // f
                CGRect(x: t, y: half - t / 2, width: w - 2 * t, height: t),           // g
            ]
            for (bit, bar) in bars.enumerated() {
                let on = mask >> UInt8(bit) & 1 == 1
                context.fill(Path(roundedRect: bar, cornerRadius: t / 2), with: .color(on ? Palette.amber : Palette.amber.opacity(0.08)))
            }
            let point = CGRect(x: size.width - t, y: h - t, width: t, height: t)
            context.fill(Path(ellipseIn: point), with: .color(dot ? Palette.amber : Palette.amber.opacity(0.08)))
        }
    }
}

struct LCDView: View {
    let lcd: XTouchOneSimulatedLCD?

    var body: some View {
        let color = lcd.map { Palette.lcd($0.color) } ?? Color(white: 0.16)
        VStack(spacing: 0) {
            line(lcd?.upper ?? "", inverted: lcd?.invertUpper ?? false, color: color)
            line(lcd?.lower ?? "", inverted: lcd?.invertLower ?? false, color: color)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black, lineWidth: 2))
        .accessibilityIdentifier("lcd")
    }

    private func line(_ text: String, inverted: Bool, color: Color) -> some View {
        let ink = lcd?.color == .black ? Color(white: 0.75) : Color(white: 0.06)
        return Text(text.padding(toLength: 7, withPad: " ", startingAt: 0))
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .foregroundStyle(inverted ? color : ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(inverted ? ink : color)
    }
}

struct MeterView: View {
    let value: UInt8?

    var body: some View {
        let lit = Int((Double(value ?? 0) / 127 * 8).rounded())
        VStack(spacing: 5) {
            ForEach((0..<8).reversed(), id: \.self) { index in
                let color: Color = index == 7 ? .red : index >= 5 ? Palette.amber : .green
                RoundedRectangle(cornerRadius: 1.5).fill(index < lit ? color : color.opacity(0.12)).frame(width: 7, height: 13)
            }
        }
        .accessibilityIdentifier("meter")
    }
}

/// The encoder: drag up or down to turn one detent per 9 points, click to press. The ring shows the last ring value sent.
struct EncoderView: View {
    let model: AppModel
    @State private var detents = 0
    @State private var held = false
    private var push: XTouchOnePanelKey? { XTouchOnePanelLayout.keys(in: .encoder).first }

    var body: some View {
        let ring = model.console.shown.encoderRing
        let lit = ring.map { Int((Double($0) / 127 * 12).rounded()) } ?? -1
        ZStack {
            ForEach(0..<13, id: \.self) { index in
                let angle = Angle.degrees(-135 + Double(index) * 22.5)
                Capsule().fill(index <= lit ? Palette.amber : Palette.amber.opacity(0.12))
                    .frame(width: 4, height: 10)
                    .offset(y: -42)
                    .rotationEffect(angle)
            }
            Circle().fill(RadialGradient(colors: [Color(white: 0.3), Color(white: 0.08)], center: .center, startRadius: 2, endRadius: 30))
                .frame(width: 58, height: 58)
                .scaleEffect(held ? 0.94 : 1)
            Capsule().fill(Color(white: 0.7)).frame(width: 3, height: 12).offset(y: -19)
                .rotationEffect(.degrees(Double(model.console.encoderTicks) * 12))
            if model.showAddresses, let push {
                Text("\(push.address)").font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.legend)
            }
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let target = Int((-drag.translation.height / 9).rounded(.towardZero))
                while detents != target {
                    let clockwise = target > detents
                    detents += clockwise ? 1 : -1
                    model.act(.encoder(clockwise: clockwise))
                }
            }
            .onEnded { drag in
                if detents == 0, abs(drag.translation.height) < 3, abs(drag.translation.width) < 3, let push {
                    held = true
                    model.act(.button(push.address, pressed: true))
                    model.act(.button(push.address, pressed: false))
                    held = false
                }
                detents = 0
            })
        .accessibilityIdentifier("encoder")
    }
}

/// The jog wheel: drag around the centre, one tick per 12 degrees.
struct JogView: View {
    let model: AppModel
    @State private var lastAngle: Double?
    @State private var carried = 0.0

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Circle().fill(Color(white: 0.05))
                Circle().stroke(Color(white: 0.92), lineWidth: 5).padding(14)
                    .shadow(color: .white.opacity(0.7), radius: 6)
                Circle().fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05)], center: .center, startRadius: 4, endRadius: 80))
                    .padding(24)
                Circle().fill(Color(white: 0.02)).frame(width: 34, height: 34).offset(y: -52)
                    .rotationEffect(.degrees(Double(model.console.jogTicks) * 12))
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let angle = atan2(drag.location.y - center.y, drag.location.x - center.x) * 180 / .pi
                    defer { lastAngle = angle }
                    guard let lastAngle else { return }
                    var delta = angle - lastAngle
                    if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                    carried += delta
                    while abs(carried) >= 12 {
                        model.act(.jog(clockwise: carried > 0))
                        carried += carried > 0 ? -12 : 12
                    }
                }
                .onEnded { _ in lastAngle = nil; carried = 0 })
        }
        .accessibilityIdentifier("jog")
    }
}

/// The fader. Dragging reports touch, travel and release, as a hand on the mock device would.
/// On the hardware link it only shows the reported position, or a dashed cap while that is unknown.
struct FaderView: View {
    let model: AppModel
    @State private var dragging = false
    private let travel: CGFloat = 300
    private let cap: CGFloat = 44

    var body: some View {
        let position = model.console.faderPosition
        let touched = model.console.faderTouched == true
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3).fill(.black).frame(width: 8, height: travel + cap)
            VStack(spacing: 0) {
                ForEach(0..<11, id: \.self) { _ in
                    Rectangle().fill(Palette.legend.opacity(0.6)).frame(width: 46, height: 1)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: travel).offset(y: cap / 2)
            RoundedRectangle(cornerRadius: 4)
                .fill(position == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.8)], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(touched ? Palette.amber : Color(white: 0.6),
                                                                 style: StrokeStyle(lineWidth: touched ? 2.5 : 1, dash: position == nil ? [4, 3] : [])))
                .frame(width: 34, height: cap)
                .offset(y: travel * (1 - CGFloat(position ?? 0) / 127))
        }
        .frame(height: travel + cap)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !dragging { dragging = true; model.act(.touch(true)) }
                let fraction = 1 - (drag.location.y - cap / 2) / travel
                let value = UInt8(max(0, min(127, (fraction * 127).rounded())))
                if value != model.console.faderPosition { model.act(.fader(value)) }
            }
            .onEnded { _ in dragging = false; model.act(.touch(false)) })
        .accessibilityIdentifier("fader")
    }
}
#endif
