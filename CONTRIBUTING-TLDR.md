# Contributing to rune-mm

Lua plugins for the Rune client, designed for horstgs’ Materia Magica configuration.

## Project context

- Target: Rune client (https://runemud.com, https://github.com/mmcdole/rune) and horstgs’ Materia Magica setup (https://github.com/horstgs/rune-materiamagica-public)
- Development: Ghostty on Debian 13; plugins should also work on Windows and macOS where possible
- Game: Materia Magica (https://www.materiamagica.com)

## Reference plugins

| Topic | Reference |
| --- | --- |
| Display methods, help rows, bare-command aliases | `annwnQuestSearch.lua` |
| Loader line and command naming | `eqdbResultsPicker.lua` |
| Cyan prefix and help footer | `jmcSolver.lua`, `druidSpellTLAs.lua` |
| Help layout | `autopouch.lua` |
| Character-name API | `charname.lua` |
| Load-time display | `fauxSextant.lua` |

## Required conventions

### File placement and header

- Put each plugin directly in `eljayPlugins/`, named `eljayPlugins/<camelName>.lua`. Do not nest plugin files.
- Use a short, descriptive camelCase name.
- Start every plugin with this header: Filename, Purpose, Version and Date—in that order—then exactly one `[[ ]]` TODO block (placeholder if nothing is planned), then Changelog, a bulleted How it works, Commands and Tweaks. Use `--` line comments everywhere else.

```lua
-- Filename: eljayPlugins/<camelName>.lua
-- Purpose: ...
-- Version: x.y
-- Date: YYYY-Mon-DD
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   x.y  ...
--
-- How it works:
--   * ...
--
-- Commands (type without "/"; "xyz" is a short alias for "<camelName>"):
--   <camelName>            show this help
--   <xyz> on|off     enable / disable the trigger(s)
--   <xyz> debug      toggle debug messages (default off)
--
-- Tweaks (top of file):
--   * LOOKUP_CMD   what it controls
--
```
- The “How it works” summary must match the Purpose and actual behavior. Preserve any “Inspired by” note and mention required plugins or external aliases.
- List all commands, the short alias, and any top-of-file tweakable constants.

### Commands, toggles and help

- Define `local NAME` and `local SHORT` once near the top, under `-- Command names: full command and short alias.` Use them wherever command names are needed.
- Register both bare commands with `rune.alias.exact` handlers taking `(args, ctx)`. Bare commands have no `/`; `rune.command.add` creates slash commands only. Choose a full command name that does not clash with an in-game command.
- Typing either command without arguments must show help.
- Provide `<plugin> on|off` for triggers (default on) and `<plugin> debug on|off` for debug messages (default off). Store both states in `rune.store` so they persist across restarts.
- Help must use `local H = require("helpstyle")` and `H.title`, `H.section`, `H.line`, and `H.foot`; print via `rune.echo` or `emit()`. Include the short-alias row after command rows and before the footer. Keep help lines to 76 characters or fewer (the footer row may be longer) and use the short alias in help rows.
- The single footer row starts with the version, omits the plugin name, and includes enabled/debug state, binding or trigger count when applicable, and stored load time. Capture `LOAD_STARTED = os.clock()` at file start; calculate rounded milliseconds once after initialization with `math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)`. Store and display that value; do not recalculate it when help is shown or use `rune.time()`.
- Exception: a loader with no commands or triggers, such as `initEljay.lua`, needs no help or toggles; it may use a file-level `DEBUG` switch, documented in its header.

### Load output

- Print one cyan-prefixed load line, such as `[pluginName] vX.Y loaded (<command> or <alias> for help)`. Use `rune.style` for the cyan prefix.
- Build the line using `NAME` and `SHORT`. Print extra rows only when attention is needed; never print a separate row for each alias, trigger or file.
- Exception: `characterLog` prints its single row with the full log path, including the character name in the filename.

### Character name and settings

- Use `local charname = require("charname")` wherever a character name is needed. Do not implement name detection or add per-plugin GMCP subscriptions for it.
- `charname.get()` may return `nil` until login. Don’t cache the name at load or build per-character keys/paths until it is known. Use `charname.key(prefix)` for per-character store keys and `charname.on_change(cb)` for changes. Keep callbacks short and wrap their work in `pcall`. Plugins must not call `charname.set()`.
- Save settings with `rune.store`, wrapping calls in `pcall`. Don’t add separate `.txt` configuration files without a clear need.
- Before each write, read the latest store table inside the write operation, mutate it, and save it. Never base a write on a long-lived cached table. After saving, refresh any in-memory cache; use that cache for reads only.

### Style

- Keep aliases and triggers on one row where possible; prefer readable, maintainable Lua.

### Cross-platform support

- Detect Windows with `package.config:sub(1, 1) == "\\"`; use forward slashes in constructed paths. For `cmd.exe` built-ins, convert paths with `(path:gsub("/", "\\"))`.
- Avoid Unix-only tools and paths without Windows alternatives. Use appropriate `cmd.exe` equivalents, `curl.exe`, and `2>NUL` where needed.
- Check temp directories in this order: `TMPDIR`, `TEMP`, `TMP`, then `/tmp`.
- Refuse unsafe-to-quote shell paths with a message—for example, paths containing `"` or `%` on Windows. Don’t pass them to the shell.
- If a plugin cannot support a platform, document that limitation in its header and in the README’s Windows notes.

### Performance and security

- Never build shell commands from unsanitized text; reduce input to expected characters first.
- For network calls, use short connect and total timeouts, cache results, skip repeat lookups, and back off after failures.
- Avoid endless loops; `pcall` cannot stop them. Defer slow work such as network calls, shell commands and large file reads so startup stays within Rune’s 5-second watchdog.
- Prefer anchored triggers; escape literal text, avoid large unanchored patterns on every incoming line, and build lookups once at load.
- Prefer `io.popen` over temp files where possible; avoid predictable temp names.
- Never log or echo secrets. Keep log folders private where possible and exclude `logs/` from git.
- Keep debug output off by default and guarded by the debug state, especially on hot paths.

### Registering and delivering plugins

- Add plugins to the `PLUGINS` list in `initEljay.lua`, alphabetically unless a load dependency requires a different order. Document each plugin in the README table with a shortened version of its Purpose, without commands.
- To disable a plugin, comment out or remove its name from `PLUGINS`.
- Deliver the full `.lua` file with performance and security recommendations, a code-cleanup offer, and a file-size-savings report.
- Use minor version bumps for normal changes (`3.7` → `3.8`). Bump the major version only with an explicit, justified reason. Keep the header version, `VERSION` constant and footer version consistent.

### Pre-flight checklist

- [ ] File is directly in `eljayPlugins/` with the correct name.
- [ ] Header has the required sections, commands and tweaks; exactly one TODO block; no other block comments.
- [ ] Purpose, “How it works” and behavior agree; preserve “Inspired by” notes.
- [ ] Changelog is current.
- [ ] Full and short bare commands use `rune.alias.exact`; bare commands show help.
- [ ] `NAME` and `SHORT` are defined once and used consistently; help includes the short-alias row before the footer.
- [ ] On/off and debug on/off controls work, use persistent store state, and have the required defaults.
- [ ] Help uses `helpstyle`; lines are at most 76 characters (footer excepted); footer includes stored load time and applicable binding/trigger count.
- [ ] Load output is one cyan-prefixed row, except for `characterLog`.
- [ ] Store writes use fresh data and refresh the read-only cache.
- [ ] Character-name handling uses `charname.lua` and safely handles `nil` before login.
- [ ] Platform support works or limitations are documented.
- [ ] Versioning follows policy and all version values match.
- [ ] Plugin is registered in `initEljay.lua` and documented in the README.
- [ ] Heavy startup work is deferred; debug logging is guarded.
- [ ] Delivery includes performance/security recommendations, a cleanup offer and a file-size-savings report.