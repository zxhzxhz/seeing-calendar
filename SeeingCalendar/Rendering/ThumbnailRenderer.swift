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
    static func renderPNG(drawingFile: URL,
                          images: [ThumbnailImageSpec],
                          targetWidth: CGFloat = defaultThumbnailWidth) -> Data? {
        let data = (try? Data(contentsOf: drawingFile)) ?? Data()
        let drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        guard !drawing.strokes.isEmpty || !images.isEmpty else { return nil }
        return render(drawing: drawing, images: images, targetWidth: targetWidth).pngData()
    }
}
