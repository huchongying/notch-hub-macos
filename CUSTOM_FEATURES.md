# Codex quota and memory status

This fork adds a compact status pill to the open-notch header:

- Plus accounts show the five-hour remaining quota.
- Pro accounts (`pro` or `prolite`) show the weekly remaining quota.
- The dashboard lists every valid quota window returned by `codex app-server`; the notch still emphasizes the plan-specific primary window.
- Memory shows active, wired, and compressed memory as a percentage of physical RAM.
- Clicking the pill opens details, reset times, and a manual refresh action.
- When media is not playing, the closed notch continuously shows Codex quota and memory usage.
- While music is playing, the closed notch shows the current synchronized lyric beside the album art, keeps the visualizer visible, and falls back to the song title when synchronized lyrics are unavailable. QQ Music is preferred, LRCLIB is a strict fallback, stale requests are cancelled on track changes, and verified results are cached locally.
- A movable Chinese desktop dashboard shows CPU, GPU, memory, disk, network, battery, thermal state, and uptime.
- The desktop dashboard starts at a compact 340×500 size, scrolls vertically, and can be freely resized from its edges.
- Daily local Codex token usage is deduplicated from session logs and split into input, cached input, output, and reasoning usage. A persistent byte-offset index reads only appended JSONL data after the first scan.
- Estimated account consumption not represented in local logs is displayed separately as low-confidence, unattributed usage and is never merged into the exact local total.
- Token quantities use Chinese `亿` units throughout the custom UI.
- Codex quota samples are retained for 30 days and used to estimate hourly burn rate and exhaustion time within the current reset window.
- Estimated remaining Token quota is learned locally from observed Token deltas per percentage point; it is labeled as an estimate and remains in learning mode until enough data exists.
- Quota estimates use the median of the latest 12 compatible samples and show a Chinese confidence level, estimate range, and sample count; samples reset when the account plan or quota window changes.
- The estimated remainder is converted into a daily budget that locks at local midnight. It remains fixed during the day, unused capacity rolls into the next day's calculation, and a new quota cycle rebuilds it immediately. Notifications fire only at 100% and 150%.
- A verified Tibo hard-reset feed is checked hourly, on launch, and after wake. Planned signals stay in the dashboard; a newly confirmed server-side hard reset sends one notification and the budget is silently recalculated when the local quota catches up.
- The idle notch offers compact, standard, and enhanced Chinese layouts. Synchronized music lyrics always take priority while media is playing.
- The desktop dashboard includes Chinese quota, hardware, and seven-day Token trend charts.
- The dashboard's six content modules can be shown or hidden and reordered by dragging; visibility and order persist across launches while the header remains fixed.
- A real-pointer fallback closes the expanded notch if SwiftUI loses its hover-exit event after presenting quota details.
- Hardware sampling adapts between 2, 5, and 15 seconds for visibility, Low Power Mode, and thermal state, and pauses while the session or display is inactive.
- The dashboard shows battery health and cycle count plus memory pressure, compressed memory, and swap usage without administrator privileges.
- Failed data sources keep their last successful value with an explicit stale label and bounded retry backoff.
- Two configurable global shortcuts open the macOS App launcher (`⌃⌥A`) and the system screenshot toolbar (`⌃⌥S`).

## Data sources

Codex quota is read through the locally authenticated `codex app-server` using the read-only
`account/read` and `account/rateLimits/read` methods. Account type comes from `account/read`,
with the rate-limit payload used only as a compatibility fallback. Boring Notch does not read
or copy Codex tokens. The process handshake and executable discovery are adapted from the MIT-licensed
[Codex Usage Bar](https://github.com/CMMUU/codex-usage-bar).

Memory usage comes from `host_statistics64` and does not require an external service.
Daily token totals are local-device statistics derived from `~/.codex/sessions` and
`~/.codex/archived_sessions`. Other-device usage can only be estimated from account quota movement and is labeled separately.
Tibo hard-reset signals come from the public structured feed at
`tibo.modelyard.dev`; the app only accepts direct, verified reset announcements and
filters banked-reset events out of this feature.

## Refresh intervals

- Codex quota and the incremental local Token scan share one ten-minute background refresh; opening the notch or dashboard refreshes stale data immediately
- Memory usage: every 10 seconds; detailed hardware sampling uses 5 seconds while visible and 15 seconds while hidden, occluded, in Low Power Mode, or thermally constrained
- Tibo hard-reset status: every hour, plus app launch and wake

## Build

Open `boringNotch.xcodeproj` in a full Xcode installation, select the `boringNotch` scheme,
and build for macOS. Xcode Command Line Tools alone cannot build this AppKit/SwiftUI project.
