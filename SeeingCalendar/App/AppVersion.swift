import Foundation
import SwiftUI
import UIKit

/// 版本信息（由 Xcode 构建设置注入：MARKETING_VERSION / CURRENT_PROJECT_VERSION）。
enum AppVersion {
    static var marketing: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// 形如 `v1.0.1 (128)`。
    static var display: String { "v\(marketing) (\(build))" }
}

enum DeviceLayout {
    /// 依据**窗口场景方向**判断横竖屏，而不是仅比较视图尺寸。
    ///
    /// 键盘弹出会压缩视图高度：若直接用 `proxy.size.height > proxy.size.width` 判断，
    /// iPad 竖屏（1024×1366）在键盘占去约 400pt 后会「翻转」成横屏分支，
    /// 整个布局被替换、TextField 被销毁 —— 这就是「便签一聚焦键盘就消失、上方页面变形」的真实根因。
    @MainActor
    static var isPortrait: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene else { return true }
        switch scene.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return false
        default: return true
        }
    }

    /// 综合考虑 iPadOS 分屏（Split View）、台前调度（Stage Manager）以及防键盘抖动的布局自适应判定。
    @MainActor
    static func isPortraitLayout(horizontalSizeClass: UserInterfaceSizeClass?, size: CGSize) -> Bool {
        // 1. 紧凑水平尺寸（如 1/3 分屏、Slide Over、小窗口）：必须使用竖屏单列流式布局
        if horizontalSizeClass == .compact { return true }
        // 2. 宽度过窄不足以容纳横屏日历矩阵与左右排布时：强制单列
        if size.width < 680 { return true }
        // 3. 宿主窗口物理方向为竖屏：即使用户唤起键盘压缩高度，也绝对锁定竖屏分支（防键盘反跳）
        if isPortrait { return true }
        // 4. 台前调度下的细长悬浮窗口
        if size.height > size.width * 1.15 { return true }
        return false
    }
}
