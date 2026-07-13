# Changelog

All notable changes to this project are documented in this file.

## 0.2.0 — 2026-07-13

Menu bar redesign — same engine, a much clearer UI.

- **New menu bar icon** — a return-arrow-onto-a-drive glyph ("space, returned") that
  matches the app icon. Renders as a template image so it adapts to light/dark menu bars,
  and tints amber then red as free space runs low.
- **Plain-language panel** — the Docker breakdown is now an itemised list anyone can read:
  "Build leftovers", "Unused app images", and "Finished containers", each with a plain
  description and a `CLEANABLE` / `NONE` tag, grouped under **Safe to clear**; your data
  volumes sit under **Protected — never touched** with a `SAFE` tag.
- **At-a-glance header** — a rounded host-free-space figure, a Healthy / Low / Critical
  health pill (same thresholds as the icon), and a "Docker is using" stack-bar with a
  colour-coded legend.
- **Action-first layout** — the Reclaim button and "Show me first" preview toggle sit
  directly under the disk summary, above the detailed list, so the one-click action is the
  first thing you see.
- After a real run the header shows "+X just returned" and the result card shows the
  measured `statfs` delta — honest reporting unchanged.

No changes to the safety model or the engine: volumes remain read-only and unrepresentable
in the API, and `reclaim-cli` output is unchanged.

## 0.1.0 — 2026-07-13

Initial release.

- **ReclaimKit** — a pure-Swift, UI-free core package: `BackendDetector` (Colima, Docker
  Desktop, OrbStack, Rancher Desktop), a zero-dependency HTTP client over Unix domain
  sockets talking straight to the Docker Engine API, `DiskProbe` (`statfs`-based host free
  space), `TrimService` (per-backend `fstrim` orchestration with streamed progress), and
  `HistoryStore` for a local run history.
- **reclaim-cli** — `status`, `clean` (dry-run by default, `--run` to execute, `--containers`,
  `--force-trim`, `--notify`), `trim`, `volumes`, and `history` subcommands.
- **Menu bar app** — live host disk free space in the status bar, a detail panel with a
  Build Cache / Images / Containers / Volumes breakdown, a preview (dry-run) toggle, a
  live progress log during cleaning, and a weekly-schedule toggle backed by
  `SMAppService`.
- **Safety guarantees** — volumes are read-only everywhere in the app; there is no code
  path, public API, or CLI flag that can ever prune or delete a volume. Enforced by
  `SafetyGuard` at the request layer and covered by a regression test that greps both
  `Sources/` and the built release binary for the forbidden volume-prune request path.
- Reports the actual host disk delta (`statfs` before/after) after a clean, not Docker's
  own `RECLAIMABLE` estimate, which is known to overstate real savings because images
  share layers.
