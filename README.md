# AppGateKit

A small Swift package that asks a remote config whether this build of an iOS
app may still run, and gives the app a state to render.

It does three things:

- A soft update notice. When a newer build is on the App Store, the app asks
  the user once per version.
- A hard force update. The app cannot run below a floor, which you publish as a
  static JSON file and not as a dashboard toggle.
- Fail-open behaviour. An unparseable version, an unreachable config, an
  expired cache and an OS that cannot install the newer build all resolve to no
  gate. A wall that a bug in the binary raises can only be fixed by a new
  binary through review, so every doubt resolves to no wall.

Other names for this are force update, kill switch, minimum supported version
and update gate.

## Installation

```swift
.package(url: "https://github.com/ken0nek/AppGateKit", from: "1.0.0")
```

Add the products you use to your target:

```swift
.product(name: "AppGateCore", package: "AppGateKit"),
.product(name: "AppGateClient", package: "AppGateKit"),
.product(name: "AppGateUI", package: "AppGateKit"),
```

## Status

1.0.0 is the first release. The package follows semantic versioning.

## Platforms

iOS 18 and later. `Package.swift` also declares a macOS floor, because the
package's tests run on a macOS host. macOS is not a supported platform.

## The three products

`AppGateCore` is pure and imports only Foundation. It contains the version
comparator, the gate state, the precedence rule, the OS-install check, the
suppression rules and the config envelope. It uses no `URLSession`, no
`UserDefaults` and no clock. The evaluator takes everything it needs as
parameters, so it is tested without a simulator. An app whose own server
already decides the floor can use this product alone.

`AppGateClient` adds the observable store, with both fetches, both last-good
caches, the TTLs, the clock-skew guard, the dismissal and the developer
overrides.

`AppGateUI` is optional. It provides one modifier for the app root, which
decides when to refresh, which of the wall and the notice shows, and what is
recorded when a notice closes. It also provides a DEBUG diagnostics view for
the developer overrides. You still draw the wall and the notice. If you write
your own presentation you do not link `AppGateUI`, and neither of the other
products links SwiftUI.

`AppGateClient` does not re-export `AppGateCore`, and `AppGateUI` re-exports
neither. A file that names `GateState`, `AppVersion` or `GateDiagnosis` imports
`AppGateCore` itself. A re-export would give each type two import paths, and
Core is meant to be usable alone.

## The config format

```json
{ "min_supported": "1.3.0",
  "feature_floors": { "share": "2.2.0" } }
```

The config URL is compiled into every shipped binary. A shipped build cannot be
told to look elsewhere, so the path you choose must stay served for as long as
that build is installed, and the format cannot change in a way that shipped
builds cannot read. Four rules follow.

1. Every field is optional, on the server and in the app, permanently. A
   shipped build has to decode a cached blob that a different version of the
   format wrote. A field's JSON type never changes. A value of the wrong type
   reads as absent, and builds on 1.0.0 reject the whole config instead and
   keep their previous cached config for up to a day.
2. Unknown fields are ignored, so a field added later cannot break an older
   build's decode.
3. The config carries no user-facing text. A string in the config could only be
   in one language. Every user-facing word stays in the app's string catalog.
4. `maintenance` is reserved and unread. No other field may take the name. When
   it is added, its shape will be machine-readable only,
   `{"until": "<ISO8601>"}`. The app then renders the time in the viewer's
   locale, and the config still carries no prose.

## The config contract

One wrong floor walls every user, so the config follows four rules.

1. No floor may exceed the version that is live on the App Store. A
   `min_supported` above it walls every user, including users who have just
   updated, until each install fetches a corrected config, which a walled
   build does at its next launch or foreground activation. A
   `feature_floors` entry above it disables that feature for every install in
   the same way. Check both against the same lookup the app reads, so the check
   and the app agree on what "live" means.
2. Every value is dotted-numeric, and every component fits in a 64-bit integer.
   The app cannot parse anything else, and an unparseable floor means no gate,
   with no error.
3. The file is served at the fixed path, as `application/json`, with status
   200, and with a short cache lifetime. A CDN that keeps serving an old body
   keeps an old floor in force for as long as it does.
4. The file is versioned as code and is not dashboard state. A change to it is
   reviewed and shipped like code.

`scripts/verify-app-config.mjs` checks the first three. It also fails a
`maintenance` field in any shape other than `{"until": "<string>"}`, so the
reserved name cannot be taken by another shape. It is Node with no
dependencies. Run it in the CI of whatever serves the file:

```
node verify-app-config.mjs https://example.com/app-config.json 123456789
```

If the lookup does not answer, the script warns and does not fail, so an
unrelated change is not blocked by Apple's uptime. If the lookup answers and a
floor is above the live version, the script fails. If the config sets a floor
and the lookup answers but lists no app with that id, the script fails too,
because a mistyped id would otherwise switch the check off. While the app is
not on sale yet, add `--not-yet-released` after the id.

## What the package does not do

- **No user-facing strings.** The app owns its string catalog.
- **No wall, no sheet and no text.** Your design system draws the views, and
  your catalog supplies the text. `AppGateUI` decides which of your views shows
  and supplies none of its own. Apps differ here in ways that parameters cannot
  cover. A wall's background is the whole screen, and the notice is a short
  sheet in one app and a full-screen "what's new" in another. Packaged versions
  of the two views would take more parameters than they have content.
- **No analytics.** A store that emitted on state change would count walls
  nobody saw. Send your own signals from the presenting layer: the notice's
  from `onNoticeShown`, which is called once each time the notice is
  presented, and the wall's when your wall appears.
- **No suppression inputs.** The app knows whether a screenshot run is in
  progress, whether onboarding is done and whether another modal has already
  shown this session, and it passes those in. The rules that use them are in
  the package and tested there.
- **No targeting.** There are no cohorts, no percentage rollout and no
  per-country rules. Those need a server.
- **No storefront choice.** The App Store lookup has no country, so Apple
  answers for the United States store. An app that is not on sale there gets
  no notice, and a wall is never released for an OS that cannot install the
  build. The config floor still walls as configured.

## What your wall and notice must do

You draw both views, and `AppGateUI` cannot enforce these four rules for you.

- **The wall has exactly one button, and it opens the App Store.** Any other
  way out defeats the wall. The wall otherwise comes down only when the config
  lowers the floor, which needs no control.
- **Both buttons open the App Store product page.**
  `AppStorePage.productURL(appStoreID:)` builds the URL. It has no country
  code, because the path redirects to the viewer's own storefront and a fixed
  country code would send everyone to one store. Store the URL in a constant
  and do not unwrap it in the button's action. If your server already supplies
  a store URL, use that.
- **Call `context.accept()` before your notice dismisses itself.** The
  dismissal is recorded however the user closes the notice. `accept()` only
  sets whether `onNoticeDismissed` reports the close as accepted or declined.
  Without the call, every close is reported as a decline. When the gate
  withdraws a notice, because a floor rose or a flag reported another modal
  this session, nothing is recorded or reported, because the user did not close
  it.
- **Keep a DEBUG release control on the wall, and label it.** The switch that
  forces a wall is behind the wall, so without a control on the wall a DEBUG
  build cannot get back to the app. A labelled control cannot be mistaken for
  the shipping wall in a screenshot.

## Fail-open rules

1. An unparseable running version gates nothing. The evaluator checks this
   first, so no later branch reaches a comparison without a parsed version.
2. A floor that is absent, unparseable or past its cache TTL gates nothing.
3. The lookup can release a gate and can never raise one. If it reports that
   the running OS cannot install the newer build, the wall comes down, because
   sending someone to a binary they cannot install is worse than showing
   nothing. An unknown `minimumOsVersion` leaves the wall up. Otherwise one
   outage at the lookup would disable every wall.

Nothing in the package traps. It has no `precondition`, no `fatalError`, and no
force-unwrap of a value that came from the network, from storage or from a
caller.

## License

MIT. See [LICENSE](LICENSE).
