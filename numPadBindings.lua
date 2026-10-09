-- Filename: eljayPlugins/numPadBindings.lua
-- Purpose: Numpad Bindings for movement accelerators
-- Version: 2.0
-- Date: 2026-Oct-09

rune.config.set("numpad", true)

rune.bind("add", function() rune.send("down") end)
rune.bind("numpad1", function() rune.send("southwest") end)
rune.bind("numpad2", function() rune.send("south") end)
rune.bind("numpad3", function() rune.send("southeast") end)
rune.bind("numpad4", function() rune.send("west") end)
rune.bind("numpad5", function() rune.send("look") end)
rune.bind("numpad6", function() rune.send("east") end)
rune.bind("numpad7", function() rune.send("northwest") end)
rune.bind("numpad8", function() rune.send("north") end)
rune.bind("numpad9", function() rune.send("northeast") end)
rune.bind("subtract", function() rune.send("up") end)

rune.bind("alt+add", function() rune.send("look down") end)
rune.bind("alt+numpad1", function() rune.send("look southwest") end)
rune.bind("alt+numpad2", function() rune.send("look south") end)
rune.bind("alt+numpad3", function() rune.send("look southeast") end)
rune.bind("alt+numpad4", function() rune.send("look west") end)
rune.bind("alt+numpad5", function() rune.send("scan") end)
rune.bind("alt+numpad6", function() rune.send("look east") end)
rune.bind("alt+numpad7", function() rune.send("look northwest") end)
rune.bind("alt+numpad8", function() rune.send("look north") end)
rune.bind("alt+numpad9", function() rune.send("look northeast") end)
rune.bind("alt+subtract", function() rune.send("look up") end)

rune.bind("ctrl+add", function() rune.send("open down door") end)
rune.bind("ctrl+numpad1", function() rune.send("open southwest door") end)
rune.bind("ctrl+numpad2", function() rune.send("open south door") end)
rune.bind("ctrl+numpad3", function() rune.send("open southeast door") end)
rune.bind("ctrl+numpad4", function() rune.send("open west door") end)
rune.bind("ctrl+numpad6", function() rune.send("open east door") end)
rune.bind("ctrl+numpad7", function() rune.send("open northwest door") end)
rune.bind("ctrl+numpad8", function() rune.send("open north door") end)
rune.bind("ctrl+numpad9", function() rune.send("open northeast door") end)
rune.bind("ctrl+subtract", function() rune.send("open up door") end)
