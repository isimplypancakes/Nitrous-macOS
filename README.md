# Nitrous

A third-party **Discord client for macOS**, built to look and feel like a
first-party Apple app — Human Interface Guidelines throughout, Liquid Glass,
adaptive theming, and **multi-account switching built in**.

> **Read this first.** Nitrous logs in with a *user* account token. Automating a
> user account is against Discord's Terms of Service and can get the account
> terminated. This project exists as a study in reverse-engineering a real
> protocol and building a native client against it. Use it at your own risk,
> ideally with an account you can afford to lose.

## Disclaimers

You WILL need a Klipy API key if you want gifs to work.
The app may not launch on first boot, all you need to do is run xattr -c /path/to/your/app.app and the app should open fine.



## Design

Not a Discord re-skin. The UI is built with Swift designed with liquid glass elements in mind.


## Features

Working: Messaging, Sending and viewing gifs (with a Klipy API Key you need to generate) reactions, replies, pings, DMs, File uploads, deleted message logging, typing indicator

Not Working/Not Implemented: Voice calling, gifs without api key, server discovery, slash commands, moderation tools, more## Build

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



## License

MIT — see [LICENSE](LICENSE).

Not affiliated with, endorsed by, or connected to Discord Inc.
