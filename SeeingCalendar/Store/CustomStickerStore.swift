import Foundation
import UIKit

/// 自定义贴纸条目
struct CustomStickerItem: Codable, Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    /// 若来源于画布图元，记录其几何与内容的特征指纹；相同指纹不重复添加，变化后作为新贴纸
    let sourceFingerprint: String?

    init(id: UUID = UUID(), fileName: String, createdAt: Date = Date(), sourceFingerprint: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.sourceFingerprint = sourceFingerprint
    }
}

/// 自定义贴纸管理器：负责导入、删除、排序与持久化
@MainActor
final class CustomStickerStore: ObservableObject {
    static let shared = CustomStickerStore()

    private let defaults = UserDefaults.standard
    private let sortKey = "customStickers.sortAscending"
    private var indexURL: URL {
        AppPaths.root.appendingPathComponent("custom_stickers_index.json")
    }

    @Published private(set) var items: [CustomStickerItem] = []
    @Published var sortAscending: Bool {
        didSet {
            defaults.set(sortAscending, forKey: sortKey)
        }
    }

    private init() {
        self.sortAscending = defaults.bool(forKey: sortKey)
        load()
    }

    /// 从索引文件加载贴纸列表
    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([CustomStickerItem].self, from: data) else {
            self.items = []
            return
        }
        // 校验文件是否存在，剔除磁盘上已缺失的项
        let valid = list.filter {
            let url = AppPaths.customStickerURL($0.fileName)
            return FileManager.default.fileExists(atPath: url.path)
        }
        self.items = valid
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 添加贴纸：可从相册、键盘贴纸或画布图元传入
    /// 如果提供了指纹且已有相同指纹的贴纸，则复用已有贴纸（防止重复刷入同一图元）；
    /// 如果指纹不同（如大小、裁剪、旋转或文字改变）或未提供指纹，则保存为全新贴纸。
    @discardableResult
    func addSticker(imageData: Data, fingerprint: String? = nil) -> CustomStickerItem? {
        if let fp = fingerprint, !fp.isEmpty {
            if let existing = items.first(where: { $0.sourceFingerprint == fp }) {
                return existing
            }
        }

        let fileName = "sticker_\(UUID().uuidString).png"
        let fileURL = AppPaths.customStickerURL(fileName)
        do {
            try imageData.write(to: fileURL, options: .atomic)
            let item = CustomStickerItem(fileName: fileName, createdAt: Date(), sourceFingerprint: fingerprint)
            items.insert(item, at: 0)
            saveIndex()
            return item
        } catch {
            return nil
        }
    }

    /// 删除指定贴纸
    func deleteSticker(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        let fileURL = AppPaths.customStickerURL(item.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        saveIndex()
    }

    /// 获取当前排序后的贴纸列表
    var sortedItems: [CustomStickerItem] {
        if sortAscending {
            // 顺序：最早添加在前
            return items.sorted { $0.createdAt < $1.createdAt }
        } else {
            // 逆序：最新添加在前
            return items.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// 读取贴纸图片数据
    func stickerData(for item: CustomStickerItem) -> Data? {
        let fileURL = AppPaths.customStickerURL(item.fileName)
        return try? Data(contentsOf: fileURL)
    }

    /// 读取贴纸 UIImage
    func stickerImage(for item: CustomStickerItem) -> UIImage? {
        let fileURL = AppPaths.customStickerURL(item.fileName)
        return UIImage(contentsOfFile: fileURL.path)
    }
}
