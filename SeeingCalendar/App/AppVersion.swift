import Foundation

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
    /// 依据**窗口场景方向**判断横竖屏，而不是比较视图尺寸。
    ///
    /// 键盘弹出会压缩视图高度：若用 `proxy.size.height > proxy.size.width` 判断，
    /// iPad 竖屏（1024×1366）在键盘占去约 400pt 后会「翻转」成横屏分支，
    /// 整个布局被替换、TextField 被销毁 —— 这就是「便签一聚焦键盘就消失、上方页面变形」的真实根因。
    static var isPortrait: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene else { return true }
        switch scene.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return false
        default: return true
        }
    }
}
