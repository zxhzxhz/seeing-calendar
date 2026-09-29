#!/usr/bin/env python3
"""Round-3 patch E: unique zoom-transition source IDs + version display in backup sheet."""
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
    "SeeingCalendar/Views/MonthGridView.swift",
    [
        (
            """            .matchedTransitionSource(id: key, in: zoomNamespace)""",
            """            .matchedTransitionSource(id: transitionID(for: key), in: zoomNamespace)""",
        ),
        (
            """    private func loadThumbnails() async {""",
            """    /// 转场源 ID 必须全局唯一：相邻月份的网格会包含同一天，
    /// 因此用「当前月键|日期键」组合，避免同屏出现重复 source。
    private func transitionID(for key: String) -> String {
        "\\(CalendarUtils.key(for: CalendarUtils.startOfMonth(month)))|\\(key)"
    }

    private func loadThumbnails() async {""",
        ),
    ],
)

patch(
    "SeeingCalendar/Views/RootView.swift",
    [
        (
            """struct EditorRequest: Identifiable {
    let day: DayRecord
    let pageIndex: Int
    var id: String { "\\(day.key)-\\(pageIndex)" }
    var sourceID: String { day.key }
}""",
            """struct EditorRequest: Identifiable {
    let day: DayRecord
    let pageIndex: Int
    /// 与 MonthGridView 的 `matchedTransitionSource` 一一对应（当前月键|日期键）。
    let sourceID: String
    var id: String { "\\(day.key)-\\(pageIndex)" }
}""",
        ),
        (
            """        selectedDate = date
        // 注意：不切换月视图 —— 点选相邻月的日格时，画布应在**本页**弹出。
        editorRequest = EditorRequest(day: record, pageIndex: pageIndex)""",
            """        selectedDate = date
        // 注意：不切换月视图 —— 点选相邻月的日格时，画布应在**本页**弹出。
        let sourceID = "\\(CalendarUtils.key(for: CalendarUtils.startOfMonth(month)))|\\(CalendarUtils.key(for: date))"
        editorRequest = EditorRequest(day: record, pageIndex: pageIndex, sourceID: sourceID)""",
        ),
    ],
)

patch(
    "SeeingCalendar/Views/BackupView.swift",
    [
        (
            """    @ViewBuilder
    private var statusSection: some View {
        Section {""",
            """    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                Label("版本", systemImage: "number")
                    .font(.system(size: 13))
                Spacer()
                Text(AppVersion.display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }""",
        ),
    ],
)

print("done")
