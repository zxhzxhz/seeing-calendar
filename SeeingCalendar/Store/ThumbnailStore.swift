import Observation
import PencilKit
import SwiftData
import UIKit

/// 多级缩略图缓存：内存 NSCache → 磁盘 PNG → 缺失时离线重建。
///
/// 1.0.18 起增加两条约束（都是为了修「翻回来缩略图消失」）：
///
/// ① **同页并发生成必须合并，而不是让后来的请求空手而归。**
///    月历同时常驻三个月，同一个日期键会落在两个月的网格里（例如 10 月网格的第 1 行
///    含 9/27–9/30，9 月网格里当然也有 9/30），两个格会几乎同时请求同一页的缩略图。
///    旧实现里 `regenerate` 见到同名文件正在生成就直接 `return`，`thumbnail(for:)`
///    随后读到空缓存便返回 `nil` —— 于是「谁抢输谁那格就是空的」。
///    现在改为 `[文件名: Task]` 合并，后来者 `await` 同一个 Task，人人有图。
///
/// ② **装载补齐不推进 `version`。**
///    `version` 是驱动月历整棵子树的信号，代次一跳，126 个日格就得重算一遍。
///    翻页过程中大量缩略图是「首次补齐」，那不是内容变化，不该惊动月历。
///    只有真正的内容变化（编辑保存、删除、导入恢复）才 `version &+= 1`。
@MainActor
@Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// 内容代次，用于驱动 SwiftUI 刷新（NSCache 本身不可观察）。
    /// **只表示「内容变了」**，缓存补齐不推进。
    private(set) var version: Int = 0

    private let memory = NSCache<NSString, UIImage>()
    /// 同页在途生成合并表：后来者 await 同一个 Task。
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memory.countLimit = 240
        memory.totalCostLimit = 64 << 20
    }

    func cached(_ fileName: String) -> UIImage? {
        memory.object(forKey: fileName as NSString)
    }

    /// 内容失效：编辑删除 / 清空后调用。图与磁盘文件一起清，并推进代次。
    func invalidate(_ fileName: String) {
        memory.removeObject(forKey: fileName as NSString)
        try? FileManager.default.removeItem(at: AppPaths.thumbnailURL(fileName))
        version &+= 1
    }

    /// 全量失效（导入恢复后调用，缩略图会按需重建）。
    func invalidateAll() {
        memory.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.thumbnails,
                                                                 includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        version &+= 1
    }

    /// 月历封面取图：**同页并发自动合并**，绝不会因为「别人正在生成」而返回 nil。
    func thumbnail(for page: DrawingPage) async -> UIImage? {
        let name = page.thumbnailFileName
        if let image = memory.object(forKey: name as NSString) { return image }

        // 同页已有在途生成 → 等它，绝不自建第二个任务。
        if let existing = inFlight[name] { return await existing.value }

        let task = Task<UIImage?, Never> { [weak self] in
            await self?.produce(name: name, page: page)
        }
        inFlight[name] = task
        defer { inFlight[name] = nil }
        return await task.value
    }

    /// 磁盘优先，其次合并出图。**只补齐、不破坏**：既不删已有文件，也不推进代次。
    private func produce(name: String, page: DrawingPage) async -> UIImage? {
        let url = AppPaths.thumbnailURL(name)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            memory.setObject(image, forKey: name as NSString, cost: data.count)
            return image
        }
        await render(page: page, name: name, isContentChange: false)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            memory.setObject(image, forKey: name as NSString, cost: data.count)
            return image
        }
        return nil
    }

    /// 内容变更后重算并落盘（编辑器路径调用）：空白页则清理缓存并推进代次。
    func regenerate(page: DrawingPage) async {
        await render(page: page, name: page.thumbnailFileName)
        version &+= 1
    }

    /// 真正干活的合成：后台渲染 1:1 PNG 并落盘。
    ///
    /// `isContentChange` 决定失败时的处置：
    /// - `true`（编辑保存）：渲染不出内容（空页）→ 清理陈旧缓存 + 推进代次（内容确实变了）；
    /// - `false`（装载补齐）：**只读不写**，绝不删文件、绝不推进代次 ——
    ///   装载路径没有资格宣布「这个页没内容」。
    private func render(page: DrawingPage, name: String, isContentChange: Bool = true) async {
        let url = AppPaths.thumbnailURL(name)
        let specs: [ThumbnailImageSpec] = page.orderedImages.map { record in
            ThumbnailImageSpec(url: AppPaths.assetURL(record.fileName),
                               worldTransform: record.worldTransform,
                               cropRect: record.cropRectOnImage,
                               naturalSize: record.naturalSize)
        }
        let drawingURL = page.drawingURL

        let png = await Task.detached(priority: .utility) {
            ThumbnailRenderer.renderPNG(drawingFile: drawingURL, images: specs)
        }.value

        guard let png else {
            if isContentChange {
                memory.removeObject(forKey: name as NSString)
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        try? png.write(to: url, options: .atomic)
        if let image = UIImage(data: png) {
            memory.setObject(image, forKey: name as NSString, cost: png.count)
        }
    }
}

extension DrawingPage {
    var thumbnailFileName: String {
        let base = drawingFile.hasSuffix(".drawing")
            ? String(drawingFile.dropLast(".drawing".count))
            : drawingFile
        return base + ".png"
    }
}
