import Observation
import PencilKit
import SwiftData
import UIKit

/// 多级缩略图缓存：内存 NSCache → 磁盘 PNG → 缺失时离线重建。
@MainActor
@Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// 内容代次，用于驱动 SwiftUI 刷新（NSCache 本身不可观察）。
    private(set) var version: Int = 0

    private let memory = NSCache<NSString, UIImage>()
    private var generating: Set<String> = []

    private init() {
        memory.countLimit = 240
        memory.totalCostLimit = 64 << 20
    }

    func cached(_ fileName: String) -> UIImage? {
        memory.object(forKey: fileName as NSString)
    }

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

    /// 月历封面取图：命中则秒回，缺失则离线重建一次。
    func thumbnail(for page: DrawingPage) async -> UIImage? {
        let name = page.thumbnailFileName
        if let image = memory.object(forKey: name as NSString) { return image }

        let url = AppPaths.thumbnailURL(name)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            memory.setObject(image, forKey: name as NSString, cost: data.count)
            return image
        }

        await regenerate(page: page)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            memory.setObject(image, forKey: name as NSString, cost: data.count)
            return image
        }
        return nil
    }

    /// 重新合成并落盘（无笔迹且无贴图的空白页直接清理缓存）。
    func regenerate(page: DrawingPage) async {
        let name = page.thumbnailFileName
        guard !generating.contains(name) else { return }
        generating.insert(name)
        defer { generating.remove(name) }

        let drawingURL = page.drawingURL
        let specs: [ThumbnailImageSpec] = page.orderedImages.map { record in
            ThumbnailImageSpec(url: AppPaths.assetURL(record.fileName),
                               worldTransform: record.worldTransform,
                               cropRect: record.cropRectOnImage,
                               naturalSize: record.naturalSize)
        }
        let targetURL = AppPaths.thumbnailURL(name)

        let png = await Task.detached(priority: .utility) {
            ThumbnailRenderer.renderPNG(drawingFile: drawingURL, images: specs)
        }.value

        guard let png else {
            memory.removeObject(forKey: name as NSString)
            try? FileManager.default.removeItem(at: targetURL)
            version &+= 1
            return
        }
        try? png.write(to: targetURL, options: .atomic)
        if let image = UIImage(data: png) {
            memory.setObject(image, forKey: name as NSString, cost: png.count)
        }
        version &+= 1
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
