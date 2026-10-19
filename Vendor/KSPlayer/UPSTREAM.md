# KSPlayer source dependency

Source: https://github.com/kingslay/KSPlayer/tree/2.3.4

Archive SHA-256: `5ba2325c6f221fff7d2e1afa75bf06126cf02438a6c63b1afabf967f0585a386`

Original Sources and LICENSE are retained. The package manifest uses the same FFmpegKit 6.1.4 version as the app and excludes upstream demo/test targets.

Local changes: seek queue generations prevent an interrupted read from consuming the first packet of the new timeline; decoder flush occurs before decoding that packet. Old-generation decoded frames are rejected before entering the render queue.

Seek latency changes: preserve fractional target times; skip preroll video pixel conversion after decoding/filtering; allow local seek readiness from decoded frames. Decoder packet/reference handling remains intact. See Docs/PlaybackSeeking.md for controlled media comparisons and device-validation limits.

Seek readiness: invalidate the previous playable state before seeking; ignore capacity samples during demux seek; submit the first target frame before resuming audio. Preserve fractional display timebase values. Production-method regression tests cover audio-first decoding and paused seeks.

Seek diagnostics: bounded in-memory stage timings, queue/clock samples and display submission status for the last seek. Generation-tagged decoder callbacks cannot pollute a subsequent trace; this instrumentation does not change playback decisions.

Fast seek alignment: discard decoded audio preroll before the first video frame, install the same boundary for incoming audio, and rebase both clocks before declaring playback ready. Compressed reference packets remain intact. The real build-12 ASF timestamp trace is covered by regression and mutation tests.

First-open resume: skip the eager initial preview while a seek is pending; retain the first target frame until audio preroll alignment and target readiness. Production-method regression tests cover both first-open and in-session seeks, with mutation checks for the previous preview behavior.

MP4 opening: filter disabled FFmpeg log levels before Swift string conversion and printf formatting. MOV sample-index traces no longer incur formatting cost at warning verbosity; filter-analysis callbacks and enabled messages remain available. Regression tests instrument the production callback and reject the former late filtering.
