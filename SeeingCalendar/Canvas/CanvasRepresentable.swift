import SwiftUI

/// SwiftUI ↔ UIKit 桥接：状态同步是单向的（模型 → UIKit），避免更新期间回写 SwiftUI 状态。
struct CanvasRepresentable: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> CanvasHostView {
        let host = CanvasHostView()
        model.attach(host: host)
        return host
    }

    func updateUIView(_ uiView: CanvasHostView, context: Context) {
        model.syncUIKitState(of: uiView)
    }
}
