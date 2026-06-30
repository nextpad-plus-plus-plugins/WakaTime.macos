# WakaTime (macOS port for Nextpad++)

Automatic coding-time tracking for [Nextpad++](https://github.com/nextpad-plus-plus) /
Notepad++ on macOS. Metrics, insights, and time tracking are generated automatically
from your editing activity and sent to [WakaTime](https://wakatime.com).

This is a faithful macOS reimplementation of the Windows
[`notepadpp-wakatime`](https://github.com/wakatime/notepadpp-wakatime) plugin
(originally C#/.NET, BSD-3-Clause, © 2014 Alan Hamlett). The heartbeat engine —
when a heartbeat fires, the throttle, the queue/flush cadence, and the exact
`wakatime-cli` arguments — is ported verbatim; only the platform layer
(Win32/WinForms → AppKit, `Process` → `NSTask`, the INI calls → a hand-rolled
reader/writer) was rewritten.

## How it works

* Watches editor activity (text edits, cursor moves, file switches, saves) and
  enqueues **heartbeats** (file path, timestamp, lines-in-file, current line,
  `is_write`).
* A heartbeat is recorded when the current file changes, when you switch files,
  when ≥ 2 minutes have passed since the last one, and **always on save**
  (`is_write = true`) — identical cadence/throttle to the official plugins.
* Every 10 seconds the queue is drained and flushed by shelling out to the
  official **`wakatime-cli`** helper (run on a background thread, so the editor
  never blocks). Multiple queued heartbeats are sent via `--extra-heartbeats`.

## Requirements: install `wakatime-cli`

Unlike the Windows plugin (which downloads and self-updates `wakatime-cli`), this
macOS port does **not** download any binary. Install the CLI yourself:

```sh
brew install wakatime-cli
```

…or download it from <https://wakatime.com/help/plugins> and place it at
`~/.wakatime/wakatime-cli` (or anywhere on your `PATH`). The plugin resolves the
CLI from, in order: `~/.wakatime/wakatime-cli*`, your `PATH` (login shell), then
`/opt/homebrew/bin` and `/usr/local/bin`. If it can't be found you'll get a
one-time alert with install guidance; heartbeats keep queueing and flush once the
CLI is available.

> **The only behavioral difference from the Windows plugin** is this manual
> CLI install (Windows auto-downloads). Everything else matches.

## Setup

1. Build (see below) or install the plugin, then restart Nextpad++.
2. On first run you'll be prompted for your
   [API key](https://wakatime.com/settings/account). You can reopen the dialog
   any time via **Plugins → WakaTime → Settings**.
3. The API key (and an optional `api_url`) are stored in the shared
   `~/.wakatime.cfg` (`[settings]` section), so they interoperate with every
   other WakaTime tool.

The **Plugins → WakaTime** menu also has a **WakaTime Dashboard** item that opens
<https://wakatime.com/dashboard>.

## Build

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Produces a universal (`arm64` + `x86_64`) `build/WakaTime.dylib`. Install it (plus
`toolbar.png` / `toolbar_dark.png`) into
`~/Library/Application Support/Nextpad++/plugins/WakaTime/`.

## License

BSD 3-Clause (see `LICENSE`), inherited from the upstream WakaTime plugin.
