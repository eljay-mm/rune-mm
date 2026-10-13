-- Filename: eljayPlugins/jmcSolver.lua
-- Purpose: Joint Magical Consortium (JMC) projectile puzzle - standalone solver (no website, no network).
-- Version: 1.5
-- Date: 2026-Oct-13
-- Changelog:
--   1.5  Repo-style header pass; command summary aligned to current formatting and still preserves the original solver logic.
--   1.4  Help screen now copies autopouch.lua's style (require("helpstyle"): H.title / H.section / H.line / H.foot printed via rune.echo, commands typed bare, key=value status footer).
--   1.3  No minimum mirror count is enforced: solutions you can build entirely from the mirrors you carry come first and are marked with `*` (even if they use more mirrors than the shortest answer); shorter answers that need mirrors you lack follow. New `more` setting; `maxm` now defaults to 8.
--   1.2  Lists several solutions (up to `alts`) so you can choose with `jmc pick <n>`; the chosen (or only) solution is copied to the clipboard, `jmc copy [n|all]` copies on demand; selftest also checks the website's own answers are among the alternatives; header brought to current format.
--   1.1  Standalone local solver replaces the ooc.dune.net web solver (no network, no clipboard, no io.popen).
--   1.0  First version: captured the console look + mirrors and submitted them to the ooc.dune.net JMC solver.
--
-- How it works:
--   * `jmc solve` (alias `jms`) sends `look console` and `inventory`, captures both replies and solves the puzzle locally.
--   * From the console look it reads the map, the launcher (position + direction) and the receiver; from the inventory
--     it counts your "angled mirror rotated ..." lines. Nothing else is kept.
--   * Rules used (inferred from the Projectile Test Ballistics Guide and from solved examples):
--       - the projectile moves cell by cell in 8 directions; a mirror turns it by its angle (see the wiki guide);
--       - it is stopped by the map edge, by an obstacle (X) and by the launcher; it counts as delivered when it
--         enters the receiver after passing through enough distinct gates (#);
--       - mirrors may be placed on '.', '#' and 'X' cells (setting `place`), never on the launcher or receiver;
--       - the beam must pass through at least 3 gates (fewer if the map has fewer; setting `gates`).
--   * Solutions that use only mirrors you carry are searched first (up to `maxm` mirrors, the fewest count plus
--     `more` larger counts) and marked with `*`. Answers with fewer mirrors that need ones you lack are listed after
--     them, with the missing mirrors named; they are only shown when they beat the best `*` answer.
--   * One solution is shown as the map with the mirrors drawn in plus a list like "90cw at C-12"
--     (column letter - row number, row 1 at the bottom) and copied to the clipboard.
--   * Several solutions are listed as numbered one-liners, e.g. `*1) [5] 90cw at A-2, ...`; `jmc pick <n>` shows and
--     copies the one you choose.
--   * `jmc copy [n|all]` copies a solution (default: the picked one) or all of them; `copy`/`clip` settings control
--     the automatic copy and the method (wl-copy / xclip / xsel, OSC 52 as last resort).
--   * `jmc selftest` solves two built-in puzzles whose website answers are known and checks them.
--   * Typing `jmc` alone shows the command summary; `jmc debug on|off` toggles debug messages (default off).
--
-- Commands:
--   jmc                 show this summary
--   jmc solve (jms)     look at the console + inventory and solve the puzzle
--   jmc again           solve the last captured look + mirrors again
--   jmc last            show the last result again
--   jmc pick <n>        show and copy solution n
--   jmc copy [n|all]    copy the picked solution, solution n, or all solutions
--   jmc rules           show the rules the solver assumes
--   jmc selftest        solve two built-in puzzles with known answers
--   jmc set             list settings
--   jmc set <key> <value>  change one setting
--   jmc debug on|off   toggle debug messages

local VERSION = "1.5"

-- Lines (Lua patterns) that frame the captures
local LOOK_HEADER = "^%s*You focus your powers of observation on the ignition console"
local ANY_LOOK    = "^%s*You focus your powers of observation on"
local INV_HEADER  = "^%s*You are carrying:"
local INV_EMPTY   = "^%s*You are not carrying anything"
local INV_END     = "^%s*You may carry a maximum of"

--[[ Settings (change live with: jmc set <key> <value>) ]]--
local cfg = {
  debug    = false,        -- verbose [jmc:debug] output
  gates    = "auto",       -- distinct gates the beam must pass: auto (= min(3, gates on the map)) or a number
  place    = ".#X",        -- map characters a mirror may be placed on
  maxm     = 8,            -- most mirrors tried when using only the ones you carry
  more     = 1,            -- how many larger mirror counts than the fewest to also list (only your own mirrors)
  maxtotal = 10,           -- most mirrors tried when allowed to add missing ones (only shown if fewer than the best *)
  alts     = 5,            -- most alternative solutions collected and listed
  copy     = true,         -- copy the shown/picked solution to the clipboard automatically
  clip     = "auto",       -- clipboard method: auto | osc | wl-copy | xclip | xsel
  budget   = 1500000,      -- search steps allowed per attempt before giving up
  lookcmd  = "look console",
  invcmd   = "inventory",
  maxlines = 60,           -- cap on captured look lines
}

local SETTINGS = {
  debug = "bool", copy = "bool", gates = "gates", place = "string", lookcmd = "string", invcmd = "string",
  clip = { "auto", "osc", "wl-copy", "xclip", "xsel" },
  maxm = "number", more = "number", maxtotal = "number", alts = "number", budget = "number", maxlines = "number",
}

--[[ State ]]--
local state = {
  pending = false,                       -- `jmc solve` is waiting for look + inventory
  fresh   = { look = false, inv = false },
  look    = nil,                         -- last captured console look (table of lines)
  owned   = nil,                         -- last captured mirror counts { ["90cw"] = n, ... }
  last    = nil,                         -- last solved { P = puzzle, res = result }
  pick    = nil,                         -- index of the solution the player picked (or the only one)
}

local cap = { look = nil, inv = nil }    -- captures in progress

--[[ Output helpers ]]--
local function paint(color, text)
  local fn = rune.style and rune.style[color]
  if type(fn) == "function" then
    local ok, out = pcall(fn, text)
    if ok and out then return out end
  end
  return text
end

local function say(msg)
  rune.echo(paint("cyan", "[jmc] ") .. msg)
end

local function dbg(msg)
  if cfg.debug then
    rune.echo(paint("blue", "[jmc:debug] ") .. msg)
  end
end

local function cleanLine(ln)
  if type(ln) == "string" then return (ln:gsub("\r", "")) end
  local ok, t = pcall(function() return ln:clean() end)
  if ok and type(t) == "string" then return (t:gsub("\r", "")) end
  return tostring(ln)
end

--[[ Clipboard ]]--
local function sanitize(text)
  text = text:gsub("\r", "")
  text = text:gsub("[\1-\8\11-\31\127]", "")
  return text
end

local function hasTool(name)
  local ok, p = pcall(io.popen, "command -v " .. name .. " 2>/dev/null")
  if not ok or not p then return false end
  local out = p:read("*l")
  p:close()
  return out ~= nil and out ~= ""
end

local EXTERNAL = {
  ["wl-copy"] = "wl-copy",
  ["xclip"]   = "xclip -selection clipboard",
  ["xsel"]    = "xsel --clipboard --input",
}

local function pickClipMethod()
  if cfg.clip ~= "auto" then return cfg.clip end
  if os.getenv("WAYLAND_DISPLAY") and hasTool("wl-copy") then return "wl-copy" end
  if os.getenv("DISPLAY") and hasTool("xclip") then return "xclip" end
  if os.getenv("DISPLAY") and hasTool("xsel") then return "xsel" end
  return "osc"
end

-- Returns ok(boolean), method(string), err(string|nil)
local function copyToClipboard(text)
  text = sanitize(text)
  local method = pickClipMethod()

  if method == "osc" then
    if not (rune.clipboard and rune.clipboard.set) then
      return false, method, "rune.clipboard is not available in this Rune version"
    end
    local ok, err = pcall(rune.clipboard.set, text)
    if not ok then return false, method, tostring(err) end
    return true, method
  end

  local okp, p = pcall(io.popen, EXTERNAL[method] .. " 2>/dev/null", "w")
  if not okp or not p then
    return false, method, "io.popen is not available (try: jmc set clip osc)"
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

--[[ Puzzle model ]]--
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

local function hasBit(m, b) return math.floor(m / POW[b]) % 2 == 1 end

local function popcount(m, ng)
  local n = 0
  for b = 0, ng - 1 do
    if hasBit(m, b) then n = n + 1 end
  end
  return n
end

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
  local P = { W = W, H = H, cells = {}, fixed = {}, gateBit = {}, ng = 0, gateCells = {},
              lx = lcol, ly = lrow, ld = ldir, rx = rcol, ry = rrow, owned = owned or {} }
  for i, line in ipairs(rows) do
    if #line ~= W then return nil, "map rows differ in length" end
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
        P.gateCells[#P.gateCells + 1] = p
      end
    end
  end
  if lcol < 1 or lcol > W or lrow < 1 or lrow > H then return nil, "launcher is outside the map" end
  if rcol < 1 or rcol > W or rrow < 1 or rrow > H then return nil, "receiver is outside the map" end
  if P.ng > 12 then return nil, "too many gates (" .. P.ng .. ") for this solver" end
  P.M = POW[P.ng]
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

--[[ Solver ]]--
local function nodeKey(P, x, y, d, m)
  return ((((y - 1) * P.W + x) * 8) + d) * P.M + m
end

-- Cheapest number of extra mirrors from every reachable beam state, ignoring stock and self-crossing.
-- Used as an admissible bound to prune the exact search. Returns hmap, h(start)
local function buildHeuristic(P)
  local W, H = P.W, P.H
  local nodes, rev, goal, queue = {}, {}, {}, {}
  local startKey = nodeKey(P, P.lx, P.ly, P.ld, 0)
  nodes[startKey] = { P.lx, P.ly, P.ld, 0 }
  queue[1] = startKey
  local qi = 1

  local function addEdge(from, nx, ny, nd, nm, cost)
    local k = nodeKey(P, nx, ny, nd, nm)
    if not nodes[k] then
      nodes[k] = { nx, ny, nd, nm }
      queue[#queue + 1] = k
    end
    local r = rev[k]
    if not r then r = {}; rev[k] = r end
    r[#r + 1] = { from, cost }
  end

  while qi <= #queue do
    local k = queue[qi]; qi = qi + 1
    local n = nodes[k]
    local x, y, d, m = n[1], n[2], n[3], n[4]
    local nx, ny = x + DX[d], y + DY[d]
    if nx >= 1 and nx <= W and ny >= 1 and ny <= H then
      if nx == P.rx and ny == P.ry then
        if popcount(m, P.ng) >= P.need then goal[k] = true end
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
          local rl = rev[k]
          if rl then
            for _, e in ipairs(rl) do
              local nd = c + e[2]
              if h[e[1]] == nil or nd < h[e[1]] then
                h[e[1]] = nd
                local nb = buckets[nd]
                if not nb then nb = {}; buckets[nd] = nb end
                nb[#nb + 1] = e[1]
              end
            end
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
      steps = steps + 1
      if steps > limit then break end
      local nx, ny = x + DX[d], y + DY[d]
      if nx < 1 or nx > W or ny < 1 or ny > H then break end
      if nx == P.rx and ny == P.ry then
        if popcount(m, P.ng) >= P.need then record() end
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

-- Returns { ok = true, solutions = { {list, n, missing = {type = n}, nmiss}, ... } } or { ok = false, why = "..." }
-- Solutions made only of mirrors you carry (nmiss == 0) come first.
local function solvePuzzle(P)
  local hmap, h0 = buildHeuristic(P)
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
        entries[#entries + 1] = { list = sol, n = #sol, missing = missing, nmiss = nmiss, idx = #entries + 1 }
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
      for e = 1, target do
        local sols, ab, nodes = search(P, hmap, target, e)
        dbg(string.format("%d mirror(s), up to %d extra: %d found (%d steps)", target, e, #sols, nodes))
        if #sols > 0 then
          local before = #entries
          local saved = P.maxsol
          P.maxsol = before + saved
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
    if aborted then return { ok = false, why = "search budget exhausted (jmc set budget <n>)" } end
    return { ok = false, why = string.format("no solution with up to %d mirrors", math.max(P.maxm, P.maxtotal)) }
  end
  table.sort(entries, function(a, b)
    local sa, sb = (a.nmiss == 0), (b.nmiss == 0)
    if sa ~= sb then return sa end
    if a.n ~= b.n then return a.n < b.n end
    if a.nmiss ~= b.nmiss then return a.nmiss < b.nmiss end
    return a.idx < b.idx
  end)
  return { ok = true, solutions = entries }
end

--[[ Parsing the captured text ]]--
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
    if l:find(MAPROW) then rows[#rows + 1] = l else break end
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

--[[ Help (helpstyle, as in autopouch.lua) ]]--
local H = require("helpstyle")

-- Status line for the help footer, key=value like autopouch
local function statusLine()
  return string.format("v%s  debug=%s  gates=%s  maxm=%d  more=%d  alts=%d  copy=%s",
    VERSION, cfg.debug and "on" or "off", tostring(cfg.gates), cfg.maxm, cfg.more, cfg.alts, cfg.copy and "on" or "off")
end

local function showHelp()
  rune.echo(H.title("jmc - Joint Magical Consortium puzzle solver (standalone)"))
  rune.echo(H.section("Run:"))
  rune.echo(H.line("jmc solve (jms)", "look at the console + inventory and solve the puzzle"))
  rune.echo(H.line("jmc again", "solve the last captured look + mirrors again"))
  rune.echo(H.line("jmc last", "show the last result again"))
  rune.echo(H.section("Choose:"))
  rune.echo(H.line("jmc pick <n>", "show and copy solution n (* = only your own mirrors)"))
  rune.echo(H.line("jmc copy [n|all]", "copy the picked solution, solution n, or all of them"))
  rune.echo(H.section("Info:"))
  rune.echo(H.line("jmc rules", "show the rules the solver assumes"))
  rune.echo(H.line("jmc selftest", "solve two built-in puzzles with known answers"))
  rune.echo(H.section("Settings:"))
  rune.echo(H.line("jmc set", "list the settings"))
  rune.echo(H.line("jmc set <key> <value>", "change one (debug gates place maxm more maxtotal alts copy clip budget lookcmd invcmd maxlines)"))
  rune.echo(H.line("jmc debug on | off", "toggle debug messages (default off)"))
  rune.echo("")
  rune.echo(H.foot(statusLine()))
end

local function showRules()
  say("Assumed rules (inferred from the wiki ballistics guide and solved examples):")
  local lines = {
    "The beam moves one cell at a time in 8 directions; a mirror turns it by its angle (45/90, cw/ccw).",
    "Map edge, obstacle (X) and launcher stop the beam; entering the receiver delivers it.",
    "Mirrors may be placed on cells in the 'place' setting (default . # X), never on launcher/receiver.",
    "The beam must pass through at least 3 distinct gates (#), or all of them if fewer (setting 'gates').",
    "No minimum mirror count: solutions built only from mirrors you carry come first (marked *); fewer-mirror answers needing ones you lack follow.",
  }
  for _, l in ipairs(lines) do rune.echo("  * " .. l) end
end

local function showSettings()
  say("Settings:")
  local keys = {}
  for k in pairs(SETTINGS) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    rune.echo(string.format("    %-9s = %s", k, tostring(cfg[k])))
  end
end

local function parseBool(v)
  v = (v or ""):lower()
  if v == "on" or v == "true" or v == "yes" or v == "1" then return true end
  if v == "off" or v == "false" or v == "no" or v == "0" then return false end
  return nil
end

local function setSetting(key, val)
  local spec = SETTINGS[key]
  if not spec then
    say("Unknown setting '" .. key .. "'. Type 'jmc set' to list them.")
    return
  end
  if spec == "bool" then
    local b = parseBool(val)
    if b == nil then say("Use on/off for " .. key); return end
    cfg[key] = b
  elseif spec == "number" then
    local n = tonumber(val)
    local min = (key == "maxlines") and 10 or ((key == "more") and 0 or 1)
    if not n or n < min then say(key .. " needs a number >= " .. min); return end
    cfg[key] = n
  elseif spec == "gates" then
    if val:lower() == "auto" then
      cfg.gates = "auto"
    else
      local n = tonumber(val)
      if not n or n < 0 then say("gates must be 'auto' or a number >= 0"); return end
      cfg.gates = n
    end
  elseif spec == "string" then
    if val == "" then say(key .. " needs a value"); return end
    cfg[key] = val
  else
    local okv = false
    for _, allowed in ipairs(spec) do
      if allowed == val then okv = true end
    end
    if not okv then say(key .. " must be one of: " .. table.concat(spec, ", ")); return end
    cfg[key] = val
  end
  say(key .. " = " .. tostring(cfg[key]))
end

--[[ Showing a solution ]]--
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

local function missingLines(entry)
  local out = {}
  for _, t in ipairs(TYPES) do
    if entry.missing[t] then out[#out + 1] = string.format("  %d %s", entry.missing[t], t) end
  end
  return out
end

-- One-line form: "[5] 90cw at A-2, 45ccw at B-2, ..." (+ missing mirrors)
local function oneLine(entry)
  local parts = {}
  for _, s in ipairs(entry.list) do parts[#parts + 1] = string.format("%s at %s", s.t, cellName(s.x, s.y)) end
  local line = string.format("[%d] %s", entry.n, table.concat(parts, ", "))
  local miss = {}
  for _, t in ipairs(TYPES) do
    if entry.missing[t] then miss[#miss + 1] = entry.missing[t] .. " " .. t end
  end
  if #miss > 0 then line = line .. "  [missing: " .. table.concat(miss, ", ") .. "]" end
  return line
end

-- Plain text of one solution, as the website prints it (used for the clipboard)
local function solutionText(P, entry)
  local out = { string.format("FOUND SOLUTION WITH %d MIRROR(s)", entry.n), "" }
  for _, r in ipairs(mapRows(P, entry, false)) do out[#out + 1] = r end
  out[#out + 1] = ""
  for _, s in ipairs(entry.list) do out[#out + 1] = string.format("%s at %s", s.t, cellName(s.x, s.y)) end
  local miss = missingLines(entry)
  if #miss > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "This requires mirrors you do not have:"
    for _, l in ipairs(miss) do out[#out + 1] = l end
  end
  return table.concat(out, "\n")
end

local function allText(P, res)
  local out = { string.format("%d SOLUTIONS (* = uses only mirrors you carry)", #res.solutions) }
  for i, e in ipairs(res.solutions) do
    out[#out + 1] = ""
    out[#out + 1] = string.format("%sSolution %d (%d mirrors):", e.nmiss == 0 and "*" or "", i, e.n)
    for _, s in ipairs(e.list) do out[#out + 1] = string.format("%s at %s", s.t, cellName(s.x, s.y)) end
    local miss = missingLines(e)
    if #miss > 0 then
      out[#out + 1] = "  requires mirrors you do not have:"
      for _, l in ipairs(miss) do out[#out + 1] = "  " .. l end
    end
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
  local miss = missingLines(entry)
  if #miss > 0 then
    rune.echo("")
    say(paint("red", "This requires mirrors you do not have:"))
    for _, l in ipairs(miss) do rune.echo(l) end
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
  else
    state.pick = nil
    local starred = 0
    for _, e in ipairs(res.solutions) do if e.nmiss == 0 then starred = starred + 1 end end
    say(paint("green", string.format("FOUND %d SOLUTIONS", n)) .. " - choose one with: jmc pick <n>")
    for i, e in ipairs(res.solutions) do
      local mark = paint(e.nmiss == 0 and "green" or "white", string.format("%s%d)", e.nmiss == 0 and "*" or " ", i))
      rune.echo(string.format("  %s %s", mark, oneLine(e)))
    end
    if starred > 0 then
      say("* = every mirror it needs is in your inventory")
    else
      say("None of these can be built from your own mirrors alone.")
    end
  end
end

local function pickSolution(arg)
  if not state.last or not state.last.res.ok then say("Nothing solved yet - run: jmc solve"); return end
  local P, res = state.last.P, state.last.res
  local n = tonumber(arg)
  if not n or n < 1 or n > #res.solutions or n ~= math.floor(n) then
    say(string.format("Usage: jmc pick <1-%d>", #res.solutions))
    return
  end
  state.pick = n
  showSolution(P, res, n)
  if cfg.copy then doCopy(solutionText(P, res.solutions[n]), true) end
end

local function copyCommand(arg)
  if not state.last or not state.last.res.ok then say("Nothing solved yet - run: jmc solve"); return end
  local P, res = state.last.P, state.last.res
  arg = (arg or ""):lower()
  if arg == "all" or (arg == "" and not state.pick) then
    doCopy(allText(P, res), true)
    return
  end
  local n = tonumber(arg) or state.pick
  if not n or n < 1 or n > #res.solutions or n ~= math.floor(n) then
    say(string.format("Usage: jmc copy [1-%d|all]", #res.solutions))
    return
  end
  doCopy(solutionText(P, res.solutions[n]), true)
end

local function runSolve(P)
  local t0 = os.clock()
  local ok, res = pcall(solvePuzzle, P)
  if not ok then
    say(paint("red", "Solver error: ") .. tostring(res))
    return
  end
  dbg(string.format("Solved in %.2fs", os.clock() - t0))
  state.last = { P = P, res = res }
  showResult(P, res, true)
end

local function solveCaptured()
  if not state.look then
    say(paint("red", "No console look captured yet.") .. " Stand at the console and run: jmc solve")
    return
  end
  local P, err = parseLook(state.look, state.owned or {})
  if not P then
    say(paint("red", "Could not read the puzzle: ") .. tostring(err))
    return
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
  runSolve(P)
end

--[[ Self test: the two puzzles whose ooc.dune.net answers are known ]]--
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

local function selftest()
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

--[[ Captures ]]--
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
  state.owned = mirrorCounts(all)     -- only the mirror counts are kept
  state.fresh.inv = true
  local n = 0
  for _, c in pairs(state.owned) do n = n + c end
  dbg(string.format("Inventory captured: %d lines, %d mirror(s)", #all, n))
  maybeSolve()
end

maybeSolve = function()
  if state.pending and state.fresh.look and state.fresh.inv then
    state.pending = false
    solveCaptured()
  end
end

-- Runs for every line; stays cheap while no capture is active
local function onLine(_, ctx)
  local ln = ctx and ctx.line
  if ln == nil then return end
  local text = cleanLine(ln)

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
    state.owned = {}
    state.fresh.inv = true
    maybeSolve()
  end
end

rune.trigger.regex("^.*$", onLine, { name = "jmc-line" })

--[[ Commands ]]--
local function solve()
  cap.look, cap.inv = nil, nil
  state.fresh = { look = false, inv = false }
  state.pending = true
  say("Looking at the console and checking your mirrors...")
  rune.send(cfg.lookcmd)
  rune.send(cfg.invcmd)
end

local commands = {
  [""]     = showHelp,
  help     = showHelp,
  solve    = solve,
  pick     = pickSolution,
  copy     = copyCommand,
  again    = function()
    if cap.look then finishLook() end
    solveCaptured()
  end,
  last     = function()
    if state.last then showResult(state.last.P, state.last.res, false) else say("Nothing solved yet - run: jmc solve") end
  end,
  rules    = showRules,
  selftest = selftest,
  debug    = function(arg)
    local b = parseBool((arg or ""):lower())
    if b == nil then say("Usage: jmc debug on|off"); return end
    cfg.debug = b
    say("Debug messages " .. (b and "on" or "off"))
  end,
}

rune.alias.regex("^jmc(?:\\s+(\\S+))?(?:\\s+(.*))?$", function(m, ctx)
  m = m or (ctx and ctx.matches) or {}
  local sub  = (m[1] or ""):lower()
  local rest = m[2] or ""

  if sub == "set" then
    local key, val = rest:match("^(%S+)%s*(.-)%s*$")
    if key then setSetting(key:lower(), val) else showSettings() end
    return
  end

  local fn = commands[sub]
  if fn then
    fn(rest)
  else
    say("Unknown command '" .. sub .. "'.")
    showHelp()
  end
end, { name = "jmc-cmd" })

rune.alias.exact("jms", "jmc solve")

say("JmcSolver v" .. VERSION .. " loaded - type 'jmc'")