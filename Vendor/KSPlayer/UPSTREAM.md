# KSPlayer source dependency

Source: https://github.com/kingslay/KSPlayer/tree/2.3.4

Archive SHA-256: `5ba2325c6f221fff7d2e1afa75bf06126cf02438a6c63b1afabf967f0585a386`

Original Sources and LICENSE are retained. The package manifest uses the same FFmpegKit 6.1.4 version as the app and excludes upstream demo/test targets.

Local changes: seek queue generations prevent an interrupted read from consuming the first packet of the new timeline; decoder flush occurs before decoding that packet. Old-generation decoded frames are rejected before entering the render queue.
