import SwiftUI
import UIKit

/// 添加形状弹窗（看齐 iOS 备忘录几何形状工具）
struct AddShapeSheet: View {
    let onCommit: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedShape: ShapeKind = .roundedRect
    @State private var strokeColorHex: String = "#000000"
    @State private var strokeWidth: CGFloat = 4
    @State private var fillType: FillKind = .none
    @State private var fillColorHex: String = "#FFCC00"

    enum ShapeKind: String, CaseIterable, Identifiable {
        case roundedRect = "圆角矩形"
        case rectangle = "矩形"
        case circle = "圆形"
        case star = "五角星"
        case bubble = "气泡"
        case arrow = "箭头"
        case heart = "爱心"
        case triangle = "三角形"
        case line = "直线"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .roundedRect: return "rectangle.roundedtop"
            case .rectangle: return "rectangle"
            case .circle: return "circle"
            case .star: return "star"
            case .bubble: return "bubble.left"
            case .arrow: return "arrow.right"
            case .heart: return "heart"
            case .triangle: return "triangle"
            case .line: return "line.diagonal"
            }
        }
    }

    enum FillKind: String, CaseIterable, Identifiable {
        case none = "无填充"
        case translucent = "半透明"
        case solid = "纯色"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("预览") {
                    HStack {
                        Spacer()
                        ShapePreviewView(
                            shape: selectedShape,
                            strokeColor: Color(hex: strokeColorHex),
                            strokeWidth: strokeWidth,
                            fillType: fillType,
                            fillColor: Color(hex: fillColorHex)
                        )
                        .frame(width: 140, height: 140)
                        .padding(.vertical, 8)
                        Spacer()
                    }
                }

                Section("形状类型") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                        ForEach(ShapeKind.allCases) { shape in
                            Button {
                                selectedShape = shape
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: shape.icon)
                                        .font(.system(size: 24))
                                    Text(shape.rawValue)
                                        .font(.system(size: 11))
                                }
                                .frame(width: 64, height: 60)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selectedShape == shape ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(selectedShape == shape ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("描边样式") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("线宽")
                            Spacer()
                            Text("\(Int(strokeWidth)) pt").foregroundStyle(.secondary)
                        }
                        Picker("线宽级别", selection: $strokeWidth) {
                            Text("细 (2pt)").tag(CGFloat(2))
                            Text("中 (4pt)").tag(CGFloat(4))
                            Text("粗 (8pt)").tag(CGFloat(8))
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("描边颜色")
                        PencilColorPaletteView(selectedHex: strokeColorHex) { hex in
                            strokeColorHex = hex
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("填充样式") {
                    Picker("填充模式", selection: $fillType) {
                        ForEach(FillKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    if fillType != .none {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("填充颜色")
                            PencilColorPaletteView(selectedHex: fillColorHex) { hex in
                                fillColorHex = hex
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("添加形状")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加到画布") {
                        commitShape()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func commitShape() {
        let size = CGSize(width: 260, height: 260)
        let strokeColor = UIColor(hex: strokeColorHex) ?? .black
        let baseFill = UIColor(hex: fillColorHex) ?? .yellow

        let actualFillColor: UIColor?
        switch fillType {
        case .none: actualFillColor = nil
        case .translucent: actualFillColor = baseFill.withAlphaComponent(0.35)
        case .solid: actualFillColor = baseFill
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let inset = strokeWidth / 2 + 8
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let path = makePath(for: selectedShape, in: rect)
            path.lineWidth = strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            if let fill = actualFillColor {
                fill.setFill()
                path.fill()
            }
            strokeColor.setStroke()
            path.stroke()
        }

        if let data = image.pngData() {
            onCommit(data)
            dismiss()
        }
    }

    private func makePath(for kind: ShapeKind, in rect: CGRect) -> UIBezierPath {
        switch kind {
        case .roundedRect:
            return UIBezierPath(roundedRect: rect, cornerRadius: 20)
        case .rectangle:
            return UIBezierPath(rect: rect)
        case .circle:
            return UIBezierPath(ovalIn: rect)
        case .star:
            return starPath(in: rect)
        case .bubble:
            return bubblePath(in: rect)
        case .arrow:
            return arrowPath(in: rect)
        case .heart:
            return heartPath(in: rect)
        case .triangle:
            return trianglePath(in: rect)
        case .line:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }

    private func starPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let points = 5
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.4
        var angle: CGFloat = -.pi / 2
        let step = .pi / CGFloat(points)

        for i in 0..<(points * 2) {
            let radius = (i % 2 == 0) ? outerRadius : innerRadius
            let pt = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            angle += step
        }
        path.close()
        return path
    }

    private func bubblePath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.78)
        let r: CGFloat = 16
        path.append(UIBezierPath(roundedRect: bodyRect, cornerRadius: r))

        // 对话气泡尖角
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: rect.minX + 30, y: bodyRect.maxY))
        tail.addLine(to: CGPoint(x: rect.minX + 15, y: rect.maxY))
        tail.addLine(to: CGPoint(x: rect.minX + 50, y: bodyRect.maxY))
        tail.close()
        path.append(tail)
        return path
    }

    private func arrowPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let midY = rect.midY
        let shaftHeight: CGFloat = rect.height * 0.35
        let headWidth: CGFloat = rect.width * 0.45

        path.move(to: CGPoint(x: rect.minX, y: midY - shaftHeight / 2))
        path.addLine(to: CGPoint(x: rect.maxX - headWidth, y: midY - shaftHeight / 2))
        path.addLine(to: CGPoint(x: rect.maxX - headWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX - headWidth, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - headWidth, y: midY + shaftHeight / 2))
        path.addLine(to: CGPoint(x: rect.minX, y: midY + shaftHeight / 2))
        path.close()
        return path
    }

    private func heartPath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let side = min(rect.width, rect.height)
        let x = rect.midX - side / 2
        let y = rect.midY - side / 2

        path.move(to: CGPoint(x: x + side * 0.5, y: y + side * 0.8))
        path.addCurve(to: CGPoint(x: x, y: y + side * 0.3),
                      controlPoint1: CGPoint(x: x + side * 0.25, y: y + side * 0.6),
                      controlPoint2: CGPoint(x: x, y: y + side * 0.45))
        path.addArc(withCenter: CGPoint(x: x + side * 0.25, y: y + side * 0.25),
                    radius: side * 0.25,
                    startAngle: .pi,
                    endAngle: 0,
                    clockwise: true)
        path.addArc(withCenter: CGPoint(x: x + side * 0.75, y: y + side * 0.25),
                    radius: side * 0.25,
                    startAngle: .pi,
                    endAngle: 0,
                    clockwise: true)
        path.addCurve(to: CGPoint(x: x + side * 0.5, y: y + side * 0.8),
                      controlPoint1: CGPoint(x: x + side, y: y + side * 0.45),
                      controlPoint2: CGPoint(x: x + side * 0.75, y: y + side * 0.6))
        path.close()
        return path
    }

    private func trianglePath(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }
}

private struct ShapePreviewView: View {
    let shape: AddShapeSheet.ShapeKind
    let strokeColor: Color
    let strokeWidth: CGFloat
    let fillType: AddShapeSheet.FillKind
    let fillColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))

            shapeRepresentation
                .padding(14)
        }
    }

    @ViewBuilder
    private var shapeRepresentation: some View {
        switch shape {
        case .roundedRect:
            RoundedRectangle(cornerRadius: 12)
                .fill(fillColorValue)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(strokeColor, lineWidth: strokeWidth))
        case .rectangle:
            Rectangle()
                .fill(fillColorValue)
                .overlay(Rectangle().strokeBorder(strokeColor, lineWidth: strokeWidth))
        case .circle:
            Circle()
                .fill(fillColorValue)
                .overlay(Circle().strokeBorder(strokeColor, lineWidth: strokeWidth))
        case .star, .bubble, .arrow, .heart, .triangle, .line:
            // 使用 SF Symbol 自适应渲染预览
            Image(systemName: shape.icon)
                .resizable()
                .scaledToFit()
                .foregroundStyle(strokeColor)
        }
    }

    private var fillColorValue: Color {
        switch fillType {
        case .none: return .clear
        case .translucent: return fillColor.opacity(0.35)
        case .solid: return fillColor
        }
    }
}
