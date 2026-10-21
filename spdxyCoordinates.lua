-- Filename: eljayPlugins/spdxyCoordinates.lua
-- Purpose: Walks to sextant coordinates, towns and clan halls, including unmapped wilderness
-- Version: 3.6
-- Date: 2026-Oct-20
--[[
- insert planning notes here between revisions.
]]
--   3.6  Faster load: helpstyle, mapper modules and saved data load on first use,
--        the walk triggers are one trigger registered at the first walk, the
--        argument aliases are one regex; load time shown in the help footer;
--        NAME/SHORT command-name locals and a short-alias help row.
--   3.5  Bare spdxyCoordinates, spdxy and nearby are rune.alias.exact handlers
--        (args, ctx); help rows go through emit(); loader line; waypoint cap.
--   3.4  Command renamed to spdxyCoordinates (spdxy kept as the short alias); new
--        bare `nearby` alias; helpstyle help with a status footer; on/off and
--        debug toggles (saved); waypoint names sanitised.
--   3.3  Added `nearby` and `back`.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * Every GMCP Room.Info carries coord.x / coord.y. After each move the
--     plugin recomputes the shortest way to the target (the world wraps
--     around) and sends ONE compass step: a diagonal while both axes are
--     off, then straight once one axis matches.
--   * Because it recomputes from the real position after every step, being
--     pushed by crosswinds, fleeing, or fear needs no special handling.
--   * Blocked steps ("You cannot move in that direction.", closed doors,
--     mounted-grapple lines) are remembered per position and the walker
--     goes around, preferring directions close to the wanted one and
--     avoiding rooms it has already visited.
--   * Entering another zone (e.g. a building) steps back out and aborts.
--   * The obstacle/water/combat triggers live in a group that is only
--     enabled while a walk is active, so they cost nothing when idle.
--     `spdxyCoordinates off` disables walking and those triggers.
--   * Named waypoints (spdxy save <name>) and the last destination
--     (spdxy again) are kept in rune.store and survive restarts.
--   * spdxy <town> looks names up in a built-in table of towns, landmarks,
--     worldgates and clan halls (from speedwalk_manager_gmcp.xml). Only
--     entries on your current plane are used, nearest first; one match
--     walks, several open a picker. Partial words work in any order.
--   * spdxy nearby [x, y] (or just `nearby [x, y]`) reports the closest
--     known place, clan hall or waypoint to those coordinates (default:
--     where you stand), with distance and compass direction, on the
--     current plane.
--   * spdxy back walks to where the last walk started (run it again to
--     return to the destination).
--   * Outside the wilds, if horstgs' mapper modules are present, it falls
--     back to walking to a MAPPED room whose stored coord matches.
--
-- Commands: spdxyCoordinates (short alias: spdxy) alone shows the help.
--   spdxy <x>, <y> | <x> <y> | <town> | again | back | stop | pause | resume
--   spdxy clan <name|#> | find <text> | nearby [x, y] | here | list
--   spdxy save <name> [x y] | del <name>
--   spdxyCoordinates on|off   - enable or disable walking and its triggers
--   spdxyCoordinates debug on|off   - verbose walk/lookup messages (default off)
--   nearby [x, y]   - same as spdxy nearby (alone: from where you stand)

----------------------------------------------------------------------
-- Plugin identity, helpers, settings
----------------------------------------------------------------------
local T0 = os.clock()   -- load timer; the result is reported in the help footer
local load_ms = 0

-- Command names: full command and short alias.
local NAME  = "spdxyCoordinates"
local SHORT = "spdxy"
local VERSION = "3.6"

local function paint(color, text)
  local f = rune.style and rune.style[color]
  if type(f) == "function" then return f(text) end
  return text
end

local PREFIX = paint("cyan", "[" .. NAME .. "] ")
local function say(msg) rune.echo(PREFIX .. msg) end
local function emit(s) rune.echo(s) end   -- helpstyle rows (H.*) go through here

local KEY_ENABLED = "spdxy.enabled"   -- default on
local KEY_DEBUG   = "spdxy.debug"     -- default off
local enabled  = rune.store.get(KEY_ENABLED) ~= false
local debug_on = rune.store.get(KEY_DEBUG) == true

-- dbg(fmt, ...): formats only when debug is on.
local function dbg(fmt, ...)
  if not debug_on then return end
  rune.echo(paint("yellow", "[" .. NAME .. " debug] ") .. string.format(fmt, ...))
end

-- helpstyle is only needed for the help screen, so it loads on first use.
local H
local function helpstyle()
  if not H then
    local ok, m = pcall(require, "helpstyle")
    if ok and type(m) == "table" then
      H = m
    else
      H = {   -- plain fallback if helpstyle is not installed
        title   = function(t) return t end,
        section = function(t) return t end,
        line    = function(c, d) return string.format("  %-34s %s", c, d) end,
        foot    = function(t) return t end,
      }
    end
  end
  return H
end

-- Optional mapper modules (fallback outside the wilds only), loaded on first use.
local store, graph, mwalk
local function mapper_modules()
  if graph == nil then
    local ok_s, s_ = pcall(require, "mapper_store")
    local ok_g, g_ = pcall(require, "mapper_graph")
    local ok_w, w_ = pcall(require, "mapper_walk")
    if ok_s and ok_g and ok_w then store, graph, mwalk = s_, g_, w_ else graph = false end
  end
  return graph ~= false
end

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------
local MAX_X, MAX_Y = 2299, 1499   -- world size used by the old plugin
local WRAP         = true         -- world wraps east<->west / north<->south
local RETRY_SECS   = 2            -- no Room.Info this long after a step: resend
local MAX_RETRIES  = 3            -- then pause instead of spamming
local PROGRESS_EVERY = 100        -- echo progress every N steps (0 = never)
local WATCH        = "spdxy-watch"
local GROUP        = "spdxy-walk"
local KEY_PLACES   = "spdxy.places"
local KEY_LAST     = "spdxy.last"
local KEY_ORIGIN   = "spdxy.origin"
local MAX_WAYPOINTS = 100        -- cap on saved waypoints (keeps rune.store small)

-- Zones where coord.x/y are sextant coordinates (lowercase).
local VMAP_ZONES = {
  ["alyria"] = true,
  ["faerie plane wilderness"] = true,
  ["great alyrian underground"] = true,
  ["sigil underground"] = true,
  ["chat rooms wilderness"] = true,
}

----------------------------------------------------------------------
-- Built-in sextant data (from speedwalk_manager_gmcp.xml)
----------------------------------------------------------------------
-- Zone name (lowercase) -> plane key used in the tables below.
local ZONE_PLANE = {
  ["alyria"] = "alyria",
  ["faerie plane wilderness"] = "faerie",
  ["great alyrian underground"] = "underground",
  ["sigil underground"] = "sug",
}
local PLANE_LABEL = {
  alyria = "Alyria", faerie = "Faerie Plane",
  underground = "Underground", sug = "Sigil Underground",
}

-- Places: { name, x, y, plane }. Add your own lines freely.
local PLACES = {
  -- plane: alyria
  { "bazaar (west)", 818, 386, "alyria" },
  { "bazaar (north)", 816, 374, "alyria" },
  { "disturbed pyramid", 745, 263, "alyria" },
  { "dungeon avarice", 671, 572, "alyria" },
  { "dungeon wroth", 736, 391, "alyria" },
  { "gilvery (west)", 950, 356, "alyria" },
  { "gilvery (east)", 962, 356, "alyria" },
  { "hall of honor (south)", 697, 741, "alyria" },
  { "hill giant's refuge", 590, 670, "alyria" },
  { "lasler", 698, 695, "alyria" },
  { "lonely dragon inn", 600, 700, "alyria" },
  { "lowangen", 1159, 421, "alyria" },
  { "mandrake woods", 654, 365, "alyria" },
  { "new kolvir (nk)", 571, 984, "alyria" },
  { "new rigel (nr) (north)", 801, 545, "alyria" },
  { "new rigel (nr) (south)", 798, 564, "alyria" },
  { "ofstadt monastery", 1120, 330, "alyria" },
  { "old degenerates clanhall", 606, 405, "alyria" },
  { "old eclipse clan hall", 630, 935, "alyria" },
  { "old federation clanhall", 874, 236, "alyria" },
  { "rune (east)", 706, 763, "alyria" },
  { "rune (west)", 684, 760, "alyria" },
  { "rune forest", 701, 680, "alyria" },
  { "shadow castle (in mandrake woods)", 654, 365, "alyria" },
  { "tavern of the boars", 797, 445, "alyria" },
  { "thorn desert (east)", 1048, 324, "alyria" },
  { "thorn desert (west)", 1031, 316, "alyria" },
  { "tower of art (toa)", 1271, 211, "alyria" },
  { "tower of art (toa) trail", 1287, 221, "alyria" },
  { "traveler's retreat", 776, 651, "alyria" },
  { "twin moons inn", 1007, 306, "alyria" },
  { "van pelt's emporium", 669, 758, "alyria" },
  { "xaventry (north)", 607, 437, "alyria" },
  { "xaventry (south)", 602, 454, "alyria" },
  { "diocletian", 553, 1360, "alyria" },
  { "emperor's crossroads", 506, 1309, "alyria" },
  { "glarshak", 778, 1281, "alyria" },
  { "old amaunet clan hall", 824, 1234, "alyria" },
  { "old armageddon clanhall", 515, 1411, "alyria" },
  { "palamire (north)", 705, 1403, "alyria" },
  { "palamire (south)", 705, 1410, "alyria" },
  { "saucy wench tavern", 760, 1303, "alyria" },
  { "shlarksh", 813, 1201, "alyria" },
  { "sigil (north)", 435, 1226, "alyria" },
  { "sigil (south)", 436, 1238, "alyria" },
  { "teolaven", 609, 1303, "alyria" },
  { "vesuvius", 295, 1160, "alyria" },
  { "vospire (east)", 330, 1176, "alyria" },
  { "vospire (west)", 312, 1177, "alyria" },
  { "althaman", 1676, 595, "alyria" },
  { "aroxa", 1759, 630, "alyria" },
  { "begora's sanctuary", 1832, 425, "alyria" },
  { "dorathon (west)", 1691, 470, "alyria" },
  { "frost giant's keep (fgk)", 1689, 389, "alyria" },
  { "jalur", 1814, 255, "alyria" },
  { "lair of the ice witch", 1754, 266, "alyria" },
  { "muldar lohk mulvar", 1651, 183, "alyria" },
  { "ogre village", 1885, 459, "alyria" },
  { "old stargazer clanhall", 1707, 438, "alyria" },
  { "tellerium (north)", 1724, 685, "alyria" },
  { "tellerium (south)", 1716, 693, "alyria" },
  { "templeton", 1620, 542, "alyria" },
  { "winton", 1582, 392, "alyria" },
  { "angry whale", 1232, 1369, "alyria" },
  { "cenotaph directory", 1430, 1241, "alyria" },
  { "chanctonbury woods", 997, 1091, "alyria" },
  { "colyon (south)", 1386, 1037, "alyria" },
  { "colyon (west)", 1373, 1030, "alyria" },
  { "dungeon deceit", 1254, 1071, "alyria" },
  { "gorth (east)", 1646, 1227, "alyria" },
  { "gorth (west)", 1629, 1223, "alyria" },
  { "kazreal?", 1384, 1370, "alyria" },
  { "maldra keep", 1304, 1092, "alyria" },
  { "mulakanathos (south)", 1556, 1237, "alyria" },
  { "old empire clanhall", 1385, 1196, "alyria" },
  { "pirate's cove (pc) (north)", 1191, 968, "alyria" },
  { "pirate's cove (pc) (west)", 1174, 975, "alyria" },
  { "takhtin", 1020, 1210, "alyria" },
  { "xalt outpost", 1453, 1204, "alyria" },
  { "abandoned oil well", 1753, 824, "alyria" },
  { "aequtus", 374, 636, "alyria" },
  { "arcane", 926, 816, "alyria" },
  { "atlantis", 1988, 1307, "alyria" },
  { "capture the flag (ctf)", 993, 893, "alyria" },
  { "coven of kalywak", 121, 273, "alyria" },
  { "daggerwind reef", 2089, 1387, "alyria" },
  { "forsaken oil well", 1728, 842, "alyria" },
  { "frigate's end", 264, 592, "alyria" },
  { "hellbent (hb) (alyria)", 1341, 366, "alyria" },
  { "irda isle - reef entrance", 1278, 747, "alyria" },
  { "irda isle - entrance", 1299, 688, "alyria" },
  { "kalywak", 120, 268, "alyria" },
  { "maelstrom (alyria)", 1540, 742, "alyria" },
  { "magencia", 865, 834, "alyria" },
  { "naulitas", 1968, 1337, "alyria" },
  { "pelican's demise", 1579, 937, "alyria" },
  { "strange ruins", 1804, 924, "alyria" },
  { "wreck of the feisty wench (north)", 1889, 954, "alyria" },
  { "dwarven passage (pass to sug)", 477, 1426, "alyria" },
  { "labyrinth molehill (lvl-restricted pass to sug)", 536, 1258, "alyria" },
  { "mineshaft (pass to sug)", 1041, 1246, "alyria" },
  { "natural cave (pass to sug)", 795, 1205, "alyria" },
  -- plane: faerie
  { "cavhfail (faerie plane) (east)", 355, 284, "faerie" },
  { "cavhfail (faerie plane) (west)", 347, 284, "faerie" },
  { "eanoss azelmar (faerie plane)", 130, 65, "faerie" },
  { "hellbent (hb) (faerie plane)", 255, 163, "faerie" },
  { "human outpost (faerie plane)", 306, 134, "faerie" },
  { "open meadow (jasper dest) (faerie plane)", 200, 200, "faerie" },
  { "rahdiyr (faerie plane) (south)", 105, 72, "faerie" },
  { "rahdiyr (faerie plane) (west)", 102, 69, "faerie" },
  { "seelie (faerie plane)", 43, 55, "faerie" },
  { "unseelie (faerie plane) (south)", 438, 299, "faerie" },
  { "unseelie (faerie plane) (west)", 431, 293, "faerie" },
  -- plane: underground
  { "arien'dyth (underground)", 731, 262, "underground" },
  { "chattering skull tavern (underground)", 804, 767, "underground" },
  { "decara (underground)", 1579, 486, "underground" },
  { "hellbent (hb) (underground)", 1341, 366, "underground" },
  { "hotel hello (hh) (underground)", 1228, 768, "underground" },
  { "kessarian's dungeon (underground)", 1590, 985, "underground" },
  { "maelstrom (underground)", 1540, 743, "underground" },
  { "sea hag (underground)", 1111, 880, "underground" },
  { "smuggler's cave (underground)", 1598, 838, "underground" },
  { "smuggler's gulch (underground) (east)", 1193, 532, "underground" },
  { "southwest passage (sw pass) (underground)", 898, 659, "underground" },
  { "three-bearded jake's (underground)", 908, 823, "underground" },
  { "three-bearded jake's (2x xp mini) (underground)", 873, 675, "underground" },
  { "vir beach (underground)", 1426, 991, "underground" },
  { "vir (east) (underground)", 1439, 1052, "underground" },
  { "vir (west) (underground)", 1428, 1061, "underground" },
  -- plane: sug
  { "a ghost town (sigil underground)", 591, 1401, "sug" },
  { "bandit camp (sigil underground)", 1017, 1178, "sug" },
  { "darksea (sigil underground)", 919, 1232, "sug" },
  { "fiery catwalk (sigil underground)", 291, 1159, "sug" },
  { "genauras (sigil underground)", 538, 1253, "sug" },
  { "gypsy village (sigil underground)", 627, 1265, "sug" },
  { "rift between sigil and the underside (sigil underground)", 428, 1231, "sug" },
  { "shrine of dira (sigil underground) (southeast)", 632, 1387, "sug" },
  { "shrine of dira (sigil underground) (southwest)", 620, 1386, "sug" },
  { "shrine of gath (sigil underground) (east)", 468, 1401, "sug" },
  { "shrine of gath (sigil underground) (northwest)", 457, 1395, "sug" },
  { "shrine of ithrilis (sigil underground) (west)", 543, 1301, "sug" },
  { "shrine of maradas (sigil underground) (east)", 421, 1260, "sug" },
  { "shrine of vandyne (sigil underground) (east)", 590, 1365, "sug" },
  { "shrine of vandyne (sigil underground) (north)", 489, 1282, "sug" },
  { "shrine of vandyne (sigil underground) (south)", 501, 1373, "sug" },
  { "shrine of vandyne (sigil underground) (west)", 424, 1301, "sug" },
  { "troglodyte village (sigil underground)", 479, 1396, "sug" },
  -- plane: alyria
  { "arcane (rec: traveler's retreat) worldgate", 967, 699, "alyria" },
  { "black lodge (rec: tower of art) worldgate", 1301, -1, "alyria" },
  { "chanctonbury (rec: pirate's cove) worldgate", 1015, 1116, "alyria" },
  { "garbool (rec: ogre village) worldgate", 2113, 754, "alyria" },
  { "kalywak (rec: xaventry) worldgate", 118, 278, "alyria" },
  { "lowangen worldgate", 1177, 384, "alyria" },
  { "maldra (rec: deceit) worldgate", 1279, 1053, "alyria" },
  { "rune worldgate", 662, 746, "alyria" },
  { "sigil (rec: emperor's crossroads) worldgate", 502, 1281, "alyria" },
  { "templeton worldgate", 1674, 541, "alyria" },
  { "xaventry worldgate", 625, 461, "alyria" },
  -- plane: faerie
  { "seelie worldgate (faerie plane)", 76, 301, "faerie" },
  { "unseelie worldgate (faerie plane)", 389, 81, "faerie" },
  -- plane: underground
  { "decara worldgate (underground)", 1538, 430, "underground" },
  { "hotel hello (hh) worldgate (underground)", 1234, 865, "underground" },
  { "vir worldgate (underground)", 1752, 986, "underground" },
  -- plane: sug
  { "bandit camp worldgate (sigil underground)", 990, 1182, "sug" },
  { "genauras worldgate (sigil underground)", 488, 1255, "sug" },
  { "ghost town worldgate (sigil underground)", 569, 1399, "sug" },
  { "gypsy village worldgate #1 (sigil underground)", 791, 1270, "sug" },
  { "gypsy village worldgate #2 (sigil underground)", 604, 1308, "sug" },
}

-- Clan halls: { number, name, x, y }. [a] abandoned, [m] merged, [o] old,
-- [uc] under construction, [#] spot now taken by clan #.
local CLANS = {
  { 1, "Tuath Fiana (Avros)", 1716, 611 },
  { 2, "Enigma (Beltane)", 1257, 1123 },
  { 3, "Phoenix (Beltane)", 972, 1038 },
  { 4, "(Cabal)[a] (Auryn)", 294, 1127 },
  { 5, "Prophecy (Sepharia)", 1180, 233 },
  { 6, "Circle of Power (Sepharia)", 877, 611 },
  { 8, "(Excession)[a] (Avros)", 1632, 486 },
  { 9, "The Lin Kuei (Beltane)", 1262, 1005 },
  { 11, "Knighthood (Beltane)", 1370, 1235 },
  { 12, "Vigil (Sepharia)", 606, 727 },
  { 13, "SpiritWalk (Sepharia)", 643, 480 },
  { 14, "(Midwinter Equinox)[a] (Avros)", 1727, 555 },
  { 15, "Caitiff (Sepharia)", 762, 607 },
  { 18, "Sanguine (Auryn)", 369, 1215 },
  { 19, "Pollacca (Sepharia)", 566, 423 },
  { 23, "Dragon (Beltane)", 1601, 1262 },
  { 25, "(Eclipse)[o] (Sepharia)", 630, 935 },
  { 26, "(Valhalla)[a] (Sepharia)", 648, 646 },
  { 27, "Apathy (Sepharia)", 768, 481 },
  { 28, "Whisper (Sepharia)", 585, 894 },
  { 29, "(Black Tower)[a] (Auryn archipielago)", 768, 1406 },
  { 30, "New Alyrian Order (Auryn)", 536, 1295 },
  { 32, "Innuendo (Auryn)", 248, 1196 },
  { 33, "(Stargazer)[o] (Avros)", 1707, 438 },
  { 35, "Avalanche (Auryn archipielago)", 776, 1213 },
  { 36, "Power of Entropy (Sepharia)", 919, 296 },
  { 37, "Euphoria (Arcane archipielago)", 1060, 709 },
  { 41, "Oracle (Auryn)", 617, 1335 },
  { 44, "Tweaked (Sepharia)", 839, 335 },
  { 45, "Blasphemy (Beltane)", 1071, 976 },
  { 46, "(The Unforgiven)[a] (Auryn archipielago)", 731, 1403 },
  { 47, "Northstar (Auryn archipielago)", 732, 1257 },
  { 51, "(Aceldama)[o] (Avros)", 1668, 411 },
  { 52, "Diversity (Auryn)", 423, 1091 },
  { 53, "(Revelations)[o] (Sepharia)", 1209, 356 },
  { 55, "(Degenerates)[o] (Sepharia)", 606, 405 },
  { 56, "(Eyes of the Dragon)[a] (Sepharia)", 1076, 342 },
  { 57, "The Hostile Crew (Beltane)", 1551, 995 },
  { 59, "(Empire)[o] (Beltane)", 1385, 1196 },
  { 67, "(Transcend)[uc] (Beltane)", 1054, 1156 },
  { 75, "Supremacy (Sepharia)", 690, 483 },
  { 79, "Far Dareis Mais (Auryn)", 618, 1252 },
  { 80, "(Federation)[o] (Sepharia)", 874, 233 },
  { 81, "Knights of Chaos (Auryn archipielago)", 439, 1329 },
  { 88, "(Vampire's Mask)[o] (Auryn)", 200, 1176 },
  { 90, "Ahriman's Army (Beltane)", 1249, 1292 },
  { 92, "The Cwn Annwn (Sepharia)", 714, 575 },
  { 93, "Amaunet (Auryn archipielago)", 782, 1401 },
  { 93, "Amaunet[o] (Auryn archipielago)", 824, 1234 },
  { 94, "(The Higher Power)[a] (Avros)", 1608, 421 },
  { 95, "(Kizaran Alliance)[a] (Avros)", 1839, 547 },
  { 99, "Odyssey (Auryn archipielago)", 809, 1298 },
  { 102, "(The Chosen)[a] (Auryn)", 264, 1224 },
  { 103, "Eternal Darkness (Sepharia)", 1254, 290 },
  { 108, "Guardians (Auryn)", 526, 1334 },
  { 109, "Legacy (Sepharia)", 739, 499 },
  { 110, "Timeworn (Auryn)", 245, 1134 },
  { 112, "(Armageddon)[o] (Auryn)", 515, 1411 },
  { 114, "Crypt (Sepharia)", 788, 387 },
  { 115, "(The Dark Order)[a] (Avros)", 1767, 372 },
  { 116, "(The Betrayed)[a] (Avros)", 1578, 305 },
  { 117, "(The Returners)[a] (Auryn archipielago)", 718, 1421 },
  { 118, "(Saresyn's Revenge)[a] (Sepharia)", 749, 457 },
  { 119, "(Paradigm)[a] (Beltane)", 1130, 1005 },
  { 120, "Mercenaries of War (Sepharia)", 788, 345 },
  { 121, "The Lion's Den (Beltane)", 1161, 1227 },
  { 123, "(Allegiance)[a] (Avros)", 1799, 638 },
  { 124, "(Arbiters of Fate)[a] (Beltane archipielago)", 1775, 1078 },
  { 127, "(The Ministry)[a] (Auryn archipielago)", 746, 1415 },
  { 129, "Insurrection (Beltane)", 1390, 1375 },
  { 130, "(Spira Devexa)[o] (Auryn archipielago)", 806, 1265 },
  { 131, "(Pandemonium)[o] (Avros)", 1736, 483 },
  { 132, "Heirs of Tuireann (Sepharia)", 975, 175 },
  { 134, "(Moonlight Requiem)[a] (Sepharia)", 530, 224 },
  { 135, "Suppression (Beltane)", 1447, 1363 },
  { 136, "(Perdition's Flame)[a] (Sepharia)", 997, 166 },
  { 138, "(Separatists)[o] (Auryn)", 368, 1262 },
  { 139, "Wonderland (Beltane)", 1311, 961 },
  { 140, "Alpha et Omega (Sepharia)", 1097, 163 },
  { 141, "Nemesis (Auryn)", 594, 1379 },
  { 143, "Order of Twilight (Sepharia)", 926, 377 },
  { 148, "Relentless (Beltane)", 1393, 1389 },
  { 149, "Fortuna Umbra (Auryn)", 629, 1379 },
  { 150, "KD Brotherhood (Sepharia)", 716, 543 },
  { 151, "Sad Panda (Auryn)", 558, 1390 },
  { 152, "Knights of Order (Auryn)", 364, 1141 },
  { 155, "Awesome (Beltane)", 994, 1167 },
}

----------------------------------------------------------------------
-- Geometry helpers
----------------------------------------------------------------------
-- x grows east, y grows south.
local DIRS = {
  { "n",   0, -1 }, { "ne",  1, -1 }, { "e",  1, 0 }, { "se",  1, 1 },
  { "s",   0,  1 }, { "sw", -1,  1 }, { "w", -1, 0 }, { "nw", -1, -1 },
}
local IDX, HEAD = {}, {}
for i, d in ipairs(DIRS) do
  IDX[d[1]] = i
  HEAD[d[2] .. "," .. d[3]] = i
end
local LONG = {
  north = "n", northeast = "ne", east = "e", southeast = "se",
  south = "s", southwest = "sw", west = "w", northwest = "nw",
}

local function sign(n) return n > 0 and 1 or (n < 0 and -1 or 0) end

local function key(x, y)
  return string.format("%d,%d", math.floor(x), math.floor(y))
end

-- Signed shortest displacement a -> b on an axis (wraps when WRAP is on).
local function delta(a, b, max)
  local d = b - a
  if WRAP then
    local ad = math.abs(d)
    if ad > max / 2 then
      local r = math.max(max - ad, 1)
      d = (d > 0) and -r or r
    end
  end
  return d
end

local function opposite(dir)
  local i = IDX[dir]
  if not i then return nil end
  return DIRS[((i - 1 + 4) % 8) + 1][1]
end

local function plane_of_zone(zone)
  return zone and ZONE_PLANE[string.lower(tostring(zone))] or nil
end

local function in_vmap(zone)
  return zone ~= nil and VMAP_ZONES[string.lower(tostring(zone))] == true
end

-- Set of available compass exits from a Room.Info exits table, or nil when
-- the format is unknown / has no compass exits (then no filtering is done).
local function exit_set(exits)
  if type(exits) ~= "table" then return nil end
  local set, n = {}, 0
  for k in pairs(exits) do
    local s = tostring(k):lower()
    s = LONG[s] or s
    if IDX[s] then set[s] = true; n = n + 1 end
  end
  if n == 0 then return nil end
  return set
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

----------------------------------------------------------------------
-- Persistent data (waypoints, last destination)
----------------------------------------------------------------------
local function load_table(k)
  local ok, v = pcall(rune.store.get, k)
  if ok and type(v) == "table" then return v end
  return {}
end

local function save_table(k, t)
  pcall(rune.store.set, k, t)
end

-- Saved data is read from rune.store on first use, not at load.
local D
local function data()
  if not D then
    D = {
      places = load_table(KEY_PLACES),   -- waypoints: name -> { x =, y =, plane = }
      target = load_table(KEY_LAST),     -- last destination { x =, y = }
      origin = load_table(KEY_ORIGIN),   -- start of the last walk { x =, y =, plane = }
    }
  end
  return D
end

local function count_places()
  local n = 0
  for _ in pairs(data().places) do n = n + 1 end
  return n
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local last = {}   -- latest Room.Info: x, y, zone, plane, exits, num
local S = nil     -- active walk, or nil

-- One combined trigger (obstacles, water, teleports, gusts, mount, combat). It is
-- registered at the first walk, then its group is enabled only while walking.
local on_walk_line   -- handler, defined in the Triggers section below
local TRIG_NAME = "spdxy-walk-lines"
local TRIG_PATTERN = [[^(?:You cannot move in that direction\.|You would surely need a grappling hook to move there\.|You can't go there while mounted\.|You need a sailing vessel to go there\.|The .+ (?:is|are) closed\.|The water current is too swift and turbulent for (?:you|your mount) to cross\.|You would need a sailing vessel or some form of levitation to go there\.|You would need a water-breathing mount to go there mounted\.|A swirling vortex of sound and energy envelops you|You hear a peal of thunder from afar\.\.|A sudden, strong gust of wind knocks you to the ground!|Your mount is sitting down\.|Not while you are in combat\.)]]
local trig_ready = false

local function set_triggers(on)
  if on and not trig_ready then
    rune.trigger.regex(TRIG_PATTERN, on_walk_line, { name = TRIG_NAME, group = GROUP })
    trig_ready = true
  end
  local fn = rune.group and (on and rune.group.enable or rune.group.disable)
  if fn then pcall(fn, GROUP) end
end

local function cleanup()
  S = nil
  pcall(rune.timer.cancel, WATCH)
  set_triggers(false)
end

local function abort(msg)
  if msg then say(msg) end
  cleanup()
end

local function pause(msg)
  if not S then return end
  S.paused = true
  S.pending = false
  say(msg)
  say(string.format("'%s resume' to continue, '%s stop' to cancel.", SHORT, SHORT))
end

----------------------------------------------------------------------
-- Step selection
----------------------------------------------------------------------
local function pick_step(x, y, want, exits, bad)
  local best, best_score
  for i, d in ipairs(DIRS) do
    local name = d[1]
    local usable = not (bad and bad[name]) and not (exits and not exits[name])
    if usable then
      local diff = math.abs(i - want)
      if diff > 4 then diff = 8 - diff end
      local nx, ny = x + d[2], y + d[3]
      local v = S.visits[key(nx, ny)] or 0
      local left = math.abs(delta(nx, S.tx, MAX_X)) + math.abs(delta(ny, S.ty, MAX_Y))
      local score = diff * 2 + v * 3 + left * 0.01
      if not best_score or score < best_score then
        best, best_score = name, score
      end
    end
  end
  return best
end

local function finish()
  local secs = os.time() - S.started
  say(string.format("arrived at %d, %d (%d steps, %ds).",
    S.tx, S.ty, S.steps, secs))
  cleanup()
end

local function advance()
  if not S or S.paused then return end
  local x, y = last.x, last.y
  if not x then abort("lost position (no coordinates); walk aborted."); return end

  if x == S.tx and y == S.ty then finish(); return end

  if S.steps >= S.max_steps then
    abort(string.format("step limit (%d) reached at %d, %d; walk aborted.",
      S.max_steps, x, y))
    return
  end

  local ddx, ddy = delta(x, S.tx, MAX_X), delta(y, S.ty, MAX_Y)
  local want = HEAD[sign(ddx) .. "," .. sign(ddy)]
  if not want then
    abort(string.format("could not work out a direction from %d, %d; aborted.", x, y))
    return
  end

  local k = key(x, y)
  local dir = pick_step(x, y, want, exit_set(last.exits), S.bad[k])
  if not dir then
    pause(string.format("no usable exit from %d, %d (all blocked).", x, y))
    return
  end

  S.pending, S.from, S.dir = true, k, dir
  S.sent_at = os.time()
  S.steps = S.steps + 1
  dbg("step %d: %s from %d, %d (target %d, %d)", S.steps, dir, x, y, S.tx, S.ty)
  if PROGRESS_EVERY > 0 and S.steps % PROGRESS_EVERY == 0 then
    say(string.format("at %d, %d - about %d steps to go.",
      x, y, math.max(math.abs(ddx), math.abs(ddy))))
  end
  rune.send(dir)
end

-- A step failed: remember it for this position and try another direction.
local function blocked()
  if not S or S.paused or not S.pending then return end
  local b = S.bad[S.from]
  if not b then b = {}; S.bad[S.from] = b end
  b[S.dir] = true
  dbg("blocked: %s at %s", S.dir, S.from)
  S.pending = false
  S.retries = 0
  advance()
end

----------------------------------------------------------------------
-- Starting a walk
----------------------------------------------------------------------
local function room_xy(room)
  local c = room and room.coord
  if type(c) ~= "table" then return nil end
  local x, y = tonumber(c.x or c[1]), tonumber(c.y or c[2])
  if x == nil or y == nil then return nil end
  return x, y
end

-- Fallback outside the wilds: walk (via the mapper) to a MAPPED room whose
-- stored coordinates match exactly.
local function mapper_goto_xy(dx, dy)
  dbg("outside the wilds (zone=%s): mapper lookup for %d, %d", tostring(last.zone), dx, dy)
  if not mapper_modules() then
    say("you are not in the wilds, and the mapper modules are not available.")
    return
  end
  local from = store.position and store.position.uid
  if not from or not store.rooms[from] then
    say("I don't know where you are (mapper has no position).")
    return
  end

  local function walk_to_uid(dest)
    dest = tostring(dest)
    local cur = store.position and store.position.uid
    if not cur then say("I don't know where you are."); return end
    local m, exhausted = graph.find_paths(cur, function(uid)
      if uid == dest then return "dest" end
      return nil
    end)
    local data = m[dest]
    if not data then
      say("no mapped path to " .. dest ..
        (exhausted and " (depth limit hit; try 'mapper depth inf')" or ""))
      return
    end
    if #data.path == 0 then say("already here."); return end
    say("-> " .. dest .. " (" .. #data.path .. " steps): " ..
      graph.build_speedwalk(data.path))
    if rune.store.get("mapper.enable_speedwalk_sends") == false then
      say("(sends disabled; `mapper sends on` to enable)")
      return
    end
    mwalk.start(data.path, dest)
  end

  local found = graph.find_paths(from, function(uid, room)
    local x, y = room_xy(room)
    if x == dx and y == dy then return "xy" end
    return nil
  end)
  local list = {}
  for uid, data in pairs(found) do
    list[#list + 1] = { uid = uid, room = store.rooms[uid], steps = #data.path }
  end
  table.sort(list, function(a, b)
    if a.steps ~= b.steps then return a.steps < b.steps end
    return tostring(a.uid) < tostring(b.uid)
  end)

  if #list == 0 then
    say(string.format(
      "not in the wilds and no reachable mapped room at %d, %d. " ..
      "Walk out to the wilds first.", dx, dy))
  elseif #list == 1 then
    walk_to_uid(list[1].uid)
  else
    local items = {}
    for i = 1, math.min(#list, 200) do
      local h = list[i]
      items[#items + 1] = {
        text = h.room.name or ("#" .. h.uid),
        desc = h.uid .. "  " .. h.steps .. " steps  " .. tostring(h.room.area or ""),
        value = h.uid,
      }
    end
    rune.ui.picker.show({
      title = string.format("Rooms at %d, %d (%d)", dx, dy, #list),
      items = items,
      on_select = walk_to_uid,
    })
  end
end

-- Kept as a global (same name as the old XML helper) for other plugins.
function speed_to_x_y(destx, desty)
  local tx, ty = tonumber(destx), tonumber(desty)
  if not tx or not ty then
    say("Usage: " .. SHORT .. " <x> [,] <y>")
    return
  end

  if not enabled then
    say("disabled; type '" .. NAME .. " on' to enable walking.")
    return
  end

  if not last.x then
    say("no position from GMCP yet; move one room (or look) and try again.")
    return
  end

  data().target = { x = tx, y = ty }
  save_table(KEY_LAST, data().target)

  if not in_vmap(last.zone) then
    mapper_goto_xy(tx, ty)
    return
  end

  if S then
    say("replacing the walk to " .. S.tx .. ", " .. S.ty .. ".")
    cleanup()
  end

  if last.x == tx and last.y == ty then
    say("already at " .. tx .. ", " .. ty .. ".")
    return
  end

  local steps = math.max(math.abs(delta(last.x, tx, MAX_X)),
                         math.abs(delta(last.y, ty, MAX_Y)))
  S = {
    tx = tx, ty = ty, zone = last.zone,
    visits = { [key(last.x, last.y)] = 1 },
    bad = {}, steps = 0, retries = 0,
    max_steps = steps * 2 + 200,
    started = os.time(),
    pending = false, paused = false,
  }
  data().origin = { x = last.x, y = last.y, plane = plane_of_zone(last.zone) }
  save_table(KEY_ORIGIN, data().origin)
  dbg("start: zone=%s plane=%s from %d, %d to %d, %d", tostring(last.zone), tostring(plane_of_zone(last.zone)), last.x, last.y, tx, ty)
  set_triggers(true)
  say(string.format("walking from %d, %d to %d, %d (~%d steps)...",
    last.x, last.y, tx, ty, steps))

  -- Watchdog: resend the step if no Room.Info arrives, pause after a few tries.
  rune.timer.every(1, function()
    if not S or S.paused or not S.pending then return end
    if os.time() - S.sent_at < RETRY_SECS then return end
    S.retries = S.retries + 1
    dbg("no Room.Info; retry %d resending %s", S.retries, S.dir)
    if S.retries > MAX_RETRIES then
      pause(string.format("no movement after %d retries at %d, %d.", MAX_RETRIES, last.x, last.y))
      return
    end
    S.sent_at = os.time()
    rune.send(S.dir)
  end, { name = WATCH })

  advance()
end

----------------------------------------------------------------------
-- GMCP
----------------------------------------------------------------------
rune.gmcp.subscribe("Room")

rune.gmcp.on("Room.Info", function(data)
  if type(data) ~= "table" then return end

  local c = data.coord
  local x, y
  if type(c) == "table" then x, y = tonumber(c.x), tonumber(c.y) end

  last.x, last.y = x, y
  last.plane = type(c) == "table" and c.name or nil
  last.zone = data.zone or data.area
  last.exits = data.exits
  last.num = data.num

  if not S then return end
  dbg("room %s, %s zone=%s", tostring(x), tostring(y), tostring(last.zone))

  if not x then
    abort("this room has no coordinates; walk aborted.")
    return
  end

  local k = key(x, y)
  if S.pending and k == S.from then return end   -- no movement (e.g. a refresh)
  S.pending = false
  S.retries = 0
  if S.paused then return end

  -- Left the wilds (entered a building / other zone): step back and stop.
  if S.zone and last.zone and tostring(last.zone) ~= tostring(S.zone) then
    local back = opposite(S.dir)
    abort("entered '" .. tostring(last.zone) .. "'; stepping back and aborting.")
    if back then rune.send(back) end
    return
  end

  S.visits[k] = (S.visits[k] or 0) + 1
  advance()
end, { name = "spdxy-room-info" })

----------------------------------------------------------------------
-- Triggers (one combined trigger; enabled only while a walk is active)
----------------------------------------------------------------------
on_walk_line = function(_, ctx)
  if not S then return end
  local ok, text = pcall(function() return ctx.line:clean() end)
  if not ok or type(text) ~= "string" then return end
  dbg("trigger: %s", text)
  if text:find("water current", 1, true) or text:find("levitation", 1, true)
     or text:find("water-breathing", 1, true) then
    if not S.paused then pause("water ahead.") end
  elseif text:find("swirling vortex", 1, true) or text:find("peal of thunder", 1, true) then
    abort("teleported/recalled; walk aborted.")
  elseif text:find("strong gust", 1, true) then
    if S.pending then rune.send("stand"); S.sent_at = os.time() end
  elseif text:find("mount is sitting", 1, true) then
    rune.send("sayto mount stand")
  elseif text:find("in combat", 1, true) then
    if not S.paused then pause("you are in combat.") end
  else
    blocked()   -- cannot move / grappling hook / mounted / sailing vessel / closed
  end
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local function status_row()
  local walk = "idle"
  if S then walk = string.format("%d,%d%s", S.tx, S.ty, S.paused and "(paused)" or "") end
  local load = load_ms < 0.5 and "<1ms" or string.format("%dms", math.floor(load_ms + 0.5))
  return string.format("v%s  enabled=%s debug=%s places=%d clans=%d waypoints=%d walk=%s load=%s",
    VERSION, tostring(enabled), tostring(debug_on), #PLACES, #CLANS, count_places(), walk, load)
end

local function help()
  local H = helpstyle()
  emit(H.title(NAME .. " - walk to sextant coordinates, towns and clan halls"))
  emit(H.section("Walk:"))
  emit(H.line(SHORT .. " <x>, <y>", "walk to coordinates (comma optional)"))
  emit(H.line(SHORT .. " <town>", "town, landmark, worldgate or waypoint"))
  emit(H.line(SHORT .. " clan <name|#>", "walk to a clan hall"))
  emit(H.line(SHORT .. " again | back", "last destination | last start"))
  emit(H.line(SHORT .. " stop | pause | resume", "control the walk"))
  emit(H.section("Look up:"))
  emit(H.line(SHORT .. " nearby [x, y]", "nearest known place (also: nearby)"))
  emit(H.line(SHORT .. " find <text>", "list matching places and clan halls"))
  emit(H.line(SHORT .. " here", "your coordinates, zone and exits"))
  emit(H.section("Waypoints:"))
  emit(H.line(SHORT .. " save <name> [x y]", "save this spot or given coordinates"))
  emit(H.line(SHORT .. " del <name> | list", "delete a waypoint | list them"))
  emit(H.section("Settings:"))
  emit(H.line(NAME .. " on | off", "enable or disable walking"))
  emit(H.line(NAME .. " debug on | off", "verbose walk and lookup messages"))
  emit(H.line(SHORT, "short alias for " .. NAME))
  emit(H.foot(status_row()))
end

local function parse_xy(s)
  local a, b = s:match("^(-?%d+)%s*,%s*(-?%d+)$")
  if not a then a, b = s:match("^(-?%d+)%s+(-?%d+)$") end
  return a, b
end

-- Plane (see ZONE_PLANE) of the zone you are standing in, or nil.
local function cur_plane()
  return plane_of_zone(last.zone)
end

-- Distance in steps from your position (diagonals count as one), or nil.
local function dist_from_here(x, y)
  if not last.x then return nil end
  return math.max(math.abs(delta(last.x, x, MAX_X)), math.abs(delta(last.y, y, MAX_Y)))
end

local function words_of(q)
  local w = {}
  for t in q:lower():gmatch("%S+") do w[#w + 1] = t end
  return w
end

-- True when `w` occurs in `n` starting at a word boundary ("vir" matches
-- "vir (east)" but not "kolvir"). With loose = true any substring counts.
local function word_found(n, w, loose)
  local init = 1
  while true do
    local s = n:find(w, init, true)
    if not s then return false end
    if loose or s == 1 or not n:sub(s - 1, s - 1):match("%w") then return true end
    init = s + 1
  end
end

-- True when every word of the query is found in the name (any order).
local function name_matches(name, words, loose)
  local n = name:lower()
  for _, w in ipairs(words) do
    if not word_found(n, w, loose) then return false end
  end
  return true
end

-- Entries: { name =, x =, y =, plane =, src = "waypoint" | "place" | "clan" }
-- A query of only digits matches a clan hall number exactly.
local function collect(q, with_places, with_clans, with_waypoints, loose)
  local words = words_of(q)
  local list = {}
  if #words == 0 then return list end
  if with_waypoints then
    for n, p in pairs(data().places) do
      if name_matches(n, words, loose) then
        list[#list + 1] = { name = n, x = p.x, y = p.y, plane = p.plane, src = "waypoint" }
      end
    end
  end
  if with_places then
    for _, p in ipairs(PLACES) do
      if name_matches(p[1], words, loose) then
        list[#list + 1] = { name = p[1], x = p[2], y = p[3], plane = p[4], src = "place" }
      end
    end
  end
  if with_clans then
    local num = q:match("^%s*(%d+)%s*$")
    num = num and tonumber(num)
    for _, c in ipairs(CLANS) do
      local hit
      if num then hit = (c[1] == num) else hit = name_matches(c[2], words, loose) end
      if hit then
        list[#list + 1] = {
          name = string.format("%s [%d]", c[2], c[1]),
          x = c[3], y = c[4], plane = "alyria", src = "clan",
        }
      end
    end
  end
  return list
end

-- Word-start matching first; if that finds nothing, any substring.
local function search(q, with_places, with_clans, with_waypoints)
  local list = collect(q, with_places, with_clans, with_waypoints, false)
  if #list == 0 then list = collect(q, with_places, with_clans, with_waypoints, true) end
  return list
end

local function by_distance(list)
  table.sort(list, function(a, b)
    local da, db = dist_from_here(a.x, a.y) or 0, dist_from_here(b.x, b.y) or 0
    if da ~= db then return da < db end
    return a.name < b.name
  end)
end

local function go_entry(e)
  local plane = cur_plane()
  if plane and e.plane and e.plane ~= plane then
    say(string.format("%s is on %s but you are on %s.",
      e.name, PLANE_LABEL[e.plane] or e.plane, PLANE_LABEL[plane] or plane))
    return
  end
  say(string.format("-> %s (%d, %d)", e.name, e.x, e.y))
  speed_to_x_y(e.x, e.y)
end

local function entry_desc(e)
  local parts = { string.format("%d, %d", e.x, e.y) }
  if e.plane then parts[#parts + 1] = PLANE_LABEL[e.plane] or e.plane end
  local d = dist_from_here(e.x, e.y)
  if d and (not e.plane or e.plane == cur_plane()) then
    parts[#parts + 1] = "~" .. d .. " steps"
  end
  if e.src == "waypoint" then parts[#parts + 1] = "waypoint" end
  return table.concat(parts, "  ")
end

local function show_picker(title, list)
  local items = {}
  for i = 1, math.min(#list, 100) do
    items[#items + 1] = { text = list[i].name, desc = entry_desc(list[i]), value = tostring(i) }
  end
  rune.ui.picker.show({
    title = string.format("%s (%d)", title, #list),
    items = items,
    on_select = function(v)
      local e = list[tonumber(v)]
      if e then go_entry(e) end
    end,
  })
end

-- Resolve a name to a destination: exact name wins, one match walks,
-- several open a picker (nearest first). Only your current plane is used.
local function goto_query(q, clans_only)
  q = trim(q)
  local list
  if clans_only then
    list = search(q, false, true, false)
  else
    list = search(q, true, false, true)
    if #list == 0 then list = search(q, false, true, false) end  -- e.g. a clan name
  end
  dbg("query '%s': %d candidate(s)", q, #list)
  if #list == 0 then
    say("nothing matches '" .. q .. "'. Try '" .. SHORT .. " find " .. q .. "' or '" .. SHORT .. " help'.")
    return
  end

  local plane = cur_plane()
  if plane then
    local same = {}
    for _, e in ipairs(list) do
      if e.plane == nil or e.plane == plane then same[#same + 1] = e end
    end
    if #same == 0 then
      say(string.format("'%s' is only known on other planes (you are on %s):",
        q, PLANE_LABEL[plane] or plane))
      by_distance(list)
      for i = 1, math.min(#list, 10) do
        rune.echo("  " .. list[i].name .. "  " .. entry_desc(list[i]))
      end
      return
    end
    list = same
  end

  local ql = q:lower()
  local exact = {}
  for _, e in ipairs(list) do
    if e.name:lower() == ql then exact[#exact + 1] = e end
  end
  if #exact > 0 then list = exact end

  by_distance(list)
  if #list == 1 then
    go_entry(list[1])
  else
    show_picker(SHORT .. ": " .. q, list)
  end
end

local function cmd_find(q)
  q = trim(q)
  if q == "" then say("Usage: " .. SHORT .. " find <text>"); return end
  local list = search(q, true, true, true)
  if #list == 0 then say("nothing matches '" .. q .. "'."); return end
  table.sort(list, function(a, b)
    if a.src ~= b.src then return a.src < b.src end
    return a.name < b.name
  end)
  say(string.format("%d match(es) for '%s':", #list, q))
  for i = 1, math.min(#list, 60) do
    local e = list[i]
    rune.echo(string.format("  %-44s %d, %d  %s", e.name, e.x, e.y,
      PLANE_LABEL[e.plane] or (e.src == "waypoint" and "waypoint" or "")))
  end
  if #list > 60 then rune.echo(string.format("  ... and %d more; narrow the search.", #list - 60)) end
end

local function sorted_names()
  local names = {}
  for n in pairs(data().places) do names[#names + 1] = n end
  table.sort(names)
  return names
end

-- Waypoint names: no control characters (terminal escapes), one space between
-- words, at most 40 characters, lowercase.
local function clean_name(s)
  s = s:gsub("%c", ""):gsub("%s+", " ")
  return trim(s):sub(1, 40):lower()
end

local function cmd_save(rest)
  local places = data().places
  local name, sx, sy = rest:match("^(.-)%s+(-?%d+)%s*,?%s*(-?%d+)$")
  local x, y, plane
  if name and name ~= "" then
    x, y = tonumber(sx), tonumber(sy)
  else
    name = rest
    x, y = last.x, last.y
    plane = cur_plane()   -- remembered so names only match on that plane
  end
  name = clean_name(name)
  if name == "" then say("Usage: " .. SHORT .. " save <name> [<x> <y>]"); return end
  if not x then
    say("no current coordinates; give them: " .. SHORT .. " save <name> <x> <y>")
    return
  end
  if not places[name] and count_places() >= MAX_WAYPOINTS then
    say(string.format("waypoint limit (%d) reached; remove one with: %s del <name>", MAX_WAYPOINTS, SHORT))
    return
  end
  places[name] = { x = x, y = y, plane = plane }
  save_table(KEY_PLACES, places)
  say(string.format("saved '%s' = %d, %d", name, x, y))
end

local function cmd_del(rest)
  local places = data().places
  local name = clean_name(rest)
  if name == "" then say("Usage: " .. SHORT .. " del <name>"); return end
  if not places[name] then say("no waypoint '" .. name .. "'."); return end
  places[name] = nil
  save_table(KEY_PLACES, places)
  say("deleted '" .. name .. "'.")
end

local function cmd_list()
  local places = data().places
  local names = sorted_names()
  if #names == 0 then
    say("no waypoints saved. Use: " .. SHORT .. " save <name>")
    return
  end
  say("waypoints:")
  for _, n in ipairs(names) do
    rune.echo(string.format("  %-24s %d, %d", n, places[n].x, places[n].y))
  end
end

local function cmd_here()
  if not last.x then
    say("no coordinates yet (move one room or look).")
    return
  end
  say(string.format("you are at %d, %d  zone=%s  plane=%s  wilds=%s",
    last.x, last.y, tostring(last.zone), tostring(last.plane),
    in_vmap(last.zone) and "yes" or "no"))
  local ex = {}
  if type(last.exits) == "table" then
    for k in pairs(last.exits) do ex[#ex + 1] = tostring(k) end
    table.sort(ex)
  end
  say("exits: " .. (#ex > 0 and table.concat(ex, " ") or "(none reported)"))
end

local function cmd_resume()
  if not S or not S.paused then say("nothing to resume."); return end
  if S.zone and last.zone and tostring(last.zone) ~= tostring(S.zone) then
    abort("you are no longer in '" .. tostring(S.zone) .. "'; walk cancelled.")
    return
  end
  S.paused, S.pending, S.retries = false, false, 0
  say(string.format("resuming to %d, %d.", S.tx, S.ty))
  advance()
end

-- 8-way compass bearing for a displacement (x grows east, y grows south).
local function compass(ddx, ddy)
  local ax, ay = math.abs(ddx), math.abs(ddy)
  if ax == 0 and ay == 0 then return "" end
  local v = ddy < 0 and "n" or "s"
  local h = ddx > 0 and "e" or "w"
  if ay <= ax * 0.4142 then return h end
  if ax <= ay * 0.4142 then return v end
  return v .. h
end

-- Closest known place / clan hall / waypoint to X,Y (default: your position).
-- Only entries on your current plane are considered when it is known.
local function cmd_nearby(rest)
  rest = trim(rest)
  local qx, qy
  if rest == "" then
    qx, qy = last.x, last.y
    if not qx then say("no coordinates yet (move one room or look)."); return end
  else
    local a, b = parse_xy(rest)
    if not a then say("Usage: " .. SHORT .. " nearby [<x>, <y>]"); return end
    qx, qy = tonumber(a), tonumber(b)
  end

  local plane = cur_plane()
  local cands = {}
  local function add(name, x, y, pl, src)
    if plane and pl and pl ~= plane then return end
    local ddx, ddy = delta(qx, x, MAX_X), delta(qy, y, MAX_Y)
    cands[#cands + 1] = {
      name = name, x = x, y = y, src = src, ddx = ddx, ddy = ddy,
      steps = math.max(math.abs(ddx), math.abs(ddy)),
      sq = ddx * ddx + ddy * ddy,
    }
  end
  for n, p in pairs(data().places) do add(n, p.x, p.y, p.plane, "waypoint") end
  for _, p in ipairs(PLACES) do add(p[1], p[2], p[3], p[4], "place") end
  for _, c in ipairs(CLANS) do
    add(string.format("%s [%d]", c[2], c[1]), c[3], c[4], "alyria", "clan hall")
  end

  if #cands == 0 then say("no known locations to compare."); return end
  dbg("nearby %d, %d: %d candidate(s)", qx, qy, #cands)
  table.sort(cands, function(a, b)
    if a.steps ~= b.steps then return a.steps < b.steps end
    if a.sq ~= b.sq then return a.sq < b.sq end
    return a.name < b.name
  end)

  local function line(e)
    local where
    if e.steps == 0 then
      where = "right there"
    else
      where = string.format("%d steps %s", e.steps, compass(e.ddx, e.ddy))
    end
    local tag = (e.src == "place") and "" or ("  [" .. e.src .. "]")
    return string.format("%s at %d, %d - %s%s", e.name, e.x, e.y, where, tag)
  end

  say(string.format("nearest to %d, %d%s: %s", qx, qy,
    plane and (" (" .. (PLANE_LABEL[plane] or plane) .. ")") or "", line(cands[1])))
  if #cands > 1 then
    say("also close:")
    for i = 2, math.min(#cands, 4) do rune.echo("  " .. line(cands[i])) end
  end
end

local function cmd_back()
  local last_origin = data().origin
  if not last_origin.x then say("no previous walk to go back from."); return end
  local plane = cur_plane()
  if plane and last_origin.plane and plane ~= last_origin.plane then
    say(string.format("your last start was on %s but you are on %s.",
      PLANE_LABEL[last_origin.plane] or last_origin.plane, PLANE_LABEL[plane] or plane))
    return
  end
  say(string.format("-> back to %d, %d", last_origin.x, last_origin.y))
  speed_to_x_y(last_origin.x, last_origin.y)
end

local function cmd_enable(on)
  enabled = on
  rune.store.set(KEY_ENABLED, on)
  if not on then
    if S then abort("walk cancelled.") end
    set_triggers(false)
  end
  say("walking " .. (on and "enabled" or "disabled (lookups still work)"))
end

local function cmd_debug(arg)
  arg = trim(arg):lower()
  if arg == "on" then debug_on = true
  elseif arg == "off" then debug_on = false
  elseif arg ~= "" then say("Usage: " .. NAME .. " debug on|off"); return end
  rune.store.set(KEY_DEBUG, debug_on)
  say("debug " .. (debug_on and "on" or "off"))
end

local function dispatch(arg)
  arg = trim(arg or "")
  dbg("command: %s", arg == "" and "(bare)" or arg)
  if arg == "" then help(); return end

  local x, y = parse_xy(arg)
  if x then speed_to_x_y(x, y); return end

  if arg:match("^-?%d+$") then
    say(string.format("one number is ambiguous: use '%s <x> <y>' or '%s clan <number>'.", SHORT, SHORT))
    return
  end

  local cmd, rest = arg:match("^(%S+)%s*(.-)$")
  cmd = cmd:lower()

  if cmd == "help" then help()
  elseif cmd == "on" or cmd == "off" then cmd_enable(cmd == "on")
  elseif cmd == "debug" then cmd_debug(rest)
  elseif cmd == "stop" or cmd == "abort" then
    if S then abort("walk cancelled.") else say("no walk in progress.") end
  elseif cmd == "pause" then
    if S and not S.paused then pause("paused.") else say("nothing to pause.") end
  elseif cmd == "resume" then cmd_resume()
  elseif cmd == "here" then cmd_here()
  elseif cmd == "again" or cmd == "last" then
    local t = data().target
    if t.x then
      speed_to_x_y(t.x, t.y)
    else
      say("no previous destination.")
    end
  elseif cmd == "save" or cmd == "set" then cmd_save(rest)
  elseif cmd == "del" or cmd == "delete" or cmd == "rm" then cmd_del(rest)
  elseif cmd == "list" or cmd == "places" then cmd_list()
  elseif cmd == "find" or cmd == "sextant" then cmd_find(rest)
  elseif cmd == "nearby" or cmd == "near" then cmd_nearby(rest)
  elseif cmd == "back" then cmd_back()
  elseif cmd == "clan" or cmd == "clanhall" then
    if trim(rest) == "" then say("Usage: " .. SHORT .. " clan <name|number>") else goto_query(rest, true) end
  else goto_query(arg, false)
  end
end

-- Aliases (typed bare, no leading slash). The bare forms are rune.alias.exact
-- handlers taking (args, ctx); every form with arguments is ONE regex alias.
-- Both go through dispatch() so commands and place names cannot collide.
local function show_help(args, ctx) help() end
rune.alias.exact(NAME, show_help, { name = NAME })
rune.alias.exact(SHORT, show_help, { name = SHORT })
rune.alias.exact("nearby", function(args, ctx) cmd_nearby("") end, { name = "nearby" })
rune.alias.regex("^(" .. NAME .. "|" .. SHORT .. "|nearby)[ ]+(.+)$", function(m)
  if m[1] == "nearby" then cmd_nearby(m[2] or "") else dispatch(m[2] or "") end
end, { name = SHORT .. "-args" })

-- One row on load.
load_ms = (os.clock() - T0) * 1000
say(string.format("v%s loaded (%s or %s for help)%s", VERSION, NAME, SHORT, enabled and "" or " - walking disabled"))