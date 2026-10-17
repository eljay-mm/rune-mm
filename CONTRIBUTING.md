# Contributing to rune-mm

This repository (https://github.com/eljay-mm/rune-mm) is a collection of Lua plugins for the Rune client (https://www.runemud.com and https://github.com/mmcdole/rune), designed to work with the horstgs (https://github.com/horstgs/rune-materiamagica-public) Materia Magica configuration. It is developed with Rune running in Ghostty on Debian 13, and the plugins are written to work on Windows and macOS as well. The project prefers a consistent house style across all plugins.

## Project context

- Target environment: Rune client (https://www.runemud.com and https://github.com/mmcdole/rune) with horstgs' MM configuration (https://github.com/horstgs/rune-materiamagica-public).
- Development terminal: Ghostty on Debian 13; plugins should also work on Windows and macOS (see [Cross-platform](#cross-platform))
- Game: Materia Magica at https://www.materiamagica.com
- Persistent settings: use `rune.store`, not separate config files, unless a plugin explicitly requires otherwise

## Reference plugins

When in doubt, copy the pattern from a plugin that already works:

| Topic | Reference |
| --- | --- |
| Display method (`paint`/`say`, `H.*` rows, bare-command aliases) | `annwnQuestSearch.lua` |
| Loader line, command name plus short alias | `eqdbResultsPicker.lua` |
| Cyan `[pluginName] ` prefix via `rune.style` | `jmcSolver.lua`, `druidSpellTLAs.lua` |
| Help footer with the version at the start of the row | `jmcSolver.lua` |
| Help layout | `autopouch.lua` (horstgs configuration) |

## Required conventions

### File placement and naming

- Put each plugin file directly in `eljayPlugins/`. The repository root *is* the `eljayPlugins` directory once cloned into `~/.config/rune/eljayPlugins`, so in the repository the files sit at the top level and are never nested further
- Use the filename format: `eljayPlugins/<camelName>.lua`
- Keep the plugin name in the same style as the rest of the repo: short, camel-cased, and descriptive

### Header format

Every plugin must begin with the same header pattern:

```lua
-- Filename: eljayPlugins/<camelName>.lua
-- Purpose: ...
-- Version: x.y
-- Date: YYYY-Mon-DD
-- Changelog:
--   x.y  ...
--
-- How it works:
--   * ...
--   * ...
--
-- Commands (type without "/"; "xyz" is a short alias for "<camelName>"):
--   <camelName>            show this help
--   <camelName> on|off     enable / disable the trigger(s)
--   <camelName> debug      toggle debug messages (default off)
--
-- Tweaks (top of file):
--   * NAME   what it controls
--
```

Rules:
- The first four comment lines must be:
  - `-- Filename: eljayPlugins/<camelName>.lua`
  - `-- Purpose: ...`
  - `-- Version: x.y`
  - `-- Date: YYYY-Mon-DD`
- Keep a short changelog immediately after the Version line
- Include a bulleted "How it works" summary in the header using the style already used in the repo
- The "How it works" statement must match the `Purpose` line
- Keep any existing "Inspired by" line in the "How it works" section if it was present before
- If the plugin needs another plugin or an alias defined elsewhere (for example `researchNotesPicker` uses the `rrl` and `rrr` aliases from `basicAliases`), say so in "How it works"
- List the plugin's commands in the header, including the short alias. If the file has constants at the top that are meant to be tweaked, list them under "Tweaks"
- Use plain `--` line comments only. Never use `[[ ]]` block-comment markers in plugin comments

### Commands and toggles

- Commands are defined without a `/` prefix. `rune.command.add` only creates `/slash` commands, so bare commands are always aliases
- The full command is the plugin name, with a short alias (for example `crystalLocator` and `crystal`, `statusTray` and `tray`, `eqdbResultsPicker` and `erp`). Both are handled the same way and both are listed in the help and the header
- The command name must not clash with an in-game command (`eqdbResultsPicker`, not `eqdb`)
- Register the bare command as a `rune.alias.exact` handler taking `(args, ctx)`, as `annwnQuestSearch.lua` does. Check the alias works when typed bare before delivering; a command that shows nothing when typed is the most common failure
- Every plugin that has triggers or commands must provide an on/off toggle for its trigger(s), using a pattern like:
  - `<pluginName> on|off`
- Every plugin must provide a debug toggle that defaults to off, using a pattern like:
  - `<pluginName> debug on|off`
- On/off and debug states are kept in `rune.store`, so they survive a restart. When nothing is stored, the defaults are on for the trigger(s) and off for debug
- Typing the command bare must print a command summary / help screen
- Help output follows the repo's `helpstyle` pattern:
  - `local H = require("helpstyle")`
  - use `H.title`, `H.section`, `H.line`, `H.foot`
  - the rows are printed with `rune.echo` (or passed to `emit()`, as `annwnQuestSearch.lua` does)
- The version appears at the start of the single `H.foot` status row, without the plugin name in that row
- Exception: a loader with no commands or triggers, such as `initEljay.lua`, has no on/off toggle or help output. It may use a file-level `DEBUG` switch instead, and its header says so

Example pattern:

```lua
local H = require("helpstyle")

local function help()
  rune.echo(H.title("Plugin title  (alias: xyz)"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line("plugin",           "show this help"))
  rune.echo(H.line("plugin on|off",    "enable / disable the trigger(s)"))
  rune.echo(H.line("plugin debug",     "toggle debug messages"))
  rune.echo(H.foot("v1.4  enabled=true debug=false"))
end
```

### Load output

- On load, a plugin prints a single row, with a cyan `[pluginName] ` prefix, as `jmcSolver` does (its `paint`/`say` helpers use `rune.style`)
- The row is a loader line in the `eqdbResultsPicker` form: `[pluginName] vX.Y loaded (<command> for help)`
- Exception: `characterLog` prints its own single row instead, showing the full log path including the character name in the filename
- Extra rows are printed only when something needs attention, such as an error
- Never print one row per alias, trigger or file

Example pattern:

```lua
local style = rune.style

local function say(msg)
  rune.echo(style.cyan("[" .. NAME .. "] ") .. msg)
end

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
```

### Settings

- Save plugin settings with `rune.store`
- Do not create separate `.txt` config files unless there is a very explicit reason and the plugin specifically needs it
- If a plugin does not need a config file, prefer `rune.store` by default

### Style

- Keep aliases and triggers on a single row each where possible
- Prefer readable, maintainable Lua
- Keep plugin behavior consistent with the rest of the repo

### basicAliases.lua restrictions

`basicAliases.lua` has stricter rules than other plugins:

- Never include:
  - `ct`
  - `at`
  - `ft`
  - `reply`
  - `talk_alias` helpers or signature helpers
- Do not add per-character overrides or per-character aliases such as:
  - `cbf`
  - `cbf2`
  - `cbf3`
  - other character-specific variants
- It is recommended that these types of personal aliases be configured using in-game aliases

## Cross-platform

Plugins must work on Linux, macOS and Windows wherever possible:

- Detect Windows with `package.config:sub(1, 1) == "\\"` and branch only where needed
- Do not depend on Unix-only tools or paths (`mkdir -p`, `find`, `sh`, `/tmp`, `2>/dev/null`) without a Windows alternative. On Windows use `cmd.exe` equivalents, `curl.exe`, and `2>NUL`
- Temp files and folders: use `TMPDIR`, then `TEMP`, then `TMP`, then `/tmp`
- Use forward slashes in `require` paths and in paths you build, since Windows accepts them
- A path that cannot be quoted safely for the shell (for example one containing `"` or `%` on Windows) is refused with a message, not passed on
- If a plugin truly cannot support a platform, say so in its header and in the README's Windows notes

## Performance and security

Every plugin delivery includes performance and security recommendations. The rules below come up repeatedly:

- **Shell input:** never build a shell command from unsanitised text. Reduce game or user text to the characters you expect (for example letters and underscores) first
- **Network calls:** use short connect and total timeouts, cache results, skip repeat lookups, and back off after a failure so a dead network cannot stall Rune's Lua thread
- **Endless loops:** avoid anything that can loop without end. `pcall` cannot catch it, and Rune's 5-second init watchdog stops the script
- **Triggers:** prefer anchored patterns, and avoid many large unanchored regexes that run against every incoming line. Escape literal text, and build lookups once at load rather than per line
- **Temp files:** avoid predictable names; prefer `io.popen` over a temp file where possible
- **Logs and secrets:** never write passwords or other secrets to a log or echo them. Keep log folders private where the platform allows it, and keep logs out of git (add `logs/` to `.gitignore`)
- **Debug output:** off by default, and never printed on the hot path of every line unless debug is on

## Registering a plugin

A plugin file does nothing until it is loaded:

- Add its name to the `PLUGINS` list in `initEljay.lua`, keeping the list alphabetical. Move it lower only if it depends on another plugin having loaded first
- Add or update its row in the README plugin table. The "What it does" text is the `Purpose` line, shortened and without commands
- To disable a plugin, comment out or delete its name in the `PLUGINS` list

## Delivery requirements

When providing or updating a plugin:

- Always deliver the full `.lua` file
- Include performance and security recommendations along with the plugin
- Keep the code aligned with the repo's current house style and conventions
- Check the repo README and ensure the plugin's "How it works" statement matches its `Purpose`
- Verify every command is defined without a `/` prefix

## Versioning

- Normal changes should be minor version bumps, not major jumps
- Example: `3.7` → `3.8`, not `4.0`
- Only bump the major version if there is an explicit and justified reason
- The version in the header, the `VERSION` constant in the code, and the help footer must all match

## Pre-flight checklist before finalizing a plugin

Before considering a plugin complete, confirm:

- [ ] File is in `eljayPlugins/` and named correctly
- [ ] Header uses the required format, with commands (and tweaks, if any) listed
- [ ] Header and code use `--` line comments only, with no `[[ ]]` markers
- [ ] Purpose and "How it works" match the actual behavior, and any "Inspired by" line is kept
- [ ] Changelog is present and current
- [ ] Commands are defined without a `/` prefix, as bare `rune.alias.exact` handlers
- [ ] Full command is the plugin name, with a short alias, and neither clashes with an in-game command
- [ ] On/off toggle exists
- [ ] Debug toggle exists and defaults to off
- [ ] Toggle states are kept in `rune.store`
- [ ] Help summary works when the command is typed bare, with the version at the start of the footer row
- [ ] Load output is a single loader row (`[pluginName] vX.Y loaded (<command> for help)`) with the coloured prefix, unless it is `characterLog`
- [ ] Settings are stored with `rune.store`
- [ ] Works on Windows as well as Linux, or the limitation is documented
- [ ] No forbidden aliases or helpers were added
- [ ] Version bump follows the repo policy, and header, `VERSION` constant and footer match
- [ ] Plugin is listed in `PLUGINS` in `initEljay.lua`
- [ ] README table row matches the `Purpose`
- [ ] Performance/security notes are included

## Summary

The repo's house style is intentionally strict: consistent headers, consistent help output, consistent toggles, consistent storage, consistent load output, and consistent naming. Keep all plugins aligned to that standard.