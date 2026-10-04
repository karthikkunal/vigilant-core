# vigilant-core — Flutter app

The Android and iOS application. Discovery lives in
[`packages/discovery_core`](../packages/discovery_core) and the native TLS chain
capture in [`packages/cert_chain`](../packages/cert_chain); this package is the
UI, the foreground pager, and the thin platform bridges.

- `lib/monitors/` — monitor model, repository, runner, the foreground service,
  and the screens that create and edit monitors
- `lib/discovery/` — the scan screen, the report view, and the resolver
  preference
- `lib/alerts/` — `AlertStyle` and notification delivery
- `lib/reminders/` — scheduled expiry reminders
- `lib/settings/` — resolver choice, Android access and battery guidance
- `lib/platform/` — platform seams (`PowerStatusController`)
- `lib/home/` — the shell and its destinations
- `lib/ui/`, `lib/theme/` — shared presentation

The whole app is described in the [top-level README](../README.md), and the
design that justifies these boundaries is in
[`docs/architecture.md`](../docs/architecture.md). Store metadata for Play
and the App Store lives in [`fastlane/metadata/`](fastlane/metadata), and
[`fastlane/metadata/README.md`](fastlane/metadata/README.md) records what still
needs a human action before submitting.

Run `scripts/check.sh full` from the repository root, or install the git hooks
with `scripts/install-git-hooks.sh`.
