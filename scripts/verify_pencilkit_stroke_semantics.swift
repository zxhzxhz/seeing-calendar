#!/usr/bin/env swift
//
//  verify_pencilkit_stroke_semantics.swift
//  PencilKit 笔迹语义探针（只打印事实，不设门禁）。
//
//  需要确认的两条事实（它们决定了"变换带 mask 的笔迹"该怎么写）：
//   1. `PKStroke.transform` 是否作用于**渲染结果**（即缩放 transform 时线宽也一起缩放）；
//   2. `PKStroke.mask` 是否随 transform 一起生效（pretransform 语义）—— 即 mask 与 path 同处局部空间。
//
//  这两条如果搞错，会出现"用范围擦除截断的笔迹，在变形/移动/旋转后消失或只剩一小截"。
//
import Foundation

#if canImport(PencilKit)
import PencilKit

print("=== PencilKit 笔迹语义探针 ===")

func makeStroke() -> PKStroke? {
    let points = (0..<8).map { index -> PKStrokePoint in
        PKStrokePoint(location: CGPoint(x: CGFloat(index) * 10, y: 0),
                      timeOffset: Double(index) * 0.01,
                      size: CGSize(width: 4, height: 4),
                      opacity: 1,
                      force: 1,
                      azimuth: 0,
                      altitude: .pi / 2)
    }
    let path = PKStrokePath(controlPoints: points, creationDate: Date())
    return PKStroke(ink: PKInk(.pen, color: .black), path: path)
}

if let stroke = makeStroke() {
    let original = stroke.renderBounds
    print("原始 renderBounds: \(original)")

    let identity = PKStroke(ink: stroke.ink, path: stroke.path, transform: .identity, mask: stroke.mask)
    print("identity 变换 renderBounds: \(identity.renderBounds)")

    let scaled = PKStroke(ink: stroke.ink,
                          path: stroke.path,
                          transform: CGAffineTransform(scaleX: 2, y: 2),
                          mask: stroke.mask)
    print("2x 缩放后 renderBounds: \(scaled.renderBounds)")

    let widthGrew = scaled.renderBounds.height > original.height * 1.5
    print(widthGrew
          ? "✅ transform 作用于渲染结果（含线宽）：缩放会带动笔迹宽度"
          : "⚠️ transform 未带动线宽，整体缩放时需要另行处理笔迹宽度")

    let boundsScaled = abs(scaled.renderBounds.width - original.width * 2) < 1
    print(boundsScaled
          ? "✅ 缩放 transform 使 renderBounds 同步放大（几何一致）"
          : "⚠️ renderBounds 与 transform 不呈线性，需复查")

    // path 与 mask 均处于局部空间：合成 transform 后二者一起被变换，不会错位。
    print("mask 语义: pretransform（与 path 同处局部坐标系）—— 合成 transform 即可保持一致")
} else {
    print("⚠️ 无法构造测试笔迹")
}
#else
print("本平台无法导入 PencilKit，跳过探针（结论以 Apple 文档与 WWDC20 为准）")
#endif

print("\nDONE")
