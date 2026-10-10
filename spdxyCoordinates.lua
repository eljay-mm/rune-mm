-- Filename: eljayPlugins/spdxyCoordinates.lua
-- Purpose: Walk to sextant coordinates (X,Y), including unmapped wilderness
-- Inspired by the MUSHclient plugin by Ruthgul
-- Version: 3.3 (v3.2 + nearby, back)
-- Date: 2026-Oct-09
--
-- How it works (in the wilds / "vmap" zones):
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
--   * Named waypoints (spdxy save <name>) and the last destination
--     (spdxy again) are kept in rune.store and survive restarts.
--   * spdxy <town> looks names up in a built-in table of towns, landmarks,
--     worldgates and clan halls (from speedwalk_manager_gmcp.xml). Only
--     entries on your current plane are used, nearest first; one match
--     walks, several open a picker. Partial words work in any order.
--   * spdxy nearby [x, y] reports the closest known place, clan hall or
--     waypoint to those coordinates (default: where you stand), with
--     distance and compass direction, on the current plane.
--   * spdxy back walks to where the last walk started (run it again to
--     return to the destination).
--   * Outside the wilds, if horstgs' mapper modules are present, it falls
--     back to walking to a MAPPED room whose stored coord matches.
--
-- Commands: spdxy <x>, <y> | spdxy <x> <y> | spdxy <town> | spdxy again
--           spdxy clan <name|#> | spdxy find <text> | spdxy nearby [x, y]
--           spdxy back
--           spdxy save <name> [x y] | spdxy del <name> | spdxy list
--           spdxy stop | pause | resume | here | help

----------------------------------------------------------------------
-- Optional mapper modules (fallback outside the wilds only)
----------------------------------------------------------------------
local ok_s, store = pcall(require, "mapper_store")
local ok_g, graph = pcall(require, "mapper_graph")
local ok_w, mwalk = pcall(require, "mapper_walk")
local have_mapper = ok_s and ok_g and ok_w

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

local places = load_table(KEY_PLACES)      -- name -> { x =, y = }
local last_target = load_table(KEY_LAST)   -- { x =, y = }
local last_origin = load_table(KEY_ORIGIN) -- { x =, y =, plane = } start of last walk

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local last = {}   -- latest Room.Info: x, y, zone, plane, exits, num
local S = nil     -- active walk, or nil

-- Obstacle/water/combat triggers are only live while a walk is active.
local function set_triggers(on)
  local fn = rune.group and (on and rune.group.enable or rune.group.disable)
  if fn then pcall(fn, GROUP) end
end

local function cleanup()
  S = nil
  pcall(rune.timer.cancel, WATCH)
  set_triggers(false)
end

local function abort(msg)
  if msg then rune.echo("[spdxy] " .. msg) end
  cleanup()
end

local function pause(msg)
  if not S then return end
  S.paused = true
  S.pending = false
  rune.echo("[spdxy] " .. msg)
  rune.echo("[spdxy] 'spdxy resume' to continue, 'spdxy stop' to cancel.")
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
  rune.echo(string.format("[spdxy] arrived at %d, %d (%d steps, %ds).",
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
  if PROGRESS_EVERY > 0 and S.steps % PROGRESS_EVERY == 0 then
    rune.echo(string.format("[spdxy] at %d, %d - about %d steps to go.",
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
  if not have_mapper then
    rune.echo("[spdxy] you are not in the wilds, and the mapper modules are not available.")
    return
  end
  local from = store.position and store.position.uid
  if not from or not store.rooms[from] then
    rune.echo("[spdxy] I don't know where you are (mapper has no position).")
    return
  end

  local function walk_to_uid(dest)
    dest = tostring(dest)
    local cur = store.position and store.position.uid
    if not cur then rune.echo("[spdxy] I don't know where you are."); return end
    local m, exhausted = graph.find_paths(cur, function(uid)
      if uid == dest then return "dest" end
      return nil
    end)
    local data = m[dest]
    if not data then
      rune.echo("[spdxy] no mapped path to " .. dest ..
        (exhausted and " (depth limit hit; try 'mapper depth inf')" or ""))
      return
    end
    if #data.path == 0 then rune.echo("[spdxy] already here."); return end
    rune.echo("[spdxy] -> " .. dest .. " (" .. #data.path .. " steps): " ..
      graph.build_speedwalk(data.path))
    if rune.store.get("mapper.enable_speedwalk_sends") == false then
      rune.echo("[spdxy] (sends disabled; `mapper sends on` to enable)")
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
    rune.echo(string.format(
      "[spdxy] not in the wilds and no reachable mapped room at %d, %d. " ..
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
    rune.echo("Usage: spdxy <x> [,] <y>")
    return
  end

  if not last.x then
    rune.echo("[spdxy] no position from GMCP yet; move one room (or look) and try again.")
    return
  end

  last_target = { x = tx, y = ty }
  save_table(KEY_LAST, last_target)

  if not in_vmap(last.zone) then
    mapper_goto_xy(tx, ty)
    return
  end

  if S then
    rune.echo("[spdxy] replacing the walk to " .. S.tx .. ", " .. S.ty .. ".")
    cleanup()
  end

  if last.x == tx and last.y == ty then
    rune.echo("[spdxy] already at " .. tx .. ", " .. ty .. ".")
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
  last_origin = { x = last.x, y = last.y, plane = plane_of_zone(last.zone) }
  save_table(KEY_ORIGIN, last_origin)
  set_triggers(true)
  rune.echo(string.format("[spdxy] walking from %d, %d to %d, %d (~%d steps)...",
    last.x, last.y, tx, ty, steps))

  -- Watchdog: resend the step if no Room.Info arrives, pause after a few tries.
  rune.timer.every(1, function()
    if not S or S.paused or not S.pending then return end
    if os.time() - S.sent_at < RETRY_SECS then return end
    S.retries = S.retries + 1
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
-- Triggers (grouped; enabled only while a walk is active)
----------------------------------------------------------------------
local function trig(pattern, fn, name)
  rune.trigger.regex(pattern, function() fn() end, { name = name, group = GROUP })
end

trig([[^You cannot move in that direction\.$]], blocked, "spdxy-t-nomove")

trig([[^(?:You would surely need a grappling hook to move there|You can't go there while mounted|You need a sailing vessel to go there|The .+ (?:is|are) closed)\.$]],
  blocked, "spdxy-t-blocked")

trig([[^(?:The water current is too swift and turbulent for (?:you|your mount) to cross|You would need a sailing vessel or some form of levitation to go there|You would need a water-breathing mount to go there mounted)\.$]],
  function()
    if S and not S.paused then pause("water ahead.") end
  end, "spdxy-t-water")

trig([[^(?:A swirling vortex of sound and energy envelops you|You hear a peal of thunder from afar\.\.)]],
  function()
    if S then abort("teleported/recalled; walk aborted.") end
  end, "spdxy-t-teleport")

trig([[^A sudden, strong gust of wind knocks you to the ground!$]],
  function()
    if S and S.pending then
      rune.send("stand")
      S.sent_at = os.time()
    end
  end, "spdxy-t-gust")

trig([[^Your mount is sitting down\.$]],
  function()
    if S then rune.send("sayto mount stand") end
  end, "spdxy-t-mount")

trig([[^Not while you are in combat\.$]],
  function()
    if S and not S.paused then pause("you are in combat.") end
  end, "spdxy-t-combat")

-- Idle until a walk starts (also resets the group after a /reload).
set_triggers(false)

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local function help()
  rune.echo("spdxy v3.3 - Walk to sextant coordinates, towns and clan halls")
  rune.echo("")
  rune.echo("* spdxy <x>, <y>        - Walk to coordinates X,Y (with comma)")
  rune.echo("* spdxy <x> <y>         - Walk to coordinates X,Y (without comma)")
  rune.echo("* spdxy <town>          - Walk to a town/landmark/worldgate or saved waypoint")
  rune.echo("                          (partial words ok: 'spdxy tellerium north')")
  rune.echo("* spdxy clan <name|#>   - Walk to a clan hall by name or number")
  rune.echo("* spdxy find <text>     - List matching places, clan halls and waypoints")
  rune.echo("* spdxy again           - Walk to the last destination")
  rune.echo("* spdxy back            - Walk back to where the last walk started")
  rune.echo("* spdxy nearby [x, y]   - Nearest known location to X,Y (default: here)")
  rune.echo("* spdxy save <name>     - Save your current spot as a waypoint")
  rune.echo("* spdxy save <name> <x> <y> - Save given coordinates as a waypoint")
  rune.echo("* spdxy del <name>      - Delete a waypoint")
  rune.echo("* spdxy list            - List your waypoints")
  rune.echo("* spdxy stop            - Cancel the walk")
  rune.echo("* spdxy pause / resume  - Pause or continue the walk")
  rune.echo("* spdxy here            - Show current coordinates, zone and exits")
  rune.echo("* spdxy help            - This help")
  rune.echo("")
  rune.echo("Examples:")
  rune.echo("* spdxy 123, 456   - with comma")
  rune.echo("* spdxy 123 456    - without comma")
  rune.echo("* spdxy tellerium  - several matches open a picker, nearest first")
  rune.echo("* spdxy clan 93    - clan hall number 93")
  rune.echo("* spdxy nearby 900, 500 - what is closest to those coordinates?")
  rune.echo("* spdxy save camp  - remember where you stand as 'camp'")
  rune.echo("")
  rune.echo("Names only match places on the plane you are standing on (Alyria,")
  rune.echo("Faerie Plane, Underground, Sigil Underground). In the wilds it steps by")
  rune.echo("compass direction from your live GMCP coordinates, so unmapped rooms are")
  rune.echo("fine. It walks around blocked steps, pauses at water or combat, and")
  rune.echo("aborts if you enter a building. Outside the wilds it only walks to a")
  rune.echo("mapped room with those coordinates.")
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
    for n, p in pairs(places) do
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
    rune.echo(string.format("[spdxy] %s is on %s but you are on %s.",
      e.name, PLANE_LABEL[e.plane] or e.plane, PLANE_LABEL[plane] or plane))
    return
  end
  rune.echo(string.format("[spdxy] -> %s (%d, %d)", e.name, e.x, e.y))
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
  if #list == 0 then
    rune.echo("[spdxy] nothing matches '" .. q .. "'. Try 'spdxy find " .. q .. "' or 'spdxy help'.")
    return
  end

  local plane = cur_plane()
  if plane then
    local same = {}
    for _, e in ipairs(list) do
      if e.plane == nil or e.plane == plane then same[#same + 1] = e end
    end
    if #same == 0 then
      rune.echo(string.format("[spdxy] '%s' is only known on other planes (you are on %s):",
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
    show_picker("spdxy: " .. q, list)
  end
end

local function cmd_find(q)
  q = trim(q)
  if q == "" then rune.echo("Usage: spdxy find <text>"); return end
  local list = search(q, true, true, true)
  if #list == 0 then rune.echo("[spdxy] nothing matches '" .. q .. "'."); return end
  table.sort(list, function(a, b)
    if a.src ~= b.src then return a.src < b.src end
    return a.name < b.name
  end)
  rune.echo(string.format("[spdxy] %d match(es) for '%s':", #list, q))
  for i = 1, math.min(#list, 60) do
    local e = list[i]
    rune.echo(string.format("  %-44s %d, %d  %s", e.name, e.x, e.y,
      PLANE_LABEL[e.plane] or (e.src == "waypoint" and "waypoint" or "")))
  end
  if #list > 60 then rune.echo(string.format("  ... and %d more; narrow the search.", #list - 60)) end
end

local function sorted_names()
  local names = {}
  for n in pairs(places) do names[#names + 1] = n end
  table.sort(names)
  return names
end

local function cmd_save(rest)
  local name, sx, sy = rest:match("^(.-)%s+(-?%d+)%s*,?%s*(-?%d+)$")
  local x, y, plane
  if name and name ~= "" then
    x, y = tonumber(sx), tonumber(sy)
  else
    name = rest
    x, y = last.x, last.y
    plane = cur_plane()   -- remembered so names only match on that plane
  end
  name = trim(name):lower()
  if name == "" then rune.echo("Usage: spdxy save <name> [<x> <y>]"); return end
  if not x then
    rune.echo("[spdxy] no current coordinates; give them: spdxy save <name> <x> <y>")
    return
  end
  places[name] = { x = x, y = y, plane = plane }
  save_table(KEY_PLACES, places)
  rune.echo(string.format("[spdxy] saved '%s' = %d, %d", name, x, y))
end

local function cmd_del(rest)
  local name = trim(rest):lower()
  if name == "" then rune.echo("Usage: spdxy del <name>"); return end
  if not places[name] then rune.echo("[spdxy] no waypoint '" .. name .. "'."); return end
  places[name] = nil
  save_table(KEY_PLACES, places)
  rune.echo("[spdxy] deleted '" .. name .. "'.")
end

local function cmd_list()
  local names = sorted_names()
  if #names == 0 then
    rune.echo("[spdxy] no waypoints saved. Use: spdxy save <name>")
    return
  end
  rune.echo("[spdxy] waypoints:")
  for _, n in ipairs(names) do
    rune.echo(string.format("  %-24s %d, %d", n, places[n].x, places[n].y))
  end
end

local function cmd_here()
  if not last.x then
    rune.echo("[spdxy] no coordinates yet (move one room or look).")
    return
  end
  rune.echo(string.format("[spdxy] you are at %d, %d  zone=%s  plane=%s  wilds=%s",
    last.x, last.y, tostring(last.zone), tostring(last.plane),
    in_vmap(last.zone) and "yes" or "no"))
  local ex = {}
  if type(last.exits) == "table" then
    for k in pairs(last.exits) do ex[#ex + 1] = tostring(k) end
    table.sort(ex)
  end
  rune.echo("[spdxy] exits: " .. (#ex > 0 and table.concat(ex, " ") or "(none reported)"))
end

local function cmd_resume()
  if not S or not S.paused then rune.echo("[spdxy] nothing to resume."); return end
  if S.zone and last.zone and tostring(last.zone) ~= tostring(S.zone) then
    abort("you are no longer in '" .. tostring(S.zone) .. "'; walk cancelled.")
    return
  end
  S.paused, S.pending, S.retries = false, false, 0
  rune.echo(string.format("[spdxy] resuming to %d, %d.", S.tx, S.ty))
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
    if not qx then rune.echo("[spdxy] no coordinates yet (move one room or look)."); return end
  else
    local a, b = parse_xy(rest)
    if not a then rune.echo("Usage: spdxy nearby [<x>, <y>]"); return end
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
  for n, p in pairs(places) do add(n, p.x, p.y, p.plane, "waypoint") end
  for _, p in ipairs(PLACES) do add(p[1], p[2], p[3], p[4], "place") end
  for _, c in ipairs(CLANS) do
    add(string.format("%s [%d]", c[2], c[1]), c[3], c[4], "alyria", "clan hall")
  end

  if #cands == 0 then rune.echo("[spdxy] no known locations to compare."); return end
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

  rune.echo(string.format("[spdxy] nearest to %d, %d%s: %s", qx, qy,
    plane and (" (" .. (PLANE_LABEL[plane] or plane) .. ")") or "", line(cands[1])))
  if #cands > 1 then
    rune.echo("[spdxy] also close:")
    for i = 2, math.min(#cands, 4) do rune.echo("  " .. line(cands[i])) end
  end
end

local function cmd_back()
  if not last_origin.x then rune.echo("[spdxy] no previous walk to go back from."); return end
  local plane = cur_plane()
  if plane and last_origin.plane and plane ~= last_origin.plane then
    rune.echo(string.format("[spdxy] your last start was on %s but you are on %s.",
      PLANE_LABEL[last_origin.plane] or last_origin.plane, PLANE_LABEL[plane] or plane))
    return
  end
  rune.echo(string.format("[spdxy] -> back to %d, %d", last_origin.x, last_origin.y))
  speed_to_x_y(last_origin.x, last_origin.y)
end

local function dispatch(arg)
  arg = trim(arg or "")
  if arg == "" then help(); return end

  local x, y = parse_xy(arg)
  if x then speed_to_x_y(x, y); return end

  if arg:match("^-?%d+$") then
    rune.echo("[spdxy] one number is ambiguous: use 'spdxy <x> <y>' or 'spdxy clan <number>'.")
    return
  end

  local cmd, rest = arg:match("^(%S+)%s*(.-)$")
  cmd = cmd:lower()

  if cmd == "help" then help()
  elseif cmd == "stop" or cmd == "abort" then
    if S then abort("walk cancelled.") else rune.echo("[spdxy] no walk in progress.") end
  elseif cmd == "pause" then
    if S and not S.paused then pause("paused.") else rune.echo("[spdxy] nothing to pause.") end
  elseif cmd == "resume" then cmd_resume()
  elseif cmd == "here" then cmd_here()
  elseif cmd == "again" or cmd == "last" then
    if last_target.x then
      speed_to_x_y(last_target.x, last_target.y)
    else
      rune.echo("[spdxy] no previous destination.")
    end
  elseif cmd == "save" or cmd == "set" then cmd_save(rest)
  elseif cmd == "del" or cmd == "delete" or cmd == "rm" then cmd_del(rest)
  elseif cmd == "list" or cmd == "places" then cmd_list()
  elseif cmd == "find" or cmd == "sextant" then cmd_find(rest)
  elseif cmd == "nearby" or cmd == "near" then cmd_nearby(rest)
  elseif cmd == "back" then cmd_back()
  elseif cmd == "clan" or cmd == "clanhall" then
    if trim(rest) == "" then rune.echo("Usage: spdxy clan <name|number>") else goto_query(rest, true) end
  else goto_query(arg, false)
  end
end

-- One alias handles every form so commands and place names cannot collide.
rune.alias.regex("^spdxy(?:[ ]+(.*))?$", function(m)
  dispatch(m[1] or "")
end, { name = "spdxy" })