-- personal.example.lua -- your own changes, kept safe from /update.
--
-- Copy this file to personal.lua (beside init.lua) and edit the copy.
-- init.lua reads personal.lua when Rune starts and on /reload; /update never
-- touches it. Everything below is switched off (commented out with --);
-- remove the -- in front of a setting to use it. A mistake in the file is
-- shown in red and the file ignored, so the rest still loads.

return {

    -- Connecting on start. false: don't connect (type /connect yourself).
    -- A string connects there instead.
    -- autoconnect = false,
    -- autoconnect = "materiamagica.com:4000",

    -- Modules not to load. Any of: autopouch, mapper, mapper_map,
    -- mapper_coord, comms, statusbar, sense, sign, spdr, terrain, panes,
    -- histkeys, numpad, quests, crystal, enemy. (mapper is needed by the
    -- map pane, mapper coord, spdr and sense.)
    -- skip = { "numpad", "autopouch" },
    skip = { "eqdb", "enemy" },

    -- Your own screen layout, used instead of the built-in one. It must
    -- declare the whole layout each time: the modules call it again to change
    -- their pane titles (rune.comms_title, rune.map_title, rune.quests_title).
    -- Name the panes "output", "comms", "map" and "quests" so the modules
    -- find them; the map sizes itself to whatever size you give its pane.
    -- This one puts the map on the left and drops the quests pane:
    --
    -- layout = function()
    --     rune.ui.layout({
    --         type = "column",
    --         children = {
    --             { type = "row", size = "1fr", children = {
    --                 { type = "pane", name = "map", size = 41, border = "full",
    --                   title = rune.map_title or "Map" },
    --                 { type = "pane", name = "output", size = "1fr", border = "none" },
    --                 { type = "pane", name = "comms", size = "35%", border = "full",
    --                   title = rune.comms_title or "Comms" },
    --             }},
    --             { type = "input" },
    --             { type = "bar", name = "status" },
    --         },
    --     })
    -- end,

    -- Anything else, run after everything has loaded: your own aliases,
    -- triggers, key bindings and Rune settings.
     after = function()
	require("eljayPlugins/initEljay-splitScreen")
    --     rune.alias.exact("gac", "get all corpse")
    --     rune.bind("f2", function() rune.send("cast 'armor'") end)
    --     rune.config.set("keep_input", false)  -- empty the input line after Enter
    --     rune.config.set("mouse", true)        -- mouse wheel scrolls Rune
     end,

}
