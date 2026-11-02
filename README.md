# seedypod for iPhone

Your Gardyn tower in 3D, run from your own network. The app talks straight to
[seedypod core](https://github.com/seedypod/core) on your LAN. It has no
account, no cloud and no telemetry.

- **Home is the tower:** every pod colored by how it's doing, the plants sized
  by how far along they are, the tank showing its level and the light bars
  glowing at their brightness. Tap a pod for what's in it, where it is in its
  grow and what to do about it.
- **Light and water:** brightness and on/off (held for 30 minutes over the
  schedule, as on the web), and bounded pump runs.
- **Alerts:** acknowledge reminders and latched hardware faults.
- **Finds your unit:** Bonjour (`_seedypod._tcp`), or type its address. An
  optional API key is kept in the Keychain.
- **Demo mode:** a simulated tower on day 19 of a grow, with no hardware
  needed.

## Build

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate          # after adding or moving files; CI checks the project is current
open Seedypod.xcodeproj
```

```sh
xcodebuild test -project Seedypod.xcodeproj -scheme Seedypod \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
swiftlint --strict
```

To work against a unit without hardware, run core's simulator
(`pnpm dev:sim` in seedypod/core) and connect to `<your Mac's IP>:3000`.

## How it fits

| Piece | Where |
|---|---|
| tRPC transport (`CoreClient`) | Ported from sleepypod/ios's `SleepypodCoreClient`, per [core ADR-0017](https://github.com/seedypod/core/blob/dev/docs/adr/0017-ios-client.md), with `X-API-Key` added |
| Live updates (`EventStream`) | core's `/api/ws` CoreEvent frames trigger a batched refresh |
| Discovery (`UnitDiscovery`) | `NWBrowser` for `_seedypod._tcp`, TXT `id`/`v`/`auth` |
| Palette (`Theme`) | core's `web/src/globals.css` `--lp-*` tokens |

`dev` is the integration branch and `main` is for releases. Use conventional commits.

## License

[AGPL-3.0](LICENSE). IBM Plex Mono is under the SIL Open Font License (`Seedypod/Resources/Fonts/OFL.txt`).
