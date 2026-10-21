# Contributing to rune-mm

Lua plugins for the Rune client working with horstgs Materia Magica configuration.

## Project context
- Env: Rune client (https://runemud.com, https://github.com/mmcdole/rune) + horstgs' MM setup (https://github.com/horstgs/rune-materiamagica-public)
- Dev: Ghostty on Debian 13; cross-platform on Windows/macOS. Game: https://www.materiamagica.com

## Reference plugins

| Topic | Reference |
| --- | --- |
| Display method (`paint`/`say`, `H.*`, aliases) | `annwnQuestSearch.lua` |
| Loader line (command + short alias) | `eqdbResultsPicker.lua` |
| Cyan `[pluginName] ` prefix & help footer | `jmcSolver.lua`, `druidSpellTLAs.lua` |
| Help layout / Load time | `autopouch.lua` / `fauxSextant.lua` |
| Character name API | `charname.lua` |

## Required conventions

### File placement, naming & header
- Path: Directly in `eljayPlugins/` as `eljayPlugins/<camelName>.lua` (short, descriptive camelCase). The repo root *is* that directory once cloned into `~/.config/rune/eljayPlugins`; never nest files.
- Every plugin must start exactly with this header format:
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
--   * <bulleted summary; must match the Purpose line>
--   * <keep any "Inspired by" line; list dependencies/aliases from other plugins>
--
-- Commands (type without "/"; "xyz" is a short alias for "<camelName>"):
--   <camelName>            show this help
--   <camelName> on|off     enable / disable the trigger(s)
--   <camelName> debug      toggle debug messages (default off)
--
-- Tweaks (top of file):
--   * LOOKUP_CMD   what it controls
--
```
- Use `--` line comments everywhere except exactly *one* `[[ ]]` Todo block in the header (placeholder if nothing is planned).

### Commands, toggles & load output
- Bare commands are `rune.alias.exact` handlers taking `(args, ctx)`, registered for both `NAME` and `SHORT` (no `/` prefix; `rune.command.add` only makes `/slash` commands). They must display help when typed bare. The name must not clash with game commands.
- Define `local NAME = "..."` and `local SHORT = "..."` once under a `-- Command names: full command and short alias.` comment and use them everywhere.
- Provide an `on|off` toggle for the trigger(s) (default on) and a `debug` toggle (default off). Save state in `rune.store`.
- Exception: a loader with no commands or triggers (`initEljay.lua`) has no toggles or help; it may use a file-level `DEBUG` switch, and its header says so.
- Help must use `local H = require("helpstyle")` (`H.title`, `H.section`, `H.line`, `H.foot`), printed via `rune.echo` or `emit()`. Include the `SHORT` alias line before the footer.
- The footer is a single `H.foot` row, without the plugin name, that starts with the version and ends with load time: `v1.4  enabled=true debug=false bindings=20  load=12ms`.
- Track load time via `local LOAD_STARTED = os.clock()` at file top, round with `math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)`, store it, and display. Do not recalculate during help display, and do not use `rune.time()`.
- Load output: Print a single row on load with a cyan prefix: `[pluginName] vX.Y loaded (<command> for help)`. Extra rows only for things needing attention; never one row per alias, trigger or file. (Exception: `characterLog` prints its full log path).

### Character name & settings
- Use `local charname = require("charname")`. Do not run ad hoc detection or explicit GMCP subscriptions for names.
- `charname.get()` returns the name or `nil` before login. `charname.key(prefix)` generates per-character keys. `charname.on_change(cb)` catches login/changes (`charname.set` is internal; never call it). Wrap callbacks in `pcall`. Never cache or build paths while name is `nil`.
- Settings: Use `rune.store`. No `.txt` config files unless there is a very explicit reason. Read the latest table inside the write operation, mutate it, save it, then refresh the local read-only cache.

### Style & basicAliases.lua
- Keep aliases/triggers on a single row where possible. Prefer readable, maintainable Lua.
- `basicAliases.lua` forbidden additions: `ct`, `at`, `ft`, `reply`, `talk_alias` or signature helpers.

## Cross-platform
- Detect Windows: `package.config:sub(1,1) == "\\"`. Use forward slashes in built paths. Use backslashes only for `cmd.exe` built-ins: `(path:gsub("/", "\\"))` (parenthesized to drop the count).
- Avoid Unix-only tools (`mkdir -p`, `find`). Use `cmd.exe` or `curl.exe` equivalents and `2>NUL`.
- Temp directories: check `TMPDIR` -> `TEMP` -> `TMP` -> `/tmp`. Refuse paths that cannot be safely quoted.
- If a plugin cannot support a platform, say so in its header and in the README's Windows notes.

## Performance and security
- **Shell input:** Sanitize text (e.g., restrict to letters/underscores) before executing shell commands.
- **Network calls:** Use short timeouts, cache results, skip repeat lookups, and use back-offs.
- **Loops & watchdogs:** Avoid infinite loops (`pcall` cannot catch them). Defer heavy logic (IO, network, files) to first use or timers to pass Rune's 5-second boot watchdog.
- **Triggers:** Prefer anchored patterns and escape literal text. Avoid unanchored regexes on every incoming line. Build lookups at load.
- **Files & Secrets:** Use `io.popen` over temp files where possible; avoid predictable names. Never log/echo secrets. Keep log folders private and out of git (`logs/` in `.gitignore`).
- **State & Logging:** Keep logging guarded by a `debug_on` flag (off by default) to keep hot-paths fast. Wrap `rune.store` updates in `pcall` using fresh lookups to prevent state overwrites. Safely handle async `charname.get()` returning `nil`.

## Managing & delivering plugins
- Register: Add to `PLUGINS` in `initEljay.lua` alphabetically (lower only if it depends on another plugin loading first) and add a row to README matching `Purpose` (shortened, no commands). Disable a plugin by commenting out its name there.
- Delivery: Always deliver the full `.lua` file alongside performance/security notes.
- Versioning: Minor bumps only (`3.7` -> `3.8`) unless major changes are explicitly justified. Header, `VERSION`, and footer must match.

## Pre-flight checklist
- [ ] File is directly in `eljayPlugins/` and named correctly.
- [ ] Header follows format exactly, with commands/tweaks listed.
- [ ] Exactly one `[[ ]]` Todo block in header; no other block comments used.
- [ ] Purpose matches "How it works" and actual plugin behavior; "Inspired by" kept.
- [ ] Changelog is present and current.
- [ ] Commands registered as bare `rune.alias.exact` handlers without a `/`.
- [ ] `NAME` and `SHORT` defined under required comment and used everywhere; `SHORT` row included before help footer.
- [ ] On/off and debug toggles exist; debug defaults to off; states saved to `rune.store`.
- [ ] Help screen renders via `helpstyle` with version at start of footer and `load=` at the end.
- [ ] Prints a single cyan-prefixed loader row on load (unless `characterLog`).
- [ ] Settings use `rune.store`; writes read fresh state first and update cache after.
- [ ] Name tracks via `charname.lua`; handles `nil` before login safely without ad hoc GMCP triggers.
- [ ] Works on Windows as well as Linux, or the limitation is documented.
- [ ] No forbidden aliases or helpers added to `basicAliases.lua`.
- [ ] Version bump rules followed; values match `VERSION` and help UI.
- [ ] Added alphabetically to `PLUGINS` in `initEljay.lua` and documented in README.
- [ ] Global hot-path logging is guarded securely behind `debug_on` checks.
- [ ] Startup sequences defer heavy IO operations to avoid watchdog timeouts.
- [ ] Performance/security notes are included.