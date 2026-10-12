-- Filename: ~/.config/rune/eljayPlugins/initEljay.lua
-- Purpose: Link each individual plugin, with this file linked to ~/.config/rune/init.lua
-- Version: 2.2
-- Date: 2026-Oct-12
--
-- Append below line to ~/.config/rune/init.lua:
-- require("eljayPlugins/initEljay")
--
-- How it works:
--  * Sets mouse support, then loads every plugin in the PLUGINS list, in order.
--  * Each require runs under pcall, so a plugin that throws an error is
--    reported and skipped; the remaining plugins still load.
--  * A plugin stuck in an endless loop cannot be caught by pcall (Rune's 5s
--    init watchdog kills the script). To find it, set DEBUG = true below:
--      - before each require, "loading <name>" is appended to PROGRESS_FILE
--        (and closed immediately, so it survives the watchdog kill)
--      - after it returns, "ok <name> (<ms>)" or "FAILED <name>: <err>"
--    After a timeout, the last "loading" line with no "ok" after it is the
--    plugin that hangs.
--  * DEBUG defaults to false: no file is written, only failures are echoed.
--  * Plugin order is alphabetical; move a plugin lower only if it depends on
--    another one having loaded first.

local DEBUG = false                                -- set true to find a hanging plugin
local PROGRESS_FILE = "/tmp/rune-init-progress.log" -- only used when DEBUG = true

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
  "spdxyCoordinates",
  "spellTLAs",
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

local function say(msg)
  if not pcall(rune.echo, msg) then print(msg) end
end

if DEBUG then
  pcall(function()
    local f = io.open(PROGRESS_FILE, "w") -- start a fresh log each run
    if f then f:write("-- initEljay run --\n"); f:close() end
  end)
end

for _, name in ipairs(PLUGINS) do
  progress("loading " .. name)
  local t0 = os.clock()
  local ok, err = pcall(require, "eljayPlugins/" .. name)
  local ms = math.floor((os.clock() - t0) * 1000)
  if ok then
    progress(string.format("ok %s (%d ms)", name, ms))
  else
    progress("FAILED " .. name .. ": " .. tostring(err))
    say("[initEljay] failed to load " .. name .. ": " .. tostring(err))
  end
end
