#!/usr/bin/env python3
"""Round-6 patch E: DayEditorView —— 页面长按拖动排序 + 原生排序面板 + 橡皮设置 UI。"""
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
    "SeeingCalendar/Views/DayEditorView.swift",
    [
        (
            """    @State private var isColorPickerPresented = false""",
            """    @State private var isColorPickerPresented = false
    @State private var isPageManagerPresented = false"""
        ),
        # 页面条：长按拖动排序 + 排序入口
        (
            """                Button {
                    model.addPage()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)""",
            """                Button {
                    model.addPage()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)

                Button {
                    isPageManagerPresented = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("页面排序")"""
        ),
        (
            """                    .buttonStyle(.plain)
                    .accessibilityLabel(page.index == 0 ? "月历封面页" : "第 \\(index + 1) 页")""",
            """                    .buttonStyle(.plain)
                    .accessibilityLabel(page.index == 0 ? "月历封面页" : "第 \\(index + 1) 页")
                    // 长按拖动即可调整页面顺序（系统拖放），拖到首位即成为月历封面。
                    .draggable(page.uuid.uuidString) {
                        Text("Page \\(index + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                        withAnimation(.snappy) {
                            model.movePage(id: id, toIndex: index)
                        }
                        return true
                    }"""
        ),
        # 排序面板挂载
        (
            """        .confirmationDialog("确认清空当前页所有笔迹与贴图？", isPresented: $isClearConfirmPresented, titleVisibility: .visible) {""",
            """        .sheet(isPresented: $isPageManagerPresented) {
            PageManagerSheet(model: model)
        }
        .confirmationDialog("确认清空当前页所有笔迹与贴图？", isPresented: $isClearConfirmPresented, titleVisibility: .visible) {"""
        ),
        # 橡皮设置 UI
        (
            """    private func penSettings(model: EditorModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("墨色").font(.headline)""",
            """    @ViewBuilder
    private func penSettings(model: EditorModel) -> some View {
        if model.activeTool == .eraser {
            eraserSettings(model: model)
        } else {
            inkSettings(model: model)
        }
    }

    private func eraserSettings(model: EditorModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("橡皮模式").font(.headline)
            ForEach(EraserMode.allCases) { mode in
                Button {
                    model.eraserMode = mode
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: mode.symbol)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(mode.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if model.eraserMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            Text("橡皮大小 \\(Int(model.eraserWidth)) pt")
                .font(.subheadline)
            Slider(value: Binding(get: { model.eraserWidth }, set: { model.eraserWidth = $0 }),
                   in: 8...160,
                   step: 2)
                .frame(width: 260)
            Text("触碰画布时会显示同等大小的空心圆圈，圈内即为擦除范围。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
        }
        .padding(16)
    }

    private func inkSettings(model: EditorModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("墨色").font(.headline)"""
        ),
        # 底部工具栏：橡皮按钮点击后自动弹出设置（模式/大小）
        (
            """            ForEach(CanvasTool.allCases) { tool in
                Button {
                    model.select(tool: tool)
                } label: {""",
            """            ForEach(CanvasTool.allCases) { tool in
                Button {
                    model.select(tool: tool)
                    if tool == .eraser, model.activeTool == .eraser {
                        isColorPickerPresented = true   // 橡皮：直接展开模式与大小设置
                    }
                } label: {"""
        ),
        # 颜色圆点在橡皮激活时改为橡皮设置入口
        (
            """            Button {
                isColorPickerPresented.toggle()
            } label: {
                Circle()
                    .fill(Color(hex: model.penColorHex, fallback: .blue))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            }
            .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
                penSettings(model: model)
            }""",
            """            Button {
                isColorPickerPresented.toggle()
            } label: {
                if model.activeTool == .eraser {
                    Image(systemName: model.eraserMode.symbol)
                        .font(.system(size: 15))
                } else {
                    Circle()
                        .fill(Color(hex: model.penColorHex, fallback: .blue))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                }
            }
            .accessibilityLabel(model.activeTool == .eraser ? "橡皮设置" : "墨色与笔宽")
            .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
                penSettings(model: model)
            }"""
        ),
        # 排序面板实现
        (
            """/// 相机 / 相册兜底选择器。""",
            """/// 页面排序面板：使用系统 List + onMove（原生拖动手柄），长按拖动即排序。
private struct PageManagerSheet: View {
    let model: EditorModel
    @Environment(\\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.pages, id: \\.uuid) { page in
                    HStack(spacing: 12) {
                        Text("Page \\(page.index + 1)")
                            .font(.system(size: 14, weight: page.uuid == model.currentPage?.uuid ? .semibold : .regular))
                        if page.index == 0 {
                            Text("月历封面")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Text("\\(page.images.count) 张贴图")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selectPage(page.index)
                        dismiss()
                    }
                }
                .onMove { source, destination in
                    model.movePages(from: source, to: destination)
                }
            }
            .environment(\\.editMode, .constant(.active))
            .navigationTitle("页面排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("长按拖动可调整顺序；排到第一位的页面将成为月历封面缩略图。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
            }
        }
    }
}

/// 相机 / 相册兜底选择器。"""
        ),
    ],
)

print("done")
