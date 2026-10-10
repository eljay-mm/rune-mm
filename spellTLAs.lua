-- Filename: eljayPlugins/spellTLAs.lua
-- Purpose: General spell Three Letter Aliases, optionally targettable
-- Version: 3.2 (added spells from multiple class path spell lists)
-- Date: 2026-Oct-10

--[[ Helper (must be defined before use)
     cast("cXX", "spell name") creates:
       cXX [target]  ->  cast 'spell name' [target]
       nXX           ->  aff clear 'spell name'   (only for keys starting with "c")
     e.g. cast("cla", "portal to the laser dimension") also gives "nla".
]]--
local function cast(key, spell)
  rune.alias.regex("^" .. key .. "(?:[ ]+(.+))?$", function(m)
    local cmd = "cast '" .. spell .. "'"
    if m[1] and m[1] ~= "" then cmd = cmd .. " " .. m[1] end
    rune.send(cmd)
  end)
  if key:sub(1, 1) == "c" then
    rune.alias.exact("n" .. key:sub(2), "aff clear '" .. spell .. "'")
  end
end

--[[ Cast Spells (with optional targets), grouped, then sorted by spell name ]]--

-- Protection & Buffs
cast("cae", "aegis")
cast("cah", "air halo")
cast("car", "armor")
cast("caa", "augment aura")
cast("bbm", "battlefield medic")
cast("cble", "bless")
cast("cblink", "blink")
cast("ccf", "channel faith")
cast("cca", "consecrate armor")
cast("ccw", "consecrate weapon")
cast("cdv", "demigod visage")
cast("ces", "elemental shield")
cast("cen", "enlighten")
cast("ceq", "equality")
cast("cfl", "fearless")
cast("cfz", "frenzy")
cast("cgl", "glacierskin")
cast("cpd", "inoculate ignorance")
cast("clc", "lava cloak")
cast("clev", "levitation")
cast("cls", "lightning shroud")
cast("clu", "lunar independence")
cast("cmf", "magnetic field")
cast("cng", "necromancers guile")
cast("cph", "phalanx")
cast("cpe", "protection from evil")
cast("cpg", "protection from good")
cast("crs", "rites of solemnity")
cast("csn", "sanctify")
cast("csa", "sanctuary")
cast("csh", "shield")
cast("csb", "smiting blows")
cast("css", "spell shield")
cast("cuw", "underwater breathing")
cast("cxb", "xorn blood")

-- Healing & Cures
cast("cacl", "aura cleansing")
cast("cb", "create bandage")
cast("cba", "create bandage")
cast("ccb", "cure blindness")
cast("ccc", "cure critical")
cast("ccd", "cure disease")
cast("cl", "cure light")
cast("ccl", "cure light")
cast("ccp", "cure poison")
cast("ccs", "cure serious")
cast("ch", "heal")
cast("che", "heal")
cast("clm", "lift malison")
cast("clib", "liberation")
cast("cre", "refresh")
cast("crc", "remove curse")
cast("cres", "resurrect")

-- Offense
cast("cabl", "air blast")
cast("cab", "arcane blast")
cast("cbd", "blood dance")
cast("cbc", "bubble cluster")
cast("cbu", "buffet")
cast("cli", "call lightning")
cast("cac", "cause critical")
cast("cal", "cause light")
cast("cch", "chain lightning")
cast("cdc", "diseased cloud")
cast("cec", "ember carom")
cast("ceo", "energy orb")
cast("cfw", "flame wind")
cast("cfs", "flintstrike")
cast("cfr", "first rain")
cast("cgw", "gravity well")
cast("cha", "harm")
cast("chr", "harrow")
cast("chw", "harrow")
cast("chs", "holy strike")
cast("ciw", "ice wind")
cast("ciwh", "ice whip")
cast("cld", "landslide")
cast("cmd", "magic dart")
cast("cqs", "quicksand")
cast("cfi", "reflective fireball")
cast("cst", "searing touch")
cast("ctr", "tremor")
cast("cww", "whirlwind")

-- Debuffs & Curses
cast("cbl", "blindness")
cast("ccm", "calm")
cast("cdn", "condemn")
cast("cco", "counterspell")
cast("ccu", "curse")
cast("cfg", "cursed fog")
cast("cdar", "desecrate armor")
cast("cex", "excommunicate")
cast("cff", "faerie fire")
cast("cpl", "plague")
cast("cpo", "poison")
cast("cti", "tinnitus")
cast("cwarp", "warp")
cast("cwe", "weaken")
cast("cwt", "withering touch")

-- Dispels
cast("cabj", "abjure")
cast("cda", "dispel area")
cast("cdm", "dispel magic")

-- Detection & Information
cast("cdal", "detect alignment")
cast("ill", "detect illusion")
cast("cdi", "detect illusion")
cast("cdiv", "detect invisibility")
cast("cdl", "detect lore")
cast("cde", "detect magic")
cast("cdt", "detect truth")
cast("cra", "read aura")
cast("csl", "sense life")

-- Summons & Conjuring
cast("ccel", "conjure celestial")
cast("cce", "conjure elemental")
cast("ccsp", "conjure spirit")
cast("cml", "megalith")
cast("cmo", "monument")
cast("ssh", "summon shaman")
cast("ssw", "summon wizard")
cast("cto", "totem")

-- Travel & Utility
cast("cbe", "beacon")
cast("cpa", "create parchment")
cast("cdg", "daggerportal")
cast("cdp", "daggerportal")
cast("cfo", "fountain")
cast("cgt", "gate travel")
cast("cilu", "illumination")
cast("cmu", "magic unlock")
cast("cla", "portal to the laser dimension")   -- also gives "nla"
cast("crp", "radiant prayer")
cast("creq", "requiem")
cast("crv", "revert catastrophe")
cast("cso", "soul sacrifice")

rune.alias.exact("wor", "cast 'word of recall'")

cast("cbat", "bathe")

-- Non-cast aliases
rune.alias.regex("^clre(?:[ ]+(.+))?$", function(m)
  local cmd = "clear affect 'repulsion'"
  if m[1] and m[1] ~= "" then cmd = cmd .. " " .. m[1] end
  rune.send(cmd)
end)
