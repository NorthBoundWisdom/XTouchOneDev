#if os(macOS)
import SwiftUI
import XTouchOneAdapter
import XTouchOnePanel
import XTouchOneSimulator

/// The device face inside a chassis card, drawn at a fixed design size and scaled as a whole.
struct SurfacePanelView: View {
    let model: AppModel
    static let naturalSize = CGSize(width: 600, height: 692)

    private var mock: Bool { model.link == .mock }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 14) {
                EncoderCell(model: model).frame(width: 104)
                VStack(alignment: .trailing, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UNIVERSAL CONTROL SURFACE").font(.system(size: 10, weight: .bold)).tracking(2.4)
                            .foregroundStyle(.secondary)
                        SegmentDisplayView(model: model)
                    }
                    KeyGroup(model: model, title: "CHANNEL", group: .channel)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    LCDView(model: model).frame(width: 104, height: 58)
                    HStack(alignment: .top, spacing: 10) {
                        FaderCell(model: model).frame(width: 72)
                        MeterView(model: model).padding(.top, 14)
                    }
                }
                .frame(width: 104)
                VStack(alignment: .trailing, spacing: 12) {
                    KeyGroup(model: model, title: "FUNCTION", group: .function)
                    KeyGroup(model: model, title: "TRANSPORT", group: .transportModes)
                    HStack(spacing: 6) {
                        ForEach(XTouchOnePanelLayout.keys(in: .transport)) { key in
                            KeyCell(model: model, key: key, width: 76, symbol: Self.transportSymbols[key.label])
                        }
                    }
                    HStack(alignment: .center, spacing: 12) {
                        BankView(model: model)
                        NavigationCluster(model: model)
                        VStack(alignment: .trailing, spacing: 6) {
                            if let scrub = XTouchOnePanelLayout.keys(in: .scrub).first {
                                KeyCell(model: model, key: scrub, width: 62)
                            }
                            JogCell(model: model).frame(width: 176, height: 198)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(18)
        .frame(width: Self.naturalSize.width, height: Self.naturalSize.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Theme.chassisTop, Theme.chassisBottom], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        }
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("X-TOUCH ONE").font(.system(size: 17, weight: .black, design: .rounded)).tracking(2)
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
                                   "PLAY": "play.fill", "RECORD": "record.circle"]
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
        VStack(spacing: 5) {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(XTouchOnePanelLayout.keys(in: group)) { KeyCell(model: model, key: $0, width: 54) }
            }
        }
        .padding(8)
        .background(Theme.slot.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One key, in the same cell style as the other consoles: an LED bar or symbol over a small label.
struct KeyCell: View {
    let model: AppModel
    let key: XTouchOnePanelKey
    var width: CGFloat
    var symbol: String?
    var compactLabel: String?
    @State private var pressing = false

    private var light: XTouchOneButtonLED { model.console.shown.buttonLEDs[key.address] ?? .off }
    private var lit: Bool { light == .on || (light == .flash && model.blink) }
    private var down: Bool { model.console.pressed.contains(key.button.elementID) }
    private var selected: Bool { model.selection == .key(key.address) }

    var body: some View {
        let color = Theme.led(key.light)
        RoundedRectangle(cornerRadius: 5)
            .fill(LinearGradient(colors: [Color(white: lit ? 0.3 : 0.24), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
            .overlay {
                VStack(spacing: 2) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                            .foregroundStyle(lit ? color : Color.secondary)
                            .shadow(color: lit ? color.opacity(0.9) : .clear, radius: 4)
                    } else {
                        Capsule().fill(lit ? color : Theme.ledOff).frame(width: min(22, width - 14), height: 4)
                            .shadow(color: lit ? color.opacity(0.9) : .clear, radius: 4)
                    }
                    Text(compactLabel ?? key.label).font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(lit ? Color.primary : Color.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    if model.showAddresses {
                        Text("B\(key.address)").font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                    }
                }
                .padding(.horizontal, 2)
            }
            .overlay { selectionStroke(selected) }
            .frame(width: width, height: 38)
            .scaleEffect(down || pressing ? 0.95 : 1)
            .brightness(down ? 0.12 : 0)
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
            .accessibilityLabel("B\(key.address) \(key.label)")
            .accessibilityValue(light == .on ? "点亮" : light == .flash ? "闪烁" : "熄灭")
            .accessibilityAddTraits(.isButton)
            .help("操作 B\(key.address) · \(key.label)")
    }
}

struct BankView: View {
    let model: AppModel
    var body: some View {
        let keys = XTouchOnePanelLayout.keys(in: .bank)
        VStack(spacing: 5) {
            Text("FADER BANK").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                KeyCell(model: model, key: keys[0], width: 46, symbol: "arrowtriangle.left.fill", compactLabel: "BANK")
                KeyCell(model: model, key: keys[1], width: 46, symbol: "arrowtriangle.right.fill", compactLabel: "BANK")
            }
            Text("CHANNEL").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                KeyCell(model: model, key: keys[2], width: 46, symbol: "arrowtriangle.left.fill", compactLabel: "CH")
                KeyCell(model: model, key: keys[3], width: 46, symbol: "arrowtriangle.right.fill", compactLabel: "CH")
            }
        }
        .padding(8)
        .background(Theme.slot.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NavigationCluster: View {
    let model: AppModel
    var body: some View {
        let keys = Dictionary(uniqueKeysWithValues: XTouchOnePanelLayout.keys(in: .navigation).map { ($0.label, $0) })
        VStack(spacing: 4) {
            KeyCell(model: model, key: keys["UP"]!, width: 38, symbol: "arrowtriangle.up.fill")
            HStack(spacing: 4) {
                KeyCell(model: model, key: keys["LEFT"]!, width: 38, symbol: "arrowtriangle.left.fill")
                KeyCell(model: model, key: keys["ZOOM"]!, width: 38)
                KeyCell(model: model, key: keys["RIGHT"]!, width: 38, symbol: "arrowtriangle.right.fill")
            }
            KeyCell(model: model, key: keys["DOWN"]!, width: 38, symbol: "arrowtriangle.down.fill")
        }
    }
}

/// Twelve seven-segment digits with dots, drawn from the masks last sent.
struct SegmentDisplayView: View {
    let model: AppModel

    var body: some View {
        let device = model.console.shown
        let masks = device.segments ?? Array(repeating: 0, count: 12)
        let dots = device.segmentDots ?? [0, 0]
        HStack(spacing: 5) {
            ForEach(0..<12, id: \.self) { index in
                let dot = index < 7 ? dots[0] >> UInt8(index) & 1 : dots[1] >> UInt8(index - 7) & 1
                SegmentDigit(mask: masks[index], dot: dot == 1).frame(width: 22, height: 36)
                if index == 1 { Spacer().frame(width: 16) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
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
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .foregroundStyle(inverted ? color : ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(inverted ? ink : color)
    }
}

struct MeterView: View {
    let model: AppModel

    var body: some View {
        let lit = Int((Double(model.console.shown.meter ?? 0) / 127 * 8).rounded())
        VStack(spacing: 4) {
            ForEach((0..<8).reversed(), id: \.self) { index in
                let color: Color = index == 7 ? .red : index >= 5 ? Theme.ring : .green
                RoundedRectangle(cornerRadius: 1.5).fill(index < lit ? color : Theme.ledOff).frame(width: 7, height: 12)
                    .shadow(color: index < lit ? color.opacity(0.8) : .clear, radius: 2)
            }
        }
        .padding(5)
        .background(Theme.slot, in: RoundedRectangle(cornerRadius: 4))
        .overlay { selectionStroke(model.selection == .meter, radius: 4) }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .meter }
        .accessibilityIdentifier("meter")
    }
}

/// The encoder cell: a ring of LEDs, a knob, the last ring value, and its push key.
/// Drag up or down to turn, one detent per 9 points.
struct EncoderCell: View {
    let model: AppModel
    @State private var detents = 0
    private var push: XTouchOnePanelKey? { XTouchOnePanelLayout.keys(in: .encoder).first }

    var body: some View {
        let ring = model.console.shown.encoderRing
        let lit = ring.map { Int((Double($0) / 127 * 12).rounded()) } ?? -1
        VStack(spacing: 4) {
            ZStack {
                ForEach(0..<13, id: \.self) { index in
                    Circle().fill(index <= lit ? Theme.ring : Theme.ledOff).frame(width: 4, height: 4)
                        .shadow(color: index <= lit ? Theme.ring.opacity(0.8) : .clear, radius: 2)
                        .offset(y: -26)
                        .rotationEffect(.degrees(-135 + 270 * Double(index) / 12))
                }
                Circle().fill(RadialGradient(colors: [Color(white: 0.32), Color(white: 0.1)], center: .center, startRadius: 2, endRadius: 22))
                    .frame(width: 40, height: 40)
                Capsule().fill(Color(white: 0.85)).frame(width: 2.5, height: 12).offset(y: -12)
                    .rotationEffect(.degrees(Double(model.console.encoderTicks) * 12))
            }
            .frame(width: 62, height: 60)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    model.selection = .encoder
                    let target = Int((-drag.translation.height / 9).rounded(.towardZero))
                    while detents != target {
                        let clockwise = target > detents
                        detents += clockwise ? 1 : -1
                        model.act(.encoder(clockwise: clockwise))
                    }
                }
                .onEnded { _ in detents = 0 })
            .help("上下拖动转动编码器")
            Text("Encoder").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.value)
            Text(ring.map { String($0) } ?? "—").font(.system(size: 11, weight: .medium, design: .monospaced))
            if let push { KeyCell(model: model, key: push, width: 62, compactLabel: "PUSH") }
        }
        .padding(6)
        .background(Theme.slot.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay { selectionStroke(model.selection == .encoder, radius: 8) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("encoder")
    }
}

/// The jog wheel: drag around the centre, one tick per 12 degrees.
struct JogCell: View {
    let model: AppModel
    @State private var lastAngle: Double?
    @State private var carried = 0.0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Circle().fill(Theme.slot)
                    Circle().stroke(Color(white: 0.85), lineWidth: 3).padding(10).shadow(color: .white.opacity(0.5), radius: 5)
                    Circle().fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.07)], center: .center, startRadius: 4, endRadius: 80))
                        .padding(18)
                    Circle().fill(Color(white: 0.03)).frame(width: 30, height: 30).offset(y: -48)
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
            HStack(spacing: 6) {
                Text("Jog").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.value)
                Text("\(model.console.jogTicks)").font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .overlay { if model.selection == .jog { selectionStroke(true, radius: 8).padding(-4) } }
        .help("绕圆心拖动转动拨轮")
        .accessibilityIdentifier("jog")
    }
}

/// The fader cell. Dragging reports touch, travel and release, as a hand on the mock device would.
/// On hardware it mirrors the reported position, or shows a dashed cap while that is unknown.
struct FaderCell: View {
    let model: AppModel
    @State private var dragging = false
    private let travel: CGFloat = 270
    private let cap: CGFloat = 34

    var body: some View {
        let position = model.console.faderPosition
        let touched = model.console.faderTouched == true
        let selected = model.selection == .fader
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.slot).frame(width: 7, height: travel + cap)
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { index in
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 30, height: 1)
                        if index < 5 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: travel).offset(y: cap / 2)
                RoundedRectangle(cornerRadius: 4)
                    .fill(position == nil ? AnyShapeStyle(Color.clear)
                        : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)))
                    .overlay { Rectangle().fill(Color.white.opacity(position == nil ? 0 : 0.85)).frame(height: 2) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(touched ? Theme.touch : Color.white.opacity(0.25),
                                    style: StrokeStyle(lineWidth: touched ? 2 : 1, dash: position == nil ? [4, 3] : []))
                    }
                    .frame(width: 44, height: cap)
                    .offset(y: travel * (1 - CGFloat(position ?? 0) / 127))
                if touched {
                    Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(Theme.touch)
                        .offset(x: 30, y: travel * (1 - CGFloat(position ?? 0) / 127) + cap / 2 - 5)
                }
            }
            .frame(height: travel + cap)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging { dragging = true; model.selection = .fader; model.act(.touch(true)) }
                    let fraction = 1 - (drag.location.y - cap / 2) / travel
                    let value = UInt8(max(0, min(127, (fraction * 127).rounded())))
                    if value != model.console.faderPosition { model.act(.fader(value)) }
                }
                .onEnded { _ in dragging = false; model.act(.touch(false)) })
            Text("Fader").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.value)
            Text(position.map { String($0) } ?? "—").font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(selected ? Theme.selection.opacity(0.12) : Theme.slot.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(touched ? Theme.touch : selected ? Theme.selection : Color.clear, lineWidth: 1.5) }
        .help("拖动推子：触摸、移动、松手")
        .accessibilityIdentifier("fader")
    }
}
#endif
