import SwiftUI

/// 长按只抬起顶端的方形封面，不包含下面的名称和统计文字。
struct SquareCoverPreviewShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: CGRect(origin: rect.origin, size: CGSize(width: rect.width, height: rect.width)))
    }
}

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
