#if os(macOS)
import ExampleParameterSets
import RobotPlugin
import SurfacePluginContracts
import SwiftUI
import XTouchOnePanel

struct ReferenceArmView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var confirmLoad = false

    private var joints: [Double]? {
        var result: [Double] = []
        for joint in 1...6 {
            let id = ParameterID(rawValue: "arm.j\(joint)")
            guard model.workspace.definition(id)?.unit == "°", let value = model.workspace.values[id] else { return nil }
            result.append(value)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionTitle("参考机械臂 · 软件姿态", icon: "point.3.connected.trianglepath.dotted")
            if let joints {
                HStack(spacing: 12) {
                    projection(joints, top: false)
                    projection(joints, top: true)
                }.frame(height: 200)
                HStack(spacing: 12) {
                    ForEach(Array(joints.enumerated()), id: \.offset) { index, degrees in
                        Text("J\(index + 1) \(degrees.formatted())°").font(.caption.monospaced())
                    }
                }
            } else {
                Button("载入参考参数…") { confirmLoad = true }.accessibilityIdentifier("arm.load")
            }
            HStack {
                if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 520)
        .confirmationDialog("在工作区加入参考机械臂参数？", isPresented: $confirmLoad) {
            Button("加入参考参数") {
                model.editWorkspace { workspace in
                    var configuration = workspace.configuration
                    let existing = Set(configuration.parameters.map(\.id))
                    configuration.parameters += try ExampleParameterSets.referenceArm().filter { !existing.contains($0.id) }
                    try workspace.apply(configuration, preserveValues: true)
                }
            }
        }
    }

    private func projection(_ degrees: [Double], top: Bool) -> some View {
        VStack {
            Text(top ? "俯视" : "侧视").font(.caption)
            Canvas { context, size in
                let radians = degrees.map { $0.truncatingRemainder(dividingBy: 360) / 180 * .pi }
                let robot = RobotModel.reference
                let transforms = (0...radians.count).map { robot.forward(Array(radians.prefix($0))) }
                let scale = min(size.width, size.height) / 1.8
                let origin = CGPoint(x: size.width / 2, y: top ? size.height / 2 : size.height * 0.8)
                let xy = transforms.map { matrix in
                    CGPoint(x: origin.x + matrix[3] * scale, y: origin.y - matrix[top ? 7 : 11] * scale)
                }
                var chain = Path()
                chain.addLines(xy)
                context.stroke(chain, with: .color(Theme.value), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                for point in xy {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.yellow))
                }
            }
        }.insetStyle()
    }
}
#endif
