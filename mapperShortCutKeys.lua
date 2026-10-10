-- Filename: eljayPlugins/mapperShortKeys.lua
-- Purpose: Mapper Short Key Aliases (converted from XML, no dependencies)
-- Version: 2.1
-- Date: 2026-Oct-10

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
rune.alias.exact("r4", "mapper goto 10636")

rune.alias.regex("^wo *(.*)$", function(matches)
  rune.send("mapper goto 10636; shop buy " .. (matches[1] or "") .. "; down; give token ganuk")
end)

-- Dungeon Deceit teleports
rune.alias.exact("dece1", "mapper goto 17138") -- first teleport
rune.alias.exact("dece2", "mapper goto 17212") -- second teleport

-- Hellbent locations
rune.alias.exact("hbrex", "mapper goto 106523") -- just outside t-rex
rune.alias.exact("hbtri", "mapper goto 106364") -- triceratops]

-- Lowangen locations
rune.alias.exact("low1", "mapper goto 16133") -- king
rune.alias.exact("low5", "mapper goto 16149") -- lootable

-- Maldra's Keep
rune.alias.exact("m0", "mapper goto 3573738") -- safe outside
rune.alias.exact("m1", "mapper goto 67947") -- QM
rune.alias.exact("m3", "mapper goto 68084")

-- Pirate's Cove
rune.alias.exact("pc0", "mapper goto 29942") -- healer/recall
rune.alias.exact("pcw", "mapper goto 3304508") -- west gate

-- Decara
rune.alias.exact("d0", "mapper goto 116022") -- healer/recall

-- Rune locations
rune.alias.exact("r0", "mapper goto 10439") -- healer/recall
rune.alias.exact("r1", "mapper goto 31323") -- QM
rune.alias.exact("r2", "mapper goto 10727") -- clanmaster
rune.alias.exact("r3", "mapper goto 81734") -- condos
rune.alias.exact("r4", "mapper goto 10636") -- iron worm
rune.alias.exact("r5", "mapper goto 10407") -- crystal guild

rune.alias.exact("r7", "mapper goto 10554") -- reagents
rune.alias.exact("r8", "mapper goto 15252") -- focault's near blarg
rune.alias.exact("r9", "mapper goto 10638") -- lottery

rune.alias.exact("rw", "mapper goto 2809518") -- west gate

-- Sigil locations
rune.alias.exact("s0", "mapper goto 28035") -- healer/recall
rune.alias.exact("s1", "mapper goto 28450") -- QM
rune.alias.exact("s2", "mapper goto 28509") -- clanmaster

-- Templeton
rune.alias.exact("t5", "mapper goto 46434")

-- Vospire
rune.alias.exact("v1", "mapper goto 40221") -- king
