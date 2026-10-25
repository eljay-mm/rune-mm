-- Filename: eljayPlugins/spdxyCoordinates.lua
-- Purpose: Walks to sextant coordinates, towns and clan halls, including unmapped wilderness
-- Version: 3.7
-- Date: 2026-Oct-25
--[[
- insert planning notes here between revisions.
]]
--   3.7  Under 16000 bytes: name lookup, nearby and waypoints moved to spdxyPlaces.lua
--        (loaded on first use); mapper fallback, find, here and manual pause removed;
--        waypoint saves re-read rune.store first.
--   3.6  Faster load: lazy helpstyle, one trigger, fewer aliases; load= in footer.
--   3.5  Bare commands are rune.alias.exact handlers; loader line; waypoint cap.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ruthgul.
--   * Each GMCP Room.Info gives coord.x/y. After every move the plugin recomputes the
--     shortest way to the target (the world wraps) and sends ONE compass step: a
--     diagonal while both axes are off, then straight. Knockbacks need no handling.
--   * Blocked steps are remembered per room and walked around. Water and combat
--     pause the walk; teleports and entering a building abort it. One combined
--     trigger watches for those lines, enabled only while walking.
--   * Towns, worldgates, clan halls, nearby and waypoints live in spdxyPlaces.lua,
--     loaded on first use (keep it out of initEljay's PLUGINS). Your plane only.
--   * Waypoints, the last destination and the last start live in rune.store.
--   * Works in the wilds only. `nearby [x, y]` alone equals `spdxy nearby [x, y]`.

local T0, load_ms = os.clock(), 0

-- Command names: full command and short alias.
local NAME = "spdxyCoordinates"
local SHORT = "spdxy"
local VERSION = "3.7"

local K_ON, K_DBG, K_WP, K_LAST, K_ORG = "spdxy.enabled", "spdxy.debug", "spdxy.places", "spdxy.last", "spdxy.origin"
local MAX_X, MAX_Y, MAX_WP = 2299, 1499, 100
local GROUP, WATCH = "spdxy-walk", "spdxy-watch"
-- zone (lowercase) -> plane letter, as used by the rows in spdxyPlaces.lua
local ZONES = { ["alyria"] = "a", ["faerie plane wilderness"] = "f",
  ["great alyrian underground"] = "u", ["sigil underground"] = "s", ["chat rooms wilderness"] = "c" }
local OLDP = { alyria = "a", faerie = "f", underground = "u", sug = "s" }

local function paint(c, t)
  local f = rune.style and rune.style[c]
  return type(f) == "function" and f(t) or t
end
local PREFIX = paint("cyan", "[" .. NAME .. "] ")
local function say(m) rune.echo(PREFIX .. m) end
local function emit(s) rune.echo(s) end
local enabled, debug_on = rune.store.get(K_ON) ~= false, rune.store.get(K_DBG) == true
local function dbg(f, ...)
  if debug_on then rune.echo(paint("yellow", "[" .. NAME .. " debug] ") .. f:format(...)) end
end
local function get(k)
  local ok, v = pcall(rune.store.get, k)
  return ok and type(v) == "table" and v or {}
end
local function put(k, v) pcall(rune.store.set, k, v) end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- x grows east, y grows south
local DIRS = { { "n", 0, -1 }, { "ne", 1, -1 }, { "e", 1, 0 }, { "se", 1, 1 },
  { "s", 0, 1 }, { "sw", -1, 1 }, { "w", -1, 0 }, { "nw", -1, -1 } }
local IDX, HEAD = {}, {}
for i, d in ipairs(DIRS) do IDX[d[1]] = i; HEAD[d[2] .. "," .. d[3]] = i end
local function sign(n) return n > 0 and 1 or n < 0 and -1 or 0 end
local function key(x, y) return ("%d,%d"):format(x, y) end
local function plane_of(zone) return zone and ZONES[tostring(zone):lower()] end
local function delta(a, b, max)
  local d = b - a
  if math.abs(d) > max / 2 then d = (d > 0 and -1 or 1) * math.max(max - math.abs(d), 1) end
  return d
end
local function dist(x1, y1, x2, y2)
  return math.max(math.abs(delta(x1, x2, MAX_X)), math.abs(delta(y1, y2, MAX_Y)))
end

local last, S = {}, nil
local on_line
local armed = false
local TRIG = [[^(?:You cannot move in that direction|You would surely need a grappling|You can't go there while mounted|You need a sailing vessel to go|The .+ (?:is|are) closed\.|The water current is too swift|You would need a (?:sailing vessel or|water-breathing)|A swirling vortex of sound|You hear a peal of thunder|A sudden, strong gust|Your mount is sitting|Not while you are in combat)]]

local function triggers(on)
  if on and not armed then
    rune.trigger.regex(TRIG, on_line, { name = "spdxy-walk-lines", group = GROUP })
    armed = true
  end
  local g = rune.group and (on and rune.group.enable or rune.group.disable)
  if g then pcall(g, GROUP) end
end
local function cleanup() S = nil; pcall(rune.timer.cancel, WATCH); triggers(false) end
local function abort(m) if m then say(m) end; cleanup() end
local function pause(m)
  if not S then return end
  S.paused, S.pending = true, false
  say(m .. (" '%s resume' continues, '%s stop' cancels."):format(SHORT, SHORT))
end

-- Walking ----------------------------------------------------------------------
local function pick(x, y, want, exits, bad)
  local best, bs
  for i, d in ipairs(DIRS) do
    local n = d[1]
    if not (bad and bad[n]) and not (exits and not exits[n]) then
      local df = math.abs(i - want)
      if df > 4 then df = 8 - df end
      local nx, ny = x + d[2], y + d[3]
      local sc = df * 2 + (S.visits[key(nx, ny)] or 0) * 3 + dist(nx, ny, S.tx, S.ty) * 0.01
      if not bs or sc < bs then best, bs = n, sc end
    end
  end
  return best
end

local function advance()
  if not S or S.paused then return end
  local x, y = last.x, last.y
  if not x then return abort("lost position; walk aborted.") end
  if x == S.tx and y == S.ty then
    say(("arrived at %d, %d (%d steps, %ds)."):format(x, y, S.steps, os.time() - S.t0))
    return cleanup()
  end
  local dx, dy, k = delta(x, S.tx, MAX_X), delta(y, S.ty, MAX_Y), key(x, y)
  local want = HEAD[sign(dx) .. "," .. sign(dy)]
  if S.steps >= S.max or not want then return abort("walk aborted at " .. k .. " (step limit).") end
  local dir = pick(x, y, want, last.exits, S.bad[k])
  if not dir then return pause("no usable exit from " .. k .. ".") end
  S.pending, S.from, S.dir, S.at = true, k, dir, os.time()
  S.steps = S.steps + 1
  dbg("step %d: %s from %s (target %d, %d)", S.steps, dir, k, S.tx, S.ty)
  rune.send(dir)
end

local function blocked()
  if not S or S.paused or not S.pending then return end
  S.bad[S.from] = S.bad[S.from] or {}
  S.bad[S.from][S.dir] = true
  dbg("blocked: %s at %s", S.dir, S.from)
  S.pending, S.retries = false, 0
  advance()
end

local function walk_to(tx, ty)
  if not enabled then return say(("disabled; type '%s on' to enable walking."):format(SHORT)) end
  put(K_LAST, { x = tx, y = ty })
  local pl = plane_of(last.zone)
  if not (last.x and pl) then return say("not in the wilds (or no GMCP position yet).") end
  if last.x == tx and last.y == ty then return say("already there.") end
  if S then cleanup() end
  put(K_ORG, { x = last.x, y = last.y, p = pl })
  local n = dist(last.x, last.y, tx, ty)
  S = { tx = tx, ty = ty, zone = last.zone, visits = { [key(last.x, last.y)] = 1 },
    bad = {}, steps = 0, retries = 0, max = n * 2 + 200, t0 = os.time() }
  triggers(true)
  say(("walking from %d, %d to %d, %d (~%d steps)..."):format(last.x, last.y, tx, ty, n))
  rune.timer.every(1, function()
    if not S or S.paused or not S.pending or os.time() - S.at < 2 then return end
    S.retries = S.retries + 1
    if S.retries > 3 then return pause("no movement after 3 retries.") end
    S.at = os.time()
    rune.send(S.dir)
  end, { name = WATCH })
  advance()
end

rune.gmcp.subscribe("Room")
rune.gmcp.on("Room.Info", function(d)
  if type(d) ~= "table" then return end
  local c = type(d.coord) == "table" and d.coord or {}
  last.x, last.y, last.zone, last.exits = tonumber(c.x), tonumber(c.y), d.zone or d.area, nil
  for k in pairs(type(d.exits) == "table" and d.exits or {}) do   -- compass exits only
    k = tostring(k):lower()
    if IDX[k] then last.exits = last.exits or {}; last.exits[k] = true end
  end
  if not S then return end
  if not last.x then return abort("room without coordinates; walk aborted.") end
  local k = key(last.x, last.y)
  if S.pending and k == S.from then return end
  S.pending, S.retries = false, 0
  if S.paused then return end
  if S.dir and tostring(last.zone) ~= tostring(S.zone) then
    local back = DIRS[((IDX[S.dir] + 3) % 8) + 1][1]
    abort("entered '" .. tostring(last.zone) .. "'; stepping back, walk aborted.")
    return rune.send(back)
  end
  S.visits[k] = (S.visits[k] or 0) + 1
  advance()
end, { name = "spdxy-room-info" })

on_line = function(_, ctx)
  if not S then return end
  local ok, t = pcall(function() return ctx.line:clean() end)
  if not ok or type(t) ~= "string" then return end
  dbg("trigger: %s", t)
  local function has(...)
    for _, w in ipairs({ ... }) do if t:find(w, 1, true) then return true end end
  end
  if has("water current", "levitation", "water-breathing") then pause("water ahead.")
  elseif has("swirling vortex", "peal of thunder") then abort("teleported; walk aborted.")
  elseif has("strong gust") then rune.send("stand"); if S.pending then S.at = os.time() end
  elseif has("mount is sitting") then rune.send("sayto mount stand")
  elseif has("in combat") then pause("you are in combat.")
  else blocked() end
end

-- Commands ---------------------------------------------------------------------
local function parse(s)   -- "x, y" or "x y"
  local a, b = s:match("^(-?%d+)%s*,%s*(-?%d+)$")
  if not a then a, b = s:match("^(-?%d+)%s+(-?%d+)$") end
  return tonumber(a), tonumber(b)
end


-- Names, nearby and waypoints live in spdxyPlaces.lua, loaded on first use.
local L
local function use(fn, ...)
  if not L then
    local ok, m = pcall(require, "eljayPlugins/spdxyPlaces")
    if not ok or type(m) ~= "function" then return say("cannot load spdxyPlaces.lua: " .. tostring(m)) end
    L = m({ say = say, get = get, put = put, trim = trim, dbg = dbg, last = last, plane_of = plane_of,
      delta = delta, dist = dist, parse = parse, walk_to = walk_to, SHORT = SHORT, K_WP = K_WP,
      MAX_WP = MAX_WP, MAX_X = MAX_X, MAX_Y = MAX_Y, OLDP = OLDP })
  end
  L[fn](...)
end

local function resume()
  if not (S and S.paused) then return say("nothing to resume.") end
  S.paused, S.pending, S.retries = false, false, 0
  advance()
end

local H
local function help()
  if not H then
    local ok, m = pcall(require, "helpstyle")
    H = ok and type(m) == "table" and m or { title = tostring, section = tostring, foot = tostring,
      line = function(c, d) return ("  %-26s %s"):format(c, d) end }
  end
  local n, w = 0, "idle"
  for _ in pairs(get(K_WP)) do n = n + 1 end
  if S then w = ("%d,%d%s"):format(S.tx, S.ty, S.paused and "(paused)" or "") end
  emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  emit(H.section("Commands"))
  emit(H.line(NAME, "show this help"))
  emit(H.section("Walk:"))
  emit(H.line(SHORT .. " <x>, <y>", "walk to coordinates"))
  emit(H.line(SHORT .. " <town>", "town, worldgate or waypoint"))
  emit(H.line(SHORT .. " clan <name|#>", "walk to a clan hall"))
  emit(H.line(SHORT .. " again | back", "last destination | last start"))
  emit(H.line(SHORT .. " stop | resume", "cancel | continue a paused walk"))
  emit(H.section("Look up:"))
  emit(H.line(SHORT .. " nearby [x, y]", "nearest known place (or: nearby)"))
  emit(H.section("Waypoints:"))
  emit(H.line(SHORT .. " save <name> [x y]", "save this spot or coordinates"))
  emit(H.line(SHORT .. " del <name> | list", "delete a waypoint | list them"))
  emit(H.section("Settings:"))
  emit(H.line(SHORT .. " on | off", "enable or disable walking"))
  emit(H.line(SHORT .. " debug on | off", "verbose walk and lookup messages"))
  emit(H.line(SHORT, "short alias for " .. NAME))
  emit(H.foot(("v%s  enabled=%s debug=%s waypoints=%d walk=%s load=%s"):format(VERSION,
    tostring(enabled), tostring(debug_on), n, w,
    load_ms < 0.5 and "<1ms" or ("%dms"):format(math.floor(load_ms + 0.5)))))
end

local function dispatch(arg)
  arg = trim(arg or "")
  if arg == "" then return help() end
  local x, y = parse(arg)
  if x then return walk_to(x, y) end
  local cmd, rest = arg:match("^(%S+)%s*(.-)$")
  cmd = cmd:lower()
  if cmd == "help" then help()
  elseif cmd == "stop" then if S then abort("walk cancelled.") else say("no walk in progress.") end
  elseif cmd == "resume" then resume()
  elseif cmd == "again" then
    local t = get(K_LAST)
    if t.x then walk_to(t.x, t.y) else say("no previous destination.") end
  elseif cmd == "back" then
    local o = get(K_ORG)
    if not o.x then say("no previous walk.")
    elseif plane_of(last.zone) ~= (o.p or OLDP[o.plane]) then say("your last start was on another plane.")
    else walk_to(o.x, o.y) end
  elseif cmd == "save" or cmd == "del" or cmd == "list" then use("waypoint", cmd, rest)
  elseif cmd == "nearby" then use("nearby", rest)
  elseif cmd == "clan" then use("query", rest, { clan = true })
  elseif cmd == "on" or cmd == "off" then
    enabled = cmd == "on"
    put(K_ON, enabled)
    if not enabled then abort() end
    say("walking " .. (enabled and "enabled" or "disabled (lookups still work)"))
  elseif cmd == "debug" then
    rest = trim(rest):lower()
    if rest == "on" or rest == "off" then debug_on = rest == "on" end
    put(K_DBG, debug_on)
    say("debug " .. (debug_on and "on" or "off"))
  else use("query", arg, { town = true, wp = true }) end
end

-- Bare forms are rune.alias.exact handlers (args, ctx); everything with arguments
-- is one regex alias. All go through dispatch().
local function bare(args, ctx) help() end
rune.alias.exact(NAME, bare, { name = NAME })
rune.alias.exact(SHORT, bare, { name = SHORT })
rune.alias.exact("nearby", function(args, ctx) use("nearby", "") end, { name = "nearby" })
rune.alias.regex("^(" .. NAME .. "|" .. SHORT .. "|nearby)[ ]+(.+)$", function(m)
  if m[1] == "nearby" then use("nearby", m[2]) else dispatch(m[2]) end
end, { name = SHORT .. "-args" })

load_ms = (os.clock() - T0) * 1000
say(("v%s loaded (%s or %s for help)%s"):format(VERSION, NAME, SHORT, enabled and "" or " - walking disabled"))