# Reclaim

[![CI](https://github.com/gokulmc/reclaim/actions/workflows/ci.yml/badge.svg)](https://github.com/gokulmc/reclaim/actions/workflows/ci.yml)

A macOS menu bar app (and CLI) that gives Docker's disk space back to your Mac —
not just back to the VM.

## The problem

Docker on macOS runs inside a Linux VM backed by a sparse disk image. When you run
`docker system prune`, blocks get freed **inside the VM's filesystem** — but the sparse
image file on macOS itself does not shrink. Your Mac gets nothing back. The fix is a
second step almost nobody runs: `fstrim` inside the VM, which issues a TRIM/discard that
tells the host to actually deallocate those blocks in the sparse file. Only then does the
free-space number on your Mac move.

Real measurement, from the machine this tool was built on:

```
docker image prune -af    →   2.68 GB reclaimed
docker builder prune -af  →  34.35 GB reclaimed   (the real monster)
colima ssh -- sudo fstrim -av
  → /mnt/lima-colima: 49.8 GiB trimmed on /dev/vdb1

Host free space: 6.5 GB → 57 GB    (~50.65 GB actually returned)
~/.colima:       84 GB  → 42 GB
```

Every prune-only tool stops at the first line. The `fstrim` is the whole differentiator —
if Reclaim did nothing else, it would still be worth having just for that.

## What it does

One click:

1. Prunes unused images and build cache (build cache is usually the bigger win —
   34 GB vs 2.7 GB above). Pruning stopped containers is optional and off by default.
2. Runs the right `fstrim` variant for your backend, so the freed blocks are actually
   returned to macOS.
3. Reports **the real number** — the host free-space delta measured with `statfs()`
   before and after — not Docker's own estimate.

That last point matters more than it sounds. Docker's `RECLAIMABLE` column is
frequently wrong: on the same machine as above, Docker reported 22.42 GB of
"reclaimable" images and the actual prune only freed 2.68 GB, because images share
layers on disk — the space Docker attributes to each image individually isn't summable.
Reclaim always shows the number your Mac's Finder would agree with, and labels
dry-run estimates explicitly as Docker's own numbers so the two are never confused.

## Safety

This tool touches a Docker daemon and shells out to a VM. The rules below are not style
preferences — they're the difference between freeing disk space and deleting someone's
database.

- **Volumes are read-only, always.** Reclaim lists volumes and their sizes; there is no
  button, flag, or code path anywhere in the app that deletes or prunes one. `docker
  volume prune` is not merely disabled — it is unrepresentable in the code. The only
  Docker API calls Reclaim's client can make are a fixed, public set (image prune, build
  cache prune, container prune, and read-only listings); the request layer that sends
  them independently rejects any mutating call whose path touches a volume, or any
  system-wide prune, as a second, redundant check.
- **Dry-run is the default everywhere.** `reclaim-cli clean` without `--run` — and the
  menu bar app's Preview toggle, which starts ON — show what would be removed and send
  zero mutating requests.
- **Never touches images used by running containers.** That's `docker image prune -a`'s
  own behavior; Reclaim doesn't hand-roll pruning logic on top of it.
- **Regression-tested in CI.** Every build greps the source tree and the compiled
  release binary for the volume-prune request path and fails the build if it's ever
  found — see `.github/workflows/ci.yml`.

Why this is worth stating loudly: a volume like `prod_pg_data` (a live Postgres
database) with no *running* container attached to it looks identical to garbage from
Docker's perspective, and has been reported as "94% reclaimable" by Docker itself on a
real machine. Reclaim's answer to that is to not let the question come up.

## Supported backends

| Backend | Socket | Trim strategy |
|---|---|---|
| Colima | `~/.colima/default/docker.sock` | `colima ssh -- sudo fstrim -av` |
| Rancher Desktop | `~/.rd/docker.sock` | `rdctl shell -- sudo fstrim -av` |
| Docker Desktop | `~/Library/Containers/com.docker.docker/Data/docker-cli.sock` | Recent versions auto-TRIM on idle — Reclaim detects this and tells you instead of doing extra work. Older versions fall back to a privileged `nsenter fstrim` container, gated behind `--force-trim` (CLI only; not exposed in the app). |
| OrbStack | `~/.orbstack/run/docker.sock` | Reclaims disk space natively. Reclaim detects this and reports it rather than pretending to add value. |

Backend detection checks each socket in order and confirms it's live with a Docker
Engine API ping before using it.

## Install

Requires macOS 13+. Build from source:

```
git clone https://github.com/gokulmc/reclaim.git
cd reclaim
./build.sh
```

This is not on the App Store, and cannot be: the App Sandbox forbids both shelling out
via `Process` (needed to run `fstrim` and backend CLIs) and arbitrary Unix domain socket
access (needed to talk to the Docker Engine API). Both are load-bearing for this app to
work at all, so it ships unsandboxed, outside the store — you build it from source.

`./setup-signing.sh` is optional — it creates a stable local code-signing identity so
macOS treats rebuilds as the same app (keeping permissions and Login Items intact across
rebuilds). Without it, `build.sh` falls back to ad-hoc signing, which works fine too.

## CLI usage

```
$ reclaim-cli --help
OVERVIEW: Reclaim disk space Docker/Colima quietly ate — and actually give it
back to macOS.

Docker on macOS runs inside a Linux VM backed by a sparse disk image. Pruning
frees
blocks inside the VM, but the sparse image on your Mac doesn't shrink until an
`fstrim` runs. Reclaim runs both steps and reports the real host disk delta.

Volumes are always read-only in this tool — there is no code path that can ever
delete one.

USAGE: reclaim-cli <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  status (default)        Show the detected backend, host disk free/total, and
                          a Docker usage breakdown.
  clean                   Prune unused images/build cache and trim the VM disk
                          image so macOS actually gets space back.
  trim                    Run only the fstrim step for the detected backend.
  volumes                 List Docker volumes, read-only. Reclaim never deletes
                          or prunes volumes.
  history                 Show past clean runs.

  See 'reclaim-cli help <subcommand>' for detailed help.
```

```
$ reclaim-cli status --help
OVERVIEW: Show the detected backend, host disk free/total, and a Docker usage
breakdown.

USAGE: reclaim-cli status

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.
```

```
$ reclaim-cli clean --help
OVERVIEW: Prune unused images/build cache and trim the VM disk image so macOS
actually gets space back.

Dry-run by default: prints what would be removed using Docker's own estimates
and
sends zero mutating requests. Pass --run to actually perform the clean.

USAGE: reclaim-cli clean [--run] [--containers] [--force-trim] [--notify]

OPTIONS:
  --run                   Actually perform the clean. Without this flag, clean
                          only previews what would happen.
  --containers            Also prune stopped containers.
  --force-trim            Docker Desktop only: force the privileged nsenter
                          fstrim fallback.
  --notify                Post a macOS notification with the result (intended
                          for scheduled runs).
  --version               Show the version.
  -h, --help              Show help information.
```

`reclaim-cli clean` finishes with the headline number: `Returned X GB to macOS (host
free: A → B)`, computed from the real `statfs` delta. Other subcommands: `trim` (just the
trim step), `volumes` (read-only listing), `history` (table of past runs).

## Menu bar app

The menu bar icon shows your Mac's free space and turns amber, then red, as the disk
fills. Click it for a panel anyone can read — no Docker jargon required:

- **A plain-language breakdown** — "Build leftovers", "Unused app images", and "Finished
  containers" under **Safe to clear**, and your data volumes under **Protected — never
  touched**, each tagged `CLEANABLE` or `SAFE`.
- **An at-a-glance header** — a rounded free-space figure, a Healthy / Low / Critical
  health pill, and a "Docker is using" stack-bar showing where the space went.
- **One-click, action-first** — the Reclaim button and a "Show me first" preview toggle
  (on by default) sit right under the summary. Preview shows what would be removed and
  sends zero mutating requests.
- **A live progress log** while cleaning — `fstrim` is slow (tens of seconds on a large
  disk), so each step is shown as it happens and it never looks hung.
- **A real result** — "X GB returned to your Mac", from the actual `statfs` delta, not
  Docker's estimate.
- **A weekly-schedule toggle** backed by `SMAppService`, so Reclaim can run itself and
  notify you instead of you remembering to open it.

<!-- TODO: add a screenshot of the panel at docs/screenshot.png and reference it here -->
The panel design lives in [`docs/design/panel.html`](docs/design/panel.html).

## Architecture

```
MenuBarExtra (SwiftUI)  →  ReclaimKit (pure Swift, no UI)  →  Docker Engine API
                                                            →  fstrim (shelled out)
```

**ReclaimKit** is a plain Swift package with no SwiftUI or AppKit imports, so it's
independently unit-testable and ships as the same logic behind both the menu bar app and
`reclaim-cli`. It talks to the Docker Engine API over its Unix domain socket using a
small hand-rolled HTTP client (no `swift-nio`, no third-party HTTP stack) — connect,
write the request, read to EOF, parse `Content-Length` or chunked bodies. `fstrim` has no
API, so that step shells out via `Process` with an explicit `PATH`, since a GUI app
doesn't inherit your shell's.

Full design rationale and the safety model live in
[`docs/SPEC.md`](docs/SPEC.md) and the locked implementation decisions in
[`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md).

## License

MIT — see [LICENSE](LICENSE).
