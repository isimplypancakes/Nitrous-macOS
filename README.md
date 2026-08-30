# Nitrous

A third-party **Discord client for iOS**, built to look and feel like a
first-party Apple app — Human Interface Guidelines throughout, Liquid Glass,
adaptive theming, and **multi-account switching built in**.

> **Read this first.** Nitrous logs in with a *user* account token. Automating a
> user account is against Discord's Terms of Service and can get the account
> terminated. This project exists as a study in reverse-engineering a real
> protocol and building a native client against it. Use it at your own risk,
> ideally with an account you can afford to lose.

## Design

Not a Discord re-skin. The UI is built from iOS primitives:

- **Tab bar shell** — Servers · Messages · You, each in its own `NavigationStack`
- Large titles, `.searchable`, inset-grouped lists
- **iMessage-style chat** — accent bubbles for you, neutral for everyone else,
  sender headers with avatar + name + time, day separators, an animated typing
  bubble, swipe-to-reply
- **Liquid Glass** (`glassEffect`, iOS 26) on rows, bubbles, reaction pills and
  the composer, with an `.ultraThinMaterial` fallback below 26
- **Themes** — System / Light / Dark plus OLED Black, Midnight, Ocean,
  Indigo Night and Slate, and an optional wallpaper the glass refracts against
- **Account switching** in the You tab, modeled on Settings.app's Apple ID card

## Features

Working: multi-account sign-in (QR remote-auth, token, or email + password with
MFA) and instant switching; servers in Discord's own saved order; categorized
channels; real-time messages over the gateway; DMs and group DMs; replies with
`message_reference` and jump-to-original; edit and delete; reactions; unread
badges; markdown (headings, quotes, code blocks, spoilers, mentions, custom
emoji); attachments; rich embeds; member list and profiles; local notifications
for DMs and mentions; an on-device diagnostics log.

Not implemented: voice and video, threads and forums, server discovery and
onboarding, slash-command UI, push notifications (see below), and most of the
settings surface.

## Architecture

```
Models/       Codable Discord types + tolerant/lossy decoding
              (Guild decodes both the REST and user-gateway shapes;
               GuildOrder parses the guild_folders protobuf)
Networking/   DiscordREST    — api/v9
              DiscordGateway — v10 WebSocket: heartbeat, IDENTIFY, RESUME,
                               close-code handling, capped backoff
              CDN            — avatar/icon/emoji URL building
Auth/         Keychain, AccountStore (multi-account), RemoteAuth (QR login)
Store/        AppModel — @MainActor coordinator and all runtime caches
UI/           Theme + Glass design layer, Components, Screens
Support/      DiagnosticLog, notifications, DEBUG-only demo data
```

## Build

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Nitrous.xcodeproj
```

Set your own signing team in Xcode (or `DEVELOPMENT_TEAM` in `project.yml`) and
change `PRODUCT_BUNDLE_IDENTIFIER` from `com.example.nitrous` to something you
own. The `.xcodeproj` is generated and intentionally not committed.

On the login screen in a DEBUG build, **Explore demo workspace** loads a fully
populated offline session, so the UI can be driven without any credentials.

## Notes on the protocol

A few things that are easy to get wrong and cost real debugging time:

- `URLSessionWebSocketTask.maximumMessageSize` defaults to **1 MiB**. A real
  user's `READY` is several MB, so the socket fails before parsing and the app
  reconnect-loops with no error. Raise it.
- The **user** gateway nests guild `name`/`icon` under `properties`; REST puts
  them at the top level. Decode both.
- DM channels arrive with `recipient_ids`, not full `recipients` — resolve names
  from the `users` cache in `READY`.
- Sidebar order lives in `user_settings_proto` (protobuf), not `user_settings`:
  field 14 → folders → `guild_ids` as **packed fixed64**.
- Every `READY` collection is decoded lossily; one unexpected element must not
  discard the whole session.

## Notifications

Notifications are **local**, raised from live gateway events while the app is
running. iOS suspends the app and the WebSocket closes, so there is no
background delivery — real push would require Discord's own APNs
infrastructure, which third-party clients cannot use.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with, endorsed by, or connected to Discord Inc.
