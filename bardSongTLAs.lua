-- Filename: eljayPlugins/bardSongTLAs.lua
-- Purpose: Bard songs with three-letter acronyms.
-- Version: 2.4
-- Date: 2026-Oct-15
-- Changelog:
--   2.4  Cyan prefix and loader line copied from druidSpellTLAs (rune.style.cyan); all song TLAs
--        share a single alias; command aliases use one regex; songs are sent with rune.send.
--   2.3  Command renamed bardSongTLAs with short alias bard; loader line; help lists all TLAs;
--        "nights fortune" matches 'help music'.
--   2.2  Command summary, enable/disable toggle, debug toggle, persistent settings.
--
-- How it works:
--   * Each row in the songs table maps a TLA to a bard song, e.g. "bfi" -> play 'fireball'.
--   * Songs are grouped as in 'help music': Peace, Martial and Versatile.
--   * All TLAs are matched by one alias built from the table, so adding a song is one new row;
--     a repeated TLA is ignored and reported in debug.
--   * Only fixed, curated song names are ever sent; no user text is forwarded.
--   * When disabled the aliases do nothing; settings persist in rune.store.
--
-- Commands (short alias: bard):
--   bardSongTLAs                show this summary
--   bardSongTLAs on|off         enable or disable all song TLAs
--   bardSongTLAs debug on|off   toggle debug output (default off)

local NAME = "bardSongTLAs"
local VERSION = "2.4"
local SETTINGS_KEY = "bardSongTLAs.settings"

local enabled = true
local debug_enabled = false

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then H = nil end

-- Cyan "[name] " prefix (same as druidSpellTLAs); plain text if rune.style is unavailable.
local function prefix()
  local p = "[" .. NAME .. "] "
  if rune.style and type(rune.style.cyan) == "function" then
    local ok, s = pcall(rune.style.cyan, p)
    if ok and type(s) == "string" then return s end
  end
  return p
end

local function say(text) rune.echo(prefix() .. text) end

local function dbg(fmt, ...)
  if not debug_enabled then return end
  local ok, s = pcall(string.format, fmt, ...)
  say("debug: " .. (ok and s or tostring(fmt)))
end

local function onoff(v) return v and "on" or "off" end

local function load_settings()
  if not (rune and rune.store and type(rune.store.get) == "function") then return end
  local ok, t = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(t) == "table" then
    if type(t.enabled) == "boolean" then enabled = t.enabled end
    if type(t.debug) == "boolean" then debug_enabled = t.debug end
  end
end

local function save_settings()
  if not (rune and rune.store and type(rune.store.set) == "function") then return end
  pcall(rune.store.set, SETTINGS_KEY, { enabled = enabled, debug = debug_enabled })
end

local songs = {
  -- Peace songs (not in combat)
  { "bbm",  "battle march" },
  { "bdi",  "detect invisibility" },
  { "bfl",  "footloose" },
  { "bes",  "enhanced strength" },
  { "bep",  "epiphany" },
  { "bih",  "inspirational hymn" },
  { "ble",  "levitation" },
  { "bli",  "light" },
  { "bml",  "mass levitation" },
  { "bsh",  "shield" },
  { "bts",  "traveling song" },

  -- Martial songs (in combat)
  { "bbl",  "blindness" },
  { "bcac", "cacophony" },
  { "bfi",  "fireball" },
  { "bea",  "earworm" },
  { "bhw",  "hands of wind" },
  { "bha",  "harmonize" },
  { "bsl",  "hinder" },
  { "bpd",  "pensive dirge" },
  { "bpf",  "plodding fugue" },
  { "bsn",  "soothing nocturne" },
  { "btro", "tremolo" },
  { "bom",  "ode to the moon" },
  { "btrr", "tempus rigor" },

  -- Versatile songs (any time)
  { "bca",  "calm" },
  { "bcl",  "cure light" },
  { "bip",  "invigorating performance" },
  { "bnf",  "nights fortune" },
  { "bre",  "refresh" },
  { "bri",  "rime of the glacierbreaker" },
  { "bth",  "thunderclap" },
  { "btr",  "tremor" },
}

-- One lookup table and one alias for every TLA (instead of one alias per song).
local lookup, names = {}, {}
for _, s in ipairs(songs) do
  if lookup[s[1]] then
    dbg("duplicate TLA %s ignored", s[1])
  else
    lookup[s[1]] = s[2]
    names[#names + 1] = s[1]
  end
end

rune.alias.regex("^(" .. table.concat(names, "|") .. ")$", function(m)
  local name = m and m[1]
  local song = name and lookup[name]
  if not song then return end
  if not enabled then
    dbg("ignored %s (disabled)", name)
    return
  end
  local cmd = "play '" .. song .. "'"
  dbg("sending: %s", cmd)
  rune.send(cmd)
end)

local function help_summary()
  local status = "v" .. VERSION .. "  enabled=" .. onoff(enabled) .. " debug=" .. onoff(debug_enabled)
  if H and H.title and H.section and H.line and H.foot then
    rune.echo(H.title("Bard song TLAs"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("bardSongTLAs", "show this summary (short alias: bard)"))
    rune.echo(H.line("bardSongTLAs on|off", "enable or disable all aliases"))
    rune.echo(H.line("bardSongTLAs debug on|off", "toggle debug output"))
    rune.echo(H.section("Song aliases"))
    rune.echo(H.line("bfi", "play 'fireball' (see the songs table)"))
    rune.echo(H.line("bcl", "play 'cure light'"))
    rune.echo(H.foot(status))
    return
  end
  rune.echo("Bard song TLAs")
  rune.echo("  bardSongTLAs              show this summary (short alias: bard)")
  rune.echo("  bardSongTLAs on|off       enable or disable all aliases")
  rune.echo("  bardSongTLAs debug on|off toggle debug output")
  rune.echo("  bfi                       play 'fireball' (see the songs table)")
  rune.echo("  bcl                       play 'cure light'")
  rune.echo(status)
end

-- Bare commands are aliases (rune.command.add would only create /slash commands).
rune.alias.regex("^(?:bardSongTLAs|bard)(?:[ ]+(.+))?$", function(m)
  local text = tostring((m and m[1]) or ""):lower()
  local cmd = text:match("^(%S*)") or ""
  local rest = text:match("^%S+%s*(.*)$") or ""

  if cmd == "on" then
    enabled = true; save_settings(); say("enabled"); return
  end
  if cmd == "off" then
    enabled = false; save_settings(); say("disabled"); return
  end
  if cmd == "debug" then
    if rest == "on" then debug_enabled = true
    elseif rest == "off" then debug_enabled = false
    else help_summary(); return end
    save_settings(); say("debug " .. onoff(debug_enabled)); return
  end

  help_summary()
end)

load_settings()
say("v" .. VERSION .. " loaded (" .. NAME .. " or bard for help)")

-- Performance: one alias for all songs, built once at load; no I/O at run time.
-- Security: only curated "play" commands are sent, and no user-supplied text is ever forwarded.