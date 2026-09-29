#!/usr/bin/env python3
"""Round-2 patch (part 2): editor toolbar — tool/lasso mutual exclusion + working maximize button."""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATH = ROOT / "SeeingCalendar/Views/DayEditorView.swift"


def main() -> None:
    text = PATH.read_text(encoding="utf-8")
    pairs = [
        (
            """            ForEach(CanvasTool.allCases) { tool in
                Button {
                    model.activeTool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(model.activeTool == tool ? Color.accentColor.opacity(0.18) : .clear)
                        )
                }
                .accessibilityLabel(tool.title)
            }""",
            """            ForEach(CanvasTool.allCases) { tool in
                Button {
                    model.select(tool: tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(model.activeTool == tool && !model.isLassoActive
                                      ? Color.accentColor.opacity(0.18)
                                      : .clear)
                        )
                }
                .accessibilityLabel(tool.title)
            }""",
        ),
        (
            """            Button {
                model.isLassoActive.toggle()
            } label: {
                Image(systemName: "lasso")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.isLassoActive ? Color.accentColor.opacity(0.20) : .clear)
                    )
            }
            .accessibilityLabel("统一套索")""",
            """            Button {
                model.toggleLasso()
            } label: {
                Image(systemName: "lasso")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.isLassoActive ? Color.accentColor.opacity(0.20) : .clear)
                    )
            }
            .accessibilityLabel("统一套索")""",
        ),
        (
            """            Button {
                model.zoomToFit()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14))
            }
            .accessibilityLabel("适应画布")""",
            """            if model.isLassoActive {
                Text("套索")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Button {
                model.toggleCanvasZoom()
            } label: {
                Image(systemName: model.isCanvasExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.isCanvasExpanded ? Color.accentColor.opacity(0.18) : .clear)
                    )
            }
            .accessibilityLabel(model.isCanvasExpanded ? "缩小画布" : "最大化画布")""",
        ),
    ]

    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"MISS: {old[:80]!r}")
        text = text.replace(old, new, 1)
    PATH.write_text(text, encoding="utf-8")
    print("patched", PATH.relative_to(ROOT))


if __name__ == "__main__":
    main()
