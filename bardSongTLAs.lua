-- Filename: eljayPlugins/bardSongTLAs.lua
-- Purpose: Bard songs with three-letter acronyms.
-- Version: 2.2
-- Date: 2026-Oct-13
-- Changelog:
--   2.2  Added command summary, enable/disable toggle, debug toggle, persistent settings and house-style cleanup.
--   2.1  Converted from XML; merged extra TLAs and checked against "help music".
-- How it works:
--   * Exact aliases map each TLA to the matching bard "play" command.
--   * Songs are grouped the same way as the Rune help text: Peace, Martial and Versatile.
--   * The plugin can be toggled on or off without editing files, and debugging can be enabled for troubleshooting.
--   * All trigger commands are sent without any user-supplied text beyond the fixed bard song names.
--
-- Commands:
--   bardSongTLAs                 show this summary
--   bardSongTLAs on|off          enable or disable all song aliases
--   bardSongTLAs debug on|off    toggle debug output

local helpstyle_ok, H = pcall(require, "helpstyle")
if not helpstyle_ok then
  H = nil
end

local VERSION = "2.2"
local SETTINGS_KEY = "bardSongTLAs.settings"

local enabled = true
local debug_enabled = false

local SONGS = {
  -- Peace songs (only when not in combat)
  { key = "bbm", song = "battle march" },
  { key = "bdi", song = "detect invisibility" },
  { key = "bfl", song = "footloose" },
  { key = "bes", song = "enhanced strength" },
  { key = "bep", song = "epiphany" },
  { key = "bih", song = "inspirational hymn" },
  { key = "ble", song = "levitation" },
  { key = "bli", song = "light" },
  { key = "bml", song = "mass levitation" },
  { key = "bsh", song = "shield" },
  { key = "bts", song = "traveling song" },

  -- Martial songs (only in combat)
  { key = "bbl", song = "blindness" },
  { key = "bcac", song = "cacophony" },
  { key = "bfi", song = "fireball" },
  { key = "bea", song = "earworm" },
  { key = "bhw", song = "hands of wind" },
  { key = "bha", song = "harmonize" },
  { key = "bsl", song = "hinder" },
  { key = "bpd", song = "pensive dirge" },
  { key = "bpf", song = "plodding fugue" },
  { key = "bsn", song = "soothing nocturne" },
  { key = "btro", song = "tremolo" },
  { key = "bom", song = "ode to the moon" },
  { key = "btrr", song = "tempus rigor" },

  -- Versatile songs (any time)
  { key = "bca", song = "calm" },
  { key = "bcl", song = "cure light" },
  { key = "bip", song = "invigorating performance" },
  { key = "bnf", song = "night's fortune" },
  { key = "bre", song = "refresh" },
  { key = "bri", song = "rime of the glacierbreaker" },
  { key = "bth", song = "thunderclap" },
  { key = "btr", song = "tremor" },
}

local function dbg(message)
  if debug_enabled then
    rune.echo("[bardSongTLAs] " .. tostring(message))
  end
end

local function load_settings()
  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then
      enabled = saved.enabled
    end
    if type(saved.debug) == "boolean" then
      debug_enabled = saved.debug
    end
  end
end

local function save_settings()
  pcall(rune.store.set, SETTINGS_KEY, {
    enabled = enabled,
    debug = debug_enabled,
  })
end

local function build_alias_action(song)
  return function()
    if not enabled then
      dbg("ignored alias for '" .. song .. "' because plugin is disabled")
      return
    end

    dbg("sending play '" .. song .. "'")
    return "play '" .. song .. "'"
  end
end

local function help_summary()
  local status = "v" .. VERSION .. "  enabled=" .. tostring(enabled) .. " debug=" .. tostring(debug_enabled)

  if H and type(H.title) == "function" and type(H.section) == "function"
    and type(H.line) == "function" and type(H.foot) == "function" then
    rune.echo(H.title("Bard song TLAs"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("bardSongTLAs", "show this summary"))
    rune.echo(H.line("bardSongTLAs on|off", "enable or disable all song aliases"))
    rune.echo(H.line("bardSongTLAs debug on|off", "toggle debug output"))
    rune.echo(H.section("Aliases"))
    rune.echo(H.line("bbm", "battle march"))
    rune.echo(H.line("bdi", "detect invisibility"))
    rune.echo(H.line("bfi", "fireball"))
    rune.echo(H.line("bcl", "cure light"))
    rune.echo(H.line("bth", "thunderclap"))
    rune.echo(H.foot(status))
    return
  end

  rune.echo("Bard song TLAs")
  rune.echo("  bardSongTLAs                 show this summary")
  rune.echo("  bardSongTLAs on|off          enable or disable all song aliases")
  rune.echo("  bardSongTLAs debug on|off   toggle debug output")
  rune.echo("  Examples: bbm, bdi, bfi, bcl, bth")
  rune.echo(status)
end

local function bard_command(args, ctx)
  local text = tostring(args or ""):lower()
  local command = text:match("^(%S*)")
  local value = text:match("^%S+%s*(.*)$") or ""

  if command == "" or command == "help" then
    help_summary()
    return
  end

  if command == "debug" then
    if value == "on" then
      debug_enabled = true
    elseif value == "off" then
      debug_enabled = false
    elseif value ~= "" then
      help_summary()
      return
    end

    save_settings()
    rune.echo("[bardSongTLAs] debug is " .. tostring(debug_enabled))
    return
  end

  if command == "on" then
    enabled = true
    save_settings()
    rune.echo("[bardSongTLAs] enabled")
    return
  end

  if command == "off" then
    enabled = false
    save_settings()
    rune.echo("[bardSongTLAs] disabled")
    return
  end

  help_summary()
end

-- Register the command summary alias.
rune.alias.exact("bardSongTLAs", bard_command)

-- Register exact song aliases; each one checks the plugin toggle before sending.
for _, spec in ipairs(SONGS) do
  rune.alias.exact(spec.key, build_alias_action(spec.song))
end

load_settings()
save_settings()

-- Performance note:
--   These aliases are fixed, exact and low-overhead; there is no network I/O or dynamic string evaluation beyond a static song name.
-- Security note:
--   The plugin only emits known bard "play" commands from the curated song list and never takes arbitrary input from the user.