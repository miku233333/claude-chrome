#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess

project = Path(__file__).resolve().parent.parent
binary = project / "dist/Claude Login Router.app/Contents/MacOS/Claude Login Router"
base = "https://claude.com/cai/login/app-google-auth"
nonce = "A" * 32
valid = f"{base}?open_in_browser=1&hop_nonce={nonce}"
cases = {
    valid: "claude-chrome",
    f"https://claude.ai/login/app-google-auth?hop_nonce={nonce}": "claude-chrome",
    f"{base}?hop_nonce={nonce}&hop_nonce={nonce}": "reject",
    f"{base}?hop_nonce={nonce}&redirect=https://example.com": "reject",
    f"{base}?hop_nonce={nonce}&open_in_browser=0": "reject",
    f"{base}?hop_nonce={nonce}#fragment": "reject",
    f"{base}?hop_nonce=short": "reject",
    f"http://claude.com/cai/login/app-google-auth?hop_nonce={nonce}": "reject",
    f"https://user@claude.com/cai/login/app-google-auth?hop_nonce={nonce}": "reject",
    f"https://claude.com:443/cai/login/app-google-auth?hop_nonce={nonce}": "reject",
    f"https://claude.com.evil.example/cai/login/app-google-auth?hop_nonce={nonce}": "fallback",
    "https://claude.ai/": "claude-external",
    "https://accounts.google.com/": "fallback",
    "https://example.com/": "fallback",
    "http://192.168.0.254/": "fallback",
    "file:///tmp/test": "reject",
}
for url, expected in cases.items():
    actual = subprocess.check_output([str(binary), "--route", url], text=True).strip()
    assert actual == expected, (expected, actual)

external_cases = {
    "https://accounts.google.com/o/oauth2/auth?state=test%2Bvalue": "claude-external",
    "https://github.com/login/oauth/authorize?state=test%2Bvalue": "claude-external",
    "https://login.microsoftonline.com/": "claude-external",
    "https://user:secret@example.com/": "reject",
    "http://example.com/": "reject",
    "file:///tmp/test": "reject",
    f"{base}?hop_nonce=short": "reject",
}
for url, expected in external_cases.items():
    actual = subprocess.check_output([str(binary), "--route", url, "--source", "com.anthropic.claudefordesktop"], text=True).strip()
    assert actual == expected, (expected, actual)
assert subprocess.check_output([str(binary), "--route", "https://accounts.google.com/", "--source", "com.apple.TextEdit"], text=True).strip() == "fallback"

source = (project / "Resources/Start.js").read_text()
function = source[source.index("  function isDesktopLoginURL("):source.index("  function validTargetURL(")]
script = function + "\nconst cases = " + json.dumps(cases) + ";\n"
script += "for (const [url, expected] of Object.entries(cases)) { if (isDesktopLoginURL(url) !== (expected === 'claude-chrome')) throw new Error('validator mismatch'); }\n"
script += "const externalCases = " + json.dumps(external_cases) + ";\n"
script += "for (const [url, expected] of Object.entries(externalCases)) { if (isExternalURL(url) !== (expected === 'claude-external')) throw new Error('external validator mismatch'); }\n"
subprocess.run(["node", "-e", script], check=True)
print(f"{len(cases) + len(external_cases) + 1} 個路由及登入網址驗證案例通過。")
