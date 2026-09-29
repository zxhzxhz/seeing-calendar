#!/usr/bin/env swift
//
//  verify_transform_math.swift
//  画布变换数学的可执行回归门禁。
//
//  为什么需要它：位移/缩放/旋转的正确性取决于 CGAffineTransform 的合成方向，
//  而这个方向**靠推理反复出错**（v1.0.2 之前四处变换全部用反，导致「手指位移 ≠ 图元位移」，
//  比值恰好等于图元自身缩放比）。这里改为在 macOS 上用真实 CoreGraphics 测量 + 断言：
//
//      swift scripts/verify_transform_math.swift --strict
//
//  下面这些公式与 SeeingCalendar/Canvas/CanvasGeometry.swift、ImageEntityView.swift
//  中的实现逐字对应，任何一侧改了另一边必须同步，否则门禁会失败。
//
import CoreGraphics
import Foundation

// MARK: - 与 App 一致的公式（CanvasGeometry.swift）

extension CGAffineTransform {
    static func worldTranslation(_ offset: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y)
    }

    static func worldScale(anchor: CGPoint, sx: CGFloat, sy: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                          tx: anchor.x - sx * anchor.x,
                          ty: anchor.y - sy * anchor.y)
    }

    static func worldRotation(center: CGPoint, angle: CGFloat) -> CGAffineTransform {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine,
                                 tx: center.x - (cosine * center.x - sine * center.y),
                                 ty: center.y - (sine * center.x + cosine * center.y))
    }

    func applied(to point: CGPoint) -> CGPoint { point.applying(self) }

    /// 实测：a.concatenating(b) = 先 a 后 b（见第 0 节）。
    func applyingWorldDelta(_ delta: CGAffineTransform) -> CGAffineTransform { concatenating(delta) }
    func applyingLocalDelta(_ delta: CGAffineTransform) -> CGAffineTransform { delta.concatenating(self) }

    /// UIView.transform 绕自身中心施加：effective = T(c) ∘ transform ∘ T(-c)（函数序）。
    /// 要令 effective == delta，必须赋值 T(c) → delta → T(-c)。
    func viewConjugate(aboutCenter center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .concatenating(self)
            .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
    }
}

// MARK: - 测试脚手架

let strict = CommandLine.arguments.contains("--strict")
var failures: [String] = []
var checks = 0

func fmt(_ value: CGFloat) -> String { String(format: "%+.4f", value) }
func fmt(_ point: CGPoint) -> String { "(\(fmt(point.x)), \(fmt(point.y)))" }
func approx(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.001) -> Bool { abs(lhs - rhs) <= tolerance }
func approx(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.001) -> Bool {
    approx(lhs.x, rhs.x, tolerance: tolerance) && approx(lhs.y, rhs.y, tolerance: tolerance)
}

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures.append(message)
        print("  ❌ \(message)")
    }
}

/// 构造一个「缩放 + 旋转 + 平移」的图元世界变换（覆盖真实照片被缩小的情形）。
func makeBase(scale: CGFloat, rotationDegrees: CGFloat, position: CGPoint) -> CGAffineTransform {
    let radians = rotationDegrees * .pi / 180
    let cosine = cos(radians) * scale
    let sine = sin(radians) * scale
    return CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine, tx: position.x, ty: position.y)
}

// MARK: - 0. 测量合成顺序

print("=== 0. CGAffineTransform.concatenating 合成顺序 ===")
let probeResult = CGPoint(x: 1, y: 0).applying(
    CGAffineTransform(scaleX: 2, y: 2).concatenating(CGAffineTransform(translationX: 10, y: 0))
)
print("  scale2.concatenating(shift10) 作用于 (1,0) -> \(fmt(probeResult))  ⇒ 先 a 后 b")
expect(approx(probeResult, CGPoint(x: 12, y: 0)), "concatenating 合成顺序应为「先 a 后 b」，实测 \(fmt(probeResult))")

// MARK: - 1. 位移等距（基点模型）
// 手指从世界点 A 移到 B，图元中心的世界位移必须**恰好等于** A→B。

print("\n=== 1. 贴图位移等距：世界位移比值恒为 1 ===")
let viewport = CGSize(width: 200, height: 120)          // 图元可见尺寸（局部）
let localCenter = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
let deltas = [CGPoint(x: 20, y: -35), CGPoint(x: -7.5, y: 3.25), CGPoint(x: 130, y: 90)]

for scale in [CGFloat(0.1), 0.3, 1.0, 2.5] {
    for rotation in [CGFloat(0), 30, 90] {
        let base = makeBase(scale: scale, rotationDegrees: rotation, position: CGPoint(x: 400, y: 300))
        for delta in deltas {
            let startWorld = CGPoint(x: 120, y: 80)      // 手势基点（世界坐标）
            let currentWorld = CGPoint(x: startWorld.x + delta.x, y: startWorld.y + delta.y)
            let fingerDelta = CGPoint(x: currentWorld.x - startWorld.x, y: currentWorld.y - startWorld.y)

            let before = localCenter.applying(base)
            let after = localCenter.applying(base.applyingWorldDelta(.worldTranslation(fingerDelta)))
            let moved = CGPoint(x: after.x - before.x, y: after.y - before.y)

            expect(approx(moved, fingerDelta),
                   "scale=\(scale) rot=\(rotation)°: 中心位移 \(fmt(moved)) 应等于手指位移 \(fmt(fingerDelta))（比值 \(fmt(moved.x / fingerDelta.x))）")
        }
    }
}
print("  已覆盖 4 种缩放 × 3 种旋转 × 3 组位移 = 36 组")

// MARK: - 2. 角手柄等比缩放：对角锚点不动 + 被拖角跟随手指

print("\n=== 2. 角手柄缩放：锚点不动、拖拽角跟随手指 ===")
let localCorners = [CGPoint(x: 0, y: 0),
                    CGPoint(x: viewport.width, y: 0),
                    CGPoint(x: viewport.width, y: viewport.height),
                    CGPoint(x: 0, y: viewport.height)]

for scale in [CGFloat(0.25), 0.6, 1.4] {
    for rotation in [CGFloat(0), 45, -120] {
        let base = makeBase(scale: scale, rotationDegrees: rotation, position: CGPoint(x: 500, y: 420))
        for cornerIndex in 0..<4 {
            let anchorLocal = localCorners[(cornerIndex + 2) % 4]
            let draggedLocal = localCorners[cornerIndex]
            let anchorWorld = anchorLocal.applying(base)
            let draggedWorld = draggedLocal.applying(base)

            // 手指把被拖角拖到「原位置向外 1.6 倍」处（局部等比例）
            let gestureTargetWorld = CGPoint(
                x: anchorWorld.x + (draggedWorld.x - anchorWorld.x) * 1.6,
                y: anchorWorld.y + (draggedWorld.y - anchorWorld.y) * 1.6
            )
            let targetLocal = gestureTargetWorld.applying(base.inverted())
            let factorX = (targetLocal.x - anchorLocal.x) / (draggedLocal.x - anchorLocal.x)
            let factorY = (targetLocal.y - anchorLocal.y) / (draggedLocal.y - anchorLocal.y)
            let uniform = abs(draggedLocal.x - anchorLocal.x) >= abs(draggedLocal.y - anchorLocal.y) ? factorX : factorY

            let localDelta = CGAffineTransform.worldScale(anchor: anchorLocal, sx: uniform, sy: uniform)
            let result = base.applyingLocalDelta(localDelta)

            expect(approx(anchorLocal.applying(result), anchorWorld),
                   "scale=\(scale) rot=\(rotation)° corner=\(cornerIndex): 对角锚点应保持不动，实际 \(fmt(anchorLocal.applying(result))) 期望 \(fmt(anchorWorld))")
            expect(approx(draggedLocal.applying(result), gestureTargetWorld),
                   "scale=\(scale) rot=\(rotation)° corner=\(cornerIndex): 被拖角应贴合手指，实际 \(fmt(draggedLocal.applying(result))) 期望 \(fmt(gestureTargetWorld))")
        }
    }
}

// MARK: - 3. 旋转手柄：世界中心不动 + 角度增量正确

print("\n=== 3. 旋转手柄：中心不动、角度精确 ===")
for scale in [CGFloat(0.3), 1.0, 2.0] {
    for baseRotation in [CGFloat(0), 25, -70] {
        let base = makeBase(scale: scale, rotationDegrees: baseRotation, position: CGPoint(x: 350, y: 260))
        for angle in [CGFloat(15), 45, 90, -30] {
            let center = base.applied(to: localCenter)
            let delta = CGAffineTransform.worldRotation(center: center, angle: angle * .pi / 180)
            let result = base.applyingWorldDelta(delta)

            let centerAfter = localCenter.applying(result)
            expect(approx(centerAfter, center),
                   "scale=\(scale) rot=\(baseRotation)°: 旋转后世界中心应不动，实际 \(fmt(centerAfter)) 期望 \(fmt(center))")

            let probe = CGPoint(x: viewport.width, y: 0)
            let before = probe.applying(base)
            let after = probe.applying(result)
            let angleBefore = atan2(before.y - center.y, before.x - center.x)
            let angleAfter = atan2(after.y - center.y, after.x - center.x)
            var turned = (angleAfter - angleBefore) * 180 / .pi
            while turned > 180 { turned -= 360 }
            while turned < -180 { turned += 360 }
            expect(approx(turned, angle, tolerance: 0.01),
                   "scale=\(scale) rot=\(baseRotation)°: 角度增量应为 \(fmt(angle))°，实际 \(fmt(turned))°")
        }
    }
}

// MARK: - 4. 复合选区整体变换：组锚点不动

print("\n=== 4. 复合选区整体变换：组锚点不动 ===")
let groupAnchor = CGPoint(x: 260, y: 210)
let bases = [makeBase(scale: 0.4, rotationDegrees: 0, position: CGPoint(x: 300, y: 250)),
             makeBase(scale: 1.2, rotationDegrees: 35, position: CGPoint(x: 700, y: 500))]

for (sx, sy) in [(CGFloat(1.5), CGFloat(1.5)), (0.6, 0.6), (1.2, 1.2)] {
    let delta = CGAffineTransform.worldScale(anchor: groupAnchor, sx: sx, sy: sy)
    for (index, base) in bases.enumerated() {
        let sampleLocal = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let originalWorld = sampleLocal.applying(base)
        let expected = CGPoint(x: groupAnchor.x + sx * (originalWorld.x - groupAnchor.x),
                               y: groupAnchor.y + sy * (originalWorld.y - groupAnchor.y))
        let actual = sampleLocal.applying(base.applyingWorldDelta(delta))
        expect(approx(actual, expected),
               "组缩放 sx=\(sx) 实体#\(index): 期望 \(fmt(expected)) 实际 \(fmt(actual))")
    }
    let anchorAfter = groupAnchor.applying(delta)
    expect(approx(anchorAfter, groupAnchor), "组锚点应是不动点，实际 \(fmt(anchorAfter))")
}

// MARK: - 5. 浮动笔迹预览：UIView 绕中心施加的共轭校正

print("\n=== 5. 浮动笔迹预览：UIView 中心原点校正 ===")
let previewCenter = CGPoint(x: 640, y: 470)          // 预览视图中心（父视图坐标系）
let previewFrameLocal = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
let deltasForPreview = [CGAffineTransform.worldScale(anchor: groupAnchor, sx: 1.4, sy: 1.4),
                        CGAffineTransform.worldRotation(center: groupAnchor, angle: 40 * .pi / 180)]

for delta in deltasForPreview {
    // UIKit 语义：有效映射 = T(c) ∘ transform ∘ T(-c)；用 concatenating 表达即 T(-c) → transform → T(c)
    let assigned = delta.viewConjugate(aboutCenter: previewCenter)
    let effective = CGAffineTransform(translationX: -previewCenter.x, y: -previewCenter.y)
        .concatenating(assigned)
        .concatenating(CGAffineTransform(translationX: previewCenter.x, y: previewCenter.y))
    expect(approx(previewFrameLocal.applying(effective), previewFrameLocal.applying(delta)),
           "预览的有效世界变换应等于 delta：实际 \(fmt(previewFrameLocal.applying(effective))) 期望 \(fmt(previewFrameLocal.applying(delta)))")

    // 再取几个点交叉验证（不能只在一点上碰巧相等）
    for probe in [CGPoint(x: 0, y: 0), CGPoint(x: 37, y: -91), CGPoint(x: 260, y: 180)] {
        expect(approx(probe.applying(effective), probe.applying(delta), tolerance: 0.01),
               "校正后预览在 \(fmt(probe)) 处应与 delta 一致")
    }
}

// MARK: - 6. 图元视图分解（center + 线性变换）自检

print("\n=== 6. 图元 center+transform 分解等价性 ===")
for scale in [CGFloat(0.3), 1.0, 2.2] {
    for rotation in [CGFloat(0), 33, -75] {
        let matrix = makeBase(scale: scale, rotationDegrees: rotation, position: CGPoint(x: 420, y: 310))
        let boundsCenter = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let center = boundsCenter.applying(matrix)                    // 视图 center
        let linear = CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d, tx: 0, ty: 0)
        let effective = CGAffineTransform(translationX: -boundsCenter.x, y: -boundsCenter.y)
            .concatenating(linear)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        for probe in [CGPoint(x: 0, y: 0), CGPoint(x: -40, y: 90), CGPoint(x: viewport.width, y: viewport.height)] {
            expect(approx(probe.applying(effective), probe.applying(matrix), tolerance: 0.01),
                   "scale=\(scale) rot=\(rotation)°: 分解后 \(fmt(probe)) 应映射到 \(fmt(probe.applying(matrix)))，实际 \(fmt(probe.applying(effective)))")
        }
    }
}

// MARK: - 结论

print("\n=== 结论 ===")
print("  断言总数：\(checks)　失败：\(failures.count)")
if failures.isEmpty {
    print("  ✅ 画布变换不变量全部成立：位移比值 = 1、锚点不动、旋转中心不动、预览与世界一致")
} else {
    for failure in failures.prefix(20) {
        print("  ❌ \(failure)")
    }
}
if strict && !failures.isEmpty {
    print("\nFAILED")
    exit(1)
}
print("\nDONE（strict=\(strict)）")
