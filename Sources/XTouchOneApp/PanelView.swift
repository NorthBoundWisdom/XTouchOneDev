#if os(macOS)
import SwiftUI
import XTouchOneAdapter
import XTouchOnePanel
import XTouchOneSimulator

/// The device face inside a chassis card, drawn at a fixed design size and scaled as a whole.
/// The arrangement follows the hardware: encoder and displays on top, LCD and the CHANNEL and FUNCTION
/// rows below, then the fader with its scale on the left and transport, navigation and jog wheel on the right.
struct SurfacePanelView: View {
    let model: AppModel
    static let naturalSize = CGSize(width: 600, height: 812)

    private var mock: Bool { model.link == .mock }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .center, spacing: 12) {
                EncoderCell(model: model).frame(width: 112, height: 104)
                VStack(alignment: .leading, spacing: 5) {
                    Text("UNIVERSAL CONTROL SURFACE").font(.system(size: 12, weight: .medium)).tracking(3)
                        .foregroundStyle(Color(white: 0.8))
                    SegmentDisplayView(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(alignment: .bottom, spacing: 12) {
                LCDView(model: model).frame(width: 84, height: 50)
                VStack(spacing: 1) {
                    Image(systemName: "triangle").font(.system(size: 15, weight: .light))
                    Text("behringer").font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(Color(white: 0.7)).frame(width: 60)
                Spacer(minLength: 0)
                KeyGroup(model: model, title: "CHANNEL", group: .channel)
            }
            HStack(alignment: .bottom, spacing: 12) {
                (Text("X").font(.system(size: 26, weight: .light, design: .serif)).italic()
                    + Text(" TOUCH ONE").font(.system(size: 13, weight: .semibold)).kerning(1.5))
                    .foregroundStyle(Color(white: 0.85))
                    .padding(.bottom, 10)
                Spacer(minLength: 0)
                KeyGroup(model: model, title: "FUNCTION", group: .function)
            }
            HStack(alignment: .top, spacing: 10) {
                HStack(alignment: .top, spacing: 4) {
                    FaderCell(model: model).frame(width: 92)
                    MeterView(model: model).padding(.top, 20)
                }
                .frame(width: 132, alignment: .leading)
                VStack(alignment: .trailing, spacing: 10) {
                    KeyGroup(model: model, title: "TRANSPORT", group: .transportModes)
                    HStack(spacing: 6) {
                        ForEach(XTouchOnePanelLayout.keys(in: .transport)) { key in
                            TransportKey(model: model, key: key, symbol: Self.transportSymbols[key.label] ?? "circle")
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        VStack(spacing: 16) {
                            BankView(model: model)
                            NavigationCluster(model: model)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if let scrub = XTouchOnePanelLayout.keys(in: .scrub).first {
                                KeyCell(model: model, key: scrub)
                            }
                            JogCell(model: model).frame(width: 232, height: 250)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 18)
        .frame(width: Self.naturalSize.width, height: Self.naturalSize.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Theme.chassisTop, Theme.chassisBottom], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(mock ? "MOCK DEVICE" : "HARDWARE MIRROR")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(mock ? Theme.value : .green)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background((mock ? Theme.value : Color.green).opacity(0.14), in: Capsule())
            Spacer()
            Text(mock ? "拖动推子 / 旋钮、按下按键 = 模拟实体操作" : "≈ 最近的输入 · — 尚未报告")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    static let transportSymbols = ["REW": "backward.fill", "FWD": "forward.fill", "STOP": "stop.fill",
                                   "PLAY": "play.fill", "RECORD": "circle.fill"]
}

private func selectionStroke(_ selected: Bool, radius: CGFloat = 5) -> some View {
    RoundedRectangle(cornerRadius: radius)
        .stroke(selected ? Theme.selection : Color.black.opacity(0.5), lineWidth: selected ? 1.5 : 1)
}

struct KeyGroup: View {
    let model: AppModel
    let title: String
    let group: XTouchOnePanelGroup

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 9.5, weight: .bold)).tracking(1.2).foregroundStyle(Color(white: 0.85))
            HStack(alignment: .top, spacing: 5) {
                ForEach(XTouchOnePanelLayout.keys(in: group)) { KeyCell(model: model, key: $0) }
            }
        }
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 5)
        .background(Theme.slot.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Press, release, selection and the light menu shared by every key shape.
private struct KeyBehavior: ViewModifier {
    let model: AppModel
    let key: XTouchOnePanelKey
    @Binding var pressing: Bool

    func body(content: Content) -> some View {
        let light = model.console.shown.buttonLEDs[key.address] ?? .off
        content
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    model.selection = .key(key.address)
                    model.act(.button(key.address, pressed: true))
                }
                .onEnded { _ in
                    pressing = false
                    model.act(.button(key.address, pressed: false))
                })
            .contextMenu {
                ForEach([("熄灭", XTouchOneButtonLED.off), ("点亮", .on), ("闪烁", .flash)], id: \.0) { name, state in
                    Button(name) { model.show(.buttonLED(key.button, state)) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("button.\(key.address)")
            .accessibilityLabel("B\(key.address) \(model.controlLabel(key.button.elementID)?.name ?? key.label)")
            .accessibilityValue(light == .on ? "点亮" : light == .flash ? "闪烁" : "熄灭")
            .accessibilityAddTraits(.isButton)
            .help("操作 B\(key.address) · \(key.label)")
    }
}

/// A translucent square cap that glows in its own colour, with the legend printed underneath.
struct KeyCell: View {
    let model: AppModel
    let key: XTouchOnePanelKey
    var size = CGSize(width: 34, height: 30)
    var legend: String?
    var showsLegend = true
    @State private var pressing = false

    private var light: XTouchOneButtonLED { model.console.shown.buttonLEDs[key.address] ?? .off }
    private var lit: Bool { light == .on || (light == .flash && model.blink) }
    private var down: Bool { pressing || model.console.pressed.contains(key.button.elementID) }

    var body: some View {
        let color = Theme.led(key.light)
        let label = model.controlLabel(key.button.elementID)
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 6)
                .fill(lit ? AnyShapeStyle(RadialGradient(colors: [.white, color], center: .center, startRadius: 1, endRadius: 22))
                    : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.42)], startPoint: .top, endPoint: .bottom)))
                .shadow(color: lit ? color.opacity(0.85) : .clear, radius: 7)
                .overlay { selectionStroke(model.selection == .key(key.address), radius: 6) }
                .overlay(alignment: .bottomLeading) {
                    if let tag = label?.color { Circle().fill(tag.color).frame(width: 5, height: 5).padding(3) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if model.showAddresses {
                        Text("\(key.address)").font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.7)).padding(2)
                    }
                }
                .frame(width: size.width, height: size.height)
                .brightness(down ? -0.2 : 0)
                .scaleEffect(down ? 0.94 : 1)
            if showsLegend {
                Text(label?.name ?? legend ?? key.label).font(.system(size: 7, weight: .semibold)).foregroundStyle(Color(white: 0.85))
                    .lineLimit(1).frame(width: size.width + 12)
            }
        }
        .modifier(KeyBehavior(model: model, key: key, pressing: $pressing))
        .opacity(model.panelOpacity(for: key.button.elementID))
    }
}

/// The wide dark transport keys, lit through their symbol.
struct TransportKey: View {
    let model: AppModel
    let key: XTouchOnePanelKey
    let symbol: String
    @State private var pressing = false

    var body: some View {
        let light = model.console.shown.buttonLEDs[key.address] ?? .off
        let lit = light == .on || (light == .flash && model.blink)
        let down = pressing || model.console.pressed.contains(key.button.elementID)
        let color = Theme.led(key.light)
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(lit ? color : Color(white: 0.45))
                    .shadow(color: lit ? color.opacity(0.9) : .clear, radius: 6)
            }
            .overlay { selectionStroke(model.selection == .key(key.address), radius: 6) }
            .overlay(alignment: .bottomTrailing) {
                if model.showAddresses {
                    Text("\(key.address)").font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(white: 0.6)).padding(3)
                }
            }
            .frame(width: 73, height: 38)
            .brightness(down ? 0.12 : 0)
            .scaleEffect(down ? 0.96 : 1)
            .modifier(KeyBehavior(model: model, key: key, pressing: $pressing))
            .opacity(model.panelOpacity(for: key.button.elementID))
    }
}

struct BankView: View {
    let model: AppModel
    var body: some View {
        let keys = XTouchOnePanelLayout.keys(in: .bank)
        VStack(spacing: 4) {
            Text("FADER BANK").font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundStyle(Color(white: 0.85))
            pair(keys[0], keys[1])
            Text("CHANNEL").font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundStyle(Color(white: 0.85))
            pair(keys[2], keys[3])
        }
        .padding(8)
        .background(Theme.slot.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pair(_ left: XTouchOnePanelKey, _ right: XTouchOnePanelKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrowtriangle.left.fill").font(.system(size: 7)).foregroundStyle(Color(white: 0.8))
            KeyCell(model: model, key: left, size: CGSize(width: 36, height: 32), showsLegend: false)
            KeyCell(model: model, key: right, size: CGSize(width: 36, height: 32), showsLegend: false)
            Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7)).foregroundStyle(Color(white: 0.8))
        }
    }
}

struct NavigationCluster: View {
    let model: AppModel
    var body: some View {
        let keys = Dictionary(uniqueKeysWithValues: XTouchOnePanelLayout.keys(in: .navigation).map { ($0.label, $0) })
        let size = CGSize(width: 34, height: 34)
        let arrow = { (name: String) in Image(systemName: name).font(.system(size: 7)).foregroundStyle(Color(white: 0.8)) }
        VStack(spacing: 4) {
            arrow("arrowtriangle.up.fill")
            KeyCell(model: model, key: keys["UP"]!, size: size, showsLegend: false)
            HStack(spacing: 4) {
                arrow("arrowtriangle.left.fill")
                KeyCell(model: model, key: keys["LEFT"]!, size: size, showsLegend: false)
                KeyCell(model: model, key: keys["ZOOM"]!, size: size, showsLegend: false)
                KeyCell(model: model, key: keys["RIGHT"]!, size: size, showsLegend: false)
                arrow("arrowtriangle.right.fill")
            }
            KeyCell(model: model, key: keys["DOWN"]!, size: size, showsLegend: false)
            arrow("arrowtriangle.down.fill")
        }
    }
}

/// Twelve seven-segment digits with dots, drawn from the masks last sent, with the printed legends:
/// two assignment digits, then the 3 + 2 + 2 + 3 counter fields.
struct SegmentDisplayView: View {
    let model: AppModel
    private static let fields: [(upper: String, lower: String, digits: Range<Int>)] = [
        ("", "ASSIGNMENT", 0..<2), ("HOURS", "BARS", 2..<5), ("MINUTES", "BEATS", 5..<7),
        ("SECONDS", "SUB DIVISION", 7..<9), ("FRAMES", "TICKS", 9..<12),
    ]

    var body: some View {
        let device = model.console.shown
        let masks = device.segments ?? Array(repeating: 0, count: 12)
        let dots = device.segmentDots ?? [0, 0]
        HStack(alignment: .top, spacing: 7) {
            ForEach(Self.fields, id: \.lower) { field in
                VStack(spacing: 2) {
                    Text(field.upper.isEmpty ? " " : field.upper).font(.system(size: 6.5, weight: .semibold))
                        .foregroundStyle(Color(white: 0.7))
                    HStack(spacing: 3) {
                        ForEach(Array(field.digits), id: \.self) { index in
                            let dot = index < 7 ? dots[0] >> UInt8(index) & 1 : dots[1] >> UInt8(index - 7) & 1
                            SegmentDigit(mask: masks[index], dot: dot == 1).frame(width: 21, height: 32)
                        }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 5)
                    .background(Color(red: 0.16, green: 0.09, blue: 0.02), in: RoundedRectangle(cornerRadius: 3))
                    Text(field.lower).font(.system(size: 6.5, weight: .bold)).foregroundStyle(.black)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity).padding(.vertical, 1)
                        .background(Color(white: 0.62), in: RoundedRectangle(cornerRadius: 2))
                }
                .fixedSize(horizontal: true, vertical: false)
                if field.lower == "ASSIGNMENT" {
                    Text("SOLO").font(.system(size: 6.5, weight: .semibold)).foregroundStyle(Color(white: 0.7))
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.black, in: RoundedRectangle(cornerRadius: 6))
        .overlay { selectionStroke(model.selection == .segments, radius: 6) }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .segments }
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
                context.fill(Path(roundedRect: bar, cornerRadius: t / 2), with: .color(on ? Theme.ring : Theme.ring.opacity(0.07)))
            }
            let point = CGRect(x: size.width - t, y: h - t, width: t, height: t)
            context.fill(Path(ellipseIn: point), with: .color(dot ? Theme.ring : Theme.ring.opacity(0.07)))
        }
    }
}

struct LCDView: View {
    let model: AppModel

    var body: some View {
        let lcd = model.console.shown.lcd
        let color = lcd.map { Theme.lcd($0.color) } ?? Color(white: 0.16)
        let ink = lcd?.color == .black ? Color(white: 0.75) : Color(white: 0.06)
        VStack(spacing: 0) {
            line(lcd?.upper ?? "", inverted: lcd?.invertUpper ?? false, color: color, ink: ink)
            line(lcd?.lower ?? "", inverted: lcd?.invertLower ?? false, color: color, ink: ink)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { selectionStroke(model.selection == .lcd, radius: 5) }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .lcd }
        .accessibilityIdentifier("lcd")
    }

    private func line(_ text: String, inverted: Bool, color: Color, ink: Color) -> some View {
        Text(text.padding(toLength: 7, withPad: " ", startingAt: 0))
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(inverted ? color : ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(inverted ? ink : color)
    }
}

/// Eight meter LEDs between the printed CLIP and SIG marks.
struct MeterView: View {
    let model: AppModel

    var body: some View {
        let lit = Int((Double(model.console.shown.meter ?? 0) / 127 * 8).rounded())
        HStack(alignment: .center, spacing: 3) {
            VStack {
                Text("CLIP")
                Spacer()
                Text("SIG")
            }
            .font(.system(size: 6.5, weight: .semibold)).foregroundStyle(Color(white: 0.75))
            VStack(spacing: 5) {
                ForEach((0..<8).reversed(), id: \.self) { index in
                    let color: Color = index == 7 ? .red : index >= 5 ? Theme.ring : .green
                    RoundedRectangle(cornerRadius: 1.5).fill(index < lit ? color : Theme.ledOff).frame(width: 5, height: 11)
                        .shadow(color: index < lit ? color.opacity(0.9) : .clear, radius: 3)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 5)
            .background(.black, in: RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 140)
        .overlay { if model.selection == .meter { selectionStroke(true, radius: 4).padding(-3) } }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .meter }
        .accessibilityIdentifier("meter")
    }
}

/// The push encoder in its well with a ring of thirteen LED bars. Drag up or down to turn,
/// one detent per 9 points; click without moving to push (address 0).
struct EncoderCell: View {
    let model: AppModel
    @State private var detents = 0
    @State private var pushing = false
    private var push: XTouchOnePanelKey? { XTouchOnePanelLayout.keys(in: .encoder).first }

    var body: some View {
        let ring = model.console.shown.encoderRing
        let lit = ring.map { Int((Double($0) / 127 * 12).rounded()) } ?? -1
        let down = pushing || (push.map { model.console.pressed.contains($0.button.elementID) } ?? false)
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Theme.slot.opacity(0.6))
            ForEach(0..<13, id: \.self) { index in
                Capsule().fill(index <= lit ? Theme.ring : Theme.ring.opacity(0.1)).frame(width: 3.5, height: 11)
                    .shadow(color: index <= lit ? Theme.ring.opacity(0.9) : .clear, radius: 3)
                    .offset(y: -36)
                    .rotationEffect(.degrees(-135 + 270 * Double(index) / 12))
            }
            Circle().fill(Color(white: 0.04)).frame(width: 58, height: 58)
            Circle().fill(AngularGradient(colors: [Color(white: 0.3), Color(white: 0.1), Color(white: 0.3), Color(white: 0.1), Color(white: 0.3)], center: .center))
                .frame(width: 48, height: 48)
                .scaleEffect(down ? 0.93 : 1)
            Capsule().fill(Color(white: 0.9)).frame(width: 2.5, height: 12).offset(y: -15)
                .rotationEffect(.degrees(Double(model.console.encoderTicks) * 12))
            if model.showAddresses, let push {
                Text("\(push.address)").font(.system(size: 7.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color(white: 0.6))
            }
            Text(ring.map { String($0) } ?? "—").font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.value)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
        }
        .overlay { selectionStroke(model.selection == .encoder, radius: 14) }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                model.selection = .encoder
                let target = Int((-drag.translation.height / 9).rounded(.towardZero))
                if target != 0, pushing, let push { pushing = false; model.act(.button(push.address, pressed: false)) }
                if target == 0, detents == 0, !pushing, abs(drag.translation.height) < 2, let push {
                    pushing = true
                    model.act(.button(push.address, pressed: true))
                }
                while detents != target {
                    let clockwise = target > detents
                    detents += clockwise ? 1 : -1
                    model.act(.encoder(clockwise: clockwise))
                }
            }
            .onEnded { _ in
                if pushing, let push { model.act(.button(push.address, pressed: false)) }
                pushing = false
                detents = 0
            })
        .help("上下拖动转动编码器，原地点按是按压")
        .accessibilityIdentifier("encoder")
        .modifier(ControlMark(model: model, id: "encoder.turn"))
    }
}

/// The jog wheel with its illuminated ring and finger dimple: drag around the centre, one tick per 12 degrees.
struct JogCell: View {
    let model: AppModel
    @State private var lastAngle: Double?
    @State private var carried = 0.0

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Circle().fill(Color(white: 0.05))
                    Circle().stroke(Color(white: 0.16), lineWidth: 10).padding(5)
                    Circle().stroke(Color.white, lineWidth: 5).padding(22).shadow(color: .white.opacity(0.75), radius: 7)
                    Circle().fill(RadialGradient(colors: [Color(white: 0.17), Color(white: 0.05)], center: .center, startRadius: 4, endRadius: 90))
                        .padding(28)
                    Circle().fill(RadialGradient(colors: [Color(white: 0.02), Color(white: 0.2)], center: .center, startRadius: 4, endRadius: 22))
                        .frame(width: 40, height: 40).offset(y: -44)
                        .rotationEffect(.degrees(Double(model.console.jogTicks) * 12))
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        model.selection = .jog
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
                .onTapGesture { model.selection = .jog }
            }
            .aspectRatio(1, contentMode: .fit)
            Text("\(model.console.jogTicks)").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Theme.value)
        }
        .overlay { if model.selection == .jog { selectionStroke(true, radius: 8).padding(-2) } }
        .help("绕圆心拖动转动拨轮")
        .accessibilityIdentifier("jog")
        .modifier(ControlMark(model: model, id: "jog"))
    }
}

/// The 100 mm motor fader with its printed dB scale. Dragging reports touch, travel and release,
/// as a hand on the mock device would. A deliberate hardware drag stages one target to send on release.
struct FaderCell: View {
    let model: AppModel
    @State private var dragging = false
    @State private var dragScope: AppModel.FaderSendScope?
    @State private var stagedTarget: UInt8?
    private let travel: CGFloat = 330
    private let cap: CGFloat = 52
    /// Printed marks and where they sit along the travel, top to bottom.
    private static let marks: [(String, CGFloat)] = [
        ("10", 0), ("5", 0.115), ("0", 0.23), ("5", 0.345), ("10", 0.46), ("20", 0.575), ("30", 0.675),
        ("40", 0.765), ("50", 0.845), ("60", 0.92), ("∞", 1),
    ]

    var body: some View {
        let position = model.console.faderPosition
        let touched = model.console.faderTouched == true
        let preview = dragScope != nil && dragScope == model.hardwareFaderSendScope ? stagedTarget : nil
        let displayed = preview ?? position
        let offset = travel * (1 - CGFloat(displayed ?? 0) / 127)
        VStack(spacing: 3) {
            ZStack(alignment: .top) {
                scale
                RoundedRectangle(cornerRadius: 2).fill(.black).frame(width: 6, height: travel + cap)
                capView(known: position != nil && preview == nil, touched: touched).offset(y: offset)
            }
            .frame(width: 92, height: travel + cap)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        model.selection = .fader
                        dragScope = model.hardwareFaderSendScope
                        if model.link == .mock { model.act(.touch(true)) }
                    }
                    let fraction = 1 - (drag.location.y - cap / 2) / travel
                    let value = UInt8(max(0, min(127, (fraction * 127).rounded())))
                    if model.link == .mock, value != model.console.faderPosition { model.act(.fader(value)) }
                    if let dragScope, model.hardwareFaderSendScope == dragScope, abs(drag.translation.height) >= 2 {
                        stagedTarget = value
                    }
                }
                .onEnded { _ in
                    if model.link == .mock { model.act(.touch(false)) }
                    if let dragScope, let stagedTarget, model.hardwareFaderSendScope == dragScope,
                       stagedTarget != model.console.faderPosition {
                        model.sendFaderPosition(stagedTarget)
                    }
                    dragging = false
                    dragScope = nil
                    stagedTarget = nil
                })
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").font(.system(size: 8)).foregroundStyle(Theme.touch)
                    .opacity(touched ? 1 : 0)
                    .accessibilityHidden(!touched)
                Text(position.map { String($0) } ?? "—").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(touched ? Theme.touch : Theme.value)
            }
        }
        .overlay { if model.selection == .fader { selectionStroke(true, radius: 8).padding(-3) } }
        .help(model.link == .mock ? "拖动模拟推子" : "拖动后松手，发送一次目标位置")
        .accessibilityIdentifier("fader")
        .modifier(ControlMark(model: model, id: "fader"))
    }

    /// Long ticks with numbers on the left of the slot, fine ticks between them on both sides.
    private var scale: some View {
        Canvas { context, size in
            let middle = size.width / 2, top = cap / 2
            let ink = GraphicsContext.Shading.color(Color(white: 0.82))
            for (index, mark) in Self.marks.enumerated() {
                let y = top + travel * mark.1
                for side: CGFloat in [-1, 1] {
                    context.fill(Path(CGRect(x: middle + side * 8 - (side < 0 ? 16 : 0), y: y - 0.5, width: 16, height: 1)), with: ink)
                }
                context.draw(Text(mark.0).font(.system(size: 7.5, weight: .medium)).foregroundColor(Color(white: 0.82)),
                             at: CGPoint(x: middle - 33, y: y), anchor: .center)
                guard index + 1 < Self.marks.count else { continue }
                let next = top + travel * Self.marks[index + 1].1
                for step in 1..<4 {
                    let minor = y + (next - y) * CGFloat(step) / 4
                    for side: CGFloat in [-1, 1] {
                        context.fill(Path(CGRect(x: middle + side * 8 - (side < 0 ? 9 : 0), y: minor - 0.25, width: 9, height: 0.5)),
                                     with: .color(Color(white: 0.55)))
                    }
                }
            }
        }
        .frame(width: 92, height: travel + cap)
    }

    /// A metallic cap with a centre line; dashed and hollow while the position is unknown.
    private func capView(known: Bool, touched: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(known ? AnyShapeStyle(LinearGradient(stops: [
                .init(color: Color(white: 0.95), location: 0), .init(color: Color(white: 0.6), location: 0.3),
                .init(color: Color(white: 0.92), location: 0.5), .init(color: Color(white: 0.5), location: 0.75),
                .init(color: Color(white: 0.8), location: 1),
            ], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.clear))
            .overlay { Rectangle().fill(Color.black.opacity(known ? 0.55 : 0)).frame(height: 1.5) }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(touched ? Theme.touch : Color(white: known ? 0.25 : 0.7),
                            style: StrokeStyle(lineWidth: touched ? 2.5 : 1, dash: known ? [] : [4, 3]))
            }
            .shadow(color: .black.opacity(known ? 0.6 : 0), radius: 3, y: 2)
            .frame(width: 30, height: cap)
    }
}

private struct ControlMark: ViewModifier {
    let model: AppModel
    let id: String

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let tag = model.controlLabel(id)?.color {
                Circle().fill(tag.color).frame(width: 6, height: 6).padding(3).allowsHitTesting(false)
            }
        }
        .opacity(model.panelOpacity(for: id))
    }
}
#endif
