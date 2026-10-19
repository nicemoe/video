import SwiftUI

struct CollageContextPreview: View {
    let assets: [Asset]
    let side: CGFloat
    let tint: Color
    var emptyIcon = "photo.on.rectangle.angled"

    var body: some View {
        CoverCollage(assets: assets, side: side, tint: tint, emptyIcon: emptyIcon)
            .frame(width: side, height: side)
            // 画满系统预览容器，由系统统一裁圆角，避免两层圆角之间露出底色。
            .clipped()
    }
}
