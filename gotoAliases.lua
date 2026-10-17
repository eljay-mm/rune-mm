-- Filename: eljayPlugins/gotoAliases.lua
-- Purpose: Aliases to run to gates, quest masters, banks, post offices and other places in the town you are in.
-- Version: 1.2
-- Date: 2026-Oct-17
--
-- Changelog:
--   1.2  Use the real Rune API: rune.gmcp.subscribe("Room") + rune.gmcp.on("Room.Info"), one exact alias per command,
--        "run <place>" shortcuts registered as exact aliases.
--   1.1  More tolerant GMCP lookup; new "goto where" diagnostic command.
--   1.0  Converted from goto_aliases.xml (MUSHclient). Main command gotoAliases, short alias goto.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona.
--   * Subscribes to GMCP Room.Info and remembers the latest room, zone and plane to work out which town you are in.
--   * goto north|east|south|west|gate runs the mapper to that town exit.
--   * goto next sends the command stored for the current room (for example "run newrigel").
--   * goto custom <text> stores your own "next" command for the current room; "goto custom clear" removes it.
--   * goto qm, rep, post, bank, reagents, lockers and crystal run the mapper to that spot,
--     and perform the action (quest request, sayto representative yes, shop buy 1) when you are already there.
--   * goto pursuer runs leg by leg towards the Orc Pursuer in Wroth; each room change continues the trip.
--   * run <place> accepts the short names below (for example "run toa") and expands them for the continent you are on.
--   * goto where shows what the plugin sees (room, zone, plane, town) to help diagnose detection problems.
--   * Settings (on/off, debug, custom sends) persist in rune.store; no config files are written.
--
-- Commands (type without "/"; "goto" is a short alias for "gotoAliases"):
--   gotoAliases | goto                   show this help
--   goto list                            show what you can goto from here
--   goto where                           show detected room, zone, plane and town
--   goto north|east|south|west|gate      run to that exit of the current town
--   goto next                            send the stored command for this room
--   goto custom <text>                   set this room's "next" command (goto custom clear removes it)
--   goto qm | rep | post | bank          quest master, tourist rep, post office, bank
--   goto reagents | lockers              reagent shop, lockers
--   goto crystal                         crystal quest office in Rune
--   goto pursuer | goto cancel           run to the Orc Pursuer / stop after this leg
--   goto on|off                          enable or disable the plugin (including the run shortcuts)
--   goto debug                           toggle debug output (default off)

local PLUGIN_NAME, SHORT, VERSION = "gotoAliases", "goto", "1.2"
local KEY_ENABLED, KEY_DEBUG, KEY_CUSTOM = "gotoAliases.enabled", "gotoAliases.debug", "gotoAliases.custom"

local style = rune.style
local H = require("helpstyle")

-- ---------------------------------------------------------------- helpers
local function say(msg) rune.echo(style.cyan("[" .. PLUGIN_NAME .. "] ") .. msg) end

local function sget(k, d)
  local ok, v = pcall(rune.store.get, k)
  if ok and v ~= nil then return v end
  return d
end
local function sset(k, v) pcall(rune.store.set, k, v) end

local function send(cmd) rune.send(cmd) end
-- Run through the alias layer (needed for "mapper goto <room>"); falls back to a plain send.
local function execute(cmd)
  for _, f in ipairs({ rune.execute, rune.exec }) do
    if type(f) == "function" and pcall(f, cmd) then return end
  end
  send(cmd)
end

-- ---------------------------------------------------------------- state
local settings = sget("gotoAliases.dummy", nil)  -- placeholder so the store is touched once; value unused
local enabled = sget(KEY_ENABLED, true) ~= false and sget(KEY_ENABLED, true) ~= "0"
local DEBUG = sget(KEY_DEBUG, false) == true or sget(KEY_DEBUG, false) == "1"
local running_to_pursuer, leg_sent, forwarding_run = false, false, false
local user_sends = {}
local cur = { num = nil, zone = nil, plane = nil }  -- latest GMCP Room.Info
local events_seen = 0

local function dbg(msg) if DEBUG then say(style.gray("debug: " .. msg)) end end

-- ---------------------------------------------------------------- data
local alyria_destinations = {
  sepharia = {
    newrigel = "newrigel", xaventry = "xaventry", avarice = "avarice", desertthorn = "desertthorn", runeforest = "runeforest",
    gilvery = "gilvery", lasler = "lasler", lowangen = "lowangen", mandrake = "mandrake", newkolvir = "newkolvir", rune = "rune",
    towerofart = "towerofart", wroth = "wroth", twinmoons = "twinmoons", hillgiants = "hillgiants", tavernoftheboars = "tavernoftheboars",
    travelersretreat = "travelersretreat", lonelydragon = "lonelydragon", jointmagicconsortium = "jointmagicconsortium",
    toa = "towerofart", thorn = "desertthorn", forest = "runeforest", jmc = "jointmagicconsortium",
  },
  auryn = { diocletian = "diocletian", shlarksh = "shlarksh", takhtin = "takhtin", emperorscrossroads = "emperorscrossroads",
    vospire = "vospire", vesuvius = "vesuvius", sigil = "sigil" },
  avros = { tellerium = "tellerium", templeton = "templeton", dorathon = "dorathon", winton = "winton", frostgiantskeep = "frostgiantskeep",
    aroxa = "aroxa", oilwells = "oilwells", desertoasis = "desertoasis", oasis = "desertoasis", fgk = "frostgiantskeep" },
  beltane = { keep = "keep", deceit = "deceit", vandemaar = "vandemaar", xalt = "xalt", mulakanathos = "mulakanathos", gorth = "gorth", piratescove = "pc" },
}
local underground_destinations = { decara = "decara", decaradocks = "decaradocks", docks = "decaradocks", ariendyth = "ariendyth",
  smugglersgulch = "smugglersgulch", vir = "vir", hellbent = "hellbent" }
local sug_destinations = { renn = "renn", hlegmal = "hlegmal", tavern = "hlegmal", goblam = "goblam", grigmorth = "grigmorth",
  cogworkcity = "cogworkcity", cogs = "cogworkcity", waylandersretreat = "waylandersretreat", unreinforcedtunnel = "unreinforcedtunnel", vaatt = "vaatt" }

local zone_key_map = {}
local function zones(key, ...) for _, z in ipairs({ ... }) do zone_key_map[z] = key end end
zones("rune", "Towne of Rune", "Runic Castle", "Player Homes - Rune", "Rune Condominiums", "Rune Estates", "Rune Realty", "Temple Crypt",
  "Temple of Sumter", "Winterborn Mansion", "Focault Magic Equipment Company", "Focault's Residence", "Van Pelt's Emporium")
zones("sigil", "Sigil", "The Sigilian Stronghold", "Sigil Castle", "Player Homes - Sigil", "Sigil Condominiums", "Sigil Realty")
zones("newrigel", "The Towne of New Rigel", "New Rigel Condominiums", "New Rigel Gardens", "New Rigel Realty", "Player Homes - New Rigel")
zones("xaventry", "The Towne of Xaventry", "The Xaventry Stronghold", "Xaventry Condominiums", "Xaventry Realty")
zones("tellerium", "Tellerium", "Player Homes - Tellerium", "Tellerium Condominiums", "Tellerium Realty")
zones("templeton", "Templeton", "The Templetonian Stronghold")
zones("piratescove", "Pirate's Cove", "Pirate's Cove Realty", "Player Homes - Pirates Cove")
zones("decara", "Towne of Decara", "Decara Condominiums", "Decara Realty", "Player Homes - Decara")
zones("vir", "Vir", "Vir Condominiums")
zones("mandrake", "Mandrake Woods", "Shadow Castle")
zones("vospire", "Vospire"); zones("diocletian", "Palace of Diocletian"); zones("lowangen", "Lowangen"); zones("maldra", "Maldra Keep")
zones("thorn", "Desert Thorn"); zones("gilvery", "Gilvery"); zones("runeforest", "Rune Forest"); zones("newkolvir", "New Kolvir")
zones("avarice", "Dungeon Avarice"); zones("wroth", "Dungeon Wroth"); zones("hillgiants", "A Hill Giant Refuge"); zones("toa", "Tower of Art")
zones("jmc", "The Joint Magical Consortium"); zones("emperorscrossroads", "Emperor's Crossroads"); zones("shlarksh", "Shlarksh")
zones("vesuvius", "Mount Vesuvius"); zones("takhtin", "Takhtin"); zones("dorathon", "The Fishing Village of Dorathon")
zones("winton", "The Hamlet of Winton"); zones("frostgiantskeep", "Forst Giant's Keep", "Frost Giant's Keep"); zones("deceit", "Dungeon Deceit")
zones("vandemaar", "Vandemaar's Keep"); zones("xalt", "Xalt, Unseelie Outpost"); zones("mulakanathos", "The Village of Mulakanathos")
zones("gorth", "Gorth"); zones("travelersretreat", "Traveler's Retreat"); zones("tavernoftheboars", "Tavern of the Boars")
zones("twinmoons", "Inn of the Twin Moons"); zones("lonelydragon", "The Lonely Dragon Inn"); zones("cenotaphy", "The Indestructible Cenotaphy")
zones("atlantis", "Atlantis"); zones("naulitas", "Naulitas"); zones("teolaven", "The Mountain Village of Teolaven")

local locations = {}
local function loc(key, continent, north, south, east, west, default_gate, qm, rep)
  locations[key] = { north = north, south = south, east = east, west = west, qm = qm, rep = rep, continent = continent,
    default_gate = default_gate or north or south or east or west }
end
-- key, continent, north, south, east, west, default_gate, qm, rep
loc("rune", "sepharia", "10435", "2832529", "2816440", "2809518", "2816440", "31323")
loc("sigil", "auryn", "3881069", "3908670", nil, nil, "3881069", "28450", "27890")
loc("newrigel", "sepharia", "2315135", "2358832", nil, nil, "2315135", "62566", "62036")
loc("xaventry", "sepharia", "2066541", "2105636", "2084947", "2087227", "2105636", "73968", "73100")
loc("tellerium", "avros", "2638058", "2656450", nil, nil, "2638058", "41852", "41790")
loc("templeton", "avros", "47337", nil, nil, "2309054", "2309054", "47421")
loc("piratescove", "beltane", "3288425", "3318326", "3295329", "3304508", "3304508")
loc("vospire", "auryn", nil, nil, "3765964", "3768246", "3765964")
loc("diocletian", "auryn", nil, "4189387")
loc("lowangen", "sepharia", nil, "2030293")
loc("maldra", "beltane", nil, "3573738", nil, nil, "3573738", "67947")
loc("thorn", "sepharia", nil, nil, "1807082", "1788665")
loc("decara", "underground", nil, nil, "11125213", nil, nil, "116546")
loc("vir", "underground", nil, nil, "12426873")
loc("gilvery", "sepharia", nil, nil, "1880596", "1880584", "1880584")
loc("runeforest", "sepharia", nil, nil, "2625535")
loc("newkolvir", "sepharia", nil, nil, nil, "3324605")
loc("avarice", "sepharia", "2377105")
loc("mandrake", "sepharia", nil, nil, "1900988")
loc("wroth", "sepharia", "1960870")
loc("hillgiants", "sepharia", nil, nil, nil, "2602424")
loc("toa", "sepharia", nil, nil, nil, "1547405")
loc("jmc", "sepharia", "1586161")
loc("emperorscrossroads", "auryn", nil, "4072040")
loc("shlarksh", "auryn", "3823947", "3835453")
loc("vesuvius", "auryn", "3729129")
loc("takhtin", "auryn", nil, "3844854")  -- technically beltane but runnable from auryn
loc("dorathon", "avros", nil, "2152729", "2145833", "2143525", "2143525")
loc("winton", "avros", "1964016")
loc("frostgiantskeep", "avros", nil, "1957223")
loc("deceit", "beltane", nil, "3525388")
loc("vandemaar", "beltane", "3925733")
loc("xalt", "beltane", nil, "3831487")
loc("mulakanathos", "beltane", "3900588")
loc("gorth", "beltane", nil, nil, nil, "3875363")
loc("travelersretreat", "sepharia", nil, nil, nil, "2558911")
loc("tavernoftheboars", "sepharia", nil, "2085131")
loc("twinmoons", "sepharia", nil, "1765641")
loc("lonelydragon", "sepharia", nil, "2669134")
loc("teolaven", "auryn", nil, nil, nil, "328834")
loc("cenotaphy", "beltane", nil, "3916564")
loc("atlantis", "ocean", "18892")
loc("naulitas", "ocean", nil, "4137902")
loc("cogworkcity", "sug", "17452076")
loc("renn", "sug", "17150349")

local function service(field, rows) for key, n in pairs(rows) do locations[key][field] = n end end
service("post", { rune = "10560", sigil = "28083", diocletian = "28988", newrigel = "62584", xaventry = "73154", tellerium = "41703",
  templeton = "46556", piratescove = "29943", vospire = "40267", lowangen = "15961", maldra = "68121" })
service("bank", { rune = "10592", sigil = "28014", diocletian = "28985", newrigel = "62529", xaventry = "73970", tellerium = "41702",
  templeton = "46001", piratescove = "29914", vospire = "40282", lowangen = "16072", maldra = "68067", decara = "116102" })
service("reagents", { rune = "10554", sigil = "28003", diocletian = "28987", newrigel = "62576", xaventry = "73745", templeton = "46405",
  piratescove = "29915", vospire = "39918", lowangen = "16062", maldra = "68111" })
service("locker", { rune = "10558", sigil = "28034", diocletian = "28984", newrigel = "62542", xaventry = "73156", tellerium = "41710",
  templeton = "45967", piratescove = "29894", vospire = "40266", lowangen = "16232", vir = "146151", decara = "116084" })

-- Default "goto next" commands, keyed by room number.
local default_sends = {}
local function dsend(key, dir, cmd) local n = locations[key][dir]; if n then default_sends[n] = cmd end end
dsend("rune", "east", "run newrigel"); dsend("rune", "west", "run xaventry")
dsend("sigil", "south", "run diocletian"); dsend("sigil", "north", "run vospire")
dsend("piratescove", "west", "run keep"); dsend("piratescove", "east", "run keep"); dsend("piratescove", "south", "run keep")
dsend("newrigel", "south", "run rune"); dsend("xaventry", "south", "run rune"); dsend("newrigel", "north", "run wroth")
dsend("tellerium", "north", "run templeton"); dsend("templeton", "west", "run tellerium")
dsend("diocletian", "south", "run sigil"); dsend("vospire", "east", "run sigil"); dsend("vospire", "west", "run vesuvius")
dsend("maldra", "south", "run pc"); dsend("decara", "east", "run vir"); dsend("vir", "east", "run decara")
default_sends["1960870"] = "run newrigel"

-- ---------------------------------------------------------------- custom sends (stored as "room<TAB>command" lines)
local function load_custom()
  user_sends = {}
  local raw = sget(KEY_CUSTOM, "")
  if type(raw) ~= "string" then return end
  for line in raw:gmatch("[^\n]+") do
    local r, c = line:match("^(%d+)\t(.*)$")
    if r then user_sends[r] = c end
  end
end

local function save_custom()
  local rows = {}
  for r, c in pairs(user_sends) do rows[#rows + 1] = r .. "\t" .. c end
  table.sort(rows)
  sset(KEY_CUSTOM, table.concat(rows, "\n"))
end

local function get_send(r)
  local u = user_sends[r]
  if u ~= nil then return u ~= "" and u or nil end  -- "" means the default was cleared
  return default_sends[r]
end

local function all_send_rooms()
  local seen, rooms = {}, {}
  for r in pairs(default_sends) do seen[r] = true end
  for r in pairs(user_sends) do seen[r] = true end
  for r in pairs(seen) do if get_send(r) then rooms[#rooms + 1] = r end end
  table.sort(rooms)
  return rooms
end

-- ---------------------------------------------------------------- location (GMCP Room.Info cache)
local function zone_key()
  if cur.zone == "Alyria" then
    for key, l in pairs(locations) do
      if l.north == cur.num or l.south == cur.num or l.west == cur.num or l.east == cur.num then return key end
    end
    return nil
  end
  return zone_key_map[cur.zone]
end

local function have_room()
  if cur.num then return true end
  say("No room data yet. Move one room, then try again (goto where shows what has arrived).")
  return false
end

local function destination(field)
  local key = zone_key()
  return key and locations[key][field] or nil
end

local function show_where()
  say("events=" .. events_seen .. "  room=" .. tostring(cur.num) .. "  zone=" .. tostring(cur.zone)
    .. "  plane=" .. tostring(cur.plane) .. "  town=" .. tostring(zone_key()))
  if events_seen == 0 then
    say("No Room.Info received yet; move one room.")
  elseif cur.zone and cur.zone ~= "Alyria" and not zone_key_map[cur.zone] then
    say("Zone '" .. cur.zone .. "' is not in the zone map (add it to the zones() table).")
  end
end

-- ---------------------------------------------------------------- goto actions
local function goto_field(field, label)
  if not have_room() then return end
  local n = destination(field)
  if n then dbg("mapper goto " .. n); execute("mapper goto " .. n)
  else say("There is no " .. label .. " for this location.") end
end

local function goto_or_act(field, label, action)
  if not have_room() then return end
  local n = destination(field)
  if not n then say("There is no " .. label .. " for this location."); return end
  if cur.num == n then send(action) else execute("mapper goto " .. n) end
end

local function show_locations()
  if not have_room() then return end
  local key = zone_key()
  if not key then say("There are no goto options from this location."); return end
  local l, out = locations[key], {}
  for _, f in ipairs({ "north", "south", "east", "west", "qm", "rep", "post", "bank", "reagents", "locker" }) do
    if l[f] then out[#out + 1] = (f == "locker") and "lockers" or f end
  end
  say("You can goto: " .. table.concat(out, ", "))
end

local function goto_next()
  if not have_room() then return end
  local cmd = get_send(cur.num)
  if cmd then dbg("next -> " .. cmd); execute(cmd)
  else say("This room has no custom send; use 'goto custom <text>' to set one.") end
end

local function custom_send(text)
  if not have_room() then return end
  text = (text or ""):match("^%s*(.-)%s*$")
  if text == "" then
    local c = get_send(cur.num)
    say(c and ("Room " .. cur.num .. " next: " .. c) or ("Room " .. cur.num .. " has no next command; use 'goto custom <text>'."))
  elseif text:lower() == "clear" then
    user_sends[cur.num] = default_sends[cur.num] and "" or nil
    save_custom(); say("The next command for this room has been cleared.")
  else
    user_sends[cur.num] = text
    save_custom(); say("'goto next' from this room will send: " .. text)
  end
end

local function goto_crystal()
  if not have_room() then return end
  local key = zone_key()
  if key == "rune" then
    if cur.num == "10407" then send("shop buy 1") else execute("mapper goto 10407") end
  elseif cur.zone == "Alyria" then send("run rune")
  elseif key == "xaventry" or key == "newrigel" then execute("mapper goto " .. locations[key].south)
  end
end

-- ---------------------------------------------------------------- orc pursuer
local function stop_pursuer() running_to_pursuer, leg_sent = false, false end

local function pursuer_step(initial)
  if not running_to_pursuer then return end
  local key = zone_key()
  dbg("pursuer step key=" .. tostring(key) .. " zone=" .. tostring(cur.zone) .. " room=" .. tostring(cur.num))

  if key == nil then
    if cur.zone == "Alyria" then
      if initial then say("Get to a gate to start running to the pursuer.") end
    else
      say("You don't know how to get there from here."); stop_pursuer()
    end
    return
  end

  if key == "wroth" then
    if initial and cur.num == "7461" then send("sayto orc yes"); send("nod orc"); stop_pursuer()
    elseif cur.num == "7682" then send("enter portal"); send("south"); stop_pursuer()
    elseif initial or cur.num == "1960870" then execute("mapper goto 7682") end
    return
  end

  local l = locations[key]
  if l.continent == "beltane" then say("You can't get there from Beltane."); stop_pursuer(); return end

  local target = (l.continent == "sepharia") and "run wroth" or "run rune"
  if cur.zone == "Alyria" then
    if not leg_sent then leg_sent = true; send(target) end  -- once per leg, not once per room on the road
  else
    leg_sent = false
    if initial then
      if l.default_gate then execute("mapper goto " .. l.default_gate)
      else say("Make your way to the gate outside to run to the pursuer.") end
    end
  end
end

local function goto_pursuer()
  if not have_room() then return end
  local key = zone_key()
  if (key == nil and cur.zone ~= "Alyria") or (key and locations[key].continent == "beltane") then
    say("You can't get to the orc pursuer from where you are!"); return
  end
  running_to_pursuer, leg_sent = true, false
  say("Running to the Orc Pursuer. 'goto cancel' stops after the current leg.")
  pursuer_step(true)
end

-- ---------------------------------------------------------------- run <place>
local function determine(destinations, input)
  local t = input:lower():match("^%s*(.-)%s*$")
  if destinations[t] then return destinations[t] end
  local matches, match, count = {}, nil, 0
  for shortcut, final in pairs(destinations) do
    if #shortcut >= #t and shortcut:sub(1, #t) == t and not matches[final] then
      matches[final], match, count = true, final, count + 1
    end
  end
  if count == 0 then return t end
  if count == 1 then return match end
  local names = {}
  for n in pairs(matches) do names[#names + 1] = n end
  table.sort(names)
  say("Ambiguous destination, choose between: " .. table.concat(names, ", "))
  return nil
end

local function forward_run(dest)
  forwarding_run = true
  send(dest ~= "" and ("run " .. dest) or "run")
  forwarding_run = false
end

local function try_run(dest)
  dest = (dest or ""):match("^%s*(.-)%s*$")
  if forwarding_run or not enabled or not cur.num then forward_run(dest); return end

  local final = dest
  if cur.plane == "Alyria" then
    local key = zone_key()
    local cont = key and locations[key].continent
    if cont and alyria_destinations[cont] then
      final = determine(alyria_destinations[cont], dest)
    else
      local all = {}
      for _, c in ipairs({ "sepharia", "auryn", "beltane", "avros" }) do
        for k, v in pairs(alyria_destinations[c]) do all[k] = v end
      end
      final = determine(all, dest)
    end
  elseif cur.plane == "Alyrian Underworld" then final = determine(underground_destinations, dest)
  elseif cur.plane == "Sigil Underground" then final = determine(sug_destinations, dest)
  end
  if final then dbg("run " .. final); forward_run(final) end
end

-- ---------------------------------------------------------------- help / dispatcher
local function show_help()
  rune.echo(H.title("Goto Aliases  (alias: goto)"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line("gotoAliases | goto", "show this help"))
  rune.echo(H.line("goto list", "what you can goto from here"))
  rune.echo(H.line("goto where", "show detected room, zone, plane and town"))
  rune.echo(H.line("goto north|east|south|west|gate", "run to that exit of the town"))
  rune.echo(H.line("goto next", "send the stored command for this room"))
  rune.echo(H.line("goto custom <text>", "set this room's next command (custom clear removes it)"))
  rune.echo(H.line("goto qm | rep | post | bank", "quest master, tourist rep, post office, bank"))
  rune.echo(H.line("goto reagents | lockers", "reagent shop, lockers"))
  rune.echo(H.line("goto crystal", "crystal quest office in Rune"))
  rune.echo(H.line("goto pursuer | cancel", "run to the Orc Pursuer / stop after this leg"))
  rune.echo(H.line("goto on|off", "enable or disable the plugin"))
  rune.echo(H.line("goto debug", "toggle debug messages"))
  rune.echo(H.section("Custom sends (room -> command)"))
  for _, r in ipairs(all_send_rooms()) do rune.echo(H.line(r, get_send(r))) end
  rune.echo(H.foot("v" .. VERSION .. "  enabled=" .. tostring(enabled) .. " debug=" .. tostring(DEBUG)
    .. " sends=" .. #all_send_rooms()))
end

local function set_enabled(on)
  enabled = on
  sset(KEY_ENABLED, on)
  if not on then stop_pursuer() end
  say(on and style.green("on") or style.red("off"))
end

local actions = {
  help = show_help,
  list = show_locations,
  where = show_where,
  north = function() goto_field("north", "north gate") end,
  south = function() goto_field("south", "south gate") end,
  east = function() goto_field("east", "east gate") end,
  west = function() goto_field("west", "west gate") end,
  gate = function() goto_field("default_gate", "gate") end,
  next = goto_next,
  qm = function() goto_or_act("qm", "quest master", "quest request 'rewarding'") end,
  rep = function() goto_or_act("rep", "town rep", "sayto representative yes") end,
  post = function() goto_field("post", "post office") end,
  bank = function() goto_field("bank", "bank") end,
  reagents = function() goto_field("reagents", "reagent shop") end,
  lockers = function() goto_field("locker", "lockers") end,
  crystal = goto_crystal,
  pursuer = goto_pursuer,
  cancel = function() say("You will stop when this leg completes."); stop_pursuer() end,
  on = function() set_enabled(true) end,
  off = function() set_enabled(false) end,
  debug = function() DEBUG = not DEBUG; sset(KEY_DEBUG, DEBUG); say("debug " .. (DEBUG and style.green("on") or style.red("off"))) end,
  ["custom"] = function(args) custom_send(type(args) == "string" and args or "") end,
  ["custom clear"] = function() custom_send("clear") end,
}

-- Subcommand -> action name (some words share an action).
local SUBS = { "", "help", "list", "where", "north", "south", "east", "west", "gate", "next", "qm", "rep", "post", "bank",
  "reagents", "reagent", "lockers", "locker", "crystal", "pursuer", "cancel", "on", "off", "debug", "custom", "custom clear" }
local ALIASED = { reagent = "reagents", locker = "lockers", [""] = "help" }

local function guarded(action)
  return function(args, ctx)
    local fn = actions[action]
    if not fn then return end
    -- Pause mutating actions while the plugin is off (help, on/off, debug, where stay available).
    if not enabled and action ~= "help" and action ~= "on" and action ~= "off" and action ~= "debug" and action ~= "where" then
      say("Plugin is off (goto on to enable).")
      return
    end
    fn(args, ctx)
  end
end

local function register_aliases(prefix)
  for _, sub in ipairs(SUBS) do
    local action = ALIASED[sub] or sub
    local command = prefix .. (sub ~= "" and (" " .. sub) or "")
    local ok, err = pcall(function() rune.alias.exact(command, guarded(action)) end)
    if not ok then say(style.red("could not register alias " .. command .. ": " .. tostring(err))) end
  end
end

-- "run <place>" shortcuts: one exact alias per known name, since exact aliases take no arguments.
local function register_run_aliases()
  local names, count = {}, 0
  for _, group in ipairs({ alyria_destinations.sepharia, alyria_destinations.auryn, alyria_destinations.avros,
    alyria_destinations.beltane, underground_destinations, sug_destinations }) do
    for shortcut in pairs(group) do names[shortcut] = true end
  end
  for shortcut in pairs(names) do
    local ok = pcall(function() rune.alias.exact("run " .. shortcut, function() try_run(shortcut) end) end)
    if ok then count = count + 1 end
  end
  dbg("registered " .. count .. " run shortcuts")
end

-- ---------------------------------------------------------------- startup
load_custom()

pcall(rune.gmcp.subscribe, "Room")
rune.gmcp.on("Room.Info", function(data)
  if type(data) ~= "table" then return end
  events_seen = events_seen + 1
  cur.num = data.num ~= nil and tostring(data.num) or nil
  cur.zone = data.zone
  cur.plane = type(data.coord) == "table" and data.coord.name or nil
  if running_to_pursuer then pursuer_step(false) end
end, { name = PLUGIN_NAME })

register_aliases(PLUGIN_NAME)
register_aliases(SHORT)
register_run_aliases()

say("v" .. VERSION .. " loaded (gotoAliases or goto for help)")