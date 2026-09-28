# Claude Chrome

<img src="Resources/Logo.png" alt="Claude Chrome icon" width="128">

[繁體中文](README.zh-Hant.md)

Claude Chrome is a small native macOS launcher that opens Google Chrome with a dedicated profile and a fixed local HTTP proxy. It keeps this profile separate from your everyday Chrome profile.

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

## Use

Open `Claude Chrome.app`. It launches Chrome with:

- a private profile under `~/Library/Application Support/Claude Chrome/Profile`;
- the local proxy at `http://127.0.0.1:17897`;
- non-proxied WebRTC UDP disabled.

If the legacy profile at `~/.local/share/claude-network-guard/chrome-login-profile` already exists, the app reuses it. Profile directories must be real directories with mode `0700`.

### Local proxy configuration

The default proxy is `http://127.0.0.1:17897`. To use another local HTTP proxy, create `~/Library/Application Support/Claude Chrome/config.json` and restart the app:

```json
{
  "proxyURL": "http://127.0.0.1:7897"
}
```

Only `http` or `https` URLs with `localhost`, `127.0.0.1`, or `::1` and an explicit port are accepted. Credentials, URL paths, PAC URLs, and direct-bypass settings are not supported.

## Security scope

This app is a Chrome privacy helper, not an operating-system network kill switch. It does not change macOS network settings and cannot protect Chrome sessions started another way. The local proxy must already be running.

It does not guarantee account availability or prevent service restrictions or bans. Claude Chrome is an independent project and is not affiliated with, endorsed by, or supported by Anthropic or Google.

Released under the MIT License.
