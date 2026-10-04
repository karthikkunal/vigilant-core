# Store metadata

`fastlane supply` (Google Play) and `fastlane deliver` (App Store Connect) read
this directory. Every `.txt` file's **entire contents** become the value that is
uploaded, so these files must contain only the value — no comments, no
explanations. That is why the placeholder guidance lives in this file instead of
inside them.

## Placeholders: filled

Every `REPLACE` marker has been replaced. The values, and what still needs a
human action behind them:

| File | Store | Value | State |
|---|---|---|---|
| `copyright.txt` | both | `2026 Ranjith Raj` | keep the year current each release |
| `ios/en-US/privacy_url.txt` | iOS | `https://vigilant-core-9a0e4f.gitlab.io/privacy-policy.html` | **resolves (HTTP 200)** — see below |
| `ios/en-US/support_url.txt` | iOS | project homepage | switch to `…/-/issues` once the project has at least one issue |
| `ios/en-US/marketing_url.txt` | iOS | `https://gitlab.com/karthikkunal/vigilant-core` | resolves |

Check for leftovers before submitting:

```bash
grep -rn REPLACE app/fastlane/metadata/ packages/cert_chain/ios/ --exclude=README.md
```

`--exclude=README.md` is because the line above lives in this file, which would
otherwise always match.

### The privacy URL and GitLab Pages

`docs/privacy-policy.md` is the source of truth and is published, alongside the
project's marketing page, by `scripts/build-site.sh` — wired up as the `pages`
job in `.gitlab-ci.yml`, which runs on every push to `main`. The URL in
`privacy_url.txt` resolves publicly; confirm with:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  https://vigilant-core-9a0e4f.gitlab.io/privacy-policy.html
```

Two things that will silently break that check if they are changed:

- The project has a **unique Pages domain**, so the site lives at the root of
  `vigilant-core-9a0e4f.gitlab.io`. Do not add a `/vigilant-core/` path segment.
- Pages access level is **`enabled`**, not `public`. gitlab.com rejects
  `public` for this project, and setting `private` — the value it shipped with —
  redirects visitors to `projects.gitlab.io/auth`, at which point both stores
  reject the build for an unreachable policy.

To preview the site before pushing:

```bash
./scripts/build-site.sh
python3 -m http.server -d public 8080
```

### The support URL and the issue tracker

`https://gitlab.com/karthikkunal/vigilant-core/-/issues` is the better support URL
and is what the F-Droid recipe's `IssueTracker` already points at. It currently
returns **404**, because GitLab serves a 404 for an empty issue list to a visitor
who is not signed in — the project simply has no issues yet. The issues feed at
`…/-/issues.atom` returns 200 with zero entries, which confirms Issues is enabled
and public. Opening the first issue makes the HTML page resolve, after which this
file should be pointed back at the tracker.

## iOS character limits

Enforced by App Store Connect; the values here are already within them.

| File | Limit |
|---|---|
| `name.txt` | 30 |
| `subtitle.txt` | 30 |
| `promotional_text.txt` | 170 |
| `keywords.txt` | 100 |
| `description.txt` | 4000 |
| `release_notes.txt` | 4000 |

## Platform differences in the copy

The iOS and Android descriptions are **not** the same text, deliberately.

Continuous background paging — the foreground service, escalating sound and
vibration, full-screen alert, Acknowledge/Mute/Re-check actions — is an **Android
only** feature in this release. The iOS description says so explicitly rather
than promising a feature iOS does not have, because claiming it and not shipping
it is a review risk. See the `Targets` section of the top-level `README.md`.

`ios/en-US/description.txt` is also the file that must change if iOS background
monitoring ever ships.

## Privacy manifest

`app/ios/Runner/PrivacyInfo.xcprivacy` declares the app's required-reason API
usage and is registered in the Xcode project's Resources build phase. It is not
part of this directory because it ships inside the app bundle, not the store
listing.
