# 跳转后画面异常调查

用户反馈：同一个 WMV 在“自动 · 软解”下跳转后花屏几秒，随后恢复。
当前核对过的依赖：KSPlayer 2.3.4、FFmpegKit 6.1.4。

## 已确认的代码问题

KSPlayer 的 `videoClockSync` 在视频落后且显示队列只剩一帧时，会返回
`dropGOPPacket`。`MEPlayerItem.getVideoOutputRender` 按 `!packet.isKeyFrame`
删除压缩包，直到关键帧或当前队列为空。非关键帧不等于非参考帧；队列在
GOP 中途耗尽后，新入队的帧仍可能引用已经丢弃的画面。

本项目通过 `ReferenceSafePlaybackOptions` 将 `dropNextPacket` 和
`dropGOPPacket` 改为 `dropNextFrame`。时间同步和解码继续进行，只跳过
已经完整解码的显示帧，不破坏压缩视频的参考链。自动硬解/软解策略保持。
这是对已确认风险的修正，尚未拿到用户原始 WMV，不能视为该文件问题已复现或已解决。
代价是解码器必须继续处理参考帧，性能不足时追赶音频可能较慢。

## 对照的上游实现

- [mpv vd_lavc.c](https://github.com/mpv-player/mpv/blob/master/video/decode/vd_lavc.c)：
  `prepare_decoding` 中精确跳转使用 `AVDISCARD_NONREF`；
  `reset_avctx`/`send_packet` 在硬解重置后等待关键帧。
- [ijkplayer ff_ffplay.c](https://github.com/bilibili/ijkplayer/blob/master/ijkmedia/ijkplayer/ff_ffplay.c)：
  seek 后清包队列、发送 flush 包，解码和显示检查 serial，拒绝旧时间线的帧。
- [VLC video.c](https://github.com/videolan/vlc/blob/master/modules/codec/avcodec/video.c)：
  flush 清理解码器；显示入口可过滤 `AV_FRAME_FLAG_CORRUPT`，受丢帧和显示损坏帧设置控制。
- [KSPlayer KSOptions.swift](https://github.com/kingslay/KSPlayer/blob/2.3.4/Sources/KSPlayer/AVPlayer/KSOptions.swift)：
  `videoClockSync` 的追赶策略。
- [KSPlayer MEPlayerItem.swift](https://github.com/kingslay/KSPlayer/blob/2.3.4/Sources/KSPlayer/MEPlayer/MEPlayerItem.swift)：
  `getVideoOutputRender` 的压缩包丢弃实现。

## 验证范围

GitHub Actions 检查 Swift 编译、现有回归测试和 iOS 归档。
仍需原始 WMV 与可复现的跳转位置验证：单次快进、连续跳转、后退、暂停时跳转，
并比较软解状态下的显示结果。测试包不声称已经消除该 WMV 的花屏。
