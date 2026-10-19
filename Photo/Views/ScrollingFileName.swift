import SwiftUI

/// 固定单行高度，长名称在两端停留后往返滚动。
struct ScrollingFileName: View {
    let text: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var availableWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - availableWidth) }
    private var isScrolling: Bool {
        isVisible && scenePhase == .active && !reduceMotion && availableWidth > 0 && overflow > 0
    }

    private var label: some View {
        Text(verbatim: text)
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.label)
            .lineLimit(1)
    }

    var body: some View {
        label
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
            .readingWidth($availableWidth)
            .opacity(isScrolling ? 0 : 1)
            .overlay(alignment: .leading) {
                // 固有文字宽度只参与测量，不参与卡片的尺寸计算。
                label
                    .fixedSize(horizontal: true, vertical: false)
                    .readingWidth($textWidth)
                    .hidden()

                if isScrolling {
                    let travelDuration = max(2, Double(overflow) / 24)
                    label
                        .fixedSize(horizontal: true, vertical: false)
                        .keyframeAnimator(initialValue: CGFloat.zero, repeating: true) { content, offset in
                            content.offset(x: offset)
                        } keyframes: { _ in
                            LinearKeyframe(CGFloat.zero, duration: 1.5)
                            LinearKeyframe(-overflow, duration: travelDuration)
                            LinearKeyframe(-overflow, duration: 1.5)
                            LinearKeyframe(CGFloat.zero, duration: travelDuration)
                        }
                        .id(AnimationIdentity(text: text, textWidth: textWidth, availableWidth: availableWidth))
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
    }

    private struct AnimationIdentity: Hashable {
        let text: String
        let textWidth: CGFloat
        let availableWidth: CGFloat
    }
}
