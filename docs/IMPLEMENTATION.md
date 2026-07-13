# Reclaim — implementation decisions

Companion to [SPEC.md](SPEC.md) (the product brief). SPEC.md says *what*; this file fixes
the *how* wherever the spec left a choice open. If this file and SPEC.md conflict on
safety rules, SPEC.md §2 wins.

## Locked decisions

| Area | Decision |
|---|---|
| Build system | Pure SwiftPM — no `.xcodeproj`. App bundle assembled by `build.sh` (same scaffold as gokulmc/membar). |
| Swift | `// swift-tools-version:5.9`, platforms: `[.macOS(.v13)]`. Swift 5 language mode (do not fight Swift 6 strict concurrency). |
| HTTP over UDS | Hand-rolled minimal client over **POSIX sockets** (`socket(AF_UNIX)` + `connect` + blocking I/O on a background queue). Send `Connection: close`, read to EOF. Must parse both `Content-Length` and `Transfer-Encoding: chunked` bodies. **No swift-nio** — zero heavy deps, and read-to-EOF makes framing trivial. |
| CLI deps | `swift-argument-parser` only. |
| Targets | `ReclaimKit` (library, zero UI imports), `reclaim-cli` (executable), `ReclaimApp` (executable, SwiftUI), `ReclaimKitTests`. |
| Bundle id | `com.gokul.reclaim`, app name **Reclaim**, `LSUIElement = true`. |
| Signing | `build.sh` signs with identity `ReclaimLocalSign` if present, else ad-hoc (this app reads no Keychain items, so ad-hoc rebuild churn is acceptable). `setup-signing.sh` creates the stable identity, same as membar. |
| UI style | Stock SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`. Native controls only — no custom glass/vibrancy layers, no custom popover chrome. Keep it plain and native. |

## Public-repo hygiene (repo will be public)

- **All test fixtures must be synthetic.** Model them on the real API shapes (samples from
  the dev machine are in the session scratchpad, see agent brief) but invent image/volume/
  container names (`web-app`, `pg-data`, …). Never commit real hostnames, project names,
  image digests, or volume names from the dev machine.
- No absolute `/Users/gokulmc/...` paths anywhere in committed code; use `~`/`NSHomeDirectory()`.

## ReclaimKit API surface

```swift
public enum Backend: String, CaseIterable { case colima, dockerDesktop, orbstack, rancherDesktop }

public struct DetectedBackend { public let backend: Backend; public let socketPath: String }

public enum BackendDetector {
    // Check sockets in order: colima, orbstack, rancherDesktop, dockerDesktop.
    // A socket counts only if GET /_ping returns "OK". Returns all live backends;
    // callers use the first. (docker context inspect fallback: document as TODO, skip v1.)
    public static func detect() -> [DetectedBackend]
}

public struct DockerClient {   // init(socketPath: String)
    public func ping() async throws -> Bool
    public func systemDF() async throws -> DiskUsage
    public func pruneImages() async throws -> PruneResult      // POST /images/prune?filters={"dangling":{"false":true}}
    public func pruneBuildCache() async throws -> PruneResult  // POST /build/prune?all=true
    public func pruneContainers() async throws -> PruneResult  // POST /containers/prune
    public func listVolumes() async throws -> [Volume]         // GET /volumes — READ ONLY
    public func listContainers(all: Bool) async throws -> [ContainerSummary]
}
```

**SafetyGuard is a design property plus enforcement**, not just a class:
1. `DockerClient`'s raw request method is `private`. The only public entry points are the
   fixed methods above. There is no method that deletes a volume — the call is
   unrepresentable.
2. The private request path runs every outgoing request through
   `SafetyGuard.validate(method:path:)`, which `throws` (and `assertionFailure`s in debug)
   on any `POST`/`DELETE` whose path contains `volume`, and on `system/prune`.
3. Tests: unit test that `SafetyGuard.validate` rejects `POST /volumes/prune`,
   `DELETE /volumes/x`, `POST /v1.41/volumes/prune`, `POST /system/prune`; plus a source-grep
   regression test asserting no file in `Sources/` contains the literal `volumes/prune`
   (build the forbidden string in the test via concatenation, `"volumes/" + "prune"`, so the
   test itself can't trip the grep). CI additionally runs `strings` on the release binary.

**DiskUsage model** (from real `GET /system/df` — top-level keys `LayersSize`, `Images`,
`Containers`, `Volumes`, `BuildCache`; every array may be `null`):
- images: total size, reclaimable size (unused = `Containers == 0`), count
- buildCache: total + reclaimable (`InUse == false`) + count. **Surface build cache first
  everywhere — it's usually the big one (SPEC §7).**
- containers: stopped count + their `SizeRw` sum
- volumes: count + size (`UsageData.Size`, may be -1) — display only, lock icon

**DiskProbe**: `statfs("/")`, `free = f_bavail * f_bsize`, plus total. Pure struct,
injectable for tests.

**TrimService** (per SPEC §4 table):
- colima: preflight `colima status` (exit 0 = running; if not, throw `.backendStopped`
  so UI can prompt "Start Colima?"); then `colima ssh -- sudo fstrim -av`.
- rancherDesktop: `rdctl shell -- sudo fstrim -av`.
- orbstack: return `.notNeeded("OrbStack reclaims disk space natively.")` — do not shell out.
- dockerDesktop: return `.notNeeded("Recent Docker Desktop TRIMs automatically when idle.")`
  by default; expose `force: Bool` that runs the privileged nsenter fallback from SPEC §4.
  CLI flag `--force-trim`; the app does not expose force in v1.
- All `Process` invocations set `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
  explicitly on the environment (SPEC §7 GUI PATH gotcha).
- Stream stdout+stderr line-by-line to a `(String) -> Void` progress callback
  (`readabilityHandler`, never block the main thread).
- Parse total trimmed bytes from `fstrim -v` output lines of the form
  `<mount>: X GiB (Y bytes) trimmed on <dev>` — sum the `(Y bytes)` capture across lines;
  tolerate lines without the parenthesized byte count by converting the human number.

**Reclaimer.clean** — the orchestration (SPEC M0):
```swift
public struct CleanOptions { var dryRun = true; var pruneContainers = false }  // dry-run DEFAULT
public func clean(options:, progress: @escaping (CleanEvent) -> Void) async throws -> CleanReport
```
- Probe host free → `systemDF` → if dryRun: report would-remove numbers **without issuing
  any POST**, and clearly label them as Docker estimates.
- Real run: pruneImages → pruneBuildCache → (optional pruneContainers) → TrimService.trim
  (streamed) → probe host free again.
- `CleanReport.hostDelta = freeAfter - freeBefore` — **this is the headline number**
  (SPEC §2.5: honest number, not Docker's estimate). Keep Docker's per-step
  `SpaceReclaimed` as secondary detail.
- Emit `CleanEvent` enum (`.step(String)`, `.log(String)`, `.done(CleanReport)`) so both CLI
  and UI can render live progress.

**HistoryStore**: append-only JSON at
`~/Library/Application Support/Reclaim/history.json`; entry = date, backend, per-step
reclaimed, trimmedBytes, hostDelta. Used by CLI `history` and the app's history section.

## CLI commands (`reclaim-cli`)

- `status` — backend detected, host disk free/total, df breakdown table (build cache first),
  volumes listed with a `protected` marker.
- `clean` — **dry-run by default**; `--run` to actually clean; `--containers` to include
  stopped containers; `--force-trim` for Docker Desktop; streams progress; final line
  `Returned X GB to macOS (host free: A → B)`. After a real build-cache prune, print the
  one-time warning that the next build will be slower (SPEC §7).
- `trim` — trim step only.
- `volumes` — read-only list, sizes, "volumes are never touched by Reclaim" footer.
- `history` — table of past runs.

## App (M1–M4)

- `MenuBarExtra`: label = SF Symbol `internaldrive` + free-space text (e.g. `57 GB`).
  Icon color state green/amber/red at free ≥15% / 8–15% / <8% (of volume capacity); if the
  label can't render color reliably in the status bar, switch symbol to
  `exclamationmark.triangle` for red instead of fighting it. Poll `DiskProbe` every 60 s.
- Panel (single window-style view, native): header with host free space + backend name;
  breakdown cards Build Cache / Images / Containers / Volumes(🔒 "never touched");
  Preview toggle (ON by default) + **Reclaim** button; live monospaced progress log while
  running (fstrim is slow — SPEC §7); result line "X GB returned to macOS" from the real
  statfs delta; collapsible history list; if backend is stopped, replace the button with
  "Start Colima" prompt (runs `colima start`, streamed into the log).
- Volumes card shows the protected-volumes banner (SPEC M3).
- Scheduling (M4): `SMAppService.agent(plistName: "com.gokul.reclaim.agent.plist")`;
  plist ships in `Contents/Library/LaunchAgents/`, runs the bundled CLI
  (`Contents/MacOS/reclaim-cli clean --run --notify`) weekly (Sunday 10:00
  `StartCalendarInterval`). `--notify` posts a user notification via
  `osascript -e 'display notification ...'` (the CLI is not an app bundle; UNUserNotificationCenter
  is not available to it). Settings row in the panel: "Clean weekly" toggle showing
  `SMAppService.status`, with the standard hint that macOS may ask for Background Items approval.
- All Docker/df calls off the main thread (`Task.detached` / async), UI updates on `@MainActor`.

## Testing

- `FakeDockerServer`: test helper that binds a real UDS in a temp dir, accepts one
  connection per request, returns canned HTTP responses (both Content-Length and chunked
  variants — chunked must be covered). Run `DockerClient` against it.
- Unit tests: df parsing (nulls!), prune result parsing, fstrim output parsing (GiB/MiB,
  multiple mounts, no-bytes variant), SafetyGuard rejections, BackendDetector with fake
  socket dirs (inject home-dir base path), HistoryStore round-trip, source-grep regression.
- `swift test` must pass cleanly before any milestone is called done.

## build.sh contract (same shape as membar)

`swift build -c release` → assemble `Reclaim.app` (Contents/MacOS/{Reclaim,reclaim-cli},
Info.plist with LSUIElement, icon, LaunchAgents plist) → codesign (ReclaimLocalSign if
available, else ad-hoc) → install to /Applications and relaunch. Icon: `scripts/render-icon.swift`
(CoreGraphics-drawn, committed to repo — a downward-returning arrow onto a drive slab,
blue→teal squircle background, membar-style) → iconutil → `.icns`.
