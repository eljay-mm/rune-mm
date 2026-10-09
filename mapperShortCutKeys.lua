-- Filename: eljayPlugins/mapperShortKeys.lua
-- Purpose: Mapper Short Key Aliases (converted from XML, no dependencies)
-- Version: 2.0
-- Date: 2026-Oct-09

-- Standard mapper commands (exact matches)
rune.alias.exact("mapi", "mapper roominfo")

-- Standard mapper commands (regex matches - need functions for captures)
rune.alias.regex("^mapf *(.*)$", function(matches)
  rune.send("mapper nearby " .. (matches[1] or ""))
end)

rune.alias.regex("^mapg *(.*)$", function(matches)
  rune.send("mapper goto " .. (matches[1] or ""))
end)

rune.alias.regex("^mapb *(.*)$", function(matches)
  rune.send("mapper bookmark goto " .. (matches[1] or ""))
end)

rune.alias.regex("^mapw *(.*)$", function(matches)
  rune.send("mapper where " .. (matches[1] or ""))
end)

-- Ganuk's Iron Worm
rune.alias.exact("r3", "mapper goto 10636")

rune.alias.regex("^wo *(.*)$", function(matches)
  rune.send("mapper goto 10636; shop buy " .. (matches[1] or "") .. "; down; give token ganuk")
end)

-- Dungeon Deceit teleports
rune.alias.exact("dece1", "mapper goto 17138")
rune.alias.exact("dece2", "mapper goto 17212")

-- Hellbent locations
rune.alias.exact("hbrex", "mapper goto 106523")
rune.alias.exact("hbtri", "mapper goto 106364")

-- Lowangen locations
rune.alias.exact("low1", "mapper goto 16133")
rune.alias.exact("low5", "mapper goto 16149")

-- Maldra's Keep
rune.alias.exact("m0", "mapper goto 3573738")
rune.alias.exact("m1", "mapper goto 67947")
rune.alias.exact("m3", "mapper goto 68084")

-- Pirate's Cove
rune.alias.exact("pc0", "mapper goto 29942")
rune.alias.exact("pcw", "mapper goto 3304508")

-- Decara
rune.alias.exact("d0", "mapper goto 116022")

-- Rune locations
rune.alias.exact("r0", "mapper goto 10439")
rune.alias.exact("r1", "mapper goto 31323")
rune.alias.exact("r2", "mapper goto 10727")
rune.alias.exact("r5", "mapper goto 10407")
rune.alias.exact("r6", "mapper goto 81734")
rune.alias.exact("r7", "mapper goto 10554")
rune.alias.exact("r8", "mapper goto 15252")
rune.alias.exact("rw", "mapper goto 2809518")

-- Sigil locations
rune.alias.exact("s0", "mapper goto 28035")
rune.alias.exact("s1", "mapper goto 28450")
rune.alias.exact("s2", "mapper goto 28509")

-- Templeton
rune.alias.exact("t5", "mapper goto 46434")

-- Vospire
rune.alias.exact("v1", "mapper goto 40221")