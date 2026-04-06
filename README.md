# text-expander

Minimal, production-minded Windows text expander built with Zig and SQLite.

`text-expander` runs as a background service, expands typed triggers globally (for example `:bb` -> `be right back.`), and stores snippets in a local SQLite database.

## Why this project

- Fast, native, low-overhead runtime.
- SQLite-backed snippet storage.
- Scriptable CLI for automation and ops.
- Optional terminal UI (TUI) for snippet browsing/editing.

## Features

- Global expansion in Windows apps.
- Background service lifecycle: `start`, `run`, `stop`, `status`.
- Hot reload of snippet changes (no service restart needed for DB edits).
- Multiline snippet support via `addm`.
- Template tokens in expansions:
  - `{{date}}` -> `YYYY-MM-DD`
  - `{{time}}` -> `HH:MM`
  - `{{datetime}}` -> `YYYY-MM-DD HH:MM`
  - `{{iso_datetime}}` -> ISO local datetime
  - `{{year}}`, `{{month}}`, `{{day}}`
- Built-in safety controls:
  - Trigger validation (`:` prefix, `[A-Za-z0-9_-]`).
  - Max trigger and expansion limits.
  - Injected-key filtering to prevent recursive loops.

## Requirements

- Windows
- Zig `0.15.2` or newer compatible with this repo
- `winsqlite3.dll` (available on supported Windows versions)

## Build

Build core CLI:

```powershell
zig build
```

Build TUI:

```powershell
zig build tui
```

Manual release build (CLI exe):

```powershell
mkdir dist
zig build-exe src/main.zig -O ReleaseSafe -lc -luser32 -femit-bin=dist/text-expander.exe
```

Or use the release helper:

```powershell
.\scripts\build-release.ps1
```

## Quick start

```powershell
.\dist\text-expander.exe doctor
.\dist\text-expander.exe add :bb "be right back."
.\dist\text-expander.exe start
.\dist\text-expander.exe status
```

Then type `:bb` + space in any app.

## CLI reference

```text
text-expander                 # start background service
text-expander start           # start background service
text-expander run             # run foreground (blocking)
text-expander stop            # stop service
text-expander status          # show status + db path
text-expander add :key "..."  # add/update single-line snippet
text-expander addm :key       # add/update multiline snippet from stdin
text-expander remove :key     # delete snippet
text-expander list            # list snippets
text-expander doctor          # health check
text-expander tui             # prints TUI launch target
text-expander help            # usage
```

## TUI

The project includes a minimal, keyboard-first TUI powered by `libvaxis`.

Run:

```powershell
zig build tui
.\zig-out\bin\text-expander-tui.exe
```

## Database location

Default DB path:

`%LOCALAPPDATA%\TextExpander\snippets.db`

Most CLI commands print `db: ...` to make support/debugging straightforward.

## Open source roadmap

Planned work is tracked in [LINEAR_TODO.md](LINEAR_TODO.md), organized by:

- `P0` ship-ready baseline
- `P1` production hardening
- `P2` enterprise readiness

## For contributors

- Keep changes small and focused.
- Preserve Windows reliability first (hook stability, safe shutdown, no recursive input).
- Prefer prepared statements and bounded memory operations.
- Validate with:
  - `zig build`
  - `zig build tui`
  - manual smoke test: `start`, type trigger, `stop`

## For AI agents

If you are an autonomous coding agent working in this repo:

- Read `build.zig` first to understand targets (`text-expander`, `text-expander-tui`).
- Treat `src/main.zig` as the service/CLI source of truth.
- Keep DB schema backward compatible unless migration is explicit.
- Do not introduce non-Windows assumptions into runtime code paths.
- Keep commands and docs synchronized whenever CLI behavior changes.

## Project links

- X / updates: [@milonspace](https://x.com/milonspace)
- Repository: [bymilon/zig-text-expander](https://github.com/bymilon/zig-text-expander)
