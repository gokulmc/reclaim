# Reclaim — a macOS menu bar app that actually gives Docker space back

**Spec for Claude Code.** Hand this file over as the project brief.

---

## Assumed decisions (change these lines if you disagree)

| Decision | Choice | Why |
|---|---|---|
| Scope | Docker / Colima only | Tight, shippable, one strong value prop. Extensible later. |
| Stack | SwiftUI, macOS 13+ | Native menu bar, tiny binary, no runtime. A disk-cleanup tool shipping a 150 MB Electron runtime is absurd. |
| Form factor | `MenuBarExtra` + detail panel | Background utility. |
| Distribution | Personal first → notarized DMG | **Not App Store.** The sandbox forbids shelling out to `docker`/`colima` and forbids arbitrary Unix socket access. This app cannot exist inside the App Store sandbox. |

---

## 1. The core insight (this IS the product)

Docker on macOS runs inside a Linux VM backed by a **sparse disk image**. When you
`docker prune`, blocks are freed **inside the VM's filesystem** — but the sparse image
file on macOS **does not shrink**. macOS gets nothing back.

`fstrim` inside the VM issues TRIM/discard, which tells the host to actually deallocate
those blocks in the sparse file. **Only then does the Mac see free space.**

Real measurement from the machine this spec came from:

```
docker image prune -af    →   2.68 GB reclaimed
docker builder prune -af  →  34.35 GB reclaimed   (the real monster)
colima ssh -- sudo fstrim -av
  → /mnt/lima-colima: 49.8 GiB trimmed on /dev/vdb1

Host free space: 6.5 GB → 57 GB    (~50.65 GB actually returned)
~/.colima:       84 GB  → 42 GB
```

Every competing tool stops after the prune. **The `fstrim` is the whole differentiator.**
If you build nothing else, build that.

---

## 2. Non-negotiable safety rules

> These are not style preferences. Violating them destroys user databases.

1. **NEVER run `docker volume prune` or `docker system prune --volumes`.**
   Volume prune deletes any volume with no *running* container. A stopped prod stack's
   database volume looks identical to garbage. On the source machine, a volume named
   `trussprod_pg_data` (a Postgres database) was reported by Docker as "94% reclaimable."

2. **Volumes are read-only in this app.** Display them, show sizes, never offer a delete
   button. If you ever add deletion, require the user to type the volume name.

3. **Never touch images belonging to running containers.** `docker image prune -a`
   already respects this — don't hand-roll it.

4. **Dry-run must be the default.** Show what *would* be removed, require an explicit click.

5. **Report the honest number.** Docker's `RECLAIMABLE` figure is misleading — it claimed
   22.42 GB of reclaimable images and delivered 2.68 GB, because images share layers.
   Always show the **actual host disk delta** (`statfs` before vs after), not Docker's estimate.

---

## 3. Architecture

```
┌─────────────────────────────────────────┐
│ MenuBarExtra (SwiftUI)                  │  live disk %, one-click Clean
│   └── DetailPanel (SwiftUI)             │  breakdown, dry-run, history
├─────────────────────────────────────────┤
│ ReclaimKit (Swift package — pure logic) │  ← unit-testable, no UI
│   ├── BackendDetector                   │  Colima / Docker Desktop / OrbStack / Rancher
│   ├── DockerClient                      │  Engine API over Unix socket
│   ├── TrimService                       │  the fstrim step, per backend
│   ├── DiskProbe                         │  statfs() host free space
│   └── SafetyGuard                       │  hard-blocks volume operations
└─────────────────────────────────────────┘
```

Keep **ReclaimKit** free of SwiftUI so the logic is testable and could later ship as a CLI.

---

## 4. Backend detection & the trim command

This is the fiddliest part. Detect the backend, then pick the right trim strategy.

| Backend | Socket | Trim strategy |
|---|---|---|
| **Colima** | `~/.colima/default/docker.sock` | `colima ssh -- sudo fstrim -av` |
| **Rancher Desktop** | `~/.rd/docker.sock` | lima-based: `rdctl shell -- sudo fstrim -av` |
| **Docker Desktop** | `~/Library/Containers/com.docker.docker/Data/docker-cli.sock` | No clean CLI. Recent versions auto-TRIM on idle. Fallback: `docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -i -n fstrim -av`. Detect version; if auto-trim is supported, tell the user instead of hacking. |
| **OrbStack** | `~/.orbstack/run/docker.sock` | Reclaims natively. **Detect and say so** — don't pretend to add value. |

Detection order: check for each socket's existence, then confirm with a `GET /_ping`.
Fall back to parsing `docker context inspect` if sockets are ambiguous.

---

## 5. Docker Engine API (prefer over CLI)

Talk to the Unix socket directly — no CLI output parsing, structured JSON, no PATH issues.

| Need | Endpoint |
|---|---|
| Usage breakdown | `GET /system/df` |
| Prune unused images | `POST /images/prune?filters={"dangling":{"false":true}}` |
| Prune build cache | `POST /build/prune?all=true` ← **the big one** |
| Prune stopped containers | `POST /containers/prune` |
| List volumes (READ ONLY) | `GET /volumes` |
| Running containers | `GET /containers/json` |

Swift has no built-in HTTP-over-UDS client. Either write a tiny one over
`Network.framework` (`NWConnection` to `NWEndpoint.unix`), or vendor
[swift-nio](https://github.com/apple/swift-nio) which supports UDS cleanly. NIO is the
lower-risk path.

`fstrim` has **no API** — it must shell out via `Process`.

---

## 6. Milestones

**M0 — ReclaimKit core (do this first, no UI)**
- `BackendDetector` → returns enum + socket path
- `DockerClient.systemDF()` → parsed usage struct
- `DiskProbe.freeBytes()` via `statfs("/")`
- `TrimService.trim()` → shells out, parses "X GiB trimmed"
- `clean(dryRun:)` → orchestrates: probe → prune images → prune build cache → trim → probe
- Unit tests with a mocked socket. **Ship this as a CLI binary first** — validate the whole
  flow before writing any UI.

**M1 — Menu bar shell**
- `MenuBarExtra` showing host disk % and a colored icon (green/amber/red)
- Poll `DiskProbe` every 60s

**M2 — Detail panel**
- Breakdown cards: Images / Build Cache / Containers / Volumes(🔒)
- Big "Reclaim" button; a "Preview" toggle for dry-run
- Live progress log during the run (users need to see `fstrim` working — it's slow)
- Result card: **"X GB returned to macOS"** using the real `statfs` delta

**M3 — Safety layer**
- `SafetyGuard` that makes volume-destructive calls literally unrepresentable in the API
- Warning banner listing detected data volumes ("these are protected")

**M4 — Scheduling**
- `SMAppService.agent` to register a weekly background run (modern replacement for hand-
  installing a launchd plist)
- Notification on completion: "Reclaimed 12 GB"
- Persist a history log so the user can see growth trends → this is your early-warning system

**M5 — Ship**
- Developer ID signing + notarization, DMG via `create-dmg`
- Do **not** attempt App Store.

---

## 7. Gotchas that will bite you

- **`docker builder prune` is usually the biggest win**, not images. Surface build cache
  prominently — it was 34 GB vs 2.7 GB of images on the source machine.
- **`fstrim` is slow** (tens of seconds on a large disk) and prints nothing until done.
  Stream output, show a spinner, never block the main thread.
- **`colima ssh` needs Colima running.** If it's stopped, prune/trim can't run at all —
  detect and prompt "Start Colima?".
- **PATH in a GUI app is not your shell's PATH.** `colima`/`docker` live in
  `/opt/homebrew/bin`, which a launched .app won't have. Set it explicitly on `Process`.
- **Sandboxing kills this app.** Don't enable App Sandbox; it blocks both `Process` and
  UDS access.
- **`docker system df` can be slow** on large daemons — call it off the main thread.
- After `builder prune -af`, the user's next build is slow (cache rebuild). Warn them once.

---

## 8. Testing

- Unit-test `ReclaimKit` against a **fake Docker socket** (spin up a local HTTP server on a
  UDS returning canned `/system/df` JSON).
- Integration-test on a **throwaway Colima profile**: `colima start -p test --disk 20`,
  pull junk images, build layers, then assert host free space actually increases.
- **Write a regression test that asserts no code path can ever emit `volume prune`.**
  Grep the built binary in CI if you have to. This is the one bug that loses data.

---

## 9. The pitch (if you ship it)

> Docker on Mac quietly eats your disk and never gives it back. `docker prune` frees space
> inside the VM — but the disk image on your Mac never shrinks. Reclaim runs the prune
> *and* the TRIM that actually returns the gigabytes to macOS. One click, and your volumes
> are never touched.

Nobody else does the second half. That's the app.
