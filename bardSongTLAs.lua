-- Filename: eljayPlugins/bardSongTLAs.lua
-- Purpose: Provide three-letter aliases for bard songs.
-- Version: 2.6
-- Date: 2026-Oct-19
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.6  Added a list subcommand to show all configured TLAs and their songs.
--   2.5  Standardized header, help, persistent toggles, command aliases, and load-time reporting.
--   2.4  Cyan prefix and loader line; all song TLAs share a single alias; commands use one regex.
--   2.3  Renamed command to bardSongTLAs with short alias bard; help lists all TLAs.
--   2.2  Added command summary, enable/disable toggle, debug toggle, and persistent settings.
--
-- How it works:
--   * Each row in the songs table maps a TLA to a bard song, e.g. "bfi" -> play 'fireball'.
--   * Songs are grouped as in 'help music': Peace, Martial, and Versatile.
--   * One alias matches all TLAs; adding a song requires adding one row to the table.
--   * The list subcommand shows all configured TLAs grouped by song type.
--   * Only fixed, curated song names are sent; no user-supplied text is forwarded.
--   * When disabled, song aliases do nothing; settings persist in rune.store.
--
-- Commands (type without "/"; short alias: bard):
--   bardSongTLAs                 show this help
--   bard                          show this help
--   bardSongTLAs list            show all configured TLAs
--   bard list                    show all configured TLAs
--   bardSongTLAs on|off          enable / disable the song aliases
--   bard on|off                  enable / disable the song aliases
--   bardSongTLAs debug on|off    enable / disable debug messages
--   bard debug on|off            enable / disable debug messages
--
-- Tweaks (top of file):
--   * songs  TLA-to-song mappings
--

local LOAD_STARTED = os.clock()

local NAME = "bardSongTLAs"
local SHORT = "bard"
local VERSION = "2.6"
local SETTINGS_KEY = "bardSongTLAs.settings"

local enabled = true
local debug_enabled = false
local load_ms = 0

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
  H = nil
end

local function prefix()
  local text = "[" .. NAME .. "] "
  if rune.style and type(rune.style.cyan) == "function" then
    local ok, colored = pcall(rune.style.cyan, text)
    if ok and type(colored) == "string" then
      return colored
    end
  end
  return text
end

local function say(text)
  rune.echo(prefix() .. text)
end

local function dbg(fmt, ...)
  if not debug_enabled then
    return
  end

  local ok, message = pcall(string.format, fmt, ...)
  say("debug: " .. (ok and message or tostring(fmt)))
end

local function load_settings()
  if not (rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, stored = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(stored) == "table" then
    if type(stored.enabled) == "boolean" then
      enabled = stored.enabled
    end
    if type(stored.debug) == "boolean" then
      debug_enabled = stored.debug
    end
  end
end

local function save_settings()
  if not (rune.store and type(rune.store.set) == "function") then
    return
  end

  pcall(rune.store.set, SETTINGS_KEY, {
    enabled = enabled,
    debug = debug_enabled,
  })
end

local function bool_text(value)
  return value and "true" or "false"
end

local songs = {
  -- Peace songs (not in combat)
  { "bbm", "battle march" },
  { "bdi", "detect invisibility" },
  { "bfl", "footloose" },
  { "bes", "enhanced strength" },
  { "bep", "epiphany" },
  { "bih", "inspirational hymn" },
  { "ble", "levitation" },
  { "bli", "light" },
  { "bml", "mass levitation" },
  { "bsh", "shield" },
  { "bts", "traveling song" },

  -- Martial songs (in combat)
  { "bbl", "blindness" },
  { "bcac", "cacophony" },
  { "bfi", "fireball" },
  { "bea", "earworm" },
  { "bhw", "hands of wind" },
  { "bha", "harmonize" },
  { "bsl", "hinder" },
  { "bpd", "pensive dirge" },
  { "bpf", "plodding fugue" },
  { "bsn", "soothing nocturne" },
  { "btro", "tremolo" },
  { "bom", "ode to the moon" },
  { "btrr", "tempus rigor" },

  -- Versatile songs (any time)
  { "bca", "calm" },
  { "bcl", "cure light" },
  { "bip", "invigorating performance" },
  { "bnf", "nights fortune" },
  { "bre", "refresh" },
  { "bri", "rime of the glacierbreaker" },
  { "bth", "thunderclap" },
  { "btr", "tremor" },
}

local lookup = {}
local names = {}

for _, song_entry in ipairs(songs) do
  local tla = song_entry[1]
  local song_name = song_entry[2]

  if lookup[tla] then
    dbg("duplicate TLA %s ignored", tla)
  else
    lookup[tla] = song_name
    names[#names + 1] = tla
  end
end

local function help()
  local footer = string.format(
    "v%s  enabled=%s debug=%s  load=%dms",
    VERSION,
    bool_text(enabled),
    bool_text(debug_enabled),
    load_ms
  )

  if H and H.title and H.section and H.line and H.foot then
    rune.echo(H.title("Bard song TLAs  (alias: " .. SHORT .. ")"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line(NAME, "show this help"))
    rune.echo(H.line(NAME .. " list", "show all configured TLAs"))
    rune.echo(H.line(NAME .. " on|off", "enable / disable the song aliases"))
    rune.echo(H.line(NAME .. " debug on|off", "toggle debug messages"))
    rune.echo(H.section("Song aliases"))
    rune.echo(H.line("bfi", "play 'fireball'"))
    rune.echo(H.line("bcl", "play 'cure light'"))
    rune.echo(H.line("See " .. NAME .. " list", "show every configured TLA"))
    rune.echo(H.foot(footer))
    return
  end

  rune.echo("Bard song TLAs  (alias: " .. SHORT .. ")")
  rune.echo("  " .. NAME .. "              show this help")
  rune.echo("  " .. NAME .. " list         show all configured TLAs")
  rune.echo("  " .. NAME .. " on|off       enable / disable the song aliases")
  rune.echo("  " .. NAME .. " debug on|off toggle debug messages")
  rune.echo("  bfi                       play 'fireball'")
  rune.echo("  bcl                       play 'cure light'")
  rune.echo("  See " .. NAME .. " list     show every configured TLA")
  rune.echo(footer)
end

local function show_song_list()
  local groups = {
    { title = "Peace songs", first = 1, last = 11 },
    { title = "Martial songs", first = 12, last = 24 },
    { title = "Versatile songs", first = 25, last = #songs },
  }

  say("configured song TLAs:")
  for _, group in ipairs(groups) do
    rune.echo(group.title .. ":")
    for i = group.first, group.last do
      local entry = songs[i]
      if entry then
        rune.echo("  " .. entry[1] .. "  " .. entry[2])
      end
    end
  end
end

local function handle_command(args)
  local text = tostring(args or ""):lower():match("^%s*(.-)%s*$")

  if text == "on" then
    enabled = true
    save_settings()
    say("enabled")
    return
  end

  if text == "off" then
    enabled = false
    save_settings()
    say("disabled")
    return
  end

  if text == "debug on" then
    debug_enabled = true
    save_settings()
    say("debug enabled")
    return
  end

  if text == "debug off" then
    debug_enabled = false
    save_settings()
    say("debug disabled")
    return
  end

  if text == "list" then
    show_song_list()
    return
  end

  help()
end

-- Bare commands are exact aliases (not slash commands).
rune.alias.exact(NAME, function(args, ctx)
  handle_command(args)
end)

rune.alias.exact(SHORT, function(args, ctx)
  handle_command(args)
end)

-- One regex alias handles every fixed TLA in the songs table.
rune.alias.regex("^(" .. table.concat(names, "|") .. ")$", function(matches, ctx)
  local tla = matches and matches[1]
  local song_name = tla and lookup[tla]

  if not song_name then
    return
  end

  if not enabled then
    dbg("ignored %s (disabled)", tla)
    return
  end

  local command = "play '" .. song_name .. "'"
  dbg("sending: %s", command)
  rune.send(command)
end)

load_settings()
load_ms = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")

-- Performance: builds the TLA lookup and regex once at load; no runtime file or network I/O.
-- Security: only curated song names are sent; command input is used only to select fixed toggles.
