import Foundation
import UIKit

/// 文本图元的可调配置（一次添加与二次编辑共享）
struct TextItemConfig: Codable, Equatable, Sendable {
    var text: String
    var fontSize: CGFloat
    var textColorHex: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var isStrikethrough: Bool
    var fontDesignRaw: String
    var alignmentRaw: Int     // 0: left, 1: center, 2: right, 3: justified
    var cardBackgroundRaw: String

    init(text: String = "输入文本...",
         fontSize: CGFloat = 28,
         textColorHex: String = "#000000",
         isBold: Bool = false,
         isItalic: Bool = false,
         isUnderline: Bool = false,
         isStrikethrough: Bool = false,
         fontDesignRaw: String = "default",
         alignmentRaw: Int = 0,
         cardBackgroundRaw: String = "transparent") {
        self.text = text
        self.fontSize = fontSize
        self.textColorHex = textColorHex
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikethrough = isStrikethrough
        self.fontDesignRaw = fontDesignRaw
        self.alignmentRaw = alignmentRaw
        self.cardBackgroundRaw = cardBackgroundRaw
    }
}

/// 形状图元的可调配置（一次添加与二次编辑共享）
struct ShapeItemConfig: Codable, Equatable, Sendable {
    var shapeKindRaw: String
    var strokeColorHex: String
    var strokeWidth: CGFloat
    var fillTypeRaw: String    // "none", "translucent", "solid"
    var fillColorHex: String
    var opacity: Double        // 整体透明度 0.1 ... 1.0

    init(shapeKindRaw: String = "roundedRect",
         strokeColorHex: String = "#000000",
         strokeWidth: CGFloat = 4,
         fillTypeRaw: String = "none",
         fillColorHex: String = "#FFCC00",
         opacity: Double = 1.0) {
        self.shapeKindRaw = shapeKindRaw
        self.strokeColorHex = strokeColorHex
        self.strokeWidth = strokeWidth
        self.fillTypeRaw = fillTypeRaw
        self.fillColorHex = fillColorHex
        self.opacity = opacity
    }
}

/// 画布图元专有载荷类型
enum CanvasItemPayload: Codable, Equatable, Sendable {
    case text(TextItemConfig)
    case shape(ShapeItemConfig)

    private enum CodingKeys: String, CodingKey {
        case type, textConfig, shapeConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "text" {
            let config = try container.decode(TextItemConfig.self, forKey: .textConfig)
            self = .text(config)
        } else if type == "shape" {
            let config = try container.decode(ShapeItemConfig.self, forKey: .shapeConfig)
            self = .shape(config)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown payload type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let config):
            try container.encode("text", forKey: .type)
            try container.encode(config, forKey: .textConfig)
        case .shape(let config):
            try container.encode("shape", forKey: .type)
            try container.encode(config, forKey: .shapeConfig)
        }
    }
}

/// 图元元数据本地磁盘存储（零侵入 SwiftData Schema，安全幂等）
enum CanvasPayloadStore {
    private static func metaURL(for fileName: String) -> URL {
        AppPaths.assetURL(fileName).deletingPathExtension().appendingPathExtension("meta")
    }

    static func savePayload(_ payload: CanvasItemPayload, for fileName: String) {
        let url = metaURL(for: fileName)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // 写入失败不中断主流程
        }
    }

    static func loadPayload(for fileName: String) -> CanvasItemPayload? {
        let url = metaURL(for: fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CanvasItemPayload.self, from: data)
    }

    static func deletePayload(for fileName: String) {
        let url = metaURL(for: fileName)
        try? FileManager.default.removeItem(at: url)
    }

    static func duplicatePayload(from originalFileName: String, to newFileName: String) {
        guard let payload = loadPayload(for: originalFileName) else { return }
        savePayload(payload, for: newFileName)
    }
}
