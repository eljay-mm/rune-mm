-- Filename: eljayPlugins/initEljay.lua
-- Purpose: Load every eljayPlugins plugin in order, skipping any that fail.
-- Version: 2.4
-- Date: 2026-Oct-13
-- Changelog:
--   2.4  Compatibility fix for rune.style usage and kept the single-row status summary.
--   2.3  Header brought to current format; single-row load summary with coloured [initEljay] prefix;
--        cross-platform progress file (TMPDIR/TEMP/tmp); failures collected and reported once.
--
-- Install: append to ~/.config/rune/init.lua (Windows: the same Rune config directory) the line:
--   require("eljayPlugins/initEljay")
--
-- How it works:
--   * Sets mouse support, then loads every plugin in the PLUGINS list, in order.
--   * Each require runs under pcall, so a plugin that throws an error is reported and skipped;
--     the remaining plugins still load.
--   * On load it prints a single row: "[initEljay] v2.4  loaded N/M plugins".
--     Only failures add extra rows (one per failed plugin, with the error).
--   * A plugin stuck in an endless loop cannot be caught by pcall (Rune's startup watchdog kills the
--     script). To find it, set DEBUG = true below:
--       - before each require, "loading <name>" is appended to PROGRESS_FILE
--         (and closed immediately, so it survives the watchdog kill)
--       - after it returns, "ok <name> (<ms>)" or "FAILED <name>: <err>"
--     After a timeout, the last "loading" line with no "ok" after it is the plugin that hangs.
--   * DEBUG defaults to false: no file is written, only failures are echoed.
--   * To disable a plugin, comment out or delete its line in PLUGINS.
--   * Plugin order is alphabetical; move a plugin lower only if it depends on another one having loaded first.
--
-- Commands:
--   none - this file is a loader and runs at startup only

local VERSION = "2.4"
local DEBUG = false -- set true to find a hanging plugin

-- Cross-platform temp location (Linux/macOS: TMPDIR or /tmp, Windows: TEMP/TMP).
local TMP = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local PROGRESS_FILE = TMP .. "/rune-init-progress.log" -- only used when DEBUG = true

rune.config.set("mouse", true)

local PLUGINS = {
  "annwnQuestSearch",
  "asciiMapPane",
  "bardSongTLAs",
  "basicAliases",
  "characterLog",
  "clipCommandOutput",
  "crystalLocator",
  "druidSpellTLAs",
  "eqdbResultsPicker",
  "fauxSextant",
  "hangmanSolver",
  "highlights",
  "jmcSolver",
  "mapperShortCutKeys",
  "numPadBindings",
  "oocWikiSearch",
  "researchNotesPicker",
  "shopListPicker",
  "spdxyCoordinates",
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

-- Echo a row with a cyan "[initEljay] " prefix; fall back safely if style usage differs.
local function say(msg)
  msg = tostring(msg or "")
  local ok, styled
  if rune and rune.style then
    if type(rune.style.cyan) == "function" then
      ok, styled = pcall(rune.style.cyan, "[initEljay] ")
      if ok and styled then
        local ok2, out = pcall(rune.echo, styled .. msg)
        if ok2 then return end
      end
    end

    if type(rune.style) == "function" then
      ok, styled = pcall(rune.style, "cyan", "[initEljay] ")
      if ok and styled then
        local ok2, out = pcall(rune.echo, styled .. msg)
        if ok2 then return end
      end
    end
  end

  if not pcall(rune.echo, "[initEljay] " .. msg) then
    print("[initEljay] " .. msg)
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

for _, name in ipairs(PLUGINS) do
  progress("loading " .. name)
  local t0 = os.clock()
  local ok, err = pcall(require, "eljayPlugins/" .. name)
  local ms = math.floor((os.clock() - t0) * 1000)
  if ok then
    loaded = loaded + 1
    progress(string.format("ok %s (%d ms)", name, ms))
  else
    failures[#failures + 1] = { name = name, err = tostring(err) }
    progress("FAILED " .. name .. ": " .. tostring(err))
  end
end

-- Single summary row on load; failures only add rows when something broke.
say(string.format("v%s  loaded %d/%d plugins%s", VERSION, loaded, #PLUGINS,
  DEBUG and ("  debug=on log=" .. PROGRESS_FILE) or ""))

for _, f in ipairs(failures) do
  say("failed to load " .. f.name .. ": " .. f.err)
end