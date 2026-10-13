-- Filename: eljayPlugins/statusTray.lua
-- Purpose: Compact bottom-row status: CRYSTAL x y | QUEST | SEXTANT x y | TELL
-- Version: 1.0
-- Date: 2026-Oct-13
-- Changelog:
--   1.0  Initial implementation as a standalone bottom-row status bar.
--
-- How it works:
--  * Renders one compact bottom bar string, for example:
--      CRYSTAL 12 34 | QUEST ON | SEXTANT 12 34 | TELL OFF
--  * The plugin keeps an in-memory state for: crystal coords, quest status,
--    sextant coords, and tell indicator. State is cheap strings/nil.
--  * State and toggles (enabled/debug) are persisted in rune.store under
--    "statustray.settings".
--  * The bar function is intentionally minimal/fast. Callers (other plugins)
--    should update state via the exported setters (require the module).
--  * A small rune.command "statustray" is provided with on|off, debug,
--    set/clear/toggle helpers and a bare help summary rendered via helpstyle.
--  * The plugin wraps rune.ui.layout once to ensure the bar appears at the
--    bottom (appended as a bar child) so it shows with existing Sextant/LIVE.

local VERSION = "1.0"
local SETTINGS_KEY = "statustray.settings"
local BAR_NAME = "status_tray"

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then H = nil end

-- Internal state (kept as simple strings or nil)
local state = {
  enabled = true,
  debug = false,
  crystal = nil,  -- "x y" or nil
  quest   = "OFF",-- arbitrary short status string
  sextant = nil,  -- "x y" or nil
  tell    = "OFF",-- "ON"/"OFF" or short text
}

-- Load/save --------------------------------------------------------------
local function load_settings()
  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then state.enabled = saved.enabled end
    if type(saved.debug) == "boolean" then state.debug = saved.debug end
    if type(saved.crystal) == "string" then state.crystal = saved.crystal end
    if type(saved.quest) == "string" then state.quest = saved.quest end
    if type(saved.sextant) == "string" then state.sextant = saved.sextant end
    if type(saved.tell) == "string" then state.tell = saved.tell end
  end
end

local function save_settings()
  pcall(rune.store.set, SETTINGS_KEY, {
    enabled = state.enabled,
    debug   = state.debug,
    crystal = state.crystal,
    quest   = state.quest,
    sextant = state.sextant,
    tell    = state.tell,
  })
end

-- Utility helpers --------------------------------------------------------
local function dbg(msg)
  if state.debug then
    pcall(rune.echo, "[statusTray:debug] " .. tostring(msg))
  end
end

local function fmt_coord(s)
  if not s or s == "" then return "--" end
  return tostring(s)
end

local function render_one()
  -- Keep the renderer extremely cheap; avoid allocations where possible.
  local crystal = "CRYSTAL " .. fmt_coord(state.crystal)
  local quest   = "QUEST " .. tostring(state.quest or "OFF")
  local sextant = "SEXTANT " .. fmt_coord(state.sextant)
  local tell    = "TELL " .. tostring(state.tell or "OFF")
  return crystal .. " | " .. quest .. " | " .. sextant .. " | " .. tell
end

-- Bar registration -------------------------------------------------------
rune.ui.bar(BAR_NAME, function()
  if not state.enabled then return nil end
  -- Return the single string for the bar; keep it cheap.
  return render_one()
end)

-- Ensure the bar is present in layouts by wrapping rune.ui.layout once.
if not rune.ui._statusTrayWrapped then
  local orig_layout = rune.ui.layout
  rune.ui._statusTrayWrapped = true

  rune.ui.layout = function(cfg)
    if type(cfg) == "table" and cfg.type == "column" and type(cfg.children) == "table" then
      local found = false
      for _, child in ipairs(cfg.children) do
        if type(child) == "table" and child.type == "bar" and child.name == BAR_NAME then
          found = true
          break
        end
      end
      if not found then
        table.insert(cfg.children, { type = "bar", name = BAR_NAME })
      end
    end
    return orig_layout(cfg)
  end
end

-- If a layout already exists, rebuild it once so the bar appears immediately.
if type(rune_build_layout) == "function" then
  pcall(rune_build_layout, rune.store.get("quest_title"))
end

-- Setters and getters (exported) ----------------------------------------
local M = {}

-- All setters call refresh and save; they tolerate nil/invalid input.
function M.set_enabled(on)
  local new = (on == true)
  if state.enabled ~= new then
    state.enabled = new
    save_settings()
    rune.ui.refresh_bars()
    dbg("enabled -> " .. tostring(new))
  end
end

function M.toggle_enabled()
  M.set_enabled(not state.enabled)
end

function M.set_debug(on)
  local new = (on == true)
  if state.debug ~= new then
    state.debug = new
    save_settings()
    dbg("debug -> " .. tostring(new))
  end
end

function M.set_crystal(x, y)
  local s = nil
  if x ~= nil then s = tostring(x) .. (y ~= nil and (" " .. tostring(y)) or "") end
  if state.crystal ~= s then
    state.crystal = s
    save_settings()
    rune.ui.refresh_bars()
    dbg("crystal -> " .. tostring(s))
  end
end

function M.clear_crystal()
  M.set_crystal(nil)
end

function M.set_quest(v)
  v = v and tostring(v) or "OFF"
  if state.quest ~= v then
    state.quest = v
    save_settings()
    rune.ui.refresh_bars()
    dbg("quest -> " .. tostring(v))
  end
end

function M.set_sextant(x, y)
  local s = nil
  if x ~= nil then s = tostring(x) .. (y ~= nil and (" " .. tostring(y)) or "") end
  if state.sextant ~= s then
    state.sextant = s
    save_settings()
    rune.ui.refresh_bars()
    dbg("sextant -> " .. tostring(s))
  end
end

function M.clear_sextant()
  M.set_sextant(nil)
end

function M.set_tell(v)
  v = v and tostring(v) or "OFF"
  if state.tell ~= v then
    state.tell = v
    save_settings()
    rune.ui.refresh_bars()
    dbg("tell -> " .. tostring(v))
  end
end

function M.clear_tell()
  M.set_tell("OFF")
end

function M.get_state()
  -- Return a shallow copy to avoid external mutation
  return {
    enabled = state.enabled,
    debug = state.debug,
    crystal = state.crystal,
    quest = state.quest,
    sextant = state.sextant,
    tell = state.tell,
  }
end

-- Command and help -------------------------------------------------------
local function status_line()
  return string.format("v%s  bar=%s  debug=%s",
    VERSION, state.enabled and "on" or "off", state.debug and "on" or "off")
end

local function show_help()
  if H then
    pcall(function()
      rune.echo(H.title("Bottom status (CRYSTAL | QUEST | SEXTANT | TELL)"))
      rune.echo(H.section("Commands"))
      rune.echo(H.line("statustray", "show this summary"))
      rune.echo(H.line("statustray on|off", "enable / disable the bar"))
      rune.echo(H.line("statustray debug on|off", "toggle debug messages (default off)"))
      rune.echo(H.line("statustray set crystal <x> <y>", "set crystal coords"))
      rune.echo(H.line("statustray clear crystal", "clear crystal coords"))
      rune.echo(H.line("statustray set sextant <x> <y>", "set sextant coords"))
      rune.echo(H.line("statustray clear sextant", "clear sextant coords"))
      rune.echo(H.line("statustray set quest <text>", "set quest status (short)"))
      rune.echo(H.line("statustray set tell <ON|OFF|text>", "set tell indicator"))
      rune.echo(H.line("statustray show", "echo current bar text"))
      rune.echo(H.foot(status_line()))
    end)
    return
  end

  -- Plain fallback
  rune.echo("Bottom status - CRYSTAL | QUEST | SEXTANT | TELL")
  rune.echo("  statustray                show this summary")
  rune.echo("  statustray on|off         enable / disable the bar")
  rune.echo("  statustray debug on|off   toggle debug messages (default off)")
  rune.echo("  statustray set crystal <x> <y>")
  rune.echo("  statustray clear crystal")
  rune.echo("  statustray set sextant <x> <y>")
  rune.echo("  statustray clear sextant")
  rune.echo("  statustray set quest <text>")
  rune.echo("  statustray set tell <ON|OFF|text>")
  rune.echo("  statustray show")
  rune.echo(status_line())
end

-- Parse a small quoted/trimmed argument list
local function words_of(s)
  local t = {}
  for w in tostring(s or ""):gmatch("%S+") do t[#t+1] = w end
  return t
end

rune.command.add("statustray", function(args)
  local a = tostring(args or ""):match("^%s*(.-)%s*$")
  if a == "" then show_help(); return end

  local w = words_of(a)
  local cmd = (w[1] or ""):lower()

  if cmd == "on" or cmd == "off" then
    M.set_enabled(cmd == "on")
    rune.echo("statustray: bar " .. (state.enabled and "on" or "off"))
    return
  end

  if cmd == "debug" then
    if w[2] == "on" then M.set_debug(true)
    elseif w[2] == "off" then M.set_debug(false)
    else rune.echo("usage: statustray debug on|off"); return end
    rune.echo("statustray: debug " .. (state.debug and "on" or "off"))
    return
  end

  if cmd == "set" then
    local what = (w[2] or ""):lower()
    if what == "crystal" then
      if not w[3] then rune.echo("usage: statustray set crystal <x> <y>"); return end
      M.set_crystal(w[3], w[4])
      rune.echo("statustray: crystal -> " .. tostring(state.crystal))
      return
    elseif what == "sextant" then
      if not w[3] then rune.echo("usage: statustray set sextant <x> <y>"); return end
      M.set_sextant(w[3], w[4])
      rune.echo("statustray: sextant -> " .. tostring(state.sextant))
      return
    elseif what == "quest" then
      local rest = a:match("^%S+%s+%S+%s+(.*)$")
      if not rest or rest == "" then rune.echo("usage: statustray set quest <text>"); return end
      M.set_quest(rest)
      rune.echo("statustray: quest -> " .. tostring(state.quest))
      return
    elseif what == "tell" then
      local rest = w[3] or ""
      if rest == "" then rune.echo("usage: statustray set tell <ON|OFF|text>"); return end
      M.set_tell(rest:upper() == "ON" and "ON" or (rest:upper() == "OFF" and "OFF" or rest))
      rune.echo("statustray: tell -> " .. tostring(state.tell))
      return
    else
      rune.echo("unknown set target; use crystal|sextant|quest|tell")
      return
    end
  end

  if cmd == "clear" then
    local what = (w[2] or ""):lower()
    if what == "crystal" then M.clear_crystal(); rune.echo("statustray: crystal cleared"); return end
    if what == "sextant" then M.clear_sextant(); rune.echo("statustray: sextant cleared"); return end
    if what == "tell" then M.clear_tell(); rune.echo("statustray: tell cleared"); return end
    rune.echo("usage: statustray clear crystal|sextant|tell")
    return
  end

  if cmd == "toggle" then
    local what = (w[2] or ""):lower()
    if what == "enabled" then M.toggle_enabled(); rune.echo("statustray: enabled -> " .. tostring(state.enabled)); return end
    rune.echo("usage: statustray toggle enabled")
    return
  end

  if cmd == "show" then
    rune.echo(render_one())
    return
  end

  show_help()
end, "Bottom status bar: manage bottom row status")

-- Init -------------------------------------------------------------------
load_settings()
dbg("loaded settings: " .. tostring(state.crystal) .. " / " .. tostring(state.sextant))

-- Export module for other plugins to require and call setters.
return M

-- Performance and security recommendations
--  * Performance:
--    - The bar renderer is intentionally minimal: it only concatenates a few
--      short strings and returns them. Keep updates infrequent: call the
--      setters only when values actually change so rune.ui.refresh_bars()
--      is not invoked excessively.
--    - Avoid doing heavy text processing inside the bar function. If another
--      plugin computes long strings (e.g. HTML parsing), compute and store a
--      short summary and pass the short string to set_*.
--  * Security:
--    - Values shown on the bar come from other plugins; sanitize inputs if any
--      of them may contain terminal escapes. This plugin stores only simple
--      printable strings, but callers should strip control characters before
--      calling the setters.
--    - rune.store is used for persistence. Do not store secrets in plain text.
--    - This plugin does not spawn subprocesses or perform network I/O.