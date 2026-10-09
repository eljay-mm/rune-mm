-- Filename: ~/.config/rune/eljayPlugins/initEljay.lua
-- Purpose: Link each individual plugin, with this file linked to ~/.config/rune/init.lua
-- Version 2.0
-- Date: 2026-Oct-09
--
-- Append below line to ~/.config/rune/init.lua:
-- require("eljayPlugins/initEljay")
--

rune.config.set("mouse", true)

require("eljayPlugins/annwnQuestSearch")
require("eljayPlugins/asciiMapPane")
require("eljayPlugins/bardSongTLAs")
require("eljayPlugins/basicAliases")
require("eljayPlugins/characterLog")
require("eljayPlugins/clipCommandOutput")
require("eljayPlugins/crystalLocator")
require("eljayPlugins/druidSpellTLAs")
require("eljayPlugins/fauxSextant")
require("eljayPlugins/hangmanSolver")
require("eljayPlugins/highlights")
require("eljayPlugins/mapperShortCutKeys")
require("eljayPlugins/numPadBindings")
require("eljayPlugins/oocWikiSearch")
require("eljayPlugins/spdxy")
require("eljayPlugins/spellTLAs")
require("eljayPlugins/vitalsChanges")