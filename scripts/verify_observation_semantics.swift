#!/usr/bin/env swift
//
//  verify_observation_semantics.swift
//  能力探针：确认 @Observable 宏是否保留 didSet 观察器。
//
//  背景：EditorModel 曾用 `var activeTool { didSet { toolNeedsApply = true } }` 驱动工具下发。
//  若宏会丢弃观察器，这条链路就完全依赖 SwiftUI 的更新回合，一旦更新回合被打断（例如
//  fullScreenCover 内容因捕获状态变化被重建），工具就再也不下发 —— 现象正是
//  「开启手指输入后，切换任何笔/工具都用同一支笔」。
//  本探针只打印事实，供实现层取舍；断言式门禁见 verify_transform_math.swift。
//
import Darwin
import Foundation
import Observation

@Observable
final class DidSetProbe {
    var value: Int = 0 {
        didSet { observerFireCount += 1 }
    }
    var observerFireCount: Int = 0
}

@Observable
final class SignatureProbe {
    var tool: String = "pen"
    private(set) var applied: [String] = []

    func applyIfNeeded() {
        let signature = "\(tool)"
        guard applied.last != signature else { return }
        applied.append(signature)
    }
}

print("=== @Observable 能力探针 ===")

let probe = DidSetProbe()
probe.value = 1
probe.value = 2
probe.value = 3
print("didSet 触发次数: \(probe.observerFireCount)（期望 3）")
if probe.observerFireCount == 3 {
    print("✅ @Observable 保留 didSet 观察器")
} else {
    print("⚠️ @Observable 丢弃了 didSet 观察器 —— 实现层不得依赖属性观察器驱动副作用")
}

// 幂等签名式同步：无论观察器语义如何，都应可靠生效
let signatureProbe = SignatureProbe()
signatureProbe.applyIfNeeded()
signatureProbe.tool = "marker"
signatureProbe.applyIfNeeded()
signatureProbe.applyIfNeeded()
signatureProbe.tool = "pencil"
signatureProbe.applyIfNeeded()
print("签名式同步下发序列: \(signatureProbe.applied)（期望 [pen, marker, pencil]）")
if signatureProbe.applied == ["pen", "marker", "pencil"] {
    print("✅ 幂等签名式同步不依赖属性观察器，可安全替代标志位方案")
} else {
    print("❌ 签名式同步逻辑有误")
    exit(1)
}

print("\nDONE")
