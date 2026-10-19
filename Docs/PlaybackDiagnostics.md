# Playback diagnostics

Normal builds hide the diagnostics menu and disable seek tracing. Disabled
tracing returns before locking, reading the clock, formatting event names/details,
or retaining entries. Playback and decoder errors are still reported normally.

For a diagnostic build, add `PLAYBACK_DIAGNOSTICS` to the **app target's**
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`, retaining existing conditions. This single
switch exposes the copy action and enables tracing for that player instance.
Remove it for the next normal build. No user preference or hidden gesture is used.

`SeekDiagnosticsTests.swift` covers both modes. Tests of playback readiness also
run with tracing disabled, so playback cannot depend on diagnostic state.
