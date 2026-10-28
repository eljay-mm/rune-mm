# Contributing to rune-mm

This repository (https://github.com/eljay-mm/rune-mm) is a collection of Lua plugins for the Rune client, designed to work with the horstgs Materia Magica configuration.

## Project context

- Target environment: Rune client (https://runemud.com and https://github.com/mmcdole/rune) with horstgs' MM configuration (https://github.com/horstgs/rune-materiamagica-public)
- Development terminal: Ghostty on Debian 13; plugins should also work on Windows and macOS
- Game: Materia Magica at https://www.materiamagica.com

## Reference plugins

| Topic | Reference |
| --- | --- |
| Display method (`paint`/`say`, `H.*` rows, bare-command aliases) | `annwnQuestSearch.lua` |
| Loader line, command name plus short alias | `eqdbResultsPicker.lua` |
| Cyan `[pluginName] ` prefix via `rune.style`; help footer with the version first | `jmcSolver.lua` (prefix also `druidSpellTLAs.lua`) |
| Help layout | `gotoAliases.lua` |
| Load time in the help footer | `fauxSextant.lua` |

## Required conventions

### File placement and naming

- Put each plugin file directly in `eljayPlugins/`. The repository root *is* that directory once cloned into `~/.config/rune/eljayPlugins`, so files sit at the top level of the repo, never nested
- Use the filename format: `eljayPlugins/<camelName>.lua`
- Keep the plugin name in the same style as the rest of the repo: short, camel-cased, and descriptive
- Keep every plugin file, companions included, under 16,000 bytes. If a plugin would exceed that, move rarely used code into a companion file in `eljayPlugins/` (for example `spdxyPlaces.lua`) that the main plugin `require`s on first use. A companion follows the same header and help rules as a plugin. It must also be listed in `PLUGINS`

### Header format

Every plugin must begin with the same header pattern:

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
--   * ...
--
-- Commands (type without "/"):
--   xyz                    show this help
--   xyz on|off             enable / disable the trigger(s)
--   xyz debug              toggle debug messages (default off)
--   xyz                    short alias for <camelName>
--
-- Tweaks (top of file):
--   * LOOKUP_CMD   what it controls
--
```

Rules:
- The first four comment lines are Filename, Purpose, Version and Date, in that order
- Include a bulleted "How it works" summary in the header, in the repo's existing style, that matches the `Purpose` line
- Keep any existing "Inspired by" line in the "How it works" section
- If the plugin needs another plugin or an alias defined elsewhere, say so in "How it works". Do the same for any required export command (for example `export TERM=xterm-256color`)
- List every command in the header exactly as the help screen shows it: sections and one row per command, including the short alias row. Never compress the list. List constants at the top that are meant to be tweaked under "Tweaks"
- On each update, roll up comments: collapse older changelog entries into one line and keep "How it works" compact
- Use plain `--` line comments everywhere. Never use `[[ ]]` block-comment markers, except the Todo block: exactly one per header, after the first four lines and before `Changelog`, holding the planning notes for the next pass, or the placeholder `- insert planning notes here between revisions.` when nothing is planned

### Commands and toggles

- Commands are defined without a `/` prefix. `rune.command.add` only creates `/slash` commands, so bare commands are always aliases
- The full command is the plugin name, with a short alias. Both are listed in the help and the header
- The command name must not clash with an in-game command (`eqdbResultsPicker`, not `eqdb`)
- Always define the full command and the short alias once, as locals at the top of the file, under a `-- Command names: full command and short alias.` comment (for example `local NAME = "characterLog"` and `local SHORT = "charlog"`). Use `NAME` and `SHORT` everywhere the command is needed: alias registration, help output, debug messages and the loader line. Do not repeat the literal names
- Register the bare command as a `rune.alias.exact` handler taking `(args, ctx)`. Check the alias works when typed bare before delivering
- Every plugin provides a debug toggle (`<pluginName> debug on|off`) that defaults to off. Every plugin with triggers or commands also provides an on/off toggle for its trigger(s) (`<pluginName> on|off`)
- On/off and debug states are kept in `rune.store`, so they survive a restart. When nothing is stored, the defaults are on for the trigger(s) and off for debug
- Typing the command bare must print a command summary / help screen
- Help output follows the repo's `helpstyle` pattern:
  - `local H = require("helpstyle")`
  - use `H.title`, `H.section`, `H.line`, `H.foot`
  - the rows are printed with `rune.echo` (or passed to `emit()`, as `annwnQuestSearch.lua` does)
- Help includes a row for the short alias, placed after the command rows and before the footer: `rune.echo(H.line(SHORT, "short alias for " .. NAME))`
- Use the short alias in the help rows and keep descriptions concise, so no help line, except the footer, is longer than 76 characters
- The version appears at the start of the single `H.foot` status row, without the plugin name in that row
- The same footer row reports enabled and debug states, the number of registered bindings or triggers when applicable, and load time
- Measure load time with `os.clock()`: capture `local LOAD_STARTED = os.clock()` at the top of the file, then calculate rounded milliseconds once after initialization with `math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)`
- Store the result (for example `LOAD_MS`) and show that stored value in the help footer. Never recalculate it when help is displayed (that would report time since load), and do not use `rune.time()`, which not all Rune setups support
- Exception: a loader with no commands or triggers, such as `initEljay.lua`, has no on/off toggle or help output. It may use a file-level `DEBUG` switch instead, and its header says so

Example pattern:

```lua
-- Command names: full command and short alias.
local NAME  = "myPlugin"
local SHORT = "myp"

local H = require("helpstyle")

local function help()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(SHORT,              "show this help"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable the trigger(s)"))
  rune.echo(H.line(SHORT .. " debug",  "toggle debug messages"))
  rune.echo(H.line(SHORT,             "short alias for " .. NAME))
  rune.echo(H.foot(string.format("v%s  enabled=%s debug=%s  load=%dms",
    VERSION, tostring(enabled), tostring(debug_on), LOAD_MS)))
end
```

### Load output

- On load, a plugin prints a single row with a cyan `[pluginName] ` prefix (`paint`/`say` helpers using `rune.style`, as `jmcSolver` does), in the `eqdbResultsPicker` loader form `[pluginName] vX.Y loaded (<command> for help)`, built from `NAME` and `SHORT`
- Exception: `characterLog` prints its own single row instead, showing the full log path including the character name in the filename
- Extra rows are printed only when something needs attention, such as an error
- Never print one row per alias, trigger or file

### Character name

- Wherever a plugin needs the character name, use horstgs' `charname.lua` rather than detecting it in the plugin
- Do not add per-plugin name detection (your own `Char.Base` handler, prompt parsing or `rune.gmcp.subscribe("Char")`): `charname.lua` already subscribes to `Char` and requests `char.base` and `char.status` on login

API:

| Call | Returns / does |
| --- | --- |
| `local charname = require("charname")` | loads the module (once, shared by all plugins) |
| `charname.get()` | the current name, or `nil` until GMCP has delivered it |
| `charname.key(prefix)` | `prefix .. "." .. name`, with the name lower-cased and every character other than letters, digits, `_` and `-` replaced by `_`. Use it for per-character `rune.store` keys |
| `charname.on_change(cb)` | calls `cb(old, new)` whenever the name changes, including the first time it is known |
| `charname.set(n)` | used by `charname.lua` itself; plugins do not call it |

Rules of use:

- The name is `nil` until GMCP delivers it after login, so never assume it is set at load and never read it once at load and keep it. Call `charname.get()` when needed, or react in an `on_change` callback
- Do not build a per-character key or path while the name is `nil`: `charname.key()` would return `prefix .. "."` with an empty name. Wait for `on_change` instead
- Keep `on_change` callbacks short and wrap their work in `pcall`, since all callbacks run in turn and one error would stop the ones after it

Example pattern:

```lua
local charname = require("charname")

local function load_for(name)
  local key = charname.key(NAME)   -- e.g. "myPlugin.somename"
  -- read per-character settings from rune.store under `key`
end

if charname.get() then load_for(charname.get()) end

charname.on_change(function(old, new)
  if new ~= "" then pcall(load_for, new) end
end)
```

### Settings

- Save plugin settings with `rune.store`, wrapping the calls in `pcall`
- Do not create separate `.txt` config files unless there is a very explicit reason
- Before writing a change, read the latest value from `rune.store` inside the write operation, modify that freshly loaded table, then save it back. Never use a long-lived cached table as the basis for a write
- After saving, refresh any in-memory copy the plugin keeps. The cached copy is for reads only (for example in triggers)

Example pattern:

```lua
local function update_settings(mutate)
  local ok, fresh = pcall(rune.store.get, KEY)
  if not ok or type(fresh) ~= "table" then fresh = {} end
  mutate(fresh)                    -- change the freshly loaded table
  pcall(rune.store.set, KEY, fresh)
  cache = fresh                    -- refresh the in-memory copy
end
```

### Style

- Keep aliases and triggers on a single row each where possible
- Prefer readable, maintainable Lua
- Rune's Lua is 5.1: no bit operators, `//` or `goto`

## Cross-platform

Plugins must work on Linux, macOS and Windows wherever possible:

- Detect Windows with `package.config:sub(1, 1) == "\\"` and branch only where needed
- Do not depend on Unix-only tools or paths (`mkdir -p`, `find`, `sh`, `/tmp`, `2>/dev/null`) without a Windows alternative; use `cmd.exe` equivalents, `curl.exe`, and `2>NUL`
- Temp files and folders: use `TMPDIR`, then `TEMP`, then `TMP`, then `/tmp`
- Use forward slashes in `require` paths and in paths you build, since Windows accepts them, but use backslashes for `cmd.exe` built-ins: `(path:gsub("/", "\\"))`, with the parentheses to drop the count
- A path that cannot be quoted safely for the shell (for example one containing `"` or `%` on Windows) is refused with a message, not passed on
- If a plugin truly cannot support a platform, say so in its header and in the README's Windows notes

## Performance and security

Every plugin delivery includes performance and security recommendations:

- **Shell input:** never build a shell command from unsanitised text. Reduce game or user text to the characters you expect (for example letters and underscores) first
- **Network calls:** use short connect and total timeouts, cache results, skip repeat lookups, and back off after a failure so a dead network cannot stall Rune's Lua thread
- **Endless loops:** avoid anything that can loop without end. `pcall` cannot catch it, and Rune's 5-second init watchdog stops the script
- **Triggers:** prefer anchored patterns, and avoid large unanchored regexes on every incoming line. Escape literal text, and build lookups once at load rather than per line
- **Temp files:** avoid predictable names; prefer `io.popen` over a temp file where possible
- **Logs and secrets:** never write passwords or other secrets to a log or echo them. Keep log folders private where the platform allows it, and keep logs out of git (add `logs/` to `.gitignore`)
- **Load time:** do only the work needed to register triggers and aliases at load, build lookups once, and defer anything slow (network calls, shell commands, large file reads) until first use or a timer. Each `rune.alias.exact` registration costs about 0.8 ms, so a plugin with many aliases uses one regex dispatcher; load `helpstyle` and settings on first use. The help footer shows the load time, so regressions are visible
- **Debug output:** off by default, and never printed on the hot path of every line unless debug is on

## Registering a plugin

A plugin file does nothing until it is loaded:

- Add its name, and the name of any companion file, to the `PLUGINS` list in `initEljay.lua`, keeping the list alphabetical. Move it lower only if it depends on another plugin having loaded first
- Add or update its row in the README plugin table. The "What it does" text is the `Purpose` line, shortened and without commands
- To disable a plugin, comment out or delete its name in the `PLUGINS` list

## Delivery requirements

When providing or updating a plugin:

- Always deliver the full `.lua` file
- Include performance and security recommendations along with the plugin
- Include a code cleanup offer and a file-size-savings report with every delivery

## Versioning

- Normal changes are minor version bumps (`3.7` → `3.8`, not `4.0`)
- Only bump the major version if there is an explicit and justified reason
- The version in the header, the `VERSION` constant in the code, and the help footer must all match

## Pre-flight checklist before finalizing a plugin

Before considering a plugin complete, confirm:

- [ ] File is in `eljayPlugins/`, named correctly and under 16,000 bytes; the plugin and its companions are listed in `PLUGINS`.
- [ ] Header has the required format, commands, tweaks where applicable, and any required export command.
- [ ] Exactly one `[[ ]]` TODO block appears between `Date` and `Changelog`; use the placeholder if there are no planning notes.
- [ ] Purpose and `How it works` match the behavior; preserve any `Inspired by` line.
- [ ] Changelog is current and rolled up; the header's commands list matches the help screen.
- [ ] Commands are bare `rune.alias.exact` handlers, with a full name and non-conflicting short alias.
- [ ] `NAME` and `SHORT` are defined under the required comment and used consistently. Help includes the short-alias row before the footer.
- [ ] On/off and debug toggles exist; debug defaults to off and is guarded.
- [ ] Bare command shows help, using the short alias in help rows; help lines (except the footer) are at most 76 characters.
- [ ] Footer starts with the version and includes the stored load time.
- [ ] Load output is one colored loader row, except for `characterLog`.
- [ ] Settings use `rune.store`; writes read fresh data and refresh the cache.
- [ ] Character names use `charname.lua`; the plugin works while the name is still `nil`.
- [ ] Load is fast; slow work is deferred.
- [ ] Windows support works or limitations are documented.
- [ ] Header, `VERSION`, and footer versions match and follow version policy.
- [ ] Plugin is listed in `initEljay.lua`; README row matches its Purpose.
- [ ] Delivery includes performance and security recommendations, a code cleanup offer and a file-size-savings report.