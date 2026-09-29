#!/usr/bin/env swift
//
//  verify_transform_math.swift
//  画布变换数学的可执行验证：在 macOS runner 上直接跑真实 CoreGraphics，
//  测量 CGAffineTransform 合成顺序，并逐条验证「手指位移 == 图元位移」等不变量。
//
//  用法：
//      swift scripts/verify_transform_math.swift           # 诊断模式：打印候选实现的表现
//      swift scripts/verify_transform_math.swift --strict  # 断言模式：任何不变量不成立即 exit 1
//
import CoreGraphics
import Foundation

// MARK: - 被测公式（与 SeeingCalendar/Canvas/CanvasGeometry.swift 中的实现逐一对应）

func worldTranslation(_ offset: CGPoint) -> CGAffineTransform {
    CGAffineTransform(translationX: offset.x, y: offset.y)
}

func worldScale(anchor: CGPoint, sx: CGFloat, sy: CGFloat) -> CGAffineTransform {
    CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                      tx: anchor.x - sx * anchor.x,
                      ty: anchor.y - sy * anchor.y)
}

func worldRotation(center: CGPoint, angle: CGFloat) -> CGAffineTransform {
    let cosine = cos(angle)
    let sine = sin(angle)
    return CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine,
                             tx: center.x - (cosine * center.x - sine * center.y),
                             ty: center.y - (sine * center.x + cosine * center.y))
}

/// 候选实现 A / B —— 只差 `concatenating` 的调用方向。
enum Variant: String {
    case a = "A: delta.concatenating(base)"
    case b = "B: base.concatenating(delta)"
}

func compose(_ base: CGAffineTransform, delta: CGAffineTransform, _ variant: Variant) -> CGAffineTransform {
    switch variant {
    case .a: return delta.concatenating(base)
    case .b: return base.concatenating(delta)
    }
}

// MARK: - 工具

let strict = CommandLine.arguments.contains("--strict")
var failures: [String] = []

func report(_ title: String, _ detail: String) {
    print("  \(title): \(detail)")
}

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✅ \(message)")
    } else {
        print("  ❌ \(message)")
        failures.append(message)
    }
}

func fmt(_ value: CGFloat) -> String { String(format: "%+.4f", value) }

func fmt(_ point: CGPoint) -> String { "(\(fmt(point.x)), \(fmt(point.y)))" }

func approx(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.0005) -> Bool {
    abs(lhs - rhs) <= tolerance
}

func approx(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.0005) -> Bool {
    approx(lhs.x, rhs.x, tolerance: tolerance) && approx(lhs.y, rhs.y, tolerance: tolerance)
}

// MARK: - 0. 先测量 concatenating 的合成顺序

print("=== 0. CGAffineTransform.concatenating 合成顺序实测 ===")
let scale2 = CGAffineTransform(scaleX: 2, y: 2)
let shift10 = CGAffineTransform(translationX: 10, y: 0)
let probe = CGPoint(x: 1, y: 0)
report("scale2.concatenating(shift10)", "probe -> \(fmt(probe.applying(scale2.concatenating(shift10))))")
report("shift10.concatenating(scale2)", "probe -> \(fmt(probe.applying(shift10.concatenating(scale2))))")
report("结论", "若前者为 (12,0) 则 a.concatenating(b) = 先 a 后 b；若为 (22,0) 则 = 先 b 后 a")

// MARK: - 1. 贴图位移：手指位移必须等距

print("\n=== 1. 贴图位移等距（手指位移 == 图元位移）===")
let photoBase = CGAffineTransform(a: 0.3, b: 0, c: 0, d: 0.3, tx: 100, ty: 200)   // 缩小到 30% 的照片
let fingerDelta = CGPoint(x: 20, y: -35)                                         // 手指在世界坐标系里的位移
let localCenter = CGPoint(x: 150, y: 100)                                        // 图元局部中心
let worldCenterBefore = localCenter.applying(photoBase)

for variant in [Variant.a, .b] {
    let result = compose(photoBase, delta: worldTranslation(fingerDelta), variant)
    let worldCenterAfter = localCenter.applying(result)
    let moved = CGPoint(x: worldCenterAfter.x - worldCenterBefore.x,
                        y: worldCenterAfter.y - worldCenterBefore.y)
    report(variant.rawValue, "中心位移 \(fmt(moved))，期望 \(fmt(fingerDelta))")
}
print("  → 期望中心位移恰好等于 \(fmt(fingerDelta))")

// MARK: - 2. 角手柄等比缩放：对角锚点不动 + 被拖角跟随手指

print("\n=== 2. 角手柄缩放（锚点不动、拖拽角跟随手指）===")
let imageBase = CGAffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 100, ty: 100)
let visibleSize = CGSize(width: 200, height: 100)
let localCorners = [CGPoint(x: 0, y: 0),
                    CGPoint(x: visibleSize.width, y: 0),
                    CGPoint(x: visibleSize.width, y: visibleSize.height),
                    CGPoint(x: 0, y: visibleSize.height)]
let anchorLocal = localCorners[0]          // TL 不动
let cornerLocal = localCorners[2]          // 拖 BR
let anchorWorldBefore = anchorLocal.applying(imageBase)
let targetWorld = CGPoint(x: 180, y: 160)  // 手指当前所在的 BR 世界坐标
let targetLocal = targetWorld.applying(imageBase.inverted())
let sx = (targetLocal.x - anchorLocal.x) / (cornerLocal.x - anchorLocal.x)
let sy = (targetLocal.y - anchorLocal.y) / (cornerLocal.y - anchorLocal.y)
let localDelta = worldScale(anchor: anchorLocal, sx: sx, sy: sy)
let worldDelta = imageBase.concatenating(localDelta).concatenating(imageBase.inverted())

for variant in [Variant.a, .b] {
    let result = compose(imageBase, delta: worldDelta, variant)
    let anchorAfter = anchorLocal.applying(result)
    let cornerAfter = cornerLocal.applying(result)
    report(variant.rawValue,
           "锚点 \(fmt(anchorAfter))（期望 \(fmt(anchorWorldBefore))）· 拖拽角 \(fmt(cornerAfter))（期望 \(fmt(targetWorld))）")
}

// MARK: - 3. 旋转：世界中心不动 + 角度正确

print("\n=== 3. 旋转手柄（世界中心不动）===")
let rotationAngle: CGFloat = 30 * .pi / 180
let baseCenter = CGPoint(x: visibleSize.width / 2, y: visibleSize.height / 2).applying(imageBase)
let rotationDelta = worldRotation(center: baseCenter, angle: rotationAngle)
let probeLocal = CGPoint(x: visibleSize.width, y: 0)
let probeWorldBefore = probeLocal.applying(imageBase)

for variant in [Variant.a, .b] {
    let result = compose(imageBase, delta: rotationDelta, variant)
    let centerAfter = CGPoint(x: visibleSize.width / 2, y: visibleSize.height / 2).applying(result)
    let probeAfter = probeLocal.applying(result)
    let angleBefore = atan2(probeWorldBefore.y - baseCenter.y, probeWorldBefore.x - baseCenter.x)
    let angleAfter = atan2(probeAfter.y - baseCenter.y, probeAfter.x - baseCenter.x)
    var delta = (angleAfter - angleBefore) * 180 / .pi
    while delta > 180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    report(variant.rawValue,
           "中心 \(fmt(centerAfter))（期望 \(fmt(baseCenter))）· 角度增量 \(String(format: "%+.2f", delta))°（期望 +30.00°）")
}

// MARK: - 4. 复合选区整体 delta：组锚点不动

print("\n=== 4. 复合选区整体缩放（组锚点不动）===")
let groupAnchor = CGPoint(x: 100, y: 100)
let groupDelta = worldScale(anchor: groupAnchor, sx: 1.5, sy: 1.5)
let entities = [imageBase, CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 300, ty: 400)]

for variant in [Variant.a, .b] {
    let moved = entities.map { base -> String in
        let result = compose(base, delta: groupDelta, variant)
        let center = CGPoint(x: 50, y: 50).applying(result)
        return fmt(center)
    }
    report(variant.rawValue, "各实体中心 -> \(moved.joined(separator: " "))")
}
print("  → 期望每个实体中心 = 锚点 + 1.5 × (原中心 - 锚点)")

// MARK: - 5. 结论 & 断言

print("\n=== 5. 断言（strict 模式下失败即 exit 1）===")

let moveVariant: Variant = {
    let a = localCenter.applying(compose(photoBase, delta: worldTranslation(fingerDelta), .a))
    let expected = CGPoint(x: worldCenterBefore.x + fingerDelta.x, y: worldCenterBefore.y + fingerDelta.y)
    return approx(a, expected) ? .a : .b
}()
print("  · 位移应使用：\(moveVariant.rawValue)")

let scaleVariant: Variant = {
    for variant in [Variant.a, .b] {
        let result = compose(imageBase, delta: worldDelta, variant)
        if approx(anchorLocal.applying(result), anchorWorldBefore), approx(cornerLocal.applying(result), targetWorld) {
            return variant
        }
    }
    return .a
}()
print("  · 缩放应使用：\(scaleVariant.rawValue)")

let rotationVariant: Variant = {
    for variant in [Variant.a, .b] {
        let result = compose(imageBase, delta: rotationDelta, variant)
        let center = CGPoint(x: visibleSize.width / 2, y: visibleSize.height / 2).applying(result)
        if approx(center, baseCenter) { return variant }
    }
    return .a
}()
print("  · 旋转应使用：\(rotationVariant.rawValue)")

let groupVariant: Variant = {
    for variant in [Variant.a, .b] {
        let result = compose(imageBase, delta: groupDelta, variant)
        let original = CGPoint(x: 50, y: 50).applying(imageBase)
        let expected = CGPoint(x: groupAnchor.x + 1.5 * (original.x - groupAnchor.x),
                               y: groupAnchor.y + 1.5 * (original.y - groupAnchor.y))
        if approx(CGPoint(x: 50, y: 50).applying(result), expected) { return variant }
    }
    return .a
}()
print("  · 整体变换应使用：\(groupVariant.rawValue)")

check(moveVariant == scaleVariant && scaleVariant == rotationVariant && rotationVariant == groupVariant,
      "四处变换必须使用同一种合成方向（否则必然出现位移不等距 / 锚点漂移）")

if strict && !failures.isEmpty {
    print("\nFAILED: \(failures.count) 项不变量不成立")
    exit(1)
}
print("\nDONE（strict=\(strict)）")
