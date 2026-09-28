# Claude Chrome

<img src="Resources/Logo.png" alt="Claude Chrome icon" width="128">

[繁體中文](README.zh-Hant.md)

Claude Chrome 1.1.0 is a small native macOS launcher for a dedicated Google Chrome profile and fixed local HTTP proxy. The project is available at [miku233333/claude-chrome](https://github.com/miku233333/claude-chrome) under the MIT License.

## Requirements

- Apple silicon Mac running macOS 13 or later
- Google Chrome installed in `/Applications`
- An HTTP proxy listening on `127.0.0.1:17897`
- Command Line Tools with `swiftc`

## Build

Build from source:

```sh
./scripts/build.sh
```

The app is written to `dist/Claude Chrome.app`. The build is ad hoc signed for local use and retains at most one previous build as `dist/Claude Chrome.app.latest-backup`.

This repository distributes source and build instructions. It does not publish an unnotarized binary release. Install the locally built app by moving it to `/Applications`.

## Install

Copy `dist/Claude Chrome.app` into `/Applications`, then open it.

## Launch behavior

Claude Chrome starts Google Chrome directly with `--app=<bundled file: start page>`. This produces a plain app-style window for the local environment check, without the Google home page, browser toolbar, or AI Mode omnibox entry.

The dedicated profile is stored at `~/Library/Application Support/Claude Chrome/Profile`. A legacy profile at `~/.local/share/claude-network-guard/chrome-login-profile` is reused when present. Profile directories must be real directories with mode `0700`.

The launcher treats this as an offline browser profile: it disables Chrome's Google sign-in preference and starts Chrome with `--disable-sync`. Signing in to the Claude website is separate and remains available after the checks pass. Chrome runs with:

- `--proxy-server=http://127.0.0.1:17897`;
- `--webrtc-ip-handling-policy=disable_non_proxied_udp`;
- `--lang=<exit primary locale>`, with the profile's selected and accepted languages set from the exit country;
- `--app=<local environment-check page>`.

The launcher uses `curl -q` with the explicit loopback proxy and an empty `--noproxy` value, so proxy bypass settings are not inherited. It obtains the exit IP, country, and IANA timezone from ipwho.is, then starts the dedicated Chrome process with `TZ=<IANA timezone>`. This changes neither the macOS timezone nor other Chrome profiles.

For one app lifetime, Claude Chrome retains the Chrome process, timezone, and language it started. Reopening the app reuses only that still-running, app-owned process after its guarded flags and recorded timezone and language match. Quitting Claude Chrome normally closes its dedicated Chrome process. If the app exits unexpectedly, the remaining Chrome process is unmanaged: fully quit that window before reopening Claude Chrome.

The launcher derives a primary locale from the exit country using macOS Foundation and ICU likely-subtags. Examples are Japan `ja-JP`, `ja`; United States `en-US`, `en`; Taiwan `zh-Hant-TW`, `zh-Hant`; and Singapore `en-SG`, `en`. Multi-language countries use the system locale data's default primary language. A country or language change requires a cold launch.

## Environment check

The local start page must pass every check before its Continue button opens `https://claude.ai`. A failed or unknown check keeps the button locked; clicking Continue repeats the live network checks before navigation.

- **Exit and region:** fresh Cloudflare Trace and ipwho.is responses must agree on public IP and country and match the native launch assessment. `Resources/SupportedRegions.js` contains the 185 Claude.ai countries from [Anthropic's supported-countries page](https://www.anthropic.com/supported-countries), captured on `2026-09-29`. Ukraine is excluded when its reported subdivision is Crimea, Donetsk, Kherson, Luhansk, or Zaporizhzhia; a missing Ukraine subdivision is unknown.
- **Timezone and clock:** the exit timezone and UTC offset must agree with live `Intl` and `Date` readings from both the main page and a Blob Worker.
- **IP reputation:** the native assessment calls ProxyCheck v3 without an API key and requires all seven risk booleans: `hosting`, `proxy`, `vpn`, `tor`, `compromised`, `scraper`, and `anonymous`. Any positive flag or risk above 25 fails. Valid results are stored in a private per-profile cache for up to 30 minutes for the same exit IP; changes and expiry trigger a refresh. The anonymous service limit is [100 queries per day](https://proxycheck.io/api/).
- **WebRTC:** a Cloudflare STUN observation must complete without a private address, non-proxied UDP address, or public address different from the HTTPS exit.
- **Language and browser baseline:** the native exit language and ordered language list must match the fresh exit country and `navigator.language`/`navigator.languages`. It also checks `navigator.webdriver`, macOS Chrome user agent and platform, screen and processor values, repeatable local Canvas output, and WebGL renderer availability.

This is a conservative app gate created by this project. It is not an official Anthropic rule, individual-IP allowlist, account-eligibility decision, or anti-ban guarantee. If an upstream response is unavailable, malformed, inconsistent, expired, or rate-limited, the result is unknown and continuation stays locked.

### Privacy

Cloudflare Trace, ipwho.is, and ProxyCheck receive the outgoing IP needed for their checks; Cloudflare's STUN service can observe the WebRTC request. Browser fingerprint values and the Canvas digest are evaluated locally and are not sent by this app. The native assessment snapshot is placed in the local `file:` URL fragment, so it can remain in this profile's local browser history, and is also stored in the private profile cache.

### Local proxy configuration

The default proxy is `http://127.0.0.1:17897`. To use another local HTTP proxy, create `~/Library/Application Support/Claude Chrome/config.json` and restart the app:

```json
{
  "proxyURL": "http://127.0.0.1:7897"
}
```

`config.json` accepts only `proxyURL`. It must be an `http` or `https` URL with `localhost`, `127.0.0.1`, or `::1` and an explicit port. Credentials, URL paths, PAC URLs, and direct-bypass settings are not supported; no API key is required.

## Security scope

Claude Chrome is a Chrome privacy helper, not an operating-system network kill switch. It does not change macOS network settings and applies only to Chrome started by this launcher. The local proxy must already be running.

Claude Chrome is an independent project and is not affiliated with, endorsed by, or supported by Anthropic or Google.

Released under the MIT License.
