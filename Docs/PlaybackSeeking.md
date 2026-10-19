# 跳转后画面异常调查

用户反馈：同一个 WMV 在“自动 · 软解”下跳转后花屏几秒，随后恢复。
当前核对过的依赖：KSPlayer 2.3.4、FFmpegKit 6.1.4。

## 跳转丢失首包的线程竞态（本次修正）

上一版只修正追帧时丢压缩包的问题，用户实测每次拖动进度仍然花屏。
继续检查 KSPlayer 2.3.4 的 `AsyncPlayerItemTrack.decodeThread`，发现：
解码线程阻塞在 `packetQueue.pop(wait: true)` 时，seek 清空队列并设为
`.flush`；线程被唤醒后可能先取走新时间线的首包，再因 `.flush` 判断而
丢弃它。先取包、后检查状态的顺序会丢掉跳转后需要的关键帧。

本项目现在直接依赖 `Vendor/KSPlayer` 中固定版本源码，以便修正底层：

- 队列每次 flush 增加代次；旧的等待只能返回空，不能拿走新代次的包。
- 在队列锁内、移除包之前检查解码器是否需要 flush，保留新首包。
- 在输出队列锁内检查解码所属代次、过滤精确跳转前的帧；seek 原子更新
  目标时间并清空显示队列，避免旧的解码回调向新时间线提交画面。
- 沿用自动硬解/软解，不增加固定延时或遮罩来掩盖错误画面。

原文件的受控实验：跳转至 1002 秒（截图 16:42），正常 seek 的首个
关键帧为 1001.768 秒。只丢这个关键帧，之后 **89 帧**的可见像素与
正常解码不同（1001.801～1004.738 秒），1004.771 秒的下一个关键帧
恢复。600 秒位置同样产生 89 帧差异，且没有 corrupt 标志或解码报错。
原始媒体保持本地，未上传。实验能解释症状，但不是 iPhone 线程现场记录。

`SeekQueueRegressionTests.swift` 编译实际生产队列，检查首包保留、旧回调
拒绝，并覆盖 300 次并发 seek/wait 调度。iOS 完整编译和归档由 Actions 验证；
手机上每次拖动是否彻底恢复仍需实机确认。

## 追帧丢压缩包的问题（上一版修正）

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
