-- Filename: eljayPlugins/jmcSolver.lua
-- Purpose: Joint Magical Consortium (JMC) projectile puzzle - standalone solver (no website, no network).
-- Version: 1.16
-- Date: 2026-Oct-26
--[[
- insert planning notes here between revisions.
]]
-- Changelog:
--   1.16 Dropped mirrors survive a reload (rune.store); `plan` draws the map with progress; an unchanged puzzle reuses the last result; clearer map errors and a stale-look warning.
--   1.15 Walking order starts at A-1; the armed plan has an overall 15 minute limit (cfg.puzzletimeout) instead of an idle one.
--   1.14 `undo`: picks the mirrors you dropped back up from the floor as you reach each square (cfg.getcmd).
--   1.13 Stuck solve and idle plan expire (cfg.pendtimeout, cfg.plantimeout); squares listed in walking order, shorter walks win ties.
--   1.12 Lighter bound calculation (flat arrays, gate-count table, LuaJIT bit library when present); phase B skips impossible extra counts; `copy all` and a duplicate helper removed; `rules` fits 76 columns.
--   1.11 Clipboard method cached; solving runs in short slices via a Rune timer (falls back to one block); the line trigger is switched off while idle (falls back to always on).
--   1.10 Faster line trigger (cheap idle pre-check, no per-line closure); wall-clock solver limit (cfg.timelimit); comments rolled up; header commands list matches the help output.
--   1.9  Brought to standard: help rows use the short alias; only the mirror lines of the inventory are kept; single file; removed `again` and `set` (settings live in cfg at the top of the file).
--   1.8  NAME/SHORT command names, short-alias help row, load time in the footer, faster load.
--   1.7  Auto-drop of the chosen solution's mirrors on arrival at each grid square; arm / plan / stop.
--   1.0-1.6  Web solver replaced by a local one; several solutions to pick from (`*` = own mirrors); clipboard; on/off; help style.
--
-- How it works:
--   * `jmc solve` (or `jms`) sends `look console` and `inventory`, captures both replies and solves the puzzle locally.
--     From the look it reads the map, launcher (position + direction) and receiver; from the inventory it keeps your
--     "angled mirror rotated ..." lines. Nothing else is kept.
--   * Rules (inferred from the wiki ballistics guide): the beam moves cell by cell in 8 directions and a mirror turns it
--     by its angle; map edge, obstacle (X) and launcher stop it; it is delivered on entering the receiver after enough
--     distinct gates (#; 3, or all if fewer, `gates`); mirrors go on cells in `place` (. # X), never launcher/receiver.
--   * Solutions using only mirrors you carry come first, marked `*` (up to `maxm` mirrors, the fewest plus `more`);
--     fewer-mirror answers needing ones you lack follow, with the missing mirrors named. The search stops at `budget`
--     steps or `timelimit` seconds, whichever comes first.
--   * One solution is shown as the map with the mirrors drawn in plus a list like "90cw at C-12" (column letter - row
--     number, row 1 at the bottom); several are numbered one-liners and `jmc pick <n>` chooses one. The shown or picked
--     solution is copied to the clipboard (wl-copy / xclip / xsel / pbcopy, clip on Windows, OSC 52 last resort).
--   * Choosing a solution arms auto-drop: when "Grid X, N of the Projectile Testing Range" shows you on a planned square
--     the plugin sends `drop <keyword>` (90clock, 45clock, 90counter, 45counter) and counts it off when the game
--     confirms. It never moves you; `look` on a planned square drops its mirror if you armed while standing there.
--   * A solve that gets no reply gives up after `pendtimeout` s; an armed plan is dropped `puzzletimeout` s (15 min)
--     after it was armed. Squares are listed in walking order (nearest next, starting at A-1); shorter walks win ties.
--   * `jmc undo` reverses it: for each mirror dropped this session it sends `get <keyword>` on arriving at its square
--     (cfg.getcmd) and counts it off when the game says "You get/take/pick up an angled mirror ...".
--   * `jmc on|off` turns the capture trigger on or off (default on, remembered in rune.store); `jmc debug on|off`
--     toggles debug messages (default off); `jmc` alone shows the command summary with version, state and load time.
--
-- Commands (jmc is the short alias for jmcSolver):
--   Run:
--     jmc solve (jms)          look at console + inventory, then solve
--     jmc last                 show the last result again
--     jmc on | off             turn the capture trigger on or off
--   Choose:
--     jmc pick <n>             show, copy and arm solution n (* = own)
--     jmc copy [n]             copy the picked solution, or solution n
--   Place:
--     jmc arm [n]              drop mirrors as you reach each grid square
--     jmc plan                 show placed and still-to-place mirrors
--     jmc undo                 pick up the mirrors you dropped
--     jmc stop                 cancel auto-drop
--   Info:
--     jmc rules                show the rules the solver assumes
--     jmc selftest             solve two built-in puzzles, check answers
--     jmc debug on | off       toggle debug messages (default off)
--     jmc                      short alias for jmcSolver

local T0 = os.clock()      -- load timer, reported in the help footer
local LOAD_MS = 0

local VERSION = "1.16"

-- Command names: full command and short alias.
local NAME  = "jmcSolver"
local SHORT = "jmc"

-- Lines (Lua patterns) that frame the captures
local LOOK_HEADER = "^%s*You focus your powers of observation on the ignition console"
local ANY_LOOK    = "^%s*You focus your powers of observation on"
local INV_HEADER  = "^%s*You are carrying:"
local INV_EMPTY   = "^%s*You are not carrying anything"
local INV_END     = "^%s*You may carry a maximum of"
local GRID        = "^%s*Grid (%a), (%d+) of the Projectile Testing Range"
local PICKED      = "^You (%a+) .-an angled mirror rotated (%d+) degrees (%a+)"   -- "You get/take/pick up an angled mirror ..."
local PICK_VERBS  = { get = true, take = true, pick = true, grab = true }
local MIRROR_KEYS = { ["45cw"] = true, ["90cw"] = true, ["45ccw"] = true, ["90ccw"] = true }
local DROPPED     = "^You drop an angled mirror rotated (%d+) degrees (%a+)%."

-- Settings (edit here and reload the plugin)
local cfg = {
  debug    = false,        -- verbose [jmcSolver:debug] output
  gates    = "auto",       -- distinct gates to pass: auto (= min(3, gates on the map)) or a number
  place    = ".#X",        -- map characters a mirror may be placed on
  maxm     = 8,            -- most mirrors tried using only the ones you carry
  more     = 1,            -- larger mirror counts than the fewest to also list (own mirrors only)
  maxtotal = 10,           -- most mirrors tried when adding missing ones
  alts     = 5,            -- most solutions collected and listed
  copy     = true,         -- copy the shown/picked solution to the clipboard
  autodrop = true,         -- arm the chosen solution for auto-drop
  getcmd   = "get",        -- pick-up command word for `undo` (followed by e.g. 90clock)
  dropcmd  = "drop",       -- drop command word (followed by e.g. 90clock)
  clip     = "auto",       -- auto | osc | wl-copy | xclip | xsel | pbcopy | clip
  budget   = 1500000,      -- search steps per attempt before giving up
  timelimit = 3,           -- seconds the whole solve may take (CPU clock) before giving up
  lookcmd  = "look console",
  invcmd   = "inventory",
  pendtimeout = 10,        -- seconds `solve` waits for the game's look + inventory before giving up
  puzzletimeout = 900,     -- seconds an armed plan (drop or undo) may last overall, 15 min (0 = never)
  maxlines = 60,           -- cap on captured look lines
}

local state = {
  pending = false,                       -- `solve` is waiting for look + inventory
  fresh   = { look = false, inv = false },
  look    = nil,                         -- last captured console look (table of lines)
  inv     = nil,                         -- last captured mirror lines of the inventory
  last    = nil,                         -- last solved { P = puzzle, res = result }
  pick    = nil,                         -- index of the solution the player picked (or the only one)
  plan    = nil,                         -- armed auto-drop plan
  pendingAt = 0,                         -- os.time() when `solve` started waiting
  placed  = {},                          -- mirrors this plugin dropped ({ x, y, t }), for `undo`
  job     = nil,                         -- coroutine of a solve running in slices
}
local cap = { look = nil, inv = nil }    -- captures in progress

-- Persistence (rune.store): the on/off switch and every setting except debug
local function storeGet(key)
  if not (rune.store and rune.store.get) then return nil end
  local ok, v = pcall(rune.store.get, key)
  if ok then return v end
  return nil
end

local function storeSet(key, value)
  if rune.store and rune.store.set then pcall(rune.store.set, key, value) end
end

-- The mirrors this plugin dropped, kept across reloads for `undo`. Read-modify-write: load the latest saved
-- list, change it, save it, then use the saved copy
local function updatePlaced(change)
  local list = storeGet("jmcSolver.placed")
  if type(list) ~= "table" then list = {} end
  change(list)
  storeSet("jmcSolver.placed", list)
  state.placed = list
end

local enabled = true      -- read from rune.store on first use (ensureLoaded)
local loaded = false

-- The on/off state is read on first use, which keeps the load fast
local function ensureLoaded()
  if loaded then return end
  loaded = true
  enabled = (storeGet("jmcSolver.enabled") ~= false)
  local saved = storeGet("jmcSolver.placed")
  if type(saved) == "table" then
    for _, p in ipairs(saved) do
      if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and MIRROR_KEYS[p.t] then
        state.placed[#state.placed + 1] = { x = p.x, y = p.y, t = p.t }
      end
    end
  end
end

-- Output helpers ----
local function paint(color, text)
  local fn = rune.style and rune.style[color]
  if type(fn) == "function" then
    local ok, out = pcall(fn, text)
    if ok and out then return out end
  end
  return text
end

local function say(msg) rune.echo(paint("cyan", "[" .. NAME .. "] ") .. msg) end

local function dbg(msg)
  if cfg.debug then rune.echo(paint("blue", "[" .. NAME .. ":debug] ") .. msg) end
end

local function cleanLine(ln)
  if type(ln) == "string" then return ln:find("\r", 1, true) and (ln:gsub("\r", "")) or ln end
  local ok, t = pcall(ln.clean, ln)
  if ok and type(t) == "string" then return t:find("\r", 1, true) and (t:gsub("\r", "")) or t end
  return tostring(ln)
end

-- Rune API probes: timer and trigger-switch names are looked up and every call is guarded, so a missing
-- or different API only means the plugin falls back (solve in one block, trigger always on) ----
local TRIG, GROUP = "jmc-line", "jmc"
local trigOn, canSwitch = true, false

local function trySwitch(on)
  local verb = on and "enable" or "disable"
  for _, c in ipairs({ { rune.trigger, TRIG }, { rune.group, GROUP } }) do
    local fn = type(c[1]) == "table" and c[1][verb]
    if type(fn) == "function" and pcall(fn, c[2]) then return true end
  end
  return false
end

-- The catch-all trigger only needs to run while something is captured, pending or armed
local function refreshTrigger()
  if not canSwitch then return end
  local plan = state.plan
  local want = not not (enabled and (state.pending or cap.look or cap.inv or (plan and plan.remaining > 0)))
  if want ~= trigOn and trySwitch(want) then
    trigOn = want
    dbg("Line trigger " .. (want and "on" or "off"))
  end
end

local TIMER_FNS = { "after", "once", "delay" }
local function timerFn()
  if type(rune.timer) ~= "table" then return nil end
  for _, k in ipairs(TIMER_FNS) do
    if type(rune.timer[k]) == "function" then return rune.timer[k] end
  end
end

-- Run fn soon, from Rune's timer; false when there is no usable timer
local function later(fn, secs)
  local f = timerFn()
  return f ~= nil and pcall(f, secs or 0.02, fn)
end

-- Give up on a solve that never got its reply, and drop an armed plan that has run out of time
local function expireStale()
  local now = os.time()
  if state.pending and now - state.pendingAt >= cfg.pendtimeout then
    cap.look, cap.inv, state.pending = nil, nil, false
    say(paint("red", "No reply from the game") .. " - stand at the console and run: " .. NAME .. " solve")
    refreshTrigger()
  end
  local plan = state.plan
  if plan and cfg.puzzletimeout > 0 and now - plan.started >= cfg.puzzletimeout then
    state.plan = nil
    say("Puzzle time limit of " .. math.floor(cfg.puzzletimeout / 60) .. " min reached - plan dropped; " .. NAME .. " arm re-arms it")
    refreshTrigger()
  end
end

-- Puzzle model, solver and parsing ----

-- Directions 0..7 = N NE E SE S SW W NW; a mirror adds its rotation to the direction
local DX  = { [0] = 0, 1, 1, 1, 0, -1, -1, -1 }
local DY  = { [0] = 1, 1, 0, -1, -1, -1, 0, 1 }
local ROT = { ["45cw"] = 1, ["90cw"] = 2, ["45ccw"] = -1, ["90ccw"] = -2 }
local TYPES = { "90cw", "90ccw", "45cw", "45ccw" }
local GLYPH = { ["45cw"] = ">", ["45ccw"] = "<", ["90cw"] = "}", ["90ccw"] = "{" }
local FROM_GLYPH = { [">"] = "45cw", ["<"] = "45ccw", ["}"] = "90cw", ["{"] = "90ccw" }
local DIRWORD = { north = 0, northeast = 1, east = 2, southeast = 3, south = 4, southwest = 5, west = 6, northwest = 7 }

local POW = { [0] = 1 }
for i = 1, 20 do POW[i] = POW[i - 1] * 2 end

-- Is gate bit b set in mask m? Uses LuaJIT's bit library when Rune provides it, plain arithmetic otherwise
local band = type(bit) == "table" and bit.band
local hasBit = band and function(m, b) return band(m, POW[b]) ~= 0 end
  or function(m, b) return math.floor(m / POW[b]) % 2 == 1 end

local function cellName(x, y) return string.char(64 + x) .. "-" .. y end

-- Canonical key of a placement set: sorted "x,y,type" entries
local function solKey(list)
  local keys = {}
  for i, s in ipairs(list) do keys[i] = s.x .. "," .. s.y .. "," .. s.t end
  table.sort(keys)
  return table.concat(keys, ";")
end

-- Build a puzzle from map rows (top row first). Returns P or nil, err
local function makePuzzle(rows, lcol, lrow, ldir, rcol, rrow, owned)
  local H = #rows
  if H == 0 then return nil, "empty map" end
  local W = #rows[1]
  local P = { W = W, H = H, cells = {}, fixed = {}, gateBit = {}, ng = 0,
              lx = lcol, ly = lrow, ld = ldir, rx = rcol, ry = rrow, owned = owned or {} }
  for i, line in ipairs(rows) do
    if #line ~= W then return nil, string.format("map row %d has %d columns, expected %d", i, #line, W) end
    local y = H - i + 1
    for x = 1, W do
      local ch = line:sub(x, x)
      local p = (y - 1) * W + x
      if FROM_GLYPH[ch] then
        P.fixed[p] = FROM_GLYPH[ch]       -- a mirror already placed on the map
        ch = "."
        P.hasFixed = true
      end
      P.cells[p] = ch
      if ch == "#" then
        P.gateBit[p] = P.ng
        P.ng = P.ng + 1
      end
    end
  end
  if lcol < 1 or lcol > W or lrow < 1 or lrow > H then return nil, "launcher is outside the map" end
  if rcol < 1 or rcol > W or rrow < 1 or rrow > H then return nil, "receiver is outside the map" end
  if P.ng > 12 then return nil, "too many gates (" .. P.ng .. ") for this solver" end
  P.M = POW[P.ng]
  local pop = { [0] = 0 }      -- number of gates passed for every gate mask
  for m = 1, P.M - 1 do pop[m] = pop[(m - m % 2) / 2] + m % 2 end
  P.pop = pop
  local need = tonumber(cfg.gates)
  if not need then need = math.min(3, P.ng) end
  P.need = math.min(need, P.ng)
  P.place = {}
  for c in cfg.place:gmatch(".") do P.place[c] = true end
  P.place["O"] = nil
  -- try the mirror types you own most of first, so solutions lean on your stock
  P.typeOrder = {}
  for i, t in ipairs(TYPES) do P.typeOrder[i] = t end
  table.sort(P.typeOrder, function(a, b)
    local oa, ob = P.owned[a] or 0, P.owned[b] or 0
    if oa ~= ob then return oa > ob end
    return a < b
  end)
  P.maxm, P.maxtotal, P.budget, P.maxsol, P.more = cfg.maxm, cfg.maxtotal, cfg.budget, cfg.alts, cfg.more
  return P
end

local SLICE = 0.05      -- seconds of solving per timer slice

-- Called every few thousand steps: true when the time limit is up; yields when solving in slices
local function checkpoint(P)
  local now = os.clock()
  if now > P.deadline then P.timedOut = true; return true end
  if P.slice and now >= P.sliceEnd then
    coroutine.yield()
    P.sliceEnd = os.clock() + SLICE
  end
  return false
end

local function nodeKey(P, x, y, d, m)
  return ((((y - 1) * P.W + x) * 8) + d) * P.M + m
end

-- Admissible bound (fewest extra mirrors per beam state) that prunes the search. Returns hmap, h(start)
local function buildHeuristic(P)
  local W, H, M = P.W, P.H, P.M
  -- Flat arrays instead of a table per state/edge: reverse edges are linked lists (head/enext) of from/cost
  local seen, head, efrom, ecost, enext, goal, queue = {}, {}, {}, {}, {}, {}, {}
  local ne, qn, qi = 0, 1, 1
  local startKey = nodeKey(P, P.lx, P.ly, P.ld, 0)
  seen[startKey], queue[1] = true, startKey

  local function addEdge(from, nx, ny, nd, nm, cost)
    local k = nodeKey(P, nx, ny, nd, nm)
    if not seen[k] then
      seen[k] = true
      qn = qn + 1
      queue[qn] = k
    end
    ne = ne + 1
    efrom[ne], ecost[ne], enext[ne] = from, cost, head[k]
    head[k] = ne
  end

  while qi <= qn do
    if qi % 4096 == 0 and checkpoint(P) then return nil end
    local k = queue[qi]; qi = qi + 1
    local m = k % M                    -- decode the state: key = ((cell * 8) + dir) * M + gates
    local r = (k - m) / M
    local d = r % 8
    local p0 = (r - d) / 8
    local x = (p0 - 1) % W + 1
    local y = (p0 - x) / W + 1
    local nx, ny = x + DX[d], y + DY[d]
    if nx >= 1 and nx <= W and ny >= 1 and ny <= H then
      if nx == P.rx and ny == P.ry then
        if P.pop[m] >= P.need then goal[k] = true end
      elseif not (nx == P.lx and ny == P.ly) then
        local p = (ny - 1) * W + nx
        local ch = P.cells[p]
        local m2 = m
        local gb = P.gateBit[p]
        if gb and not hasBit(m, gb) then m2 = m + POW[gb] end
        local fx = P.fixed[p]
        if fx then
          addEdge(k, nx, ny, (d + ROT[fx]) % 8, m2, 0)
        else
          if ch ~= "X" then addEdge(k, nx, ny, d, m2, 0) end
          if P.place[ch] then
            for _, t in ipairs(TYPES) do
              addEdge(k, nx, ny, (d + ROT[t]) % 8, m2, 1)
            end
          end
        end
      end
    end
  end

  local h = {}
  local buckets = { [0] = {} }
  for k in pairs(goal) do
    h[k] = 0
    buckets[0][#buckets[0] + 1] = k
  end
  for c = 0, 64 do
    local b = buckets[c]
    if b then
      local i = 1
      while i <= #b do
        local k = b[i]; i = i + 1
        if h[k] == c then
          local e = head[k]
          while e do
            local f, nd = efrom[e], c + ecost[e]
            if h[f] == nil or nd < h[f] then
              h[f] = nd
              local nb = buckets[nd]
              if not nb then nb = {}; buckets[nd] = nb end
              nb[#nb + 1] = f
            end
            e = enext[e]
          end
        end
      end
    end
  end
  return h, h[startKey]
end

-- Exact depth-limited search for consistent placements with exactly `target` mirrors (at most
-- `extraAllowed` of them beyond what you carry). Collects up to P.maxsol distinct solutions.
-- Returns list of solutions (each a list of {x, y, t}), aborted(bool), nodes
local function search(P, hmap, target, extraAllowed)
  local W, H = P.W, P.H
  local placed, order, passed, counts = {}, {}, {}, {}
  local extra, nodes, aborted = 0, 0, false
  local sols, seen = {}, {}
  local limit = 2 * W * H

  local function record()
    local list, keys = {}, {}
    for i, p in ipairs(order) do
      list[i] = { x = (p - 1) % W + 1, y = math.floor((p - 1) / W) + 1, t = placed[p] }
      keys[i] = p .. ":" .. placed[p]
    end
    table.sort(keys)
    local key = table.concat(keys, ",")
    if not seen[key] then
      seen[key] = true
      sols[#sols + 1] = list
    end
  end

  local dfs
  dfs = function(x, y, d, m, k, steps)
    local marked = {}
    while true do
      nodes = nodes + 1
      if nodes > P.budget then aborted = true; break end
      if nodes % 4096 == 0 and checkpoint(P) then aborted = true; break end
      steps = steps + 1
      if steps > limit then break end
      local nx, ny = x + DX[d], y + DY[d]
      if nx < 1 or nx > W or ny < 1 or ny > H then break end
      if nx == P.rx and ny == P.ry then
        if P.pop[m] >= P.need then record() end
        break
      end
      if nx == P.lx and ny == P.ly then break end

      local p = (ny - 1) * W + nx
      local gb = P.gateBit[p]
      if gb and not hasBit(m, gb) then m = m + POW[gb] end
      local fx = P.fixed[p] or placed[p]
      if fx then
        d = (d + ROT[fx]) % 8
        x, y = nx, ny
      else
        local ch = P.cells[p]
        if k < target and P.place[ch] and not passed[p] then
          for _, t in ipairs(P.typeOrder) do
            local over = (counts[t] or 0) >= (P.owned[t] or 0)
            if (not over) or extra < extraAllowed then
              local nd = (d + ROT[t]) % 8
              local hh = hmap[nodeKey(P, nx, ny, nd, m)]
              if hh and k + 1 + hh <= target then
                placed[p] = t
                order[#order + 1] = p
                counts[t] = (counts[t] or 0) + 1
                if over then extra = extra + 1 end
                dfs(nx, ny, nd, m, k + 1, steps)
                if over then extra = extra - 1 end
                counts[t] = counts[t] - 1
                order[#order] = nil
                placed[p] = nil
                if aborted or #sols >= P.maxsol then break end
              end
            end
          end
          if aborted or #sols >= P.maxsol then break end
        end
        if ch == "X" then break end
        local hh = hmap[nodeKey(P, nx, ny, d, m)]
        if not hh or k + hh > target then break end
        passed[p] = true
        marked[#marked + 1] = p
        x, y = nx, ny
      end
    end
    for _, c in ipairs(marked) do passed[c] = nil end
  end

  dfs(P.lx, P.ly, P.ld, 0, 0, 0)
  return sols, aborted, nodes
end

-- Visit order for a solution's squares: nearest next square (Manhattan) starting at A-1;
-- also returns the walk length, used to break ties between equally good solutions
local function walkOrder(list)
  local left, out, total = {}, {}, 0
  for i, s in ipairs(list) do left[i] = s end
  local cx, cy = 1, 1
  while #left > 0 do
    local bi, bd = 1, nil
    for i, s in ipairs(left) do
      local dist = math.abs(s.x - cx) + math.abs(s.y - cy)
      if not bd or dist < bd then bi, bd = i, dist end
    end
    local s = table.remove(left, bi)
    out[#out + 1] = s
    total = total + bd
    cx, cy = s.x, s.y
  end
  return out, total
end

-- Returns { ok = true, solutions = { {list, n, missing = {type = n}, nmiss}, ... } } or { ok = false, why = "..." }
-- Solutions made only of mirrors you carry (nmiss == 0) come first.
local function solvePuzzle(P)
  P.deadline, P.timedOut, P.sliceEnd = os.clock() + cfg.timelimit, false, os.clock() + SLICE
  local hmap, h0 = buildHeuristic(P)
  if P.timedOut then return { ok = false, why = "time limit reached (raise cfg.timelimit in jmcSolver.lua)" } end
  if not h0 then
    return { ok = false, why = "the beam cannot reach the receiver even with unlimited mirrors under the current rules" }
  end
  dbg(string.format("Bound: at least %d mirror(s) needed; %d gate(s) on the map, %d required", h0, P.ng, P.need))

  local totalOwned = 0
  for _, t in ipairs(TYPES) do totalOwned = totalOwned + (P.owned[t] or 0) end

  local entries, seen, aborted = {}, {}, false
  local function add(sols)
    for _, sol in ipairs(sols) do
      if #entries >= P.maxsol then return end
      local key = solKey(sol)
      if not seen[key] then
        seen[key] = true
        local counts, missing, nmiss = {}, {}, 0
        for _, s in ipairs(sol) do counts[s.t] = (counts[s.t] or 0) + 1 end
        for t, n in pairs(counts) do
          local short = n - (P.owned[t] or 0)
          if short > 0 then missing[t] = short; nmiss = nmiss + short end
        end
        local _, walk = walkOrder(sol)
        entries[#entries + 1] = { list = sol, n = #sol, missing = missing, nmiss = nmiss, walk = walk, idx = #entries + 1 }
      end
    end
  end

  -- A: only mirrors you carry; the fewest count that works plus `more` larger counts
  local bestA
  for target = h0, math.min(P.maxm, totalOwned) do
    if (bestA and target > bestA + P.more) or #entries >= P.maxsol then break end
    local sols, ab, nodes = search(P, hmap, target, 0)
    dbg(string.format("Owned mirrors only, %d mirror(s): %d found (%d steps)", target, #sols, nodes))
    if #sols > 0 then
      bestA = bestA or target
      add(sols)
    end
    if ab then aborted = true; break end
  end

  -- B: fewer mirrors than the best A (or any, if A found nothing), adding mirrors you lack
  local limitB = math.min(P.maxtotal, bestA and (bestA - 1) or P.maxtotal)
  if not aborted then
    local foundB = false
    for target = h0, limitB do
      for e = math.max(1, target - totalOwned), target do      -- fewer extras than this cannot work
        local sols, ab, nodes = search(P, hmap, target, e)
        dbg(string.format("%d mirror(s), up to %d extra: %d found (%d steps)", target, e, #sols, nodes))
        if #sols > 0 then
          local saved = P.maxsol
          P.maxsol = #entries + saved
          add(sols)
          P.maxsol = saved
          foundB = true
          break
        end
        if ab then aborted = true; break end
      end
      if foundB or aborted then break end
    end
  end

  if #entries == 0 then
    if aborted then
      return { ok = false, why = P.timedOut and "time limit reached (raise cfg.timelimit in jmcSolver.lua)"
        or "search budget exhausted (raise cfg.budget in jmcSolver.lua)" }
    end
    return { ok = false, why = string.format("no solution with up to %d mirrors", math.max(P.maxm, P.maxtotal)) }
  end
  table.sort(entries, function(a, b)
    local sa, sb = (a.nmiss == 0), (b.nmiss == 0)
    if sa ~= sb then return sa end
    if a.n ~= b.n then return a.n < b.n end
    if a.nmiss ~= b.nmiss then return a.nmiss < b.nmiss end
    if a.walk ~= b.walk then return a.walk < b.walk end
    return a.idx < b.idx
  end)
  return { ok = true, solutions = entries }
end

local MAPROW = "^[%.#XO<>{}]+$"

-- Returns puzzle or nil, err
local function parseLook(lines, owned)
  -- the map: the run of map rows after the legend (or the first long run of map rows)
  local start = nil
  for i, l in ipairs(lines) do
    if l:find("^<%s*%-%s*Placed Mirror") then start = i + 1; break end
  end
  if start then
    while lines[start] and lines[start]:match("^%s*$") do start = start + 1 end
  else
    for i = 1, #lines do
      if lines[i]:find(MAPROW) and lines[i + 1] and lines[i + 1]:find(MAPROW) then start = i; break end
    end
  end
  if not start then return nil, "no map found in the console look" end

  local rows = {}
  for i = start, #lines do
    local l = lines[i]:gsub("%s+$", "")
    if l:find(MAPROW) then
      rows[#rows + 1] = l
    elseif l ~= "" and not l:find("%s") and (#rows == 0 or #l == #rows[1]) then
      return nil, string.format("unrecognised map symbol '%s' in map row %d", l:match("[^%.#XO<>{}]"), #rows + 1)
    else
      break
    end
  end
  if #rows < 2 then return nil, "map rows not recognised" end

  -- launcher and receiver (the last pair in the text wins)
  local ldir, lcol, lrow, rcol, rrow
  for _, l in ipairs(lines) do
    local dw, lc, lr = l:match("shot (%a+) from Grid (%a), (%d+)")
    if dw and DIRWORD[dw:lower()] then
      ldir, lcol, lrow = DIRWORD[dw:lower()], lc:upper():byte() - 64, tonumber(lr)
    end
    local rc, rr = l:match("catcher located in Grid (%a), (%d+)")
    if rc then rcol, rrow = rc:upper():byte() - 64, tonumber(rr) end
  end
  if not ldir then return nil, "launcher line ('The projectile will be shot ...') not found" end
  if not rcol then return nil, "receiver line ('... catcher located in Grid ...') not found" end

  return makePuzzle(rows, lcol, lrow, ldir, rcol, rrow, owned)
end

local function mirrorCounts(invLines)
  local owned = {}
  for _, l in ipairs(invLines) do
    if l:lower():find("angled mirror", 1, true) then
      local n = tonumber(l:match("^%s*%(%s*(%d+)%)")) or 1
      local deg, dir = l:match("rotated (%d+) degrees (%a+)")
      if deg and dir then
        local suffix = (dir == "counterclockwise") and "ccw" or ((dir == "clockwise") and "cw" or nil)
        if suffix and ROT[deg .. suffix] then
          local t = deg .. suffix
          owned[t] = (owned[t] or 0) + n
        end
      end
    end
  end
  return owned
end


-- Clipboard, auto-drop and showing solutions ----

-- Clipboard ----
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local NULL = IS_WINDOWS and "nul" or "/dev/null"

local function hasTool(name)
  local probe = IS_WINDOWS and ("where " .. name .. " 2>" .. NULL) or ("command -v " .. name .. " 2>" .. NULL)
  local ok, p = pcall(io.popen, probe)
  if not ok or not p then return false end
  local out = p:read("*l")
  p:close()
  return out ~= nil and out ~= ""
end

local EXTERNAL = {
  ["wl-copy"] = "wl-copy",
  ["xclip"]   = "xclip -selection clipboard",
  ["xsel"]    = "xsel --clipboard --input",
  ["pbcopy"]  = "pbcopy",
  ["clip"]    = "clip",
}

local autoClip      -- method found by auto-detection, cached because detection spawns shell commands

local function pickClipMethod()
  if cfg.clip ~= "auto" then return cfg.clip end
  if autoClip then return autoClip end
  if IS_WINDOWS then autoClip = hasTool("clip") and "clip" or "osc"
  elseif os.getenv("WAYLAND_DISPLAY") and hasTool("wl-copy") then autoClip = "wl-copy"
  elseif os.getenv("DISPLAY") and hasTool("xclip") then autoClip = "xclip"
  elseif os.getenv("DISPLAY") and hasTool("xsel") then autoClip = "xsel"
  elseif hasTool("pbcopy") then autoClip = "pbcopy"
  else autoClip = "osc" end
  return autoClip
end

-- Returns ok(boolean), method(string), err(string|nil)
local function copyToClipboard(text)
  text = text:gsub("\r", ""):gsub("[\1-\8\11-\31\127]", "")
  local method = pickClipMethod()
  if method == "osc" then
    if not (rune.clipboard and rune.clipboard.set) then
      return false, method, "rune.clipboard is not available in this Rune version"
    end
    local ok, err = pcall(rune.clipboard.set, text)
    if not ok then return false, method, tostring(err) end
    return true, method
  end
  local cmd = EXTERNAL[method]
  if not cmd then return false, method, "unknown clipboard method" end
  if IS_WINDOWS then text = text:gsub("\n", "\r\n") end
  local okp, p = pcall(io.popen, cmd .. " 2>" .. NULL, "w")
  if not okp or not p then
    return false, method, "io.popen is not available (try cfg.clip = \"osc\" in jmcSolver.lua)"
  end
  p:write(text)
  p:close()
  return true, method
end

local function doCopy(text, announce)
  local ok, method, err = copyToClipboard(text)
  if ok then
    local msg = string.format("Copied %d chars (%d lines) to clipboard via %s",
      #text, select(2, text:gsub("\n", "\n")) + 1, method)
    if announce then say(msg) else dbg(msg) end
  else
    say(paint("red", "Clipboard copy failed (" .. method .. "): ") .. tostring(err))
  end
  return ok
end

-- Auto-drop ----
-- Drop keywords as the game accepts them (seen: `drop 90clock`, `drop 45counter`; the others follow the pattern)
local MIRROR_KEY = { ["45cw"] = "45clock", ["90cw"] = "90clock", ["45ccw"] = "45counter", ["90ccw"] = "90counter" }

local function planLeft(plan)
  local left = {}
  for _, e in ipairs(plan.entries) do
    if not e.done then left[#left + 1] = cellName(e.x, e.y) .. " " .. e.t end
  end
  return left
end

local function missingList(entry)
  local miss = {}
  for _, t in ipairs(TYPES) do
    if entry.missing[t] then miss[#miss + 1] = entry.missing[t] .. " " .. t end
  end
  return miss
end

-- Arm the mirrors of one solution; `force` ignores the autodrop setting (explicit `arm`)
local function armPlan(res, idx, force)
  if not (cfg.autodrop or force) then state.plan = nil; refreshTrigger(); return end   -- choosing another solution drops an older plan
  local entry = res.solutions[idx]
  if not entry then return end
  local entries = {}
  for i, s in ipairs((walkOrder(entry.list))) do entries[i] = { x = s.x, y = s.y, t = s.t } end
  state.plan = { entries = entries, remaining = #entries, at = nil, idx = idx, started = os.time() }
  refreshTrigger()
  say(string.format("Auto-drop armed (solution %d): walk to %s - each mirror is dropped on arrival (%s stop cancels)",
    idx, table.concat(planLeft(state.plan), ", "), NAME))
  local miss = missingList(entry)
  if #miss > 0 then
    say(paint("red", "You lack: ") .. table.concat(miss, ", ") .. " - those squares cannot be completed")
  end
end

-- You arrived on grid square (x, y): drop the mirror planned there
local function arrival(x, y)
  local plan = state.plan
  plan.at = { x, y }
  for _, e in ipairs(plan.entries) do
    if e.x == x and e.y == y and not e.done and (not e.sent or os.time() - e.sent >= 3) then
      e.sent = os.time()
      local verb = (plan.mode == "undo") and cfg.getcmd or cfg.dropcmd
      dbg(string.format("Arrived at %s: %s %s", cellName(x, y), verb, e.t))
      rune.send(verb .. " " .. MIRROR_KEY[e.t])
    end
  end
end

-- The game confirmed a drop (or, in undo mode, a pick-up) of mirror type t on the square you are standing on
local function confirmDrop(t)
  local plan = state.plan
  if not plan.at then return end
  for _, e in ipairs(plan.entries) do
    if e.x == plan.at[1] and e.y == plan.at[2] and e.t == t and not e.done then
      e.done = true
      plan.remaining = plan.remaining - 1
      local undo = plan.mode == "undo"
      updatePlaced(function(list)
        if not undo then
          list[#list + 1] = { x = e.x, y = e.y, t = e.t }
          return
        end
        for i, p in ipairs(list) do
          if p.x == e.x and p.y == e.y and p.t == e.t then table.remove(list, i); break end
        end
      end)
      if plan.remaining == 0 then
        if undo then
          say(paint("green", "All mirrors are picked up"))
        else
          say(paint("green", "All mirrors are in place") .. " - push the console to start the test")
        end
        refreshTrigger()
      else
        say(string.format("%s %s at %s - %d to go", undo and "Picked up" or "Placed", e.t, cellName(e.x, e.y), plan.remaining))
      end
      return
    end
  end
end

-- The map with the plan's mirrors drawn in: still to do yellow, done green (picked-up ones disappear)
local function planMap(P, plan)
  local at = {}
  for _, e in ipairs(plan.entries) do at[(e.y - 1) * P.W + e.x] = e end
  local undo = plan.mode == "undo"
  local rows = {}
  for y = P.H, 1, -1 do
    local parts = {}
    for x = 1, P.W do
      local p = (y - 1) * P.W + x
      local e = at[p]
      if e and not (undo and e.done) then
        parts[#parts + 1] = paint(e.done and "green" or "yellow", GLYPH[e.t])
      elseif P.fixed[p] then
        parts[#parts + 1] = GLYPH[P.fixed[p]]
      else
        parts[#parts + 1] = P.cells[p]
      end
    end
    rows[#rows + 1] = table.concat(parts)
  end
  return rows
end

local function planStatus()
  local plan = state.plan
  if not plan then
    say("No mirrors armed - choose a solution first: " .. NAME .. " pick <n>")
    return
  end
  local left = planLeft(plan)
  local done, todo = "placed", "place"
  if plan.mode == "undo" then done, todo = "picked up", "pick up" end
  if #left == 0 then
    say("All " .. #plan.entries .. " mirrors are " .. done)
  else
    say(string.format("%d of %d %s; still to %s: %s", #plan.entries - #left, #plan.entries, done, todo, table.concat(left, ", ")))
  end
  local P = state.last and state.last.P
  if P then
    for _, e in ipairs(plan.entries) do
      if e.x > P.W or e.y > P.H then return end      -- the plan belongs to another puzzle
    end
    rune.echo("")
    for _, r in ipairs(planMap(P, plan)) do rune.echo(r) end
    rune.echo("")
  end
end

-- Showing a solution ----
local function mapRows(P, entry, colored)
  local at = {}
  for _, s in ipairs(entry.list) do at[(s.y - 1) * P.W + s.x] = s.t end
  local rows = {}
  for y = P.H, 1, -1 do
    local parts = {}
    for x = 1, P.W do
      local p = (y - 1) * P.W + x
      if at[p] then
        local g = GLYPH[at[p]]
        parts[#parts + 1] = colored and paint("yellow", g) or g
      elseif P.fixed[p] then
        parts[#parts + 1] = GLYPH[P.fixed[p]]
      else
        parts[#parts + 1] = P.cells[p]
      end
    end
    rows[#rows + 1] = table.concat(parts)
  end
  return rows
end

local function placements(entry)
  local out = {}
  for i, s in ipairs(entry.list) do out[i] = string.format("%s at %s", s.t, cellName(s.x, s.y)) end
  return out
end

-- One-line form: "[5] 90cw at A-2, 45ccw at B-2, ..." (+ missing mirrors)
local function oneLine(entry)
  local line = string.format("[%d] %s", entry.n, table.concat(placements(entry), ", "))
  local miss = missingList(entry)
  if #miss > 0 then line = line .. "  [missing: " .. table.concat(miss, ", ") .. "]" end
  return line
end

-- Plain text of one solution, as the website prints it (used for the clipboard)
local function solutionText(P, entry)
  local out = { string.format("FOUND SOLUTION WITH %d MIRROR(s)", entry.n), "" }
  for _, r in ipairs(mapRows(P, entry, false)) do out[#out + 1] = r end
  out[#out + 1] = ""
  for _, l in ipairs(placements(entry)) do out[#out + 1] = l end
  local miss = missingList(entry)
  if #miss > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "This requires mirrors you do not have:"
    for _, l in ipairs(miss) do out[#out + 1] = "  " .. l end
  end
  return table.concat(out, "\n")
end

local function showSolution(P, res, idx)
  local entry = res.solutions[idx]
  if #res.solutions == 1 then
    say(paint("green", string.format("FOUND SOLUTION WITH %d MIRROR(s)", entry.n)))
  else
    say(paint("green", string.format("SOLUTION %d of %d (%d mirrors)%s", idx, #res.solutions, entry.n,
      entry.nmiss == 0 and " *" or "")))
  end
  rune.echo("")
  for _, r in ipairs(mapRows(P, entry, true)) do rune.echo(r) end
  rune.echo("")
  for _, s in ipairs(entry.list) do
    rune.echo(string.format("%s at %s", paint("yellow", s.t), cellName(s.x, s.y)))
  end
  local miss = missingList(entry)
  if #miss > 0 then
    rune.echo("")
    say(paint("red", "This requires mirrors you do not have:"))
    for _, l in ipairs(miss) do rune.echo("  " .. l) end
  end
end

-- Show the result: a single solution in full, several as a numbered list to choose from
local function showResult(P, res, autoCopy)
  if not res.ok then
    say(paint("red", "NO SOLUTION: ") .. tostring(res.why))
    return
  end
  local n = #res.solutions
  if n == 1 then
    state.pick = 1
    showSolution(P, res, 1)
    if autoCopy and cfg.copy then doCopy(solutionText(P, res.solutions[1]), true) end
    if autoCopy then armPlan(res, 1, false) end
    return
  end
  state.pick = nil
  local starred = 0
  for _, e in ipairs(res.solutions) do if e.nmiss == 0 then starred = starred + 1 end end
  say(paint("green", string.format("FOUND %d SOLUTIONS", n)) .. " - choose one with: " .. NAME .. " pick <n>")
  for i, e in ipairs(res.solutions) do
    local mark = paint(e.nmiss == 0 and "green" or "white", string.format("%s%d)", e.nmiss == 0 and "*" or " ", i))
    rune.echo(string.format("  %s %s", mark, oneLine(e)))
  end
  say(starred > 0 and "* = every mirror it needs is in your inventory" or "None of these can be built from your own mirrors alone.")
end

-- The last solved puzzle and result, or nil after saying so
local function lastSolved()
  local last = state.last
  if not (last and last.res.ok) then
    say("Nothing solved yet - run: " .. NAME .. " solve")
    return nil
  end
  return last.P, last.res
end

-- A solution number from user input, or nil after saying how to give one
local function solutionNumber(arg, res, usage)
  local n = tonumber(arg)
  if not n or n < 1 or n > #res.solutions or n ~= math.floor(n) then
    say(string.format("Usage: %s %s", NAME, usage:format(#res.solutions)))
    return nil
  end
  return n
end

local Show = { arrival = arrival, confirmDrop = confirmDrop, plan = planStatus }

function Show.pick(arg)
  local P, res = lastSolved()
  if not P then return end
  local n = solutionNumber(arg, res, "pick <1-%d>")
  if not n then return end
  state.pick = n
  showSolution(P, res, n)
  if cfg.copy then doCopy(solutionText(P, res.solutions[n]), true) end
  armPlan(res, n, false)
end

function Show.copy(arg)
  local P, res = lastSolved()
  if not P then return end
  local n = solutionNumber(tonumber(arg) or state.pick, res, "copy [1-%d]")
  if n then doCopy(solutionText(P, res.solutions[n]), true) end
end

-- Arm the pick-up of every mirror this plugin dropped: on arriving at its square the mirror is taken back
function Show.undo()
  if #state.placed == 0 then
    say("No mirrors to pick up - none were dropped by " .. NAME .. " this session")
    return
  end
  local list = walkOrder(state.placed)
  local entries = {}
  for i, p in ipairs(list) do entries[i] = { x = p.x, y = p.y, t = p.t } end
  state.plan = { mode = "undo", entries = entries, remaining = #entries, at = nil, started = os.time() }
  refreshTrigger()
  say(string.format("Pick-up armed: walk to %s - each mirror is picked up on arrival (%s stop cancels)",
    table.concat(planLeft(state.plan), ", "), NAME))
end

function Show.arm(arg)
  local P, res = lastSolved()
  if not P then return end
  local n = solutionNumber(tonumber(arg) or state.pick, res, "arm <1-%d>")
  if not n then return end
  state.pick = n
  armPlan(res, n, true)
end

function Show.last()
  local last = state.last
  if last then showResult(last.P, last.res, false) else say("Nothing solved yet - run: " .. NAME .. " solve") end
end

-- Solve the captured console look + mirror lines
function Show.solve()
  if not state.look then
    say(paint("red", "No console look captured yet.") .. " Stand at the console and run: " .. NAME .. " solve")
    return
  end
  -- Same console look, mirrors and settings as the last solved puzzle: reuse its result
  local key = table.concat(state.look, "\n") .. "\0" .. table.concat(state.inv or {}, "\n") .. "\0" ..
    table.concat({ tostring(cfg.gates), cfg.place, cfg.maxm, cfg.more, cfg.maxtotal, cfg.alts }, "|")
  local prev = state.last
  if prev and prev.key == key and prev.res.ok then
    say("Same puzzle and mirrors as the last solve - showing that result")
    showResult(prev.P, prev.res, true)
    return
  end
  local P, err = parseLook(state.look, mirrorCounts(state.inv or {}))
  if not P then
    say(paint("red", "Could not read the puzzle: ") .. tostring(err))
    return
  end
  for _, c in ipairs({ { "launcher", P.lx, P.ly }, { "receiver", P.rx, P.ry } }) do
    if P.cells[(c[3] - 1) * P.W + c[2]] ~= "O" then
      say(paint("yellow", "Warning: ") .. "the map shows no O at the " .. c[1] .. " square " .. cellName(c[2], c[3]) ..
        " - the look may be stale or only partly captured")
    end
  end
  if #state.placed > 0 and not P.hasFixed then      -- the floor mirrors we recorded are gone from the map
    updatePlaced(function(list) for i = #list, 1, -1 do list[i] = nil end end)
    dbg("Forgot the recorded mirrors: the map shows none placed")
  end
  if P.hasFixed then
    say(paint("yellow", "The map already holds placed mirrors; they are kept as given (> 45cw, < 45ccw, } 90cw, { 90ccw)."))
  end
  local ownedCount, parts = 0, {}
  for _, t in ipairs(TYPES) do
    if P.owned[t] then
      ownedCount = ownedCount + P.owned[t]
      parts[#parts + 1] = P.owned[t] .. " " .. t
    end
  end
  say(string.format("Puzzle %dx%d, %d gate(s), you carry %d mirror(s)%s - solving...",
    P.W, P.H, P.ng, ownedCount, (#parts > 0) and (": " .. table.concat(parts, ", ")) or ""))
  local t0 = os.clock()
  local function finish(ok, res)
    state.job = nil
    if not ok then
      say(paint("red", "Solver error: ") .. tostring(res))
      return
    end
    dbg(string.format("Solved in %.2fs", os.clock() - t0))
    state.last = { P = P, res = res, key = key }
    showResult(P, res, true)
  end
  if not timerFn() then
    finish(pcall(solvePuzzle, P))      -- no Rune timer: solve in one block
    return
  end
  -- Solve in short slices from a Rune timer so the client stays responsive
  P.slice = true
  local co = coroutine.create(function() return solvePuzzle(P) end)
  state.job = co
  local function step()
    if state.job ~= co then return end             -- cancelled or replaced
    local ok, res = coroutine.resume(co)
    if coroutine.status(co) == "dead" then return finish(ok, res) end
    if not later(step) then                         -- the timer failed: finish in one block
      P.slice = false
      repeat ok, res = coroutine.resume(co) until coroutine.status(co) == "dead"
      finish(ok, res)
    end
  end
  step()
end


-- Settings, rules and self test ----

local Tools = {}

function Tools.rules()
  say("Assumed rules (from the wiki ballistics guide):")
  local lines = {
    "The beam moves in 8 directions; a mirror turns it by its angle.",
    "Edge, obstacle (X) and launcher stop it; the receiver ends it.",
    "It must pass 3 distinct gates (#), or all if fewer (cfg.gates).",
    "Mirrors go on cells in cfg.place (. # X), never launcher/receiver.",
    "Solutions using only your own mirrors come first, marked *.",
  }
  for _, l in ipairs(lines) do rune.echo("  * " .. l) end
end

-- Self test: the two puzzles whose ooc.dune.net answers are known ----
local SAMPLES = {
  { name = "puzzle 1 (north from A-1 to E-12)", lcol = 1, lrow = 1, ldir = 0, rcol = 5, rrow = 12,
    expectFirst = 5, expectStar = true,
    web = { "90cw at C-12", "45cw at C-11", "90ccw at G-7", "90cw at A-3", "45ccw at C-3" },
    owned = { ["90cw"] = 3, ["45ccw"] = 2, ["45cw"] = 1, ["90ccw"] = 1 },
    rows = { "..##OX......", "..X....X....", "....XX.X..X#", ".........X..", "............", "X.....#..X.X",
             "............", "......X....X", "............", "X....X....X.", ".....X......", "O.....X....." } },
  { name = "puzzle 2 (south from H-12 to A-9)", lcol = 8, lrow = 12, ldir = 4, rcol = 1, rrow = 9,
    expectFirst = 6, expectStar = true,
    web = { "45ccw at H-11", "45cw at A-8", "90cw at L-7", "90cw at G-2" },
    owned = { ["90ccw"] = 4, ["90cw"] = 3, ["45cw"] = 1 },
    rows = { ".......O....", "...X..X.X...", "X....X......", "O.X.........", "X..........X", "...X........",
             "X.......XX#.", "..........X.", "X.X..X......", ".....#X#.#..", "X.X.........", "......X....." } },
}

local function webKey(items)
  local list = {}
  for _, item in ipairs(items) do
    local t, c, r = item:match("^(%S+) at (%a)%-(%d+)$")
    list[#list + 1] = { x = c:upper():byte() - 64, y = tonumber(r), t = t }
  end
  return solKey(list)
end

function Tools.selftest()
    local passed = 0
  for _, s in ipairs(SAMPLES) do
    local P, err = makePuzzle(s.rows, s.lcol, s.lrow, s.ldir, s.rcol, s.rrow, s.owned)
    if not P then
      say(paint("red", "FAIL ") .. s.name .. ": " .. tostring(err))
    else
      P.maxsol = 20
      local t0 = os.clock()
      local res = solvePuzzle(P)
      local first, star, found = nil, false, false
      if res.ok then
        first, star = res.solutions[1].n, res.solutions[1].nmiss == 0
        local want = webKey(s.web)
        for _, e in ipairs(res.solutions) do
          if solKey(e.list) == want then found = true end
        end
      end
      if res.ok and first == s.expectFirst and star == s.expectStar and found then
        passed = passed + 1
        say(string.format("%s %s: %d solution(s), first = %d mirror(s)%s, website's answer among them (%.2fs)",
          paint("green", "PASS"), s.name, #res.solutions, first, star and " *" or "", os.clock() - t0))
      else
        say(string.format("%s %s: got %s, expected first = %d mirror(s) *, website's answer listed", paint("red", "FAIL"), s.name,
          res.ok and (first .. " mirror(s)" .. (star and " *" or "") .. ", " .. (found and "listed" or "website's answer missing")) or tostring(res.why),
          s.expectFirst))
      end
    end
  end
  say(string.format("Self test: %d of %d passed", passed, #SAMPLES))
end


-- Help (helpstyle, loaded on first use) ----
local H     -- helpstyle module (nil = not tried yet, false = unavailable)

-- Echo a helpstyle row (H[fn](...)), or the plain text when helpstyle is unavailable
local function emit(fn, plain, ...)
  if H == nil then
    local ok, m = pcall(require, "helpstyle")
    H = (ok and type(m) == "table") and m or false
  end
  if H and type(H[fn]) == "function" then
    local ok, out = pcall(H[fn], ...)
    if ok and type(out) == "string" then rune.echo(out); return end
  end
  rune.echo(plain)
end

local function row(cmd, desc) emit("line", string.format("  %-24s %s", cmd, desc), cmd, desc) end
local function section(name) emit("section", name, name) end

local function showHelp()
  ensureLoaded()
  local title = NAME .. "  (alias: " .. SHORT .. ") - JMC puzzle solver"
  emit("title", title, title)
  section("Run:")
  row(SHORT .. " solve (jms)", "look at console + inventory, then solve")
  row(SHORT .. " last", "show the last result again")
  row(SHORT .. " on | off", "turn the capture trigger on or off")
  section("Choose:")
  row(SHORT .. " pick <n>", "show, copy and arm solution n (* = own)")
  row(SHORT .. " copy [n]", "copy the picked solution, or solution n")
  section("Place:")
  row(SHORT .. " arm [n]", "drop mirrors as you reach each grid square")
  row(SHORT .. " plan", "show placed and still-to-place mirrors")
  row(SHORT .. " undo", "pick up the mirrors you dropped")
  row(SHORT .. " stop", "cancel auto-drop")
  section("Info:")
  row(SHORT .. " rules", "show the rules the solver assumes")
  row(SHORT .. " selftest", "solve two built-in puzzles, check answers")
  row(SHORT .. " debug on | off", "toggle debug messages (default off)")
  row(SHORT, "short alias for " .. NAME)
  local status = string.format("v%s  enabled=%s  debug=%s  gates=%s  maxm=%d  more=%d  alts=%d  copy=%s  autodrop=%s  load=%dms",
    VERSION, tostring(enabled), cfg.debug and "on" or "off", tostring(cfg.gates), cfg.maxm, cfg.more,
    cfg.alts, cfg.copy and "on" or "off", cfg.autodrop and "on" or "off", LOAD_MS)
  emit("foot", status, status)
end

-- Captures ----
local maybeSolve

local function finishLook()
  local lines = cap.look
  cap.look = nil
  if not lines then return end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  state.look = lines
  state.fresh.look = true
  dbg(string.format("Console look captured: %d lines", #lines))
end

local function finishInv()
  local all = cap.inv
  cap.inv = nil
  if not all then return end
  local mirrors = {}       -- only the mirror lines are kept
  for _, l in ipairs(all) do
    if l:lower():find("angled mirror", 1, true) then mirrors[#mirrors + 1] = l end
  end
  state.inv = mirrors
  state.fresh.inv = true
  dbg(string.format("Inventory captured: %d lines, %d mirror line(s)", #all, #mirrors))
  maybeSolve()
  refreshTrigger()
end

maybeSolve = function()
  if state.pending and state.fresh.look and state.fresh.inv then
    state.pending = false
    Show.solve()
  end
  refreshTrigger()
end

-- Runs for every line; stays cheap while no capture is active
local function onLine(_, ctx)
  if not loaded then ensureLoaded() end
  if not enabled then return end
  local ln = ctx and ctx.line
  if ln == nil then return end
  local text = cleanLine(ln)
  if state.pending or state.plan then expireStale() end

  -- Idle fast path: every line this plugin reacts to when nothing is captured contains "You" or "Grid"
  if not (cap.look or cap.inv or state.pending or state.plan) and not text:find("You", 1, true) then return end

  local S = state.plan and Show
  if S then
    local gc, gr = text:match(GRID)
    if gc then
      S.arrival(gc:upper():byte() - 64, tonumber(gr))
    else
      local deg, dir
      if state.plan.mode == "undo" then
        local verb
        verb, deg, dir = text:match(PICKED)
        if not PICK_VERBS[verb or ""] then deg = nil end
      else
        deg, dir = text:match(DROPPED)
      end
      if deg then S.confirmDrop(deg .. ((dir == "counterclockwise") and "ccw" or "cw")) end
    end
  end

  if cap.look then
    if text:find(INV_HEADER) then
      finishLook()
      cap.inv = { text }
    elseif text:find(ANY_LOOK) then
      finishLook()
      if text:find(LOOK_HEADER) then cap.look = { text } end
    else
      cap.look[#cap.look + 1] = text
      if #cap.look >= cfg.maxlines then finishLook() end
    end
    return
  end

  if cap.inv then
    cap.inv[#cap.inv + 1] = text
    if text:find(INV_END) or #cap.inv >= 400 then finishInv() end
    return
  end

  if text:find(LOOK_HEADER) then
    cap.look = { text }
  elseif text:find(INV_HEADER) then
    cap.inv = { text }
  elseif state.pending and text:find(INV_EMPTY) then
    state.inv = {}
    state.fresh.inv = true
    maybeSolve()
  end
end

local okReg = pcall(rune.trigger.regex, "^.*$", onLine, { name = TRIG, group = GROUP })
if not okReg then rune.trigger.regex("^.*$", onLine, { name = TRIG }) end
canSwitch = trySwitch(true)      -- only switch when Rune accepted a probe call
refreshTrigger()

-- Commands ----
local function solve()
  if not enabled then
    say("The trigger is off - turn it on with: " .. SHORT .. " on")
    return
  end
  cap.look, cap.inv = nil, nil
  state.plan, state.job = nil, nil
  state.fresh = { look = false, inv = false }
  state.pending, state.pendingAt = true, os.time()
  refreshTrigger()
  later(expireStale, cfg.pendtimeout + 1)
  say("Looking at the console and checking your mirrors...")
  rune.send(cfg.lookcmd)
  rune.send(cfg.invcmd)
end

local function setEnabled(on)
  enabled = on
  storeSet("jmcSolver.enabled", on)
  if not on then
    cap.look, cap.inv = nil, nil
    state.pending = false
    state.plan, state.job = nil, nil
  end
  refreshTrigger()
  say("Trigger " .. (on and "on" or "off"))
end

local commands = {
  [""]     = showHelp,
  help     = showHelp,
  on       = function() setEnabled(true) end,
  off      = function() setEnabled(false) end,
  solve    = solve,
  pick     = Show.pick,
  copy     = Show.copy,
  arm      = Show.arm,
  plan     = Show.plan,
  undo     = Show.undo,
  last     = Show.last,
  rules    = Tools.rules,
  selftest = Tools.selftest,
  stop     = function()
    if state.job then state.job = nil; say("Solving cancelled") end
    if state.plan then
      local word = (state.plan.mode == "undo") and "Pick-up" or "Auto-drop"
      state.plan = nil
      refreshTrigger()
      say(word .. " cancelled")
    else
      say("Auto-drop is not armed")
    end
  end,
  debug    = function(arg)
    local b = ({ on = true, off = false })[(arg or ""):lower():match("^%s*(%S*)")]
    if b == nil then say("Usage: " .. SHORT .. " debug on|off"); return end
    cfg.debug = b
    say("Debug messages " .. (b and "on" or "off"))
    if b then
      for _, ns in ipairs({ "timer", "group", "trigger" }) do
        local names = {}
        for k, v in pairs(type(rune[ns]) == "table" and rune[ns] or {}) do
          if type(v) == "function" then names[#names + 1] = k end
        end
        table.sort(names)
        dbg("rune." .. ns .. ": " .. table.concat(names, " "))
      end
      dbg("line trigger switching: " .. (canSwitch and "available" or "not available (stays on)")
        .. "; background solving: " .. (timerFn() and "available" or "not available (one block)"))
    end
  end,
}

local function dispatch(m, ctx)
  ensureLoaded()
  expireStale()
  m = m or (ctx and ctx.matches) or {}
  local sub, rest = (m[1] or ""):lower(), m[2] or ""
  local fn = commands[sub]
  if fn then
    fn(rest)
  else
    say("Unknown command '" .. sub .. "'.")
    showHelp()
  end
end

-- Bare command and short alias show the help; subcommands go through one regex alias
local function helpHandler(args, ctx) showHelp() end
rune.alias.exact(NAME, helpHandler)
rune.alias.exact(SHORT, helpHandler)
rune.alias.regex("^(?:" .. NAME .. "|" .. SHORT .. ")\\s+(\\S+)(?:\\s+(.*))?$", dispatch, { name = NAME .. "-cmd" })
rune.alias.exact("jms", NAME .. " solve")

LOAD_MS = math.floor((os.clock() - T0) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")