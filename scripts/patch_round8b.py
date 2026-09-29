#!/usr/bin/env python3
"""Round-8 patch B: 显式绘制「变换基准点」十字标记 —— 让"以选区正中心为基准"可视化可验证。"""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def patch(rel: str, pairs: list[tuple[str, str]]) -> None:
    path = ROOT / rel
    text = path.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"MISS in {rel}: {old[:90]!r}")
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print("patched", rel)


patch(
    "SeeingCalendar/Canvas/SelectionOverlayView.swift",
    [
        (
            """    private(set) var mode: Mode = .none
    private let marqueeLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()""",
            """    private(set) var mode: Mode = .none
    private let marqueeLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()
    /// 变换基准点标记（缩放/旋转的不动点 = 选区正中心）。
    private let pivotLayer = CAShapeLayer()"""
        ),
        (
            """        lassoLayer.lineWidth = 1.5
        lassoLayer.lineJoin = .round
        layer.addSublayer(lassoLayer)""",
            """        lassoLayer.lineWidth = 1.5
        lassoLayer.lineJoin = .round
        layer.addSublayer(lassoLayer)

        pivotLayer.strokeColor = UIColor.systemBlue.cgColor
        pivotLayer.fillColor = UIColor.clear.cgColor
        pivotLayer.lineWidth = 1.5
        layer.addSublayer(pivotLayer)"""
        ),
        (
            """        let layout = handleLayout()
        for handle in handleViews {""",
            """        updatePivotLayer(scale: scale)

        let layout = handleLayout()
        for handle in handleViews {"""
        ),
        (
            """    // MARK: - 内部拖动（仅变形态）""",
            """    /// 基准点：单选/复合变形都以包围盒中心为不动点，这里把它画出来（圆 + 十字）。
    private func updatePivotLayer(scale: CGFloat) {
        guard let center = pivotPoint() else {
            pivotLayer.path = nil
            return
        }
        let radius = 7 * scale
        let arm = 11 * scale
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        pivotLayer.path = path
        pivotLayer.lineWidth = 1.5 * scale
    }

    /// 变换不动点。单图与复合选区的缩放/旋转都以它为中心。
    func pivotPoint() -> CGPoint? {
        switch mode {
        case .none, .composite:
            return nil
        case .compositeTransform(let rect):
            return CGPoint(x: rect.midX, y: rect.midY)
        case .cropping(let quad):
            guard quad.count == 4 else { return nil }
            let box = CanvasGeometry.boundingBox(quad)
            return CGPoint(x: box.midX, y: box.midY)
        case .image(let quad):
            guard quad.count == 4 else { return nil }
            let box = CanvasGeometry.boundingBox(quad)
            return CGPoint(x: box.midX, y: box.midY)
        }
    }

    // MARK: - 内部拖动（仅变形态）"""
        ),
    ],
)

print("done")
