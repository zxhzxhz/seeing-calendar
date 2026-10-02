import PencilKit
import UIKit

/// 贴图离线合成描述（Sendable，可安全投递到后台 actor / detached task）。
struct ThumbnailImageSpec: Sendable {
    var url: URL
    var worldTransform: CGAffineTransform
    var cropRect: CGRect
    var naturalSize: CGSize
}

/// Page 1 缩略图确定性离线合成：中层贴图 → 顶层笔迹，严格 1:1 输出，绝不拉伸变形。
///
/// 结果类型 `ThumbnailRenderResult` 与处置策略 `ThumbnailLoadPolicy` 定义在
/// `Rendering/ThumbnailLoadPolicy.swift`（纯逻辑、无平台依赖，供 CI 门禁直接引用）。
enum ThumbnailRenderer {
    static let canvasSize = CGSize(width: 1400, height: 1400)
    static let defaultThumbnailWidth: CGFloat = 320

    static func render(drawing: PKDrawing, images: [ThumbnailImageSpec], targetWidth: CGFloat) -> UIImage {
        let scale = targetWidth / canvasSize.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetWidth, height: targetWidth), format: format)

        return renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetWidth))

            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)

            for spec in images {
                guard let image = UIImage(contentsOfFile: spec.url.path) else { continue }
                let visible = CGRect(x: 0,
                                     y: 0,
                                     width: max(1, spec.naturalSize.width * spec.cropRect.width),
                                     height: max(1, spec.naturalSize.height * spec.cropRect.height))
                cg.saveGState()
                cg.concatenate(spec.worldTransform)
                cg.clip(to: visible)
                image.draw(in: CGRect(origin: .zero, size: spec.naturalSize))
                cg.restoreGState()
            }

            let strokes = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 1)
            strokes.draw(in: CGRect(origin: .zero, size: canvasSize))
            cg.restoreGState()
        }
    }

    /// 直接从磁盘上的笔迹文件合成 PNG（可后台执行）。
    ///
    /// 注意：**既没有笔迹也没有贴图**才能断言 `.empty`。
    /// 这一条是「清空页之后月历要立刻空掉」的唯一可信依据 ——
    /// 不能把「文件读不到」也算成空，因为 `PageRepository.addPage` 不建文件，
    /// 新页在首次 `save()` 之前本来就没有 `.drawing`。
    static func renderPNG(drawingFile: URL,
                          images: [ThumbnailImageSpec],
                          targetWidth: CGFloat = defaultThumbnailWidth) -> ThumbnailRenderResult {
        var drawing = PKDrawing()
        var drawingReadable = false
        if let data = try? Data(contentsOf: drawingFile), let parsed = try? PKDrawing(data: data) {
            drawing = parsed
            drawingReadable = true
        }

        guard !drawing.strokes.isEmpty || !images.isEmpty else {
            return drawingReadable ? .empty : .unreadable
        }
        guard let png = render(drawing: drawing, images: images, targetWidth: targetWidth).pngData() else {
            return .failed
        }
        return .png(png)
    }
}
