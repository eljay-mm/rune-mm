-- Filename: eljayPlugins/initEljay.lua
-- Purpose: Load every eljayPlugins plugin in order, skipping any that fail.
-- Version: 2.7
-- Date: 2026-Nov-10
--[[
- insert planning notes here between revisions.
--]]
-- Changelog:
--   2.7 - asciiMap* references removed; no jmcSolver support modules listed;
--         install line now goes in personal.lua instead of init.lua.
--   2.3-2.6 - single-row summary with load time, cross-platform progress file,
--         rune.style fallbacks, half-screen layout override, tidied layout block.
--
-- Install: append to personal.lua (in the Rune config directory, ~/.config/rune on
--   Linux, the same Rune config directory on Windows) the line:
--   require("eljayPlugins/initEljay")
--   Do not edit init.lua itself.
--
-- How it works:
--   * Sets mouse support, declares the screen layout, then loads every plugin in the
--     PLUGINS list, in order.
--   * Each require runs under pcall, so a plugin that throws an error is reported and
--     skipped; the remaining plugins still load.
--   * On load it prints a single row: "[initEljay] v2.7  loaded N/M plugins  load=Nms".
--     Only failures add extra rows (one per failed plugin, with the error).
--   * rune_build_layout() is called again by comms and mapper_map when a pane title,
--     area or zoom changes. It reads rune.comms_title and rune.map_title, which those
--     modules set. Keep everything else in it stable.
--   * A plugin stuck in an endless loop cannot be caught by pcall (Rune's startup
--     watchdog kills the script). To find it, set DEBUG = true below:
--       - before each require, "loading <name>" is appended to PROGRESS_FILE
--         (and closed immediately, so it survives the watchdog kill)
--       - after it returns, "ok <name> (<ms>)" or "FAILED <name>: <err>"
--     After a timeout, the last "loading" line with no "ok" after it is the plugin
--     that hangs. With DEBUG on, the summary row also names the slowest plugin.
--   * DEBUG defaults to false: no file is written, only failures are echoed.
--   * To disable a plugin, comment out or delete its line in PLUGINS.
--   * Plugin order is alphabetical; move a plugin lower only if it depends on another
--     one having loaded first.
--   * Support modules (companions) that load on their own are not listed here.
--
-- Commands:
--   none - this file is a loader and runs at startup only

local T0 = os.clock()
local VERSION = "2.7"
local DEBUG = false -- set true to find a hanging plugin

-- Cross-platform temp location (Linux/macOS: TMPDIR or /tmp, Windows: TEMP/TMP).
local TMP = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local PROGRESS_FILE = TMP .. "/rune-init-progress.log" -- only used when DEBUG = true

--==-- Over-rides
rune.config.set("mouse", true)

-- Panes have no runtime title setter, so comms calls rune_build_layout again
-- when the filter changes, and mapper_map does the same when the map's area or
-- zoom changes.
function rune_build_layout()
  rune.ui.layout({
    type = "column",
    children = {
      { type = "row", size = "1fr", children = {
        { type = "pane", name = "output", size = 74, border = "none" },
        { type = "column", size = "1fr", children = {
          { type = "pane", name = "comms", size = 20, border = "full",
            title = rune.comms_title or "Comms",
            hidden = rune.pane.is_hidden("comms") or false },
          { type = "row", size = "1fr", children = {
            { type = "column", size = 44, children = {
              { type = "pane", name = "map", size = "1fr", border = "full",
                title = rune.map_title or "Map",
                hidden = rune.map_hidden == true
                  or rune.pane.is_hidden("map") or false },
              { type = "pane", name = "quests", size = "1fr", border = "full",
                title = "Quests",
                hidden = rune.pane.is_hidden("quests") or false },
            }},
          }},
        }},
      }},
      { type = "input" },
      { type = "bar", name = "status" },
    },
  })
end

rune_build_layout()
--==-- end Over-ride section

local PLUGINS = {
  "annwnQuestSearch",
  "bardSongTLAs",
  "basicAliases",
  "characterLog",
  "clipCommandOutput",
--  "crystalLocator",
  "druidSpellTLAs",
  "eqdbResultsPicker",
--  "fauxSextant",
  "gotoAliases",
  "hangmanSolver",
  "herbAliases",
  "highlights",
  "highlightCustom",
  "jmcSolver",
  "lootableTracker",
  "mapperShortKeys",
--  "megaQuestSearch",
  "missingAffects",
--  "numPadBindings",
  "oocWikiSearch",
  "researchNotesPicker",
  "shopListPicker",
  -- "spdxyCoordinates",
  -- "spdxyPlaces", -- support module only
  "spellTLAs",
  "statusTray",
  "vitalsChanges",
}

local function progress(line)
  if not DEBUG then return end
  pcall(function()
    local f = io.open(PROGRESS_FILE, "a")
    if f then
      f:write(line, "\n")
      f:close()
    end
  end)
end

-- Cyan text via rune.style; tries both call styles, falls back to plain text.
local function cyan(text)
  local ok, out = pcall(function() return rune.style.cyan(text) end)
  if ok and type(out) == "string" then return out end
  ok, out = pcall(function() return rune.style("cyan", text) end)
  if ok and type(out) == "string" then return out end
  return text
end

-- Echo one row with a cyan "[initEljay] " prefix.
local function say(msg)
  local prefix = "[initEljay] "
  if not pcall(rune.echo, cyan(prefix) .. tostring(msg or "")) then
    print(prefix .. tostring(msg or ""))
  end
end

if DEBUG then
  pcall(function()
    local f = io.open(PROGRESS_FILE, "w") -- start a fresh log each run
    if f then
      f:write("-- initEljay run --\n")
      f:close()
    end
  end)
end

local loaded, failures = 0, {}
local slowName, slowMs = nil, -1

for _, name in ipairs(PLUGINS) do
  progress("loading " .. name)
  local t0 = os.clock()
  local ok, err = pcall(require, "eljayPlugins/" .. name)
  local ms = math.floor((os.clock() - t0) * 1000)
  if ms > slowMs then slowName, slowMs = name, ms end
  if ok then
    loaded = loaded + 1
    progress(string.format("ok %s (%d ms)", name, ms))
  else
    failures[#failures + 1] = { name = name, err = tostring(err) }
    progress("FAILED " .. name .. ": " .. tostring(err))
  end
end

-- Single summary row on load; failures only add rows when something broke.
local totalMs = math.floor((os.clock() - T0) * 1000)
say(string.format("v%s  loaded %d/%d plugins  load=%dms%s", VERSION, loaded, #PLUGINS, totalMs,
  DEBUG and string.format("  slowest=%s(%dms)  log=%s", tostring(slowName), slowMs, PROGRESS_FILE) or ""))

for _, f in ipairs(failures) do
  say("failed to load " .. f.name .. ": " .. f.err)
end