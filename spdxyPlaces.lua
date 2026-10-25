-- Filename: eljayPlugins/spdxyPlaces.lua
-- Purpose: Town and clan hall data, name lookup, nearby and waypoints for spdxyCoordinates
-- Version: 1.0
-- Date: 2026-Oct-25
--[[
- insert planning notes here between revisions.
]]
--   1.0  Split out of spdxyCoordinates.lua (v3.7) to keep both under 16000 bytes.
--
-- How it works:
--   * Not a plugin: spdxyCoordinates requires it on the first name lookup, nearby
--     or waypoint command. Keep it out of initEljay's PLUGINS list.
--   * towns rows are name|x|y|plane (a Alyria, f Faerie Plane, u Underground,
--     s Sigil Underground); clans rows are number|name|x|y. Add or fix rows freely.
--   * Source: speedwalk_manager_gmcp.xml. Waypoint writes re-read rune.store first.

local towns = [[
bazaar (west)|818|386|a
bazaar (north)|816|374|a
disturbed pyramid|745|263|a
dungeon avarice|671|572|a
dungeon wroth|736|391|a
gilvery (west)|950|356|a
gilvery (east)|962|356|a
hall of honor (south)|697|741|a
hill giant's refuge|590|670|a
lasler|698|695|a
lonely dragon inn|600|700|a
lowangen|1159|421|a
mandrake woods|654|365|a
new kolvir (nk)|571|984|a
new rigel (nr) (north)|801|545|a
new rigel (nr) (south)|798|564|a
ofstadt monastery|1120|330|a
old degenerates clanhall|606|405|a
old eclipse clan hall|630|935|a
old federation clanhall|874|236|a
rune (east)|706|763|a
rune (west)|684|760|a
rune forest|701|680|a
shadow castle (in mandrake woods)|654|365|a
tavern of the boars|797|445|a
thorn desert (east)|1048|324|a
thorn desert (west)|1031|316|a
tower of art (toa)|1271|211|a
tower of art (toa) trail|1287|221|a
traveler's retreat|776|651|a
twin moons inn|1007|306|a
van pelt's emporium|669|758|a
xaventry (north)|607|437|a
xaventry (south)|602|454|a
diocletian|553|1360|a
emperor's crossroads|506|1309|a
glarshak|778|1281|a
old amaunet clan hall|824|1234|a
old armageddon clanhall|515|1411|a
palamire (north)|705|1403|a
palamire (south)|705|1410|a
saucy wench tavern|760|1303|a
shlarksh|813|1201|a
sigil (north)|435|1226|a
sigil (south)|436|1238|a
teolaven|609|1303|a
vesuvius|295|1160|a
vospire (east)|330|1176|a
vospire (west)|312|1177|a
althaman|1676|595|a
aroxa|1759|630|a
begora's sanctuary|1832|425|a
dorathon (west)|1691|470|a
frost giant's keep (fgk)|1689|389|a
jalur|1814|255|a
lair of the ice witch|1754|266|a
muldar lohk mulvar|1651|183|a
ogre village|1885|459|a
old stargazer clanhall|1707|438|a
tellerium (north)|1724|685|a
tellerium (south)|1716|693|a
templeton|1620|542|a
winton|1582|392|a
angry whale|1232|1369|a
cenotaph directory|1430|1241|a
chanctonbury woods|997|1091|a
colyon (south)|1386|1037|a
colyon (west)|1373|1030|a
dungeon deceit|1254|1071|a
gorth (east)|1646|1227|a
gorth (west)|1629|1223|a
kazreal?|1384|1370|a
maldra keep|1304|1092|a
mulakanathos (south)|1556|1237|a
old empire clanhall|1385|1196|a
pirate's cove (pc) (north)|1191|968|a
pirate's cove (pc) (west)|1174|975|a
takhtin|1020|1210|a
xalt outpost|1453|1204|a
abandoned oil well|1753|824|a
aequtus|374|636|a
arcane|926|816|a
atlantis|1988|1307|a
capture the flag (ctf)|993|893|a
coven of kalywak|121|273|a
daggerwind reef|2089|1387|a
forsaken oil well|1728|842|a
frigate's end|264|592|a
hellbent (hb) (alyria)|1341|366|a
irda isle - reef entrance|1278|747|a
irda isle - entrance|1299|688|a
kalywak|120|268|a
maelstrom (alyria)|1540|742|a
magencia|865|834|a
naulitas|1968|1337|a
pelican's demise|1579|937|a
strange ruins|1804|924|a
wreck of the feisty wench (north)|1889|954|a
dwarven passage (pass to sug)|477|1426|a
labyrinth molehill (lvl-restricted pass to sug)|536|1258|a
mineshaft (pass to sug)|1041|1246|a
natural cave (pass to sug)|795|1205|a
cavhfail (faerie plane) (east)|355|284|f
cavhfail (faerie plane) (west)|347|284|f
eanoss azelmar (faerie plane)|130|65|f
hellbent (hb) (faerie plane)|255|163|f
human outpost (faerie plane)|306|134|f
open meadow (jasper dest) (faerie plane)|200|200|f
rahdiyr (faerie plane) (south)|105|72|f
rahdiyr (faerie plane) (west)|102|69|f
seelie (faerie plane)|43|55|f
unseelie (faerie plane) (south)|438|299|f
unseelie (faerie plane) (west)|431|293|f
arien'dyth (underground)|731|262|u
chattering skull tavern (underground)|804|767|u
decara (underground)|1579|486|u
hellbent (hb) (underground)|1341|366|u
hotel hello (hh) (underground)|1228|768|u
kessarian's dungeon (underground)|1590|985|u
maelstrom (underground)|1540|743|u
sea hag (underground)|1111|880|u
smuggler's cave (underground)|1598|838|u
smuggler's gulch (underground) (east)|1193|532|u
southwest passage (sw pass) (underground)|898|659|u
three-bearded jake's (underground)|908|823|u
three-bearded jake's (2x xp mini) (underground)|873|675|u
vir beach (underground)|1426|991|u
vir (east) (underground)|1439|1052|u
vir (west) (underground)|1428|1061|u
a ghost town (sigil underground)|591|1401|s
bandit camp (sigil underground)|1017|1178|s
darksea (sigil underground)|919|1232|s
fiery catwalk (sigil underground)|291|1159|s
genauras (sigil underground)|538|1253|s
gypsy village (sigil underground)|627|1265|s
rift between sigil and the underside (sigil underground)|428|1231|s
shrine of dira (sigil underground) (southeast)|632|1387|s
shrine of dira (sigil underground) (southwest)|620|1386|s
shrine of gath (sigil underground) (east)|468|1401|s
shrine of gath (sigil underground) (northwest)|457|1395|s
shrine of ithrilis (sigil underground) (west)|543|1301|s
shrine of maradas (sigil underground) (east)|421|1260|s
shrine of vandyne (sigil underground) (east)|590|1365|s
shrine of vandyne (sigil underground) (north)|489|1282|s
shrine of vandyne (sigil underground) (south)|501|1373|s
shrine of vandyne (sigil underground) (west)|424|1301|s
troglodyte village (sigil underground)|479|1396|s
arcane (rec: traveler's retreat) worldgate|967|699|a
black lodge (rec: tower of art) worldgate|1301|-1|a
chanctonbury (rec: pirate's cove) worldgate|1015|1116|a
garbool (rec: ogre village) worldgate|2113|754|a
kalywak (rec: xaventry) worldgate|118|278|a
lowangen worldgate|1177|384|a
maldra (rec: deceit) worldgate|1279|1053|a
rune worldgate|662|746|a
sigil (rec: emperor's crossroads) worldgate|502|1281|a
templeton worldgate|1674|541|a
xaventry worldgate|625|461|a
seelie worldgate (faerie plane)|76|301|f
unseelie worldgate (faerie plane)|389|81|f
decara worldgate (underground)|1538|430|u
hotel hello (hh) worldgate (underground)|1234|865|u
vir worldgate (underground)|1752|986|u
bandit camp worldgate (sigil underground)|990|1182|s
genauras worldgate (sigil underground)|488|1255|s
ghost town worldgate (sigil underground)|569|1399|s
gypsy village worldgate #1 (sigil underground)|791|1270|s
gypsy village worldgate #2 (sigil underground)|604|1308|s
]]
local clans = [[
1|Tuath Fiana (Avros)|1716|611
2|Enigma (Beltane)|1257|1123
3|Phoenix (Beltane)|972|1038
4|(Cabal)[a] (Auryn)|294|1127
5|Prophecy (Sepharia)|1180|233
6|Circle of Power (Sepharia)|877|611
8|(Excession)[a] (Avros)|1632|486
9|The Lin Kuei (Beltane)|1262|1005
11|Knighthood (Beltane)|1370|1235
12|Vigil (Sepharia)|606|727
13|SpiritWalk (Sepharia)|643|480
14|(Midwinter Equinox)[a] (Avros)|1727|555
15|Caitiff (Sepharia)|762|607
18|Sanguine (Auryn)|369|1215
19|Pollacca (Sepharia)|566|423
23|Dragon (Beltane)|1601|1262
25|(Eclipse)[o] (Sepharia)|630|935
26|(Valhalla)[a] (Sepharia)|648|646
27|Apathy (Sepharia)|768|481
28|Whisper (Sepharia)|585|894
29|(Black Tower)[a] (Auryn archipielago)|768|1406
30|New Alyrian Order (Auryn)|536|1295
32|Innuendo (Auryn)|248|1196
33|(Stargazer)[o] (Avros)|1707|438
35|Avalanche (Auryn archipielago)|776|1213
36|Power of Entropy (Sepharia)|919|296
37|Euphoria (Arcane archipielago)|1060|709
41|Oracle (Auryn)|617|1335
44|Tweaked (Sepharia)|839|335
45|Blasphemy (Beltane)|1071|976
46|(The Unforgiven)[a] (Auryn archipielago)|731|1403
47|Northstar (Auryn archipielago)|732|1257
51|(Aceldama)[o] (Avros)|1668|411
52|Diversity (Auryn)|423|1091
53|(Revelations)[o] (Sepharia)|1209|356
55|(Degenerates)[o] (Sepharia)|606|405
56|(Eyes of the Dragon)[a] (Sepharia)|1076|342
57|The Hostile Crew (Beltane)|1551|995
59|(Empire)[o] (Beltane)|1385|1196
67|(Transcend)[uc] (Beltane)|1054|1156
75|Supremacy (Sepharia)|690|483
79|Far Dareis Mais (Auryn)|618|1252
80|(Federation)[o] (Sepharia)|874|233
81|Knights of Chaos (Auryn archipielago)|439|1329
88|(Vampire's Mask)[o] (Auryn)|200|1176
90|Ahriman's Army (Beltane)|1249|1292
92|The Cwn Annwn (Sepharia)|714|575
93|Amaunet (Auryn archipielago)|782|1401
93|Amaunet[o] (Auryn archipielago)|824|1234
94|(The Higher Power)[a] (Avros)|1608|421
95|(Kizaran Alliance)[a] (Avros)|1839|547
99|Odyssey (Auryn archipielago)|809|1298
102|(The Chosen)[a] (Auryn)|264|1224
103|Eternal Darkness (Sepharia)|1254|290
108|Guardians (Auryn)|526|1334
109|Legacy (Sepharia)|739|499
110|Timeworn (Auryn)|245|1134
112|(Armageddon)[o] (Auryn)|515|1411
114|Crypt (Sepharia)|788|387
115|(The Dark Order)[a] (Avros)|1767|372
116|(The Betrayed)[a] (Avros)|1578|305
117|(The Returners)[a] (Auryn archipielago)|718|1421
118|(Saresyn's Revenge)[a] (Sepharia)|749|457
119|(Paradigm)[a] (Beltane)|1130|1005
120|Mercenaries of War (Sepharia)|788|345
121|The Lion's Den (Beltane)|1161|1227
123|(Allegiance)[a] (Avros)|1799|638
124|(Arbiters of Fate)[a] (Beltane archipielago)|1775|1078
127|(The Ministry)[a] (Auryn archipielago)|746|1415
129|Insurrection (Beltane)|1390|1375
130|(Spira Devexa)[o] (Auryn archipielago)|806|1265
131|(Pandemonium)[o] (Avros)|1736|483
132|Heirs of Tuireann (Sepharia)|975|175
134|(Moonlight Requiem)[a] (Sepharia)|530|224
135|Suppression (Beltane)|1447|1363
136|(Perdition's Flame)[a] (Sepharia)|997|166
138|(Separatists)[o] (Auryn)|368|1262
139|Wonderland (Beltane)|1311|961
140|Alpha et Omega (Sepharia)|1097|163
141|Nemesis (Auryn)|594|1379
143|Order of Twilight (Sepharia)|926|377
148|Relentless (Beltane)|1393|1389
149|Fortuna Umbra (Auryn)|629|1379
150|KD Brotherhood (Sepharia)|716|543
151|Sad Panda (Auryn)|558|1390
152|Knights of Order (Auryn)|364|1141
155|Awesome (Beltane)|994|1167
]]

return function(C)
  local say, get, put, trim, dbg, last = C.say, C.get, C.put, C.trim, C.dbg, C.last
  local plane_of, delta, dist, parse, walk_to = C.plane_of, C.delta, C.dist, C.parse, C.walk_to
  local SHORT, K_WP, MAX_WP, MAX_X, MAX_Y, OLDP = C.SHORT, C.K_WP, C.MAX_WP, C.MAX_X, C.MAX_Y, C.OLDP
  local PLANES = { a = "Alyria", f = "Faerie Plane", u = "Underground", s = "Sigil Underground" }
  local E
  local function pool()
    if not E then
      E = {}
      for l in towns:gmatch("[^\n]+") do
        local n, x, y, p = l:match("^(.-)|(-?%d+)|(-?%d+)|(%a)$")
        if n then E[#E + 1] = { n = n, x = tonumber(x), y = tonumber(y), p = p, k = "town" } end
      end
      for l in clans:gmatch("[^\n]+") do
        local c, n, x, y = l:match("^(%d+)|(.-)|(-?%d+)|(-?%d+)$")
        if c then E[#E + 1] = { n = n, c = tonumber(c), x = tonumber(x), y = tonumber(y), p = "a", k = "clan" } end
      end
    end
    local all = {}
    for _, e in ipairs(E) do all[#all + 1] = e end
    for n, p in pairs(get(K_WP)) do
      all[#all + 1] = { n = n, x = p.x, y = p.y, p = OLDP[p.plane] or p.plane, k = "wp" }
    end
    return all
  end
  local function label(e) return e.c and ("%s [%d]"):format(e.n, e.c) or e.n end
  local function word_at(n, w, loose)
    local i = 1
    while true do
      local s = n:find(w, i, true)
      if not s then return false end
      if loose or s == 1 or not n:sub(s - 1, s - 1):match("%w") then return true end
      i = s + 1
    end
  end
  -- Entries of the wanted kinds whose name has every word of q (word starts first).
  local function search(q, kinds)
    local words, num = {}, tonumber(q:match("^%s*(%d+)%s*$"))
    for w in q:lower():gmatch("%S+") do words[#words + 1] = w end
    local all = pool()
    for pass = 1, 2 do
      local list = {}
      for _, e in ipairs(all) do
        local ok = kinds[e.k]
        if ok and e.c and num then ok = e.c == num
        elseif ok then
          local n = e.n:lower()
          for _, w in ipairs(words) do if not word_at(n, w, pass == 2) then ok = false; break end end
        end
        if ok then list[#list + 1] = e end
      end
      if #list > 0 then return list end
    end
    return {}
  end
  local function go(e)
    say(("-> %s (%d, %d)"):format(label(e), e.x, e.y))
    walk_to(e.x, e.y)
  end
  local function query(q, kinds)
    q = trim(q)
    local list = #q > 0 and search(q, kinds) or {}
    if #list == 0 and kinds.town then list = search(q, { clan = true }) end
    local pl, same = plane_of(last.zone), {}   -- only your plane
    for _, e in ipairs(list) do if not (pl and e.p and e.p ~= pl) then same[#same + 1] = e end end
    list = same
    dbg("query '%s': %d match(es)", q, #list)
    if #list == 0 then return say(("nothing on your plane matches '%s'."):format(q)) end
    local exact = {}
    for _, e in ipairs(list) do if label(e):lower() == q:lower() then exact[#exact + 1] = e end end
    if #exact > 0 then list = exact end
    local function d(e) return last.x and dist(last.x, last.y, e.x, e.y) or 0 end
    table.sort(list, function(a, b) if d(a) ~= d(b) then return d(a) < d(b) end; return a.n < b.n end)
    if #list == 1 then return go(list[1]) end
    local items = {}
    for i = 1, math.min(#list, 100) do
      local e = list[i]
      items[i] = { text = label(e), value = tostring(i),
        desc = ("%d, %d  %s  ~%d steps"):format(e.x, e.y, PLANES[e.p] or "waypoint", d(e)) }
    end
    rune.ui.picker.show({ title = ("%s: %s (%d)"):format(SHORT, q, #list), items = items,
      on_select = function(v) local e = list[tonumber(v)]; if e then go(e) end end })
  end

  -- Closest known place, clan hall or waypoint to x, y (default: where you stand).
  local function nearby(a)
    local qx, qy = parse(trim(a or ""))
    if not qx then qx, qy = last.x, last.y end
    if not qx then return say("Usage: " .. SHORT .. " nearby [<x>, <y>]") end
    local pl, best, bd, bs, bdx, bdy = plane_of(last.zone)
    for _, e in ipairs(pool()) do
      if not (pl and e.p and e.p ~= pl) then
        local dx, dy = delta(qx, e.x, MAX_X), delta(qy, e.y, MAX_Y)
        local st, sq = math.max(math.abs(dx), math.abs(dy)), dx * dx + dy * dy
        if not best or st < bd or (st == bd and sq < bs) then best, bd, bs, bdx, bdy = e, st, sq, dx, dy end
      end
    end
    if not best then return say("no known locations to compare.") end
    local ax, ay = math.abs(bdx), math.abs(bdy)
    local v, h = bdy < 0 and "n" or "s", bdx > 0 and "e" or "w"
    local c = ay <= ax * 0.4142 and h or ax <= ay * 0.4142 and v or v .. h
    say(("nearest to %d, %d: %s at %d, %d - %s"):format(qx, qy, label(best), best.x, best.y,
      bd == 0 and "right there" or bd .. " steps " .. c))
  end

  local function waypoint(cmd, rest)
    local wp, n = get(K_WP), 0
    for _ in pairs(wp) do n = n + 1 end
    if cmd == "list" then
      local names = {}
      for k in pairs(wp) do names[#names + 1] = k end
      table.sort(names)
      if #names == 0 then return say("no waypoints saved.") end
      for _, k in ipairs(names) do rune.echo(("  %-24s %d, %d"):format(k, wp[k].x, wp[k].y)) end
      return
    end
    local name, sx, sy = rest:match("^(.-)%s+(-?%d+)%s*,?%s*(-?%d+)$")
    local x, y, p = tonumber(sx), tonumber(sy)
    if not name or name == "" then name, x, y, p = rest, last.x, last.y, plane_of(last.zone) end
    name = trim(name:gsub("%c", ""):gsub("%s+", " ")):sub(1, 40):lower()
    if name == "" then return say("Usage: " .. SHORT .. " save|del <name> [<x> <y>]") end
    if cmd == "del" then
      if not wp[name] then return say("no waypoint '" .. name .. "'.") end
      wp[name] = nil
    elseif not x then return say("no position yet: save <name> <x> <y>")
    elseif not wp[name] and n >= MAX_WP then return say("waypoint limit reached; use del.")
    else wp[name] = { x = x, y = y, plane = p } end
    put(K_WP, wp)
    say((cmd == "del" and "deleted '%s'." or "saved '%s'."):format(name))
  end


  return { query = query, nearby = nearby, waypoint = waypoint }
end