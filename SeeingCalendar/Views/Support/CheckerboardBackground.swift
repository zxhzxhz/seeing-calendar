import SwiftUI

/// 棋盘格透明指示背景（用于文字/图形/贴纸透明度展示）
struct CheckerboardBackground: View {
    var step: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / step))
            let rows = Int(ceil(size.height / step))

            for r in 0..<rows {
                for c in 0..<cols {
                    let isEven = (r + c) % 2 == 0
                    let rect = CGRect(x: CGFloat(c) * step, y: CGFloat(r) * step, width: step, height: step)
                    let color = isEven ? Color(uiColor: .systemBackground) : Color(uiColor: .secondarySystemBackground)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
