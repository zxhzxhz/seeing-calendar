#!/usr/bin/env python3
"""Round-6 patch A: pageCount 冗余（消除月历渲染时的关系 fault）+ 页面排序能力。"""
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
    "SeeingCalendar/Models/Models.swift",
    [
        (
            """    var note: String
    var updatedAt: Date
    var workspace: Workspace?""",
            """    var note: String
    var updatedAt: Date
    /// 冗余页数：月历一次要渲染 126 个格子，若逐格访问 `pages` 关系会触发大量 SwiftData fault，
    /// 在真机上表现为「点选日期有十分明显的延迟」。这里用整型冗余把 fault 从渲染路径上彻底移除。
    var pageCount: Int = 0
    var workspace: Workspace?""",
        ),
        (
            """    var orderedPages: [DrawingPage] {
        pages.sorted { $0.index < $1.index }
    }""",
            """    var orderedPages: [DrawingPage] {
        pages.sorted { $0.index < $1.index }
    }

    /// 与 `pages.count` 对齐（关系变化后调用）。
    func syncPageCount() {
        pageCount = pages.count
    }""",
        ),
    ],
)

patch(
    "SeeingCalendar/Store/PageRepository.swift",
    [
        (
            """    @discardableResult
    func addPage(to day: DayRecord) -> DrawingPage {
        let index = (day.pages.map(\\.index).max() ?? -1) + 1
        let page = DrawingPage(index: index, dayKey: day.key, drawingFile: AppPaths.newFileName(extension: "drawing"))
        context.insert(page)
        page.day = day
        day.updatedAt = .now
        try? context.save()
        return page
    }""",
            """    @discardableResult
    func addPage(to day: DayRecord) -> DrawingPage {
        let index = (day.pages.map(\\.index).max() ?? -1) + 1
        let page = DrawingPage(index: index, dayKey: day.key, drawingFile: AppPaths.newFileName(extension: "drawing"))
        context.insert(page)
        page.day = day
        day.updatedAt = .now
        day.syncPageCount()
        try? context.save()
        return page
    }

    /// 按给定顺序重排页面：index 即位置，Page 1 自动成为月历封面。
    func applyPageOrder(_ ordered: [DrawingPage], in day: DayRecord) {
        for (position, page) in ordered.enumerated() where page.index != position {
            page.index = position
        }
        day.syncPageCount()
        day.updatedAt = .now
        try? context.save()
    }

    /// 一次性回填历史数据的 pageCount（旧库升级到本版本时执行一次）。
    func backfillPageCountsIfNeeded() {
        let key = "didBackfillPageCounts_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let descriptor = FetchDescriptor<DayRecord>()
        let days = (try? context.fetch(descriptor)) ?? []
        for day in days {
            let actual = day.pages.count
            if day.pageCount != actual {
                day.pageCount = actual
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }""",
        ),
        (
            """    /// 删除页面后重排索引（Page 1 语义必须保持连续）。
    func reindex(_ day: DayRecord) {
        let ordered = day.pages.sorted { $0.index < $1.index }
        for (index, page) in ordered.enumerated() where page.index != index {
            page.index = index
        }
        try? context.save()
    }""",
            """    /// 删除页面后重排索引（Page 1 语义必须保持连续）。
    func reindex(_ day: DayRecord) {
        let ordered = day.pages.sorted { $0.index < $1.index }
        for (index, page) in ordered.enumerated() where page.index != index {
            page.index = index
        }
        day.syncPageCount()
        try? context.save()
    }""",
        ),
    ],
)

print("done")
