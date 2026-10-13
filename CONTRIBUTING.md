# Contributing to rune-mm

This repository is a collection of Lua plugins for the Rune client, designed to work with the horstgs Materia Magica configuration and the Rune client running in Ghostty on Debian 13. The project prefers a consistent house style across all plugins.

## Project context

- Target environment: Rune client with horstgs' MM configuration
- Terminal: Ghostty on Debian 13
- Game: Materia Magica at materiamagica.com
- Persistent settings: use `rune.store`, not separate config files, unless a plugin explicitly requires otherwise
- `RUNE_CHARACTER` does not exist; do not rely on it

## Required conventions

### File placement and naming

- Put each plugin file directly in `eljayPlugins/`
- Use the filename format: `eljayPlugins/<CamelName>.lua`
- Do not use a `y_` prefix on the filename or the header `Filename` line
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
-- How it works
--   * ...
--   * ...
--
```

Rules:
- The first four comment lines must be:
  - `-- Filename: eljayPlugins/<camelName>.lua`
  - `-- Purpose: ...`
  - `-- Version: x.y`
  - `-- Date: YYYY-Mon-DD`
- Keep a short changelog immediately after the Version line
- Include a bulleted “How it works” summary in the header using the style already used in the repo
- Keep any existing “Inspired by” line in the “How it works” section if it was present before
- If an earlier version had it and it was dropped, restore it

### Commands and toggles

- Commands are defined without a `/` prefix
- Every plugin should provide an on/off toggle for its trigger(s), using a pattern like:
  - `<pluginName> on|off`
- Every plugin should provide a debug toggle that defaults to off, using a pattern like:
  - `<pluginName> debug on|off`
- Typing the command bare should print a command summary / help screen
- Help output follows the repo’s `helpstyle` pattern:
  - `require("helpstyle")`
  - use `H.title`, `H.section`, `H.line`, `H.foot`
  - print with `rune.echo`
- The version should appear at the start of the single `H.foot` status row, without the plugin name in that row

Example pattern:

```lua
local function help()
  require("helpstyle")
  local H = helpstyle or {}
  rune.echo(H.title("Plugin title"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line("plugin on|off"))
  rune.echo(H.line("plugin debug on|off"))
  rune.echo(H.foot("v1.4  enabled=true debug=false"))
end
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

## Delivery requirements

When providing or updating a plugin:

- Always deliver the full `.lua` file
- Include performance and security recommendations along with the plugin
- Keep the code aligned with the repo’s current house style and conventions
- Check the repo README and ensure the plugin’s “How it works” statement matches its `Purpose`
- Verify every command is defined without a `/` prefix

## Versioning

- Normal changes should be minor version bumps, not major jumps
- Example: `3.7` → `3.8`, not `4.0`
- Only bump the major version if there is an explicit and justified reason

## Pre-flight checklist before finalizing a plugin

Before considering a plugin complete, confirm:

- [ ] File is in `eljayPlugins/` and named correctly
- [ ] Header uses the required format
- [ ] Purpose and “How it works” match the actual behavior
- [ ] Changelog is present and current
- [ ] Commands are cleaner and use no `/` prefix
- [ ] On/off toggle exists
- [ ] Debug toggle exists and defaults to off
- [ ] Help summary works when the command is typed bare
- [ ] Settings are stored with `rune.store`
- [ ] No forbidden aliases or helpers were added
- [ ] Version bump follows the repo policy
- [ ] Performance/security notes are included

## Summary

The repo’s house style is intentionally strict: consistent headers, consistent help output, consistent toggles, consistent storage, and consistent naming. Keep all plugins aligned to that standard.