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
这是对已确认风险的修正；原始 WMV 的对照实验见下文，iPhone 上的实际播放仍待验证。
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

## 原始 WMV 对照实验

对用户提供的本地文件进行只读分析：ASF/WMV3、1920×1080、30000/1001 fps，
时长 2722.133 秒，关键帧间隔约 3.003 秒。未上传视频或导出画面。
实验环境为 Windows、PyAV 12.3.0，libavcodec 60.31.102 / libavformat 60.16.100
（FFmpeg 6.1 系列）。按时间戳逐帧比较可见像素的 SHA-256，排除缓冲区 padding。

| 跳转位置 | 正常跳转与提前解码的差异帧 | 中途丢 8 个非关键压缩包后的差异帧 | 只丢 8 个显示帧后的差异帧 |
| --- | ---: | ---: | ---: |
| 60 秒 | 0 / 438 | 79 / 430 | 0 / 430 |
| 300 秒 | 0 / 438 | 80 / 430 | 0 / 430 |
| 600 秒 | 0 / 374 | 54 / 366 | 0 / 366 |

第一组异常从 60.794 秒持续到 63.396 秒，63.430 秒关键帧恢复；
另外两组也在下一个关键帧恢复。压缩包丢失后的异常帧均没有 `is_corrupt`
标记，解码器也没有报错，因此只检查解码失败或损坏标记不能解决这条路径。

这是模拟上游队列在 GOP 中途耗尽的控制实验，证明该文件在此丢包策略下
会产生约 1.8～2.6 秒的错误解码输出，并证明丢显示帧不改变后续解码结果。
实验使用 PyAV 的 seek 接口，未运行 iOS 的 KSPlayer 渲染和音画同步线程，
不能据此断言手机上的所有花屏都已经解决。

GitHub Actions 验证 Swift 编译、现有回归测试和 iOS 归档。
仍需在 iPhone 上验证同一 WMV：单次快进、连续跳转、后退、暂停时跳转。
