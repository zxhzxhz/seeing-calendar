import Foundation

/// 沙盒目录规划：所有大体积二进制（笔迹 / 贴图）走文件系统，元数据走 SwiftData。
enum AppPaths {
    /// Application Support/SeeingCalendar —— 需要备份的用户数据根目录。
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("SeeingCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Caches/SeeingCalendar —— 可被系统回收的派生数据。
    static let cacheRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("SeeingCalendar", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// PencilKit `.drawing` 矢量笔迹。
    static let drawings: URL = makeDirectory(root, "drawings")
    /// 贴图 / 照片原始码流（保持导入时的编码，不做二次转码）。
    static let assets: URL = makeDirectory(root, "assets")
    /// 自动本地快照。
    static let snapshots: URL = makeDirectory(root, "Backups")
    /// 分级缩略图缓存。
    static let thumbnails: URL = makeDirectory(cacheRoot, "Thumbnails")
    /// 备份 / 恢复的临时工作区。
    static let work: URL = makeDirectory(cacheRoot, "Work")

    static func makeDirectory(_ parent: URL, _ name: String) -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func drawingURL(_ fileName: String) -> URL { drawings.appendingPathComponent(fileName) }
    static func assetURL(_ fileName: String) -> URL { assets.appendingPathComponent(fileName) }
    static func thumbnailURL(_ fileName: String) -> URL { thumbnails.appendingPathComponent(fileName) }

    static func ensureDirectories() {
        _ = [root, cacheRoot, drawings, assets, snapshots, thumbnails, work]
        let temporary = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: temporary)
    }

    /// 生成唯一文件名：`<uuid>.<ext>`。
    static func newFileName(extension ext: String) -> String {
        let suffix = ext.isEmpty ? "png" : ext.lowercased()
        return "\(UUID().uuidString).\(suffix)"
    }

    static func fileExtension(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "png" : ext
    }

    /// 依据文件头魔术字节推断图片扩展名（保持原始编码，不做二次转码）。
    static func imageExtension(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if data.count > 12 {
            let brand = String(decoding: data[4..<12], as: UTF8.self).lowercased()
            if brand.contains("heic") || brand.contains("heif") || brand.contains("mif1") { return "heic" }
            if brand.contains("webp") { return "webp" }
        }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" }
        return "jpg"
    }

    static func makeWorkDirectory() throws -> URL {
        let url = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
