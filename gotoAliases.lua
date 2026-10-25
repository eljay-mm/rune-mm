-- Filename: eljayPlugins/gotoAliases.lua
-- Purpose: Aliases to run to gates, quest masters, banks, post offices and other places in the town you are in.
-- Version: 1.11
-- Date: 2026-Oct-25
--[[
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.11 Standard pass: exact aliases, persistent debug state, aligned help.
--   1.10 Standard pass, 23.3 KB to under 16 KB: compact town data parsed on first use, no exact-alias
--        fallback or load breakdown, saves read the latest store value, NAME/SHORT help rows.
--   1.9  Remove goto next and goto custom.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona.
--   * Reads GMCP Room.Info to work out which town you are in.
--   * Bare aliases gotoAliases and goto show help; arguments dispatch goto commands.
--   * goto north|east|south|west|gate runs the mapper to that town exit.
--   * goto qm and rep run to the destination, then act if already there.
--   * goto post|bank|reagents|lockers only runs the mapper; no action when
--     already at the destination.
--   * goto crystal runs to the crystal quest office in Rune.
--   * goto pursuer runs leg by leg towards the Orc Pursuer in Wroth.
--   * Town data is parsed on first use. Settings are saved in rune.store.
--
-- Commands (type without "/"; "goto" is a short alias for "gotoAliases"):
--   gotoAliases | goto               show this help
--   goto list                        show what you can goto from here
--   goto where                       show detected room, zone and town
--   goto north|east|south|west|gate  run to that exit of the current town
--   goto qm|rep|post|bank            quest master, tourist rep, post, bank
--   goto reagents|lockers            reagent shop, lockers
--   goto crystal                     crystal quest office in Rune
--   goto pursuer|cancel              run to the Orc Pursuer / stop after this leg
--   goto on|off                      enable or disable the plugin
--   goto debug [on|off]              toggle debug messages (default off)

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME = "gotoAliases"
local SHORT = "goto"
local VERSION = "1.11"
local STORE_KEY = "gotoAliases.settings"

local style = rune.style
local enabled, DEBUG = true, false
local LOAD_MS = 0
local cur, events = {}, 0
local pursuing, leg_sent = false, false

local function paint(color, text)
  local fn = style and style[color]
  return fn and fn(text) or text
end

local function say(msg)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. msg)
end

local function dbg(msg)
  if DEBUG then say(paint("gray", "debug: " .. msg)) end
end

local function send(cmd)
  rune.send(cmd)
end

local function execute(cmd)
  local fn = rune.execute or rune.exec
  if fn then
    local ok = pcall(fn, cmd)
    if ok then return end
  end
  send(cmd)
end

local function load_settings()
  local ok, settings = pcall(rune.store.get, STORE_KEY)
  if ok and type(settings) == "table" then return settings end
  return {}
end

local function update_settings(mutate)
  local settings = load_settings()
  mutate(settings)
  local ok, err = pcall(rune.store.set, STORE_KEY, settings)
  if not ok then
    say("could not save settings: " .. tostring(err))
    return false
  end
  enabled = settings.enabled ~= false
  DEBUG = settings.debug == true
  return true
end

do
  local settings = load_settings()
  enabled = settings.enabled ~= false
  DEBUG = settings.debug == true
end

-- Compact town data is parsed on first use.
local DATA = {
  "rune sepharia n10435 s2832529 e2816440 w2809518 g2816440 q31323 p10560 b10592 r10554 l10558 =Towne of Rune|Runic Castle|Player Homes - Rune|Rune Condominiums|Rune Estates|Rune Realty|Temple Crypt|Temple of Sumter|Winterborn Mansion|Focault Magic Equipment Company|Focault's Residence|Van Pelt's Emporium",
  "sigil auryn n3881069 s3908670 g3881069 q28450 t27890 p28083 b28014 r28003 l28034 =Sigil|The Sigilian Stronghold|Sigil Castle|Player Homes - Sigil|Sigil Condominiums|Sigil Realty",
  "newrigel sepharia n2315135 s2358832 g2315135 q62566 t62036 p62584 b62529 r62576 l62542 =The Towne of New Rigel|New Rigel Condominiums|New Rigel Gardens|New Rigel Realty|Player Homes - New Rigel",
  "xaventry sepharia n2066541 s2105636 e2084947 w2087227 g2105636 q73968 t73100 p73154 b73970 r73745 l73156 =The Towne of Xaventry|The Xaventry Stronghold|Xaventry Condominiums|Xaventry Realty",
  "tellerium avros n2638058 s2656450 g2638058 q41852 t41790 p41703 b41702 l41710 =Tellerium|Player Homes - Tellerium|Tellerium Condominiums|Tellerium Realty",
  "templeton avros n47337 w2309054 g2309054 q47421 p46556 b46001 r46405 l45967 =Templeton|The Templetonian Stronghold",
  "piratescove beltane n3288425 s3318326 e3295329 w3304508 g3304508 p29943 b29914 r29915 l29894 =Pirate's Cove|Pirate's Cove Realty|Player Homes - Pirates Cove",
  "vospire auryn e3765964 w3768246 g3765964 p40267 b40282 r39918 l40266 =Vospire",
  "diocletian auryn s4189387 p28988 b28985 r28987 l28984 =Palace of Diocletian",
  "lowangen sepharia s2030293 p15961 b16072 r16062 l16232 =Lowangen",
  "maldra beltane s3573738 g3573738 q67947 p68121 b68067 r68111 =Maldra Keep",
  "thorn sepharia e1807082 w1788665 =Desert Thorn",
  "decara underground e11125213 q116546 b116102 l116084 =Towne of Decara|Decara Condominiums|Decara Realty|Player Homes - Decara",
  "vir underground e12426873 l146151 =Vir|Vir Condominiums",
  "gilvery sepharia e1880596 w1880584 g1880584 =Gilvery",
  "runeforest sepharia e2625535 =Rune Forest",
  "newkolvir sepharia w3324605 =New Kolvir",
  "avarice sepharia n2377105 =Dungeon Avarice",
  "mandrake sepharia e1900988 =Mandrake Woods|Shadow Castle",
  "wroth sepharia n1960870 =Dungeon Wroth",
  "hillgiants sepharia w2602424 =A Hill Giant Refuge",
  "toa sepharia w1547405 =Tower of Art",
  "jmc sepharia n1586161 =The Joint Magical Consortium",
  "emperorscrossroads auryn s4072040 =Emperor's Crossroads",
  "shlarksh auryn n3823947 s3835453 =Shlarksh",
  "vesuvius auryn n3729129 =Mount Vesuvius",
  "takhtin auryn s3844854 =Takhtin",
  "dorathon avros s2152729 e2145833 w2143525 g2143525 =The Fishing Village of Dorathon",
  "winton avros n1964016 =The Hamlet of Winton",
  "frostgiantskeep avros s1957223 =Forst Giant's Keep|Frost Giant's Keep",
  "deceit beltane s3525388 =Dungeon Deceit",
  "vandemaar beltane n3925733 =Vandemaar's Keep",
  "xalt beltane s3831487 =Xalt, Unseelie Outpost",
  "mulakanathos beltane n3900588 =The Village of Mulakanathos",
  "gorth beltane w3875363 =Gorth",
  "travelersretreat sepharia w2558911 =Traveler's Retreat",
  "tavernoftheboars sepharia s2085131 =Tavern of the Boars",
  "twinmoons sepharia s1765641 =Inn of the Twin Moons",
  "lonelydragon sepharia s2669134 =The Lonely Dragon Inn",
  "teolaven auryn w328834 =The Mountain Village of Teolaven",
  "cenotaphy beltane s3916564 =The Indestructible Cenotaphy",
  "atlantis ocean n18892 =Atlantis",
  "naulitas ocean s4137902 =Naulitas",
  "cogworkcity sug n17452076 =",
  "renn sug n17150349 =",
}

local FIELD = {
  n = "north", s = "south", e = "east", w = "west", g = "default_gate",
  q = "qm", t = "rep", p = "post", b = "bank", r = "reagents", l = "locker",
}
local towns, zone_town, gate_town

local function load_data()
  if towns then return end
  towns, zone_town, gate_town = {}, {}, {}
  for _, row in ipairs(DATA) do
    local head, zones = row:match("^(.-)=(.*)$")
    local key, continent, rest = head:match("^(%S+) (%S+) ?(.*)$")
    local town = { continent = continent }
    for token in rest:gmatch("%S+") do
      local field = FIELD[token:sub(1, 1)]
      if field then town[field] = token:sub(2) end
    end
    town.default_gate = town.default_gate or town.north or town.south
      or town.east or town.west
    towns[key] = town
    for _, direction in ipairs({ "north", "south", "east", "west" }) do
      if town[direction] and not gate_town[town[direction]] then
        gate_town[town[direction]] = key
      end
    end
    for zone in zones:gmatch("[^|]+") do zone_town[zone] = key end
  end
end

local function town_key()
  load_data()
  if cur.zone == "Alyria" then return gate_town[cur.num] end
  return zone_town[cur.zone]
end

local function have_room()
  if cur.num then return true end
  say("No room data yet. Move one room, then try again.")
  say("Use " .. SHORT .. " where to see what room data has arrived.")
  return false
end

local function where()
  load_data()
  say("room=" .. tostring(cur.num) .. " zone=" .. tostring(cur.zone)
    .. " plane=" .. tostring(cur.plane) .. " town=" .. tostring(town_key())
    .. " events=" .. events)
  if cur.zone and cur.zone ~= "Alyria" and not zone_town[cur.zone] then
    say("Zone '" .. cur.zone .. "' is not in the town data (add it to DATA).")
  end
end

local function goto_field(field, label, action)
  if not have_room() then return end
  local key = town_key()
  local room = key and towns[key][field]
  if room then
    if action and cur.num == room then
      send(action)
    else
      dbg("mapper goto " .. room)
      execute("mapper goto " .. room)
    end
  else
    say("There is no " .. label .. " for this location.")
  end
end

local function list_options()
  if not have_room() then return end
  local key, out = town_key(), {}
  if not key then
    say("There are no goto options from this location.")
    return
  end
  for _, field in ipairs({
    "north", "south", "east", "west", "qm", "rep", "post", "bank",
    "reagents", "locker",
  }) do
    if towns[key][field] then
      out[#out + 1] = field == "locker" and "lockers" or field
    end
  end
  say("You can goto: " .. table.concat(out, ", "))
end

local function go_crystal()
  if not have_room() then return end
  local key = town_key()
  if key == "rune" then
    if cur.num == "10407" then send("shop buy 1")
    else execute("mapper goto 10407") end
  elseif cur.zone == "Alyria" then
    send("run rune")
  elseif key == "xaventry" or key == "newrigel" then
    execute("mapper goto " .. towns[key].south)
  else
    say("There is no crystal quest office route from this location.")
  end
end

local function pursuer_step(initial)
  if not pursuing then return end
  local key = town_key()
  if not key then
    if cur.zone ~= "Alyria" then
      say("You don't know how to get there from here.")
      pursuing = false
    elseif initial then
      say("Get to a gate to start running to the pursuer.")
    end
    return
  end

  if key == "wroth" then
    if initial and cur.num == "7461" then
      send("sayto orc yes")
      send("nod orc")
      pursuing = false
    elseif cur.num == "7682" then
      send("enter portal")
      send("south")
      pursuing = false
    elseif initial or cur.num == "1960870" then
      execute("mapper goto 7682")
    end
    return
  end

  local town = towns[key]
  if town.continent == "beltane" then
    say("You can't get there from Beltane.")
    pursuing = false
    return
  end

  if cur.zone == "Alyria" then
    if not leg_sent then
      leg_sent = true
      send(town.continent == "sepharia" and "run wroth" or "run rune")
    end
  else
    leg_sent = false
    if initial then
      if town.default_gate then
        execute("mapper goto " .. town.default_gate)
      else
        say("Make your way to the gate outside to run to the pursuer.")
      end
    end
  end
end

local function go_pursuer()
  if not have_room() then return end
  local key = town_key()
  if (not key and cur.zone ~= "Alyria")
      or (key and towns[key].continent == "beltane") then
    say("You can't get to the orc pursuer from where you are!")
    return
  end
  pursuing, leg_sent = true, false
  say("Running to the Orc Pursuer. '" .. SHORT
    .. " cancel' stops after the current leg.")
  pursuer_step(true)
end

local function help()
  local ok, H = pcall(require, "helpstyle")
  if not ok then
    H = {
      title = tostring,
      section = tostring,
      foot = tostring,
      line = function(a, b) return a .. "  " .. b end,
    }
  end

  local rows = {
    { NAME, "show this help" },
    { SHORT .. " list", "what you can goto here" },
    { SHORT .. " where", "show room, zone and town" },
    { SHORT .. " north|east|south|west|gate", "run to that town exit" },
    { SHORT .. " qm|rep|post|bank", "quest master, rep, post, bank" },
    { SHORT .. " reagents|lockers", "reagent shop, lockers" },
    { SHORT .. " crystal", "crystal quest office, Rune" },
    { SHORT .. " pursuer|cancel", "Orc Pursuer run / stop" },
    { SHORT .. " on|off", "enable or disable this plugin" },
    { SHORT .. " debug [on|off]", "toggle debug messages" },
    { SHORT, "short alias for " .. NAME },
  }

  local width = 0
  for _, row in ipairs(rows) do
    if #row[1] > width then width = #row[1] end
  end

  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  for _, row in ipairs(rows) do
    rune.echo(H.line(row[1] .. string.rep(" ", width - #row[1]), row[2]))
  end
  rune.echo(H.foot(string.format(
    "v%s  enabled=%s debug=%s  load=%dms",
    VERSION, tostring(enabled), tostring(DEBUG), LOAD_MS
  )))
end

local function set_enabled(on)
  if enabled == on then
    say(on and paint("green", "already on") or paint("red", "already off"))
    return
  end
  if not update_settings(function(settings) settings.enabled = on end) then
    return
  end
  if not on then pursuing = false end
  say(on and paint("green", "on") or paint("red", "off"))
end

local function set_debug(value)
  local next_value = value == "on" or (value ~= "off" and not DEBUG)
  if not update_settings(function(settings) settings.debug = next_value end) then
    return
  end
  say("debug " .. (DEBUG and paint("green", "on") or paint("red", "off")))
end

local FIELDS = {
  north = "north", south = "south", east = "east", west = "west",
  gate = "default_gate", post = "post", bank = "bank",
  reagents = "reagents", reagent = "reagents",
  lockers = "locker", locker = "locker",
}
local ACT = {
  help = help,
  list = list_options,
  where = where,
  crystal = go_crystal,
  pursuer = go_pursuer,
  qm = function()
    goto_field("qm", "quest master", "quest request 'rewarding'")
  end,
  rep = function()
    goto_field("rep", "town rep", "sayto representative yes")
  end,
  cancel = function()
    if pursuing then
      say("You will stop when this leg completes.")
      pursuing = false
    else
      say("No pursuer run is active.")
    end
  end,
  on = function() set_enabled(true) end,
  off = function() set_enabled(false) end,
  debug = set_debug,
}
local ALWAYS = { help = true, on = true, off = true, debug = true, where = true }

local function typed(args, ctx)
  if type(args) == "string" then return args end
  if type(args) == "table" then
    if type(args.line) == "string" then return args.line end
    if type(args.text) == "string" then return args.text end
    if type(args.args) == "string" then return args.args end
    if type(args[1]) == "string" then return table.concat(args, " ") end
  end
  if type(ctx) == "table" then
    if type(ctx.line) == "string" then return ctx.line end
    if type(ctx.text) == "string" then return ctx.text end
  end
  return ""
end

local function handle(command, args, ctx)
  local line = typed(args, ctx):match("^%s*(.-)%s*$")
  line = line:gsub("^" .. NAME .. "%s*", "")
  line = line:gsub("^" .. SHORT .. "%s*", "")
  local sub, arg = line:match("^(%S*)%s*(.-)$")
  sub = (sub or ""):lower()
  arg = (arg or ""):lower()
  if sub == "" then sub = "help" end

  if not enabled and not ALWAYS[sub] then
    say("Plugin is off (" .. SHORT .. " on to enable).")
    return
  end

  if FIELDS[sub] then
    goto_field(FIELDS[sub], sub)
  elseif ACT[sub] then
    ACT[sub](arg)
  else
    say("Unknown option '" .. sub .. "'. Type " .. SHORT .. " for help.")
  end
end

local ok_name, err_name = pcall(rune.alias.exact, NAME, handle)
if not ok_name then
  say(paint("red", "could not register " .. NAME .. " alias: " .. tostring(err_name)))
end
local ok_short, err_short = pcall(rune.alias.exact, SHORT, handle)
if not ok_short then
  say(paint("red", "could not register " .. SHORT .. " alias: " .. tostring(err_short)))
end

pcall(rune.gmcp.subscribe, "Room")
local ok_gmcp, err_gmcp = pcall(function()
  rune.gmcp.on("Room.Info", function(data)
    if type(data) ~= "table" then return end
    events = events + 1
    cur.num = data.num ~= nil and tostring(data.num) or nil
    cur.zone = data.zone
    cur.plane = type(data.coord) == "table" and data.coord.name or nil
    if pursuing then pursuer_step(false) end
  end, { name = NAME })
end)
if not ok_gmcp then
  say(paint("red", "could not register Room.Info handler: " .. tostring(err_gmcp)))
end

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
