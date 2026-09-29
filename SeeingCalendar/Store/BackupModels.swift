import Foundation

// MARK: - 编解码统一配置

enum BackupCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - `.vcal` 容器内部结构

enum BackupEntry {
    static let manifest = "manifest.json"
    static let database = "database_dump.json"
    static let drawingsPrefix = "drawings/"
    static let assetsPrefix = "assets/"

    static func drawing(_ file: String) -> String { drawingsPrefix + file }
    static func asset(_ file: String) -> String { assetsPrefix + file }
    static func isPayload(_ name: String) -> Bool {
        name.hasPrefix(drawingsPrefix) || name.hasPrefix(assetsPrefix)
    }
}

struct BackupManifest: Codable, Sendable {
    var schemaVersion: Int
    var appVersion: String
    var exportDate: Date
    var deviceModel: String
    var systemVersion: String
    var workspaceCount: Int
    var dayCount: Int
    var pageCount: Int
    var imageCount: Int
    /// `database_dump.json` 的 SHA-256 指纹，用于导入前的完整性校验。
    var databaseDigest: String
}

struct BackupDatabase: Codable, Sendable {
    var workspaces: [WorkspaceDTO] = []
    var days: [DayDTO] = []
    var pages: [PageDTO] = []
    var images: [ImageDTO] = []
    var subscriptions: [SubscriptionDTO] = []
}

struct WorkspaceDTO: Codable, Sendable {
    var uuid: UUID
    var name: String
    var sortIndex: Int
    var createdAt: Date
}

struct DayDTO: Codable, Sendable {
    var workspaceUUID: UUID
    var dateKey: String
    var note: String
    var updatedAt: Date
    var pageUUIDs: [UUID] = []
}

struct PageDTO: Codable, Sendable {
    var uuid: UUID
    var index: Int
    var drawingFile: String
    var updatedAt: Date
    var imageUUIDs: [UUID] = []
}

struct ImageDTO: Codable, Sendable {
    var uuid: UUID
    var fileName: String
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var tx: Double
    var ty: Double
    var cropX: Double
    var cropY: Double
    var cropW: Double
    var cropH: Double
    var naturalWidth: Double
    var naturalHeight: Double
    var zIndex: Int
}

struct SubscriptionDTO: Codable, Sendable {
    var uuid: UUID
    var name: String
    var urlString: String
    var colorHex: String
    var workspaceUUID: UUID?
    var isEnabled: Bool
}

// MARK: - 传输载体

struct BackupRequest: Sendable {
    var database: BackupDatabase
    var appVersion: String
    var deviceModel: String
    var systemVersion: String
    var exportDate: Date
    var fileName: String
    /// 归档内条目名 → 沙盒文件
    var drawingFiles: [String: URL]
    var assetFiles: [String: URL]
}

struct RestoreBundle: Sendable {
    var manifest: BackupManifest?
    var database: BackupDatabase
    /// `database_dump.json` 原始字节，用于与清单指纹比对。
    var databaseData: Data
    /// 归档内条目名 → 已解压的临时文件
    var files: [String: URL]
}

enum RestoreMode: String, CaseIterable, Identifiable, Sendable {
    case fullOverwrite
    case smartMerge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullOverwrite: return "完整覆写"
        case .smartMerge: return "智能增量合并"
        }
    }

    var detail: String {
        switch self {
        case .fullOverwrite:
            return "清空当前库，以备份为绝对基准全量还原。"
        case .smartMerge:
            return "保留当前数据；同日冲突时把备份的多页画作转为后置拓展页，绝不覆盖已有笔迹。"
        }
    }
}

struct RestoreSummary: Sendable {
    var mode: RestoreMode = .smartMerge
    var workspaces = 0
    var days = 0
    var pages = 0
    var images = 0
    var subscriptions = 0

    var message: String {
        "\(mode.title)完成：维度 \(workspaces) · 日期 \(days) · 画页 \(pages) · 贴图 \(images) · 订阅 \(subscriptions)"
    }
}

enum RestoreError: LocalizedError {
    case missingDatabase
    case digestMismatch
    case emptyBackup

    var errorDescription: String? {
        switch self {
        case .missingDatabase: return "归档中缺少 database_dump.json"
        case .digestMismatch: return "归档指纹校验失败，文件可能已损坏"
        case .emptyBackup: return "归档中没有可用数据"
        }
    }
}
