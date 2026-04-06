# text-expander

Windows text expander written in Zig with SQLite storage.

## What it does

- Global text expansion (`:bb` -> `be right back.`).
- Uses Windows-native `winsqlite3.dll` dynamically (no external SQLite install required).
- Stores snippets in `%LOCALAPPDATA%\\TextExpander\\snippets.db`.
- Quit hotkey while running: `Ctrl+Shift+Q`.

## Commands

```powershell
text-expander.exe run
text-expander.exe start
text-expander.exe stop
text-expander.exe status
text-expander.exe add :bb "be right back."
@"
Best regards,
Team
"@ | text-expander.exe addm :sig
text-expander.exe remove :bb
text-expander.exe list
text-expander.exe doctor
text-expander.exe tui
```

## Build (manual)

Use your working Zig binary path:

```powershell
zig build-exe src/main.zig -lc -fno-emit-bin
```

For a release executable, use this on a normal local environment:

```powershell
mkdir dist
zig build-exe src/main.zig -O ReleaseSafe -lc -luser32 -femit-bin=dist/text-expander.exe
```

Or use:

```powershell
./scripts/build-release.ps1
```

## Start using

1. Build the release executable.
2. Run `text-expander.exe doctor` once.
3. Run `text-expander.exe add :bb "be right back."`.
4. Run `text-expander.exe start` (background mode).
5. In any app, type `:bb` then space.

## Production notes

- Trigger validation enforces `:` prefix and `[A-Za-z0-9_-]`.
- SQL access uses prepared statements and bound parameters.
- Runtime ignores injected keystrokes to avoid recursive expansion loops.
- CLI commands print the SQLite DB file path (`db: ...`) for support/debugging.
- Multiline snippets are supported through `addm` (read from stdin).

## TUI (tui.zig)

Raycast/Linear-inspired minimal snippet manager UI is available in `src/tui_main.zig`.

Install `tui.zig` dependency first:

```powershell
zig fetch --save git+https://github.com/muhammad-fiaz/tui.zig.git
```

Then build and run the TUI:

```powershell
zig build tui
.\zig-out\bin\text-expander-tui.exe
```
