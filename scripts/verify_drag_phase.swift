#!/usr/bin/env swift
//
//  verify_drag_phase.swift
//  贴图拖动相位机门禁（CI 以 --strict 执行）
//
//  钉的是「一次拖动生命周期被 5 个扁平字段隐式表达」引出的三类回退：
//
//  【相位用扁平字段表达，无类型约束】旧实现里 `ImageEntityView` 用
//     `isMoving` / `gestureBase` / `gestureStartPoint` / `hasLeftDeadZone` /
//     `gestureStartWindow` 五个字段共同表达 idle / armed / dragging 三态，
//     三个分支各自手工维护「字段是否同时成立」。本门禁：
//     ① 用文本护栏钉死旧存储声明不得回潮（断言 0 负向护栏）；
//     ② 用 declarationBody 精确断言 `handlePan` 体内不再出现那四个旧字段名；
//     ③ 对 (3 相位 × 3 事件) 全组合穷举 5 条不变量（断言 1）。
//
//  【死区 / 亚像素的内联魔数 3 与 0.5】旧实现是两处内联字面量。本门禁把
//     `leftDeadZone`（严格 >= 死区，2.9 / 3.0 / 3.1）与 `exceedsEpsilon`
//     （严格 > 阈值，0.4 / 0.5 / 0.6）在边界上逐点钉死（断言 2）。
//
//  【位移改回增量累加】旧实现的两条注释都强调位移恒以**基点**为参考、绝不累加。
//     本门禁用「重锚不跳变」「基点语义 C − base」「往返回到出发点位移为 .zero」
//     钉死，并写一个增量累加式破坏变体做反证（断言 3、4）。
//
//  运行：swift scripts/verify_drag_phase.swift [--strict]
//

import Foundation
// ★ 必须显式导入 CoreGraphics：在 Apple 平台上 CGPoint 的 Equatable 一致性来自
// CoreGraphics 覆写层，只 import Foundation 时 `enum Phase: Equatable` 的合成会失败
// （Linux 的 Foundation 自带 CGPoint 且自带 Equatable，所以本机跑绿、CI 上编译不过）。
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - 迷你断言框架

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    checks += 1
    if lhs != rhs { failures.append("\(label)：期望 \(rhs)，实际 \(lhs)") }
}

// MARK: - 被测逻辑（生产代码的镜像）

/// 镜像 CGAffineTransform 中与拖动相关的部分（Linux 无 CoreGraphics）。
/// 世界平移 delta 叠加到 base 上 = 平移分量相加（`concatenating` 对纯平移即如此）。
struct Mat: Equatable {
    var tx: CGFloat
    var ty: CGFloat

    static let identity = Mat(tx: 0, ty: 0)

    /// 镜像 `base.applyingWorldDelta(.worldTranslation(offset))`。
    func applyingWorldDelta(_ offset: CGPoint) -> Mat {
        Mat(tx: tx + offset.x, ty: ty + offset.y)
    }
}

enum Phase: Equatable {
    case idle
    case armed(base: Mat, anchor: CGPoint, windowAnchor: CGPoint)
    case dragging(base: Mat, anchor: CGPoint)

    var allowsRemount: Bool { self == .idle }

    var isMoving: Bool {
        switch self {
        case .idle: return false
        case .armed, .dragging: return true
        }
    }

    var activeBase: Mat? {
        switch self {
        case .idle: return nil
        case .armed(let base, _, _): return base
        case .dragging(let base, _): return base
        }
    }

    var activeAnchor: CGPoint? {
        switch self {
        case .idle: return nil
        case .armed(_, let anchor, _): return anchor
        case .dragging(_, let anchor): return anchor
        }
    }
}

enum Event: Equatable {
    case began(base: Mat, anchor: CGPoint, windowAnchor: CGPoint)
    case moved(anchor: CGPoint, windowAnchor: CGPoint)
    case ended
}

enum Policy {
    static let deadZone: CGFloat = 3
    static let epsilon: CGFloat = 0.5

    static func translation(anchor: CGPoint, from base: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x - base.x, y: anchor.y - base.y)
    }

    static func leftDeadZone(current: CGPoint, anchor: CGPoint, deadZone: CGFloat = deadZone) -> Bool {
        hypot(current.x - anchor.x, current.y - anchor.y) >= deadZone
    }

    static func exceedsEpsilon(_ delta: CGPoint, epsilon: CGFloat = epsilon) -> Bool {
        abs(delta.x) > epsilon || abs(delta.y) > epsilon
    }

    static func reduce(_ phase: Phase, event: Event) -> Phase {
        switch event {
        case .began(let base, let anchor, let windowAnchor):
            return .armed(base: base, anchor: anchor, windowAnchor: windowAnchor)

        case .moved(let anchor, let windowAnchor):
            switch phase {
            case .idle:
                return .idle
            case .armed(let base, _, let windowStart):
                guard leftDeadZone(current: windowAnchor, anchor: windowStart) else { return phase }
                return .dragging(base: base, anchor: anchor)
            case .dragging:
                return phase
            }

        case .ended:
            return .idle
        }
    }
}

/// 破坏变体（增量累加式）：不存基点，逐帧把「当前点 − 上一帧点」累加进一个总量。
/// 这正是旧实现注释里明确警告过的形状：亚像素帧被过滤时位移会丢、往返会漂移。
enum BrokenAccumulatingPolicy {
    static func total(start: CGPoint, points: [CGPoint]) -> CGPoint {
        var last = start
        var total = CGPoint.zero
        for point in points {
            let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
            last = point
            guard Policy.exceedsEpsilon(delta) else { continue }
            total = CGPoint(x: total.x + delta.x, y: total.y + delta.y)
        }
        return total
    }
}

/// 正确形状（基点式）：位移恒为「当前点 − 基点」，与经过多少帧无关。
enum BaseReferencedPolicy {
    static func total(anchor: CGPoint, points: [CGPoint]) -> CGPoint {
        guard let last = points.last else { return .zero }
        return Policy.translation(anchor: last, from: anchor)
    }
}

// MARK: - 源码读取工具

func productionSource(_ relativePath: String) -> String? {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 取出某个声明的主体（花括号配平）。找不到返回 nil。
func declarationBody(of declaration: String, in source: String) -> String? {
    guard let start = source.range(of: declaration),
          let open = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
    var depth = 0
    var index = open.lowerBound
    while index < source.endIndex {
        let character = source[index]
        if character == "{" { depth += 1 }
        else if character == "}" {
            depth -= 1
            if depth == 0 { return String(source[open.lowerBound...index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

// MARK: - 断言 0：与生产源码同源（文本护栏）

func verifySourceGuardrails() {
    // ---- 纯逻辑相位机文件 ----
    let policy = productionSource("SeeingCalendar/Canvas/DragPhasePolicy.swift") ?? ""
    check(policy.contains("enum DragPhase: Equatable, Sendable"),
          "DragPhase 必须仍是 Equatable + Sendable 的纯值类型")
    check(policy.contains("case idle"), "DragPhase 必须保留 .idle")
    check(policy.contains("case armed(base: CGAffineTransform, anchor: CGPoint, windowAnchor: CGPoint)"),
          "DragPhase.armed 必须同时携带基点、世界锚点与窗口锚点")
    check(policy.contains("case dragging(base: CGAffineTransform, anchor: CGPoint)"),
          "DragPhase.dragging 必须携带基点与已重锚的锚点")
    check(policy.contains("var allowsRemount: Bool { self == .idle }"),
          "allowsRemount 必须恰好等价于 .idle（拖拽期间严禁重挂载）")
    check(policy.contains("var isMoving: Bool"), "isMoving 必须是相位上的只读投影")
    check(policy.contains("var activeBase: CGAffineTransform?"), "必须提供 activeBase 投影")
    check(policy.contains("var activeAnchor: CGPoint?"), "必须提供 activeAnchor 投影")
    check(policy.contains("enum DragEvent: Equatable, Sendable"),
          "DragEvent 必须仍是 Equatable + Sendable")
    check(policy.contains("case began(base: CGAffineTransform, anchor: CGPoint, windowAnchor: CGPoint)"),
          "began 必须携带基点、世界锚点与窗口锚点")
    check(policy.contains("case moved(anchor: CGPoint, windowAnchor: CGPoint)"),
          "moved 必须同时携带世界锚点与窗口锚点（死区用后者度量）")
    check(policy.contains("case ended"), "必须保留 ended 事件")
    check(policy.contains("static let deadZone: CGFloat = 3"),
          "起始死区必须具名化为 3，不许再内联")
    check(policy.contains("static let epsilon: CGFloat = 0.5"),
          "亚像素阈值必须具名化为 0.5，不许再内联")
    check(policy.contains("static func translation(anchor: CGPoint, from base: CGPoint) -> CGPoint"),
          "位移计算必须是独立可测的纯函数")
    check(policy.contains("hypot(current.x - anchor.x, current.y - anchor.y) >= deadZone"),
          "死区判定必须以窗口坐标度量且为严格 >= deadZone")
    check(policy.contains("abs(delta.x) > epsilon || abs(delta.y) > epsilon"),
          "亚像素判定必须严格大于（与旧内联判定逐位等价）")
    check(policy.contains("return .dragging(base: base, anchor: anchor)"),
          "退出死区必须把锚点重锚到当前位置")
    check(policy.contains("if case .idle = phase { return .idle }"),
          "idle 收到 moved 必须原样返回")
    check(policy.contains("if case .ended = event {"),
          "ended 必须从任何相位回到 idle（幂等）")
    check(policy.contains("static func reduce(_ phase: DragPhase, event: DragEvent) -> DragPhase"),
          "必须存在拖动相位的转移函数")
    check(policy.contains("enum DragPolicy"), "转移函数必须收在 DragPolicy 命名空间里")

    // ---- 宿主视图（M10 写入点）----
    let entity = productionSource("SeeingCalendar/Canvas/ImageEntityView.swift") ?? ""
    check(entity.contains("private(set) var dragPhase: DragPhase = .idle"),
          "dragPhase 必须是单一真值入口")
    check(entity.contains("var isMoving: Bool { dragPhase.isMoving }"),
          "isMoving 必须降级为只读计算投影")
    check(entity.contains("event: .began(base: worldTransform"),
          "起手必须把当前 worldTransform 作为基点喂给相位机")
    check(entity.contains("event: .moved(anchor: current, windowAnchor: windowPoint)"),
          "移动必须把世界锚点与窗口锚点一起喂给相位机")
    check(entity.contains("DragPolicy.reduce(dragPhase, event: .ended)"),
          "结束必须改走相位事件")
    check(entity.contains("DragPolicy.translation(anchor: current, from: anchor)"),
          "位移必须以相位锚点为基点计算")
    check(entity.contains("DragPolicy.exceedsEpsilon(delta)"),
          "亚像素过滤必须改走策略调用")
    check(entity.contains("guard case .dragging(let base, let anchor) = next else { return }"),
          "只有 dragging 相位才允许产生位移")

    // 负向护栏：旧存储声明不得回潮
    check(!entity.contains("private var gestureBase:"),
          "★ 不得回退为 `private var gestureBase:` 存储字段")
    check(!entity.contains("private var gestureStartPoint:"),
          "★ 不得回退为 `private var gestureStartPoint:` 存储字段")
    check(!entity.contains("private var hasLeftDeadZone"),
          "★ 不得回退为 `private var hasLeftDeadZone` 存储字段")
    check(!entity.contains("private var gestureStartWindow"),
          "★ 不得回退为 `private var gestureStartWindow` 存储字段")
    check(!entity.contains("private(set) var isMoving = false"),
          "★ 不得回退为 isMoving 存储旗标（必须是相位投影）")
    check(!entity.contains("dragDeadZone") && !entity.contains("dragEpsilon"),
          "★ 死区 / 亚像素魔数必须收进 DragPolicy，宿主视图不得再出现旧静态常量")
    check(!entity.contains("Self.dragDeadZone") && !entity.contains("Self.dragEpsilon"),
          "★ 不得再以 `Self.dragDeadZone` / `Self.dragEpsilon` 内联引用旧常量")

    // 精确到函数体：文件级检查会被「识别旧形状」的说明性注释误伤。
    if let body = declarationBody(of: "func handlePan(", in: entity) {
        check(!body.contains("gestureBase"),
              "★ handlePan 体内不得再出现 gestureBase")
        check(!body.contains("gestureStartPoint"),
              "★ handlePan 体内不得再出现 gestureStartPoint")
        check(!body.contains("hasLeftDeadZone"),
              "★ handlePan 体内不得再出现 hasLeftDeadZone")
        check(!body.contains("gestureStartWindow"),
              "★ handlePan 体内不得再出现 gestureStartWindow")
        check(!body.contains("Self.dragDeadZone") && !body.contains("Self.dragEpsilon"),
              "★ handlePan 体内不得再内联旧死区 / 亚像素常量")

        // 逐位保留的既有行为（真机 bug 修出来的顺序）：
        if let setPos = body.range(of: "event: .began(base: worldTransform")?.lowerBound,
           let selectPos = body.range(of: "onSelect?(self)")?.lowerBound,
           let beginPos = body.range(of: "onBeginMove?(self)")?.lowerBound {
            check(setPos < selectPos,
                  "★ .began 必须先置位（dragPhase → armed）再回调 onSelect（否则重挂载立刻打断本手势）")
            check(selectPos < beginPos,
                  "★ .began 必须 onSelect 之后才 onBeginMove")
        } else {
            check(false, "无法在 handlePan 体内定位 .began 的置位 / onSelect / onBeginMove 顺序")
        }

        if let resetPos = body.range(of: "DragPolicy.reduce(dragPhase, event: .ended)")?.lowerBound,
           let endPos = body.range(of: "onEndMove?(self)")?.lowerBound {
            check(resetPos < endPos,
                  "★ .ended 必须先复位（回到 idle）再回调 onEndMove（容器在它里面补做置顶重挂载）")
        } else {
            check(false, "无法在 handlePan 体内定位 .ended 的复位 / onEndMove 顺序")
        }

        // .changed 的相位链路完整
        check(body.contains("guard let parent = superview else { return }"),
              ".changed 必须先从 superview 取世界坐标")
        check(body.range(of: "DragPolicy.reduce(dragPhase, event: .moved") != nil,
              ".changed 必须走 moved 事件")
    } else {
        check(false, "无法定位 handlePan 的函数体 —— 签名改了吗？")
    }
}

// MARK: - 断言 1：(3 相位 × 3 事件) 穷举不变量

private let allPhases: [Phase] = [
    .idle,
    .armed(base: Mat(tx: 1, ty: 2), anchor: CGPoint(x: 10, y: 20), windowAnchor: CGPoint(x: 100, y: 200)),
    .dragging(base: Mat(tx: 1, ty: 2), anchor: CGPoint(x: 10, y: 20))
]

private let allEvents: [Event] = [
    .began(base: Mat(tx: 5, ty: 6), anchor: CGPoint(x: 50, y: 60), windowAnchor: CGPoint(x: 500, y: 600)),
    .moved(anchor: CGPoint(x: 300, y: 400), windowAnchor: CGPoint(x: 3000, y: 4000)),
    .ended
]

func verifyExhaustiveInvariants() {
    for phase in allPhases {
        for event in allEvents {
            let next = Policy.reduce(phase, event: event)
            let label = "\(phase) × \(event)"

            // 不变量 5：allowsRemount 为真的恰好是 .idle。
            checkEqual(next.allowsRemount, next == .idle,
                       "\(label)：allowsRemount 必须恰好等价于 .idle")
            // isMoving 是 allowsRemount 的补（armed / dragging 皆为真）。
            checkEqual(next.isMoving, !next.allowsRemount,
                       "\(label)：isMoving 必须恰好是 allowsRemount 的补")
            // idle 的投影必须全灭。
            if next == .idle {
                check(next.activeBase == nil, "\(label)：idle 的 activeBase 必须为 nil")
                check(next.activeAnchor == nil, "\(label)：idle 的 activeAnchor 必须为 nil")
                checkEqual(next, .idle, "\(label)：idle 必须仍是 idle")
            } else {
                check(next.activeBase != nil, "\(label)：非 idle 必须有 activeBase")
                check(next.activeAnchor != nil, "\(label)：非 idle 必须有 activeAnchor")
            }

            // 不变量 4：ended 从任何相位都回到 idle（幂等）。
            if case .ended = event {
                checkEqual(next, .idle, "\(label)：ended 必须回到 idle")
            }
            // 不变量 4：idle 收到 moved 原样返回。
            if case .moved = event, phase == .idle {
                checkEqual(next, .idle, "\(label)：idle × moved 必须原样返回 idle")
            }
            // began 从任何相位都落到 armed，并携带事件里的值。
            if case .began(let base, let anchor, let windowAnchor) = event {
                checkEqual(next, .armed(base: base, anchor: anchor, windowAnchor: windowAnchor),
                           "\(label)：began 必须进入 armed 并携带基点 / 锚点 / 窗口锚点")
            }
            // 不变量 1：任何非 idle 相位的锚点都可作参考 → 自参考位移恒为零。
            if let anchor = next.activeAnchor {
                checkEqual(Policy.translation(anchor: anchor, from: anchor), .zero,
                           "\(label)：translation 以基点为参考，自参考位移必然为零")
            }
            // 不变量：dragging 收到 moved 时基点与锚点都不变（位移恒相对同一基点）。
            if case .dragging = phase, case .moved = event {
                checkEqual(next, phase, "\(label)：dragging × moved 必须保持基点与锚点不变")
            }
            // armed 未出死区时原样返回（近距窗口位移）。
            if case .armed(_, let anchor, let windowAnchor) = phase, case .moved = event {
                let near = CGPoint(x: windowAnchor.x + 0.1, y: windowAnchor.y)
                checkEqual(Policy.reduce(phase, event: .moved(anchor: anchor, windowAnchor: near)), phase,
                           "\(label)：armed 未出死区必须原样保持 armed")
            }
        }
    }

    // 死区退出：armed → dragging 且锚点重锚到当前位置。
    let armed = Phase.armed(base: Mat(tx: 9, ty: 9),
                            anchor: CGPoint(x: 0, y: 0),
                            windowAnchor: CGPoint(x: 0, y: 0))
    let exited = Policy.reduce(armed, event: .moved(anchor: CGPoint(x: 7, y: 5), windowAnchor: CGPoint(x: 8, y: 0)))
    checkEqual(exited, .dragging(base: Mat(tx: 9, ty: 9), anchor: CGPoint(x: 7, y: 5)),
               "★ 退出死区必须转 dragging 且锚点重锚到当前位置")
}

// MARK: - 断言 2：死区与亚像素的逐位等价

func verifyThresholdParity() {
    // translation 逐点等价于 current − base。
    let pairs: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 3, y: 4), .zero),
        (CGPoint(x: -2.5, y: 7.25), CGPoint(x: 1.5, y: 0.25)),
        (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
        (CGPoint(x: 10, y: -10), CGPoint(x: -10, y: 10))
    ]
    for (a, b) in pairs {
        checkEqual(Policy.translation(anchor: a, from: b),
                   CGPoint(x: a.x - b.x, y: a.y - b.y),
                   "translation(\(a), from: \(b)) 必须逐位等于 current − base")
    }

    // leftDeadZone：严格 >= deadZone 才算越界。
    for travel in [CGFloat(2.9), 3.0, 3.1] {
        let expected = travel >= 3
        checkEqual(Policy.leftDeadZone(current: CGPoint(x: travel, y: 0), anchor: .zero),
                   expected,
                   "leftDeadZone(travel=\(travel)) 必须与手写期望 \(expected) 逐位一致")
    }
    check(!Policy.leftDeadZone(current: CGPoint(x: 2.999, y: 0), anchor: .zero), "略小于 3 不得越界")
    check(Policy.leftDeadZone(current: CGPoint(x: 2, y: 2.3), anchor: .zero), "斜向位移按欧氏距离度量")
    checkEqual(Policy.deadZone, 3, "死区必须是 3")

    // exceedsEpsilon：严格 > epsilon 才算越界。
    for value in [CGFloat(0.4), 0.5, 0.6] {
        let expected = value > 0.5
        checkEqual(Policy.exceedsEpsilon(CGPoint(x: value, y: 0)),
                   expected,
                   "exceedsEpsilon(\(value)) 必须与手写期望 \(expected) 逐位一致")
    }
    check(!Policy.exceedsEpsilon(CGPoint(x: 0, y: 0.5)), "恰好 0.5 不触发（严格大于）")
    check(Policy.exceedsEpsilon(CGPoint(x: 0, y: -0.6)), "负方向越界同样触发")
    checkEqual(Policy.epsilon, 0.5, "亚像素阈值必须是 0.5")
}

// MARK: - 断言 3：重锚不跳变 + 基点语义

func verifyReanchorAndBaseSemantics() {
    // ---- 重锚不跳变：began → moved(travel = 5) ----
    var phase = Policy.reduce(.idle,
                              event: .began(base: Mat(tx: 100, ty: 100),
                                            anchor: CGPoint(x: 0, y: 0),
                                            windowAnchor: CGPoint(x: 0, y: 0)))
    checkEqual(phase, .armed(base: Mat(tx: 100, ty: 100),
                             anchor: CGPoint(x: 0, y: 0),
                             windowAnchor: CGPoint(x: 0, y: 0)),
               "began 之后必须停在 armed")
    check(phase.isMoving, "armed 也算正在进行中（isMoving 为真）")
    check(!phase.allowsRemount, "armed 不允许重挂载（手势已成立）")

    let current = CGPoint(x: 5, y: 0)
    phase = Policy.reduce(phase, event: .moved(anchor: current, windowAnchor: current))
    guard case .dragging(_, let anchor) = phase else {
        check(false, "began → moved(travel=5) 必须退出死区进入 dragging")
        return
    }
    checkEqual(anchor, current, "★ 退出死区那一步必须把锚点重锚到当前位置")
    checkEqual(Policy.translation(anchor: current, from: anchor), .zero,
               "★ 重锚帧位移必须为零（死区不产生一次性跳变）")
    checkEqual(phase.activeBase, Mat(tx: 100, ty: 100), "重锚不得改动基点")

    // ---- 基点语义：base → moved(A) → moved(B) → moved(C) ----
    let base = CGPoint(x: 0, y: 0)
    let pointsA = CGPoint(x: 10, y: 3)
    let pointsB = CGPoint(x: 20, y: 7)
    let pointsC = CGPoint(x: 15, y: 9)
    let total = BaseReferencedPolicy.total(anchor: base, points: [pointsA, pointsB, pointsC])
    checkEqual(total, CGPoint(x: pointsC.x - base.x, y: pointsC.y - base.y),
               "★ 多次移动后位移必须恒为 C − base")

    // 从 dragging 相位喂 moved，锚点必须保持不动、位移逐帧都相对同一基点。
    var dragging: Phase = .dragging(base: Mat(tx: 0, ty: 0), anchor: base)
    for point in [pointsA, pointsB, pointsC] {
        let next = Policy.reduce(dragging, event: .moved(anchor: point, windowAnchor: point))
        guard case .dragging(_, let keep) = next else {
            check(false, "dragging × moved 必须仍是 dragging")
            break
        }
        checkEqual(keep, base, "dragging 期间锚点必须恒为基点")
        checkEqual(Policy.translation(anchor: point, from: keep),
                   CGPoint(x: point.x - base.x, y: point.y - base.y),
                   "位移必须相对基点而非上一帧")
        dragging = next
    }

    // ---- 往返回到出发点：位移必须精确为 .zero ----
    let roundTrip = [CGPoint(x: 12, y: 4), CGPoint(x: 3, y: -9), base]
    checkEqual(BaseReferencedPolicy.total(anchor: base, points: roundTrip), .zero,
               "★ 往返回到基点后位移必须精确为 .zero（增量式实现会漂移）")

    // ---- 携带基点应用：worldTransform = base + (current − 基点) ----
    let applied = Mat(tx: 100, ty: 50).applyingWorldDelta(Policy.translation(anchor: CGPoint(x: 5, y: 5), from: base))
    checkEqual(applied, Mat(tx: 105, ty: 55), "世界位移必须叠加到基点上")
}

// MARK: - 断言 4：反证 —— 增量累加式破坏变体必须被抓到

func verifyBrokenVariantIsCaught() {
    let base = CGPoint(x: 0, y: 0)

    // ① 亚像素帧被过滤 → 增量式丢位移。
    let withSkippedFrame = [CGPoint(x: 5, y: 0), CGPoint(x: 5.2, y: 0), base]
    let correct = BaseReferencedPolicy.total(anchor: base, points: withSkippedFrame)
    let broken = BrokenAccumulatingPolicy.total(start: base, points: withSkippedFrame)
    checkEqual(correct, .zero, "正确实现：往返回到基点位移为零")
    check(broken != .zero, "★ 增量式破坏变体在亚像素帧上丢掉位移，返回后必然漂移")
    check(correct != broken, "★ 正反两实现必须在亚像素往返序列上分歧")

    // ② 浮点漂移：非精确二进制小数往返。
    let driftTrip = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.7), base]
    let correctDrift = BaseReferencedPolicy.total(anchor: base, points: driftTrip)
    let brokenDrift = BrokenAccumulatingPolicy.total(start: base, points: driftTrip)
    checkEqual(correctDrift, .zero, "正确实现：浮点往返位移仍精确为零")
    check(brokenDrift != .zero, "★ 增量累加在浮点往返上必然留下漂移残差")
    check(correctDrift != brokenDrift, "★ 正反两实现必须在浮点往返序列上分歧")

    // ③ 门禁不得退化成恒真：至少要有一批真实断言。
    check(checks > 80, "断言数量必须足够大（实际 \(checks) 条），否则等于没查")
}

// MARK: - 运行

verifySourceGuardrails()
verifyExhaustiveInvariants()
verifyThresholdParity()
verifyReanchorAndBaseSemantics()
verifyBrokenVariantIsCaught()

let strict = CommandLine.arguments.contains("--strict")
if failures.isEmpty {
    print("✓ 拖动相位机：\(checks)/\(checks) 条断言通过")
    exit(0)
}
print("✗ \(failures.count)/\(checks) 条断言失败：")
for line in failures { print("  - \(line)") }
exit(strict ? 1 : 0)
