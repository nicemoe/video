import SwiftUI
import UIKit

/// 放在滚动内容里，只缩小系统刷新控件，刷新仍由 .refreshable 管理。
struct CompactRefreshIndicator: UIViewRepresentable {
    func makeUIView(context: Context) -> IndicatorSizingView {
        let view = IndicatorSizingView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: IndicatorSizingView, context: Context) {
        uiView.setNeedsLayout()
    }

    final class IndicatorSizingView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // 等 SwiftUI 安装滚动容器及 refreshControl 后，在下一轮布局中调整。
            DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if let control = scrollView.refreshControl {
                        let scale = CGAffineTransform(scaleX: 0.65, y: 0.65)
                        if control.transform != scale { control.transform = scale }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
