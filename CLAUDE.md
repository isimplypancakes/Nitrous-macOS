# CLAUDE.md

Guidance for Claude Code (and anyone else) working in this repository.

## What this is

Nitrous is a third-party Discord client for iOS written in SwiftUI. It talks to
Discord's real API: REST (`api/v9`) plus the v10 gateway WebSocket, using a user
account token. There is no backend of our own.

## Build & run

The `.xcodeproj` is **generated** — never edit it, and never commit it.

```bash
xcodegen generate
xcodebuild -project Nitrous.xcodeproj -scheme Nitrous \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

On macOS where `xcode-select` points at the Command Line Tools, prefix commands
with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Signing is intentionally blank. Set `DEVELOPMENT_TEAM` in `project.yml` and a
bundle id you own before building to a device.

## Design law

**It must read as a first-party Apple app, not a Discord re-skin.** No server
rail, no blurple, no forced dark mode, no swipe drawers. Use `TabView`,
`NavigationStack`, large titles, inset-grouped lists, SF Symbols, system colors,
and iMessage-style bubbles. When in doubt, copy Messages and Settings.

Accent color is defined once in `Brand.accent` (`UI/Theme.swift`) and applied
universally — themes deliberately do **not** override it. Anything drawn on top
of the accent uses `Brand.onAccent`.

## Architecture

- `Models/` — Codable Discord types. Decoding is **tolerant by design**.
- `Networking/DiscordREST` — REST calls, rate-limit retry.
- `Networking/DiscordGateway` — WebSocket lifecycle and dispatch.
- `Auth/` — `Keychain`, `AccountStore` (multi-account), `RemoteAuth` (QR login).
- `Store/AppModel` — `@MainActor` coordinator; owns every runtime cache the UI
  observes. Views should read from it, not fetch on their own.
- `UI/Theme.swift` + `UI/Glass.swift` — the design system. Use these, don't
  hardcode colors or blurs at call sites.
- `Support/DiagnosticLog.swift` — user-visible log at You → Diagnostics.

## Protocol landmines

These were all found the hard way. Don't regress them.

1. **`maximumMessageSize`** — `URLSessionWebSocketTask` defaults to 1 MiB and a
   real `READY` is several MB. Without raising it the socket fails *before any
   parsing*, so it presents as an endless "Connecting… / Offline" loop with no
   error. Set it in `openSocket`.
2. **Guild shape** — the user gateway nests `name`/`icon` under `properties`;
   REST puts them top-level. `Guild` decodes both.
3. **Lossy collections** — every `READY` array uses `decodeLossyArray`. One
   unexpected element must never discard the session.
4. **DM recipients** — the gateway sends `recipient_ids`, not `recipients`.
   Resolve names/avatars from the `users` cache via `AppModel.displayName(for:)`.
5. **Guild order** — `user_settings` is absent; order is in
   `user_settings_proto`: field 14 → folders (field 1) → `guild_ids` (field 1,
   **packed fixed64**, not varint).
6. **Heartbeat** — `d` must be JSON `null` when there's no sequence yet.
   Passing a Swift `Optional` makes `JSONSerialization` fail and the beat is
   silently dropped.
7. **Never fail silently.** Decode errors go through `DiagnosticLog`, and a dead
   session must render a visible "Can't Connect / Try Again", never an empty
   list.

## SwiftUI landmines

1. **Gestures vs. context menus** — attaching `.gesture(DragGesture…)` swallows
   the long-press that opens a context menu. Use `.simultaneousGesture`.
2. **`.textSelection(.enabled)`** on message text also steals the long-press and
   shows iOS's Copy/Share popover instead of the message actions. Don't add it;
   Copy lives in the context menu.
3. **Press feedback in scrollable lists** must come from `ButtonStyle`
   (`.buttonStyle(.bouncy)` / `.bouncyRow`), which the system cancels when a
   scroll starts. A `DragGesture(minimumDistance: 0)` competes with the scroll
   view and makes scrolling feel like it catches.
4. **Glass must wrap the content**, not sit behind it. `.listRowBackground`
   puts glass in a separate view that can't scale with a press or receive the
   touch that drives `.interactive()`. Use `.glassCard()`.
5. **`scaledToFill` images propagate their intrinsic width** and stretch
   siblings past the screen edge. Always clip to a measured size
   (`GeometryReader` + `.frame` + `.clipped()`), and reserve aspect-correct
   space for remote images so loading doesn't reflow the list.
6. **Theme changes must not re-root the view tree.** `Palette` reads
   `ThemeStore.shared.current` live and screens observe `ThemeStore`; putting
   `.id(theme)` on the root resets navigation and boots the user out of the
   screen they're on.
7. **Wallpaper is drawn per screen** (`.themedBackground()`). Drawn once at the
   root it's hidden by the tab and navigation containers' own backgrounds.

## Testing

There is no live-account test suite — treat any account you sign in with as
production data. Prefer the DEBUG **demo workspace** on the login screen for UI
work. Model decoding can be exercised standalone by compiling the model layer with a
small `main.swift` of your own that feeds it a sample payload:

```bash
swiftc -o decodetest Nitrous/Models/*.swift Nitrous/Networking/CDN.swift main.swift
```

When patching files with scripted find-and-replace, **`grep` afterwards to
confirm the edit actually landed** — a silently no-op'd replacement has shipped
a "fix" that never existed here before.

## Privacy

Tokens live only in the device keychain. Never log a token, never commit real
account data (ids, guild ids, diagnostics dumps, wallpapers), and keep the
placeholder bundle id and empty signing team in `project.yml`.
