-- Filename: eljayPlugins/asciiMapPane.lua
-- Purpose: ASCII map pane for Rune + horstgs Materia Magica.
-- Version: 2.6
-- Date: 2026-Oct-13
-- Changelog:
--   2.6  Switched help output to the repo-standard footer format and prefixed commands to bare `asciiMapPane` usage; slash compatibility retained as a fallback.
--   2.5  Added safe fallbacks, saved settings validation, and style cleanup.
-- How it works:
--   * Rune sends GMCP Room.Info on every move; the plugin keeps the latest room and redraws the pane.
--   * It finds the horstgs mapper store (or a limited fallback reader) and resolves nearby rooms by exit links.
--   * The current room and nearby exits are laid out relative to the player so the map works in homes, dungeons and zone transitions.
--   * Rooms are symbolled and coloured by terrain, flags and name; recent trail rooms are highlighted and far-away rooms are faded.
--   * Only the relevant local area is rendered, and redraws are skipped when the layout has not changed.
--   * Settings and size choices are saved with rune.store, while debug output stays off by default unless enabled.
--   * Server-supplied text is stripped of control characters before display to protect the terminal from injected escapes.
--   * Typing the command on its own shows a help summary using helpstyle, with the version at the start of the footer row.
--
-- Commands:
--   asciiMapPane                     show this summary
--   asciiMapPane on|off              show or hide the map pane
--   asciiMapPane compact|spaced      1 char per room / wider with link lines
--   asciiMapPane color on|off        ANSI colours on/off
--   asciiMapPane size <W> <H>        set pane size in characters
--   asciiMapPane pad <N>             border allowance
--   asciiMapPane debug on|off        debug logging (default off)
--   asciiMapPane help                show this summary

local PANE_ID = "asciiMapPane"

-- Rune's pane API has no size query, so this is the "auto" size. Edit
-- these two numbers (or use asciiMapPane size W H) to match your pane.
local DEFAULT_W = 42
local DEFAULT_H = 10

-- Limits (input validation / resource safety).
local MIN_W, MAX_W = 10, 200
local MIN_H, MAX_H = 3, 100
local MAX_PAD = 10

-- Reading mapper/map.db ourselves keeps a second copy of the map in
-- memory, so it is OFF unless the live mapper store can't be found.
local USE_MAPFILE_FALLBACK = false
local MAPFILE_MAX_BYTES = 64 * 1024 * 1024
local MAPFILE_MAX_LINE  = 20000
local MAPFILE_MAX_ROOMS = 500000

local EMPTY_MARKER   = " "
local ROOM_MARKER    = "o"
local UP_MARKER      = "^"
local DOWN_MARKER    = "v"
local UPDOWN_MARKER  = "%"
local CURRENT_MARKER = "@"

local enabled = true
local redraw_pending = false
local current_info = nil
local last_pane_text = nil

local manual_w, manual_h = nil, nil
local use_color = true
local compact = true
local border_pad = 2

-- Redraw skipping
local last_sig = nil
local epoch = 0

-- Server-supplied text may include control characters.
local function clean(value)
    local text = tostring(value == nil and "" or value)
    text = text:gsub("%c", "?")
    text = text:gsub("\194[\128-\159]", "?")
    return text
end

-- Debug logging: OFF by default.
local DEBUG = false

local function dbg(...)
    local ok, text = pcall(string.format, ...)
    if type(rune.echo) == "function" then
        rune.echo("[asciiMapPane:debug] " .. clean(ok and text or tostring((...))))
    end
end

-----------------------------------------------------------------------
-- Store access (lazy)
-----------------------------------------------------------------------

local store = nil
local store_source = "none"

local function looks_like_store(t)
    return type(t) == "table"
        and type(rawget(t, "rooms")) == "table"
        and type(rawget(t, "get")) == "function"
end

local function has_rooms(t)
    return looks_like_store(t) and next(rawget(t, "rooms")) ~= nil
end

local function find_store()
    local found = {}

    local function consider(label, value)
        if looks_like_store(value) then
            found[#found + 1] = { label = label, store = value }
        end
    end

    consider("_G.mapper_store", _G.mapper_store)

    if type(_G.mapper) == "table" then
        consider("_G.mapper.store", _G.mapper.store)
        consider("_G.mapper", _G.mapper)
    end

    pcall(function()
        for _, name in ipairs({ "mapper_store", "eljayPlugins.mapper_store" }) do
            consider("package.loaded." .. name, package.loaded[name])
        end

        for name, value in pairs(package.loaded) do
            consider("package.loaded." .. tostring(name), value)
        end

        for name, value in pairs(_G) do
            consider("_G." .. tostring(name), value)
        end
    end)

    for _, name in ipairs({ "mapper_store", "eljayPlugins.mapper_store" }) do
        local ok, mod = pcall(require, name)
        if ok then
            consider("require(" .. name .. ")", mod)
        end
    end

    for _, f in ipairs(found) do
        if has_rooms(f.store) then
            return f.store, f.label
        end
    end

    if found[1] then
        return found[1].store, found[1].label .. " (empty)"
    end

    return nil, "none"
end

-- Fallback map.db reader
local US, RS = "\31", "\30"
local own = { rooms = {} }
function own.get(uid)
    if uid == nil then
        return nil
    end
    return own.rooms[tostring(uid)]
end

local own_state = { done = false, text = nil, pos = 1, err = nil,
    rooms_n = 0, skipped = 0 }
local store_note = nil
local live_retry = 0

local function parse_room(line)
    local f = {}
    local start = 1

    for i = 1, 8 do
        local at = line:find(US, start, true)
        if not at then
            f[i] = line:sub(start)
            break
        end
        f[i] = line:sub(start, at - 1)
        start = at + 1
    end

    local uid = f[1]
    if not uid or #uid == 0 or #uid > 32 or not uid:match("^[%w_%-%.:]+$") then
        return nil
    end

    local room = { uid = uid, name = f[2], area = f[3], flags = f[4], terrain = f[5], terraininfo = f[6] }

    if f[7] and f[7] ~= "" then
        local x, y, z = f[7]:match("([^,]*),([^,]*),([^,]*)")
        x, y = tonumber(x), tonumber(y)
        if x and y then
            room.coord = { x = x, y = y, z = tonumber(z) or 0 }
        end
    end

    if f[8] and f[8] ~= "" then
        room.exits = {}
        for pair in f[8]:gmatch("[^" .. RS .. "]+") do
            local dir, dest = pair:match("^(%a+)=(.*)$")
            if dir and dest and dest ~= "" then
                room.exits[dir] = dest
            end
        end
    end

    return room
end

local function own_fail(message)
    own_state.done = true
    own_state.text = nil
    own_state.err = message
    return true
end

local function own_load_step()
    if own_state.done then
        return true
    end

    if not own_state.text then
        local dir = rune.config_dir
        if type(dir) ~= "string" or dir == "" then
            return own_fail("config_dir unknown; not reading map.db")
        end

        local path = dir .. "/mapper/map.db"
        local f = io.open(path, "r")
        if not f then
            return own_fail("cannot open " .. path)
        end

        local size = f:seek("end")
        if not size or size > MAPFILE_MAX_BYTES then
            f:close()
            return own_fail("map.db unreadable or over the size limit")
        end

        f:seek("set")
        own_state.text = f:read("*a") or ""
        f:close()
        own_state.pos = 1
        own_state.rooms_n, own_state.skipped = 0, 0
    end

    local clock = os.clock
    local t0 = clock and clock() or 0
    local text, pos = own_state.text, own_state.pos

    while true do
        local nl = text:find("\n", pos, true)
        local line = nl and text:sub(pos, nl - 1) or text:sub(pos)
        pos = (nl or #text) + 1

        if #line > MAPFILE_MAX_LINE then
            own_state.skipped = own_state.skipped + 1
        else
            line = line:gsub("\r$", "")
            local room = parse_room(line)
            if room then
                own.rooms[room.uid] = room
                own_state.rooms_n = own_state.rooms_n + 1
            else
                own_state.skipped = own_state.skipped + 1
            end
        end

        if own_state.rooms_n >= MAPFILE_MAX_ROOMS then
            own_fail("map.db room limit reached")
            break
        end

        if not nl then
            own_state.done = true
            own_state.text = nil
            break
        end

        if clock and clock() - t0 > 0.15 then
            break
        end
    end

    own_state.pos = pos

    if own_state.done and DEBUG then
        dbg("map.db: %d rooms, %d lines skipped", own_state.rooms_n, own_state.skipped)
    end

    return own_state.done
end

local function own_count()
    local n = 0
    for _ in pairs(own.rooms) do
        n = n + 1
    end
    return n
end

local store_loading = false
local next_find = 0

local function release_own()
    own.rooms = {}
    own_state.done, own_state.text, own_state.pos = false, nil, 1
    own_state.err, own_state.total = nil, nil
    own_state.rooms_n, own_state.skipped = 0, 0
end

local function get_store()
    if store and store ~= own and has_rooms(store) then
        return store
    end

    live_retry = live_retry + 1
    local now = os.time and os.time() or 0

    if (store ~= own and now >= next_find) or (store == own and live_retry % 20 == 0) then
        local found, label = find_store()
        if found and has_rooms(found) then
            store, store_source = found, label
            store_loading = false
            release_own()
            if DEBUG then dbg("store -> %s", store_source) end
            return store
        end
        next_find = now + 5
    end

    store_loading = false

    if not USE_MAPFILE_FALLBACK then
        store_note = "mapper store not found (retrying). Set USE_MAPFILE_FALLBACK = true to read map.db directly."
        return nil
    end

    if not own_load_step() then
        store_loading = true
        store_note = string.format("Loading map file... %d rooms", own_state.rooms_n)
        return nil
    end

    if own_state.total == nil then
        own_state.total = own_count()
        if DEBUG then dbg("map.db parsed: %d rooms", own_state.total) end
    end

    if own_state.total == 0 then
        store_note = own_state.err or "map.db is empty."
        return nil
    end

    if store ~= own then
        store, store_source = own, "own map.db reader"
        if DEBUG then dbg("store -> %s", store_source) end
    end

    return store
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function key_of(x, y)
    return (x + 1024) * 2048 + (y + 1024)
end

local function read_coord(c)
    if type(c) == "string" then
        local a, b, d = c:match("(%-?%d+)[, ]+(%-?%d+)[, ]*(%-?%d*)")
        if a and b then
            return tonumber(a), tonumber(b), tonumber(d) or 0
        end
        return nil
    end

    if type(c) ~= "table" then
        return nil
    end

    local x = tonumber(c.x or c[1])
    local y = tonumber(c.y or c[2])
    local z = tonumber(c.z or c[3] or c.level or 0)

    if x and y then
        return x, y, z or 0
    end

    return nil
end

local WEAK = { __mode = "k" }
local coord_x = setmetatable({}, WEAK)
local coord_y = setmetatable({}, WEAK)

local function room_xy(room)
    local x = coord_x[room]

    if x == nil then
        local cx, cy = read_coord(room.coord)
        if cx then
            coord_x[room], coord_y[room] = cx, cy
            return cx, cy
        end

        coord_x[room] = false
        return nil
    end

    if x == false then
        return nil
    end

    return x, coord_y[room]
end

local function info_uid(info)
    if type(info) ~= "table" then
        return nil
    end

    local uid = info.num or info.id or info.uid
    if uid == nil then
        return nil
    end

    return tostring(uid)
end

-----------------------------------------------------------------------
-- Index
-----------------------------------------------------------------------

local function has_exit(room, dir)
    return room ~= nil
        and type(room.exits) == "table"
        and room.exits[dir] ~= nil
end

-----------------------------------------------------------------------
-- Pane + size
-----------------------------------------------------------------------

local function write_pane(text)
    if text == last_pane_text then
        return
    end

    last_pane_text = text

    if not rune.pane then
        return
    end

    local done = false

    if type(rune.pane.replace) == "function" then
        done = pcall(rune.pane.replace, PANE_ID, text)
    end

    if not done then
        if rune.pane.clear then
            rune.pane.clear(PANE_ID)
        end

        if rune.pane.write then
            rune.pane.write(PANE_ID, text)
        end
    end

    if type(rune.pane.scroll_to_top) == "function" then
        pcall(rune.pane.scroll_to_top, PANE_ID)
    end
end

local function show_pane()
    if rune.pane and rune.pane.show then
        rune.pane.show(PANE_ID)
    end
end

local function hide_pane()
    if rune.pane and rune.pane.hide then
        rune.pane.hide(PANE_ID)
    end
end

local function detect_size_raw()
    if manual_w and manual_h then
        return manual_w, manual_h, "manual"
    end

    local p = rune.pane

    if type(p) == "table" then
        for _, name in ipairs({
            "size", "get_size", "dimensions", "dims", "info", "get",
            "metrics", "rect", "bounds",
        }) do
            if type(p[name]) == "function" then
                local ok, a, b = pcall(p[name], PANE_ID)
                if ok then
                    local w, h
                    if type(a) == "table" then
                        w = a.width or a.w or a.cols or a.columns
                        h = a.height or a.h or a.rows or a.lines
                    else
                        w, h = a, b
                    end

                    w, h = tonumber(w), tonumber(h)
                    if w and h and w > 0 and h > 0 then
                        return w - border_pad, h - border_pad, "pane." .. name
                    end
                end
            end
        end

        if type(p.width) == "function" and type(p.height) == "function" then
            local ok1, w = pcall(p.width, PANE_ID)
            local ok2, h = pcall(p.height, PANE_ID)
            w, h = tonumber(w), tonumber(h)
            if ok1 and ok2 and w and h and w > 0 and h > 0 then
                return w - border_pad, h - border_pad, "pane.width/height"
            end
        end
    end

    return DEFAULT_W, DEFAULT_H, "default"
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function detect_size()
    local w, h, src = detect_size_raw()
    return clamp(math.floor(w), MIN_W, MAX_W),
        clamp(math.floor(h), MIN_H, MAX_H), src
end

-----------------------------------------------------------------------
-- Drawing
-----------------------------------------------------------------------

local function header_line(info, stored, width)
    local name = info.name or (stored and stored.name) or "Unknown room"
    local area = info.area or info.zone or (stored and stored.area)
        or (type(info.coord) == "table" and info.coord.name)
        or "Unknown zone"

    local text = string.format("%s %s | %s",
        clean(info_uid(info) or (stored and stored.uid) or "?"),
        clean(name), clean(area))

    if #text > width then
        text = text:sub(1, width)
    end

    return text
end

local EXIT_ORDER = {
    "n", "ne", "e", "se", "s", "sw", "w", "nw", "u", "d", "in", "out",
}

local function exits_line(stored, info, width)
    local present = {}

    local function add_from(exits)
        if type(exits) ~= "table" then
            return
        end
        for dir in pairs(exits) do
            present[tostring(dir):lower()] = true
        end
    end

    add_from(stored and stored.exits)

    if next(present) == nil then
        add_from(info and info.exits)
    end

    local list = {}
    for _, dir in ipairs(EXIT_ORDER) do
        if present[dir] then
            list[#list + 1] = dir
        end
    end

    local text = "Exits: " .. (#list > 0 and table.concat(list, " ") or "-")
    return text:sub(1, width)
end

-----------------------------------------------------------------------
-- Styling tables
-----------------------------------------------------------------------

local GLYPHS = {
    { "~", { "water", "swim", "ocean", "river", "lake", "sea" }, "34" },
    { "#", { "road", "street", "path", "trail", "lane", "city", "town",
             "urban", "paved" }, "33" },
    { "$", { "shop" }, "32" },
    { "o", { "forest", "wood", "jungle", "tree" }, "32" },
    { "o", { "mountain", "hill", "peak" }, "90" },
    { "o", { "inside", "indoor", "building", "house", "cave",
             "dungeon", "tunnel" }, "36" },
}

local DEFAULT_ROOM_COLOR = "37"

local NAME_GLYPHS = {
    { "#", { "road", "street", "trail", "path", "lane", "avenue", "alley",
             "highway", "boulevard", "crossroads", "bridge" }, "33" },
    { "$", { "shop", "store", "market", "bazaar" }, "32" },
}

local FLAG_FG  = { { "safe", "92" } }
local FLAG_MOD = { { "dark", "2" } }

local UNEXPLORED_MARKER = "?"

local TRAIL_LENGTH = 6
local TRAIL_COLORS = { "1;95", "95", "35", "35", "2;35", "2;35" }
local DIM_START = 0.7

local ESC = string.char(27)

local COLORS = {
    ["@"] = "1;97;45",
    ["?"] = "1;91",
    ["#"] = "33", ["$"] = "32", ["o"] = "37", ["~"] = "34",
    ["^"] = "1;92", ["v"] = "1;92", ["%"] = "1;92",
    ["-"] = "90", ["|"] = "90", ["/"] = "90", ["\\"] = "90",
    ["X"] = "90",
}

local opts = { flags = true, trail = true, dim = true, strict = true }

local history = {}

local function first_match(entries, text, plain_words)
    for _, entry in ipairs(entries) do
        for _, word in ipairs(entry[2]) do
            local hit
            if plain_words then
                hit = text:find("%f[%a]" .. word .. "%f[%A]")
            else
                hit = text:find(word, 1, true)
            end

            if hit then
                return entry[1], entry[3]
            end
        end
    end

    return nil
end

local function compute_style(room)
    local glyph, color
    local up = has_exit(room, "u")
    local down = has_exit(room, "d")

    if up and down then
        glyph = UPDOWN_MARKER
    elseif up then
        glyph = UP_MARKER
    elseif down then
        glyph = DOWN_MARKER
    end

    if glyph then
        color = COLORS[glyph]
    else
        local text = (tostring(room.terrain or "") .. " "
            .. tostring(room.terraininfo or "") .. " "
            .. tostring(room.flags or "")):lower()

        if text:match("%S") then
            glyph, color = first_match(GLYPHS, text, false)
        end

        if not glyph or glyph == ROOM_MARKER then
            local name = tostring(room.name or ""):lower():gsub("[^%a]", " ")
            local g, c = first_match(NAME_GLYPHS, " " .. name .. " ", true)

            if g then
                glyph, color = g, c
            end
        end

        if not glyph then
            glyph, color = ROOM_MARKER, DEFAULT_ROOM_COLOR
        end
    end

    local flags = tostring(room.flags or ""):lower()
    local fg, mod

    for _, f in ipairs(FLAG_FG) do
        if flags:find(f[1], 1, true) then
            fg = f[2]
            break
        end
    end

    for _, f in ipairs(FLAG_MOD) do
        if flags:find(f[1], 1, true) then
            mod = f[2]
            break
        end
    end

    return { glyph = glyph, color = color or DEFAULT_ROOM_COLOR,
        flag_fg = fg, flag_mod = mod }
end

local style_cache = setmetatable({}, { __mode = "k" })

local function room_style(room)
    local st = style_cache[room]
    if st == nil then
        st = compute_style(room)
        style_cache[room] = st
    end
    return st
end

local function cell_color(st, rank, dist)
    local code = st.color

    if opts.flags then
        if st.flag_fg then
            code = st.flag_fg
        end

        if st.flag_mod then
            code = st.flag_mod .. ";" .. code
        end
    end

    if rank and opts.trail then
        return TRAIL_COLORS[math.min(rank, #TRAIL_COLORS)]
    end

    if opts.dim and dist > DIM_START and code:sub(1, 2) ~= "2;" then
        code = "2;" .. code
    end

    return code
end

-----------------------------------------------------------------------
-- Layout
-----------------------------------------------------------------------

local DIR_OFFSET = {
    n = { 0, 1 }, s = { 0, -1 }, e = { 1, 0 }, w = { -1, 0 },
    ne = { 1, 1 }, nw = { -1, 1 }, se = { 1, -1 }, sw = { -1, -1 },
}

local LAYOUT_DIRS = { "n", "e", "s", "w", "ne", "se", "sw", "nw" }

local DIR_DX, DIR_DY = {}, {}

for i, d in ipairs(LAYOUT_DIRS) do
    DIR_DX[i], DIR_DY[i] = DIR_OFFSET[d][1], DIR_OFFSET[d][2]
end

local LONG_DIRS = {
    north = "n", south = "s", east = "e", west = "w",
    northeast = "ne", northwest = "nw", southeast = "se",
    southwest = "sw", up = "u", down = "d",
}

local view_stats = "layout: none"
local needs_followup = false

local function exit_uid(e)
    if type(e) == "string" or type(e) == "number" then
        return tostring(e)
    end

    if type(e) == "table" then
        local v = e.uid or e.to or e.num or e.id
        return v and tostring(v) or nil
    end

    return nil
end

local function pseudo_room(info)
    local room = { uid = info_uid(info), name = info.name,
        area = info.area or info.zone, terrain = info.terrain,
        terraininfo = info.terraininfo, flags = info.flags,
        coord = info.coord, exits = {} }

    if type(info.exits) == "table" then
        for dir, e in pairs(info.exits) do
            local d = tostring(dir):lower()
            d = LONG_DIRS[d] or d

            local uid = exit_uid(e)
            if uid then
                room.exits[d] = uid
            end
        end
    end

    return room
end

local function layout_from_exits(s, start, start_uid, hx, hy)
    local k0 = key_of(0, 0)
    local grid = { [k0] = start }
    local uids = { [k0] = start_uid }
    local unexplored = {}
    local posx, posy = { [start] = 0 }, { [start] = 0 }
    local queue, head = { start }, 1
    local missing, skipped = false, 0
    local strict = opts.strict

    while queue[head] and head <= 4000 do
        local room = queue[head]
        head = head + 1

        local exits = room.exits
        if type(exits) == "table" then
            local px, py = posx[room], posy[room]
            local rx, ry

            if strict then
                rx, ry = room_xy(room)
            end

            for i = 1, #LAYOUT_DIRS do
                local e = exits[LAYOUT_DIRS[i]]
                if e then
                    local ox, oy = DIR_DX[i], DIR_DY[i]
                    local nx, ny = px + ox, py + oy
                    local k = key_of(nx, ny)

                    if grid[k] == nil and not unexplored[k]
                        and nx <= hx and nx >= -hx
                        and ny <= hy and ny >= -hy then
                        local uid = type(e) == "string" and e or exit_uid(e)
                        local dest = uid and s.get(uid)

                        if not dest then
                            unexplored[k] = true
                            missing = true
                        elseif posx[dest] == nil then
                            local ok = true

                            if rx then
                                local dx, dy = room_xy(dest)
                                if dx then
                                    local ddx, ddy = dx - rx, dy - ry
                                    if not (ddx == ox and ddy == oy)
                                        and not (ddx == 0 and ddy == 0) then
                                        ok = false
                                    end
                                end
                            end

                            if ok then
                                grid[k] = dest
                                uids[k] = uid
                                posx[dest], posy[dest] = nx, ny
                                queue[#queue + 1] = dest
                            else
                                skipped = skipped + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return grid, uids, unexplored, #queue, missing, skipped
end

-----------------------------------------------------------------------
-- Colour output
-----------------------------------------------------------------------

local function paint_text(text, code)
    if not use_color then
        return text
    end
    return ESC .. "[" .. code .. "m" .. text .. ESC .. "[0m"
end

local function paint_row(chars, codes)
    if not use_color then
        return table.concat(chars)
    end

    local out, current = {}, nil

    for i = 1, #chars do
        local ch = chars[i]
        local code = codes[i]

        if ch == " " then
            code = nil
        elseif not code then
            code = COLORS[ch]
        end

        if code ~= current then
            if current then
                out[#out + 1] = ESC .. "[0m"
            end

            if code then
                out[#out + 1] = ESC .. "[" .. code .. "m"
            end

            current = code
        end

        out[#out + 1] = ch
    end

    if current then
        out[#out + 1] = ESC .. "[0m"
    end

    return table.concat(out)
end

-----------------------------------------------------------------------
-- Drawing
-----------------------------------------------------------------------

local function reset_caches()
    style_cache = setmetatable({}, { __mode = "k" })
    coord_x = setmetatable({}, WEAK)
    coord_y = setmetatable({}, WEAK)
end

local draw

local function draw_impl()
    redraw_pending = false

    if not enabled then
        return
    end

    if type(current_info) ~= "table" then
        write_pane("Waiting for Room.Info.")
        return
    end

    local s = get_store()
    if not s then
        write_pane(store_note or "mapper_store not found.")
        if store_loading and rune.timer and rune.timer.after then
            redraw_pending = true
            rune.timer.after(0.05, draw)
        end
        return
    end

    local width, height = detect_size()
    width = math.max(width, 5)
    height = math.max(height, 3)

    local uid = info_uid(current_info)
    local stored = uid and s.get(uid) or nil

    local start = pseudo_room(current_info)
    if next(start.exits) == nil and stored then
        start = stored
    end

    if start.coord == nil and stored then
        start.coord = stored.coord
    end

    local es = {}
    for i = 1, #LAYOUT_DIRS do
        local e = start.exits and start.exits[LAYOUT_DIRS[i]]
        es[i] = e and tostring(exit_uid(e)) or ""
    end

    local sig = table.concat({
        uid or "?", epoch, width, height,
        compact and 1 or 0, use_color and 1 or 0,
        opts.flags and 1 or 0, opts.trail and 1 or 0,
        opts.dim and 1 or 0, opts.strict and 1 or 0,
        table.concat(history, ","), table.concat(es, ","),
    }, "|")

    if sig == last_sig and not needs_followup then
        if DEBUG then dbg("draw skipped (unchanged)") end
        return
    end

    local header = header_line(current_info, stored, width)
    local rows = math.max(height - 2, 1)
    local sx0 = math.floor((width + 1) / 2)
    local sy0 = math.floor((rows + 1) / 2)

    local lines = {
        paint_text(header, "1;37"),
        paint_text(exits_line(start, current_info, width), "36"),
    }

    local span = compact and 2 or 4
    local half_w = math.max(width / span, 1)
    local half_h = math.max(rows / span, 1)

    local grid, uids, unexplored, placed, missing, skipped =
        layout_from_exits(s, start, uid, math.ceil(half_w) + 1,
            math.ceil(half_h) + 1)

    needs_followup = (stored == nil)

    local n_unexplored = 0
    for _ in pairs(unexplored) do
        n_unexplored = n_unexplored + 1
    end

    view_stats = string.format("layout: %d rooms, %d skipped, %d unexplored",
        placed, skipped, n_unexplored)

    local trail_rank = {}
    if opts.trail then
        for i = 2, #history do
            trail_rank[history[i]] = i - 1
        end
    end

    local abs = math.abs

    local function room_cell(ox, oy)
        local k = key_of(ox, oy)
        local room = grid[k]

        if room then
            local st = room_style(room)
            local dist = math.max(abs(ox) / half_w, abs(oy) / half_h)
            return st.glyph, cell_color(st, trail_rank[uids[k]], dist)
        end

        if unexplored[k] then
            return UNEXPLORED_MARKER, nil
        end

        return nil
    end

    local function room_at_offset(ox, oy)
        return grid[key_of(ox, oy)]
    end

    for sy = 1, rows do
        local dy = sy - sy0
        local chars, codes = {}, {}

        for sx = 1, width do
            local dx = sx - sx0
            local ch, code = " ", nil

            if compact then
                if dx == 0 and dy == 0 then
                    ch = CURRENT_MARKER
                else
                    local g, c = room_cell(dx, -dy)
                    if g then
                        ch, code = g, c
                    end
                end
            else
                local row_is_room = (dy % 2 == 0)
                local col_is_room = (dx % 2 == 0)

                local top = row_is_room and (-dy / 2) or (-(dy - 1) / 2)
                local left = col_is_room and (dx / 2) or ((dx - 1) / 2)

                if row_is_room and col_is_room then
                    if dx == 0 and dy == 0 then
                        ch = CURRENT_MARKER
                    else
                        local g, c = room_cell(left, top)
                        if g then
                            ch, code = g, c
                        end
                    end

                elseif row_is_room then
                    local l = room_at_offset(left, top)
                    local r = room_at_offset(left + 1, top)

                    if has_exit(l, "e") or has_exit(r, "w") then
                        ch = "-"
                    end

                elseif col_is_room then
                    local up = room_at_offset(left, top)
                    local dn = room_at_offset(left, top - 1)

                    if has_exit(up, "s") or has_exit(dn, "n") then
                        ch = "|"
                    end

                else
                    local ul = room_at_offset(left, top)
                    local ur = room_at_offset(left + 1, top)
                    local ll = room_at_offset(left, top - 1)
                    local lr = room_at_offset(left + 1, top - 1)

                    local back = has_exit(ul, "se") or has_exit(lr, "nw")
                    local fwd = has_exit(ll, "ne") or has_exit(ur, "sw")

                    if back and fwd then
                        ch = "X"
                    elseif back then
                        ch = "\\"
                    elseif fwd then
                        ch = "/"
                    end
                end
            end

            chars[#chars + 1] = ch
            codes[#codes + 1] = code or false
        end

        lines[#lines + 1] = paint_row(chars, codes)
    end

    write_pane(table.concat(lines, "\n"))
    last_sig = sig
end

draw = function()
    local clock = DEBUG and os.clock or nil
    local t0 = clock and clock() or 0

    local ok, err = pcall(draw_impl)

    if not ok then
        redraw_pending = false
        last_pane_text = nil
        last_sig = nil
        write_pane("asciiMapPane error:\n" .. clean(err))
        if DEBUG then
            dbg("draw error: %s", tostring(err))
        end
    elseif clock then
        dbg("draw %.2f ms | %s", (clock() - t0) * 1000, view_stats)
    end
end

-----------------------------------------------------------------------
-- Legend
-----------------------------------------------------------------------

local function legend()
    local width = detect_size()
    local items, seen = {}, {}

    local function add(glyph, code, label)
        local key = glyph .. "|" .. code
        if not seen[key] then
            seen[key] = true
            items[#items + 1] = {
                text = paint_text(glyph, code) .. " " .. label,
                len = #glyph + 1 + #label,
            }
        end
    end

    add(CURRENT_MARKER, COLORS["@"], "you")
    add(UNEXPLORED_MARKER, COLORS["?"], "unexplored exit")

    for _, entry in ipairs(GLYPHS) do
        add(entry[1], entry[3], entry[2][1])
    end

    add(UP_MARKER, COLORS["^"], "up")
    add(DOWN_MARKER, COLORS["v"], "down")
    add(UPDOWN_MARKER, COLORS["%"], "up+down")

    local out = { paint_text("asciiMapPane legend", "1;37") }
    local line, len = {}, 0

    local function flush()
        if #line > 0 then
            out[#out + 1] = table.concat(line, "  ")
            line, len = {}, 0
        end
    end

    for _, item in ipairs(items) do
        if len > 0 and len + 2 + item.len > width then
            flush()
        end

        line[#line + 1] = item.text
        len = len + item.len + (#line > 1 and 2 or 0)
    end

    flush()

    out[#out + 1] = paint_text("safe", FLAG_FG[1][2]) .. " = safe room, "
        .. paint_text("dark", "2;" .. DEFAULT_ROOM_COLOR) .. " = dark"
    out[#out + 1] = paint_text("magenta", TRAIL_COLORS[1])
        .. " = path you walked, faint = far away"

    last_pane_text = nil
    write_pane(table.concat(out, "\n"))
end

local function later(delay)
    if redraw_pending then
        return
    end

    if rune.timer and rune.timer.after then
        redraw_pending = true
        if DEBUG then dbg("follow-up redraw in %.2fs", delay) end
        rune.timer.after(delay, draw)
    end
end

local function request_draw()
    if not enabled then
        return
    end

    draw()
    if needs_followup then
        later(0.25)
    end
end

local function request_later_draw()
    epoch = epoch + 1
    if enabled then
        later(0.1)
    end
end

-----------------------------------------------------------------------
-- Debug
-----------------------------------------------------------------------

local function debug_dump()
    local detail, summary = {}, {}

    if type(current_info) == "table" then
        local parts = {}
        for k, v in pairs(current_info) do
            if type(v) ~= "table" and type(v) ~= "function" then
                parts[#parts + 1] = clean(k) .. "=" .. clean(v)
            end
        end
        table.sort(parts)
        detail[#detail + 1] = "Room.Info: " .. table.concat(parts, " ")
    else
        detail[#detail + 1] = "Room.Info: none yet"
    end

    local names = {}
    if type(rune.pane) == "table" then
        for k, v in pairs(rune.pane) do
            names[#names + 1] = tostring(k) .. (type(v) == "function" and "()" or "")
        end
        table.sort(names)
    end
    detail[#detail + 1] = "rune.pane: " .. table.concat(names, " ")

    local top = {}
    if type(rune) == "table" then
        for k, v in pairs(rune) do
            top[#top + 1] = tostring(k) .. (type(v) == "table" and "{}" or "")
        end
        table.sort(top)
    end
    detail[#detail + 1] = "rune: " .. table.concat(top, " ")

    local s = get_store()
    local w, h, src = detect_size()

    summary[#summary + 1] = string.format("pane size %sx%s (%s)", tostring(w), tostring(h), src)

    if s then
        local total = 0
        for _ in pairs(s.rooms) do
            total = total + 1
        end

        local stored = info_uid(current_info) and s.get(info_uid(current_info))
        local sx, sy, sz = read_coord(stored and stored.coord)

        summary[#summary + 1] = string.format("store: %s | rooms %d", store_source, total)
        summary[#summary + 1] = string.format("here: %s,%s,%s | %s", tostring(sx), tostring(sy), tostring(sz), view_stats)
        summary[#summary + 1] = string.format("terrain=[%s] info=[%s] glyph=%s",
            clean(stored and stored.terrain or ""),
            clean(stored and stored.terraininfo or ""),
            stored and room_style(stored).glyph or "-")
    else
        summary[#summary + 1] = "store: NOT FOUND - " .. tostring(store_note)
    end

    local out = {}
    for _, line in ipairs(detail) do out[#out + 1] = line end
    for _, line in ipairs(summary) do out[#out + 1] = line end

    last_pane_text = nil
    write_pane(table.concat(out, "\n"))
end

local function list_terrains()
    local s = get_store()
    if not s then
        write_pane("mapper_store not found.")
        return
    end

    local counts = {}
    for _, room in pairs(s.rooms) do
        local t = tostring(room.terrain or "(none)")
        counts[t] = (counts[t] or 0) + 1
    end

    local rows = {}
    for t, n in pairs(counts) do
        rows[#rows + 1] = { t, n }
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)

    local out = { "terrain (rooms):" }
    for i = 1, math.min(#rows, 25) do
        out[#out + 1] = string.format("%s (%d)", clean(rows[i][1]), rows[i][2])
    end

    last_pane_text = nil
    write_pane(table.concat(out, "\n"))
end

-----------------------------------------------------------------------
-- Calibration ruler
-----------------------------------------------------------------------

local function calibrate()
    local ruler = ""
    for k = 1, 12 do
        ruler = ruler .. string.format("%10d", k * 10)
    end

    local lines = {}
    for n = 60, 1, -1 do
        lines[#lines + 1] = string.format("%02d", n) .. ruler:sub(3)
    end

    last_pane_text = nil
    write_pane(table.concat(lines, "\n"))
end

-----------------------------------------------------------------------
-- Setup
-----------------------------------------------------------------------

if rune.pane and rune.pane.create then
    rune.pane.create(PANE_ID, {
        title = "Map",
        border = "full",
    })
end

local function set_enabled(value)
    enabled = value
    if enabled then
        show_pane()
        draw()
    else
        hide_pane()
    end
end

-----------------------------------------------------------------------
-- Help
-----------------------------------------------------------------------

local ok_helpstyle, H = pcall(require, "helpstyle")
if not ok_helpstyle or type(H) ~= "table" then
    H = {
        title   = function(t) return t end,
        section = function(t) return t end,
        line    = function(c, d) return string.format("  %-32s %s", c, d) end,
        foot    = function(t) return t end,
    }
end

local function onoff(v) return v and "on" or "off" end

local function help_status()
    local w, h, src = detect_size()
    return string.format(
        "v2.6  enabled=%s compact=%s color=%s size=%sx%s (%s) flags=%s trail=%s dim=%s strict=%s debug=%s",
        onoff(enabled), compact and "compact" or "spaced", onoff(use_color),
        tostring(w), tostring(h), src, onoff(opts.flags), onoff(opts.trail),
        onoff(opts.dim), onoff(opts.strict), onoff(DEBUG))
end

local function show_help(note)
    local out = {}
    local function emit(text) out[#out + 1] = text end

    if note then emit("[asciiMapPane] " .. note) end

    emit(H.title("asciiMapPane - ASCII map of the rooms around you"))
    emit(H.section("Display:"))
    emit(H.line("asciiMapPane", "show this summary"))
    emit(H.line("asciiMapPane on|off", "show or hide the map pane"))
    emit(H.line("asciiMapPane compact|spaced", "1 char per room / wider with link lines"))
    emit(H.line("asciiMapPane color on|off", "ANSI colours"))
    emit(H.line("asciiMapPane refresh", "force a redraw (clears caches)"))
    emit(H.line("asciiMapPane reset", "restore defaults"))
    emit(H.line("asciiMapPane legend", "what the symbols and colours mean"))
    emit(H.section("Overlays:"))
    emit(H.line("asciiMapPane flags on|off", "tint safe and dark rooms"))
    emit(H.line("asciiMapPane trail on|off", "colour the rooms you just walked"))
    emit(H.line("asciiMapPane dim on|off", "fade far-away rooms"))
    emit(H.line("asciiMapPane strict on|off", "hide rooms whose coordinates say they are not adjacent"))
    emit(H.section("Size:"))
    emit(H.line("asciiMapPane size <W> <H>", "set pane size in characters"))
    emit(H.line("asciiMapPane size auto", "back to the default size"))
    emit(H.line("asciiMapPane pad <N>", "border allowance (default 2)"))
    emit(H.line("asciiMapPane calibrate", "ruler to measure the pane"))
    emit(H.section("Info:"))
    emit(H.line("asciiMapPane terrains", "list terrain names in your map"))
    emit(H.line("asciiMapPane debug", "pane API, size and room data"))
    emit(H.line("asciiMapPane debug on|off", "debug logging (default off)"))
    emit(H.line("asciiMapPane help", "this summary"))
    emit("")
    emit(H.foot(help_status()))

    if type(rune.echo) == "function" then
        for _, line in ipairs(out) do rune.echo(line) end
    else
        show_pane()
        last_pane_text = nil
        write_pane(table.concat(out, "\n"))
    end
end

-- Saved settings (rune.store). Debug is deliberately not saved.
local SETTINGS_KEY = "asciiMapPane.settings"
local saved_sig = nil

local function settings_table()
    return {
        enabled = enabled, compact = compact, color = use_color,
        flags = opts.flags, trail = opts.trail, dim = opts.dim,
        strict = opts.strict, w = manual_w, h = manual_h, pad = border_pad,
    }
end

local function settings_signature()
    local t = settings_table()
    return table.concat({
        tostring(t.enabled), tostring(t.compact), tostring(t.color),
        tostring(t.flags), tostring(t.trail), tostring(t.dim),
        tostring(t.strict), tostring(t.w), tostring(t.h), tostring(t.pad),
    }, "|")
end

local function save_settings()
    if not (rune.store and type(rune.store.set) == "function") then return end
    local sig = settings_signature()
    if sig ~= saved_sig then
        if pcall(rune.store.set, SETTINGS_KEY, settings_table()) then
            saved_sig = sig
        end
    end
end

local function load_settings()
    if not (rune.store and type(rune.store.get) == "function") then return end
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if not ok or type(saved) ~= "table" then return end

    if type(saved.enabled) == "boolean" then enabled = saved.enabled end
    if type(saved.compact) == "boolean" then compact = saved.compact end
    if type(saved.color) == "boolean" then use_color = saved.color end

    for _, name in ipairs({ "flags", "trail", "dim", "strict" }) do
        if type(saved[name]) == "boolean" then opts[name] = saved[name] end
    end

    local w, h = tonumber(saved.w), tonumber(saved.h)
    if w and h then
        manual_w = clamp(math.floor(w), MIN_W, MAX_W)
        manual_h = clamp(math.floor(h), MIN_H, MAX_H)
    end

    local pad = tonumber(saved.pad)
    if pad then border_pad = clamp(math.floor(pad), 0, MAX_PAD) end

    saved_sig = settings_signature()
end

load_settings()

if not enabled then hide_pane() end

local function say(msg)
    if type(rune.echo) == "function" then rune.echo(msg) else last_pane_text = nil; write_pane(msg) end
end

local function run_command_impl(arg_text)
    epoch = epoch + 1

    local words = {}
    for word in tostring(arg_text or ""):gmatch("%S+") do words[#words + 1] = word:lower() end
    local action = words[1] or ""

    if action == "" or action == "help" or action == "?" or action == "h" or action == "-h" or action == "--help" then
        show_help()
    elseif action == "off" then
        set_enabled(false)
    elseif action == "on" then
        set_enabled(true)
    elseif action == "debug" then
        if words[2] == "on" or words[2] == "off" then
            DEBUG = (words[2] == "on")
            say("[asciiMapPane] debug logging " .. (DEBUG and "on" or "off"))
        else
            debug_dump()
        end
    elseif action == "calibrate" then
        calibrate()
    elseif action == "color" or action == "colour" then
        use_color = (words[2] ~= "off")
        last_pane_text = nil
        draw()
    elseif action == "legend" then
        legend()
    elseif action == "terrains" then
        list_terrains()
    elseif action == "compact" or action == "spaced" then
        compact = (action == "compact")
        last_pane_text = nil
        draw()
    elseif action == "refresh" then
        reset_caches()
        last_pane_text = nil
        draw()
    elseif action == "reset" then
        enabled, compact, use_color = true, true, true
        opts.flags, opts.trail, opts.dim, opts.strict = true, true, true, true
        manual_w, manual_h, border_pad = nil, nil, 2
        reset_caches()
        show_pane()
        last_pane_text = nil
        draw()
        say("[asciiMapPane] settings reset to defaults")
    elseif action == "size" then
        local w, h = tonumber(words[2]), tonumber(words[3])
        if w and h then
            local cw = clamp(math.floor(w), MIN_W, MAX_W)
            local ch = clamp(math.floor(h), MIN_H, MAX_H)
            manual_w, manual_h = cw, ch
            if cw ~= w or ch ~= h then
                say(string.format("[asciiMapPane] size limited to %dx%d (allowed %d-%d x %d-%d)", cw, ch, MIN_W, MAX_W, MIN_H, MAX_H))
            end
        else
            manual_w, manual_h = nil, nil
        end
        last_pane_text = nil
        draw()
    elseif action == "pad" then
        local n = tonumber(words[2])
        if n then border_pad = clamp(math.floor(n), 0, MAX_PAD) end
        last_pane_text = nil
        draw()
    elseif opts[action] ~= nil then
        opts[action] = (words[2] ~= "off")
        last_pane_text = nil
        draw()
    else
        show_help("unknown option '" .. action .. "'")
    end

    save_settings()
end

local function args_to_text(args)
    if type(args) == "table" then return table.concat(args, " ") end
    return tostring(args or "")
end

local function run_command(arg_text)
    if DEBUG then dbg("command: '%s'", tostring(arg_text)) end
    local ok, err = pcall(run_command_impl, arg_text)
    if not ok then last_pane_text = nil; write_pane("asciiMapPane error:\n" .. tostring(err)) end
end

-- Bare command preferred; slash form is retained for compatibility.
if rune.alias and rune.alias.regex then
    pcall(rune.alias.regex, "^/?asciiMapPane(.*)$", function(match) run_command(match[1]) end, { name = "asciiMapPane" })
end

if type(rune.command) == "table" then
    for _, fname in ipairs({ "add", "register", "create", "define", "set", "on", }) do
        local f = rune.command[fname]
        if type(f) == "function" then
            local ok = pcall(f, "asciiMapPane", function(args) run_command(args_to_text(args)) end)
            if ok then break end
        end
    end
end

if rune.gmcp and rune.gmcp.on then
    rune.gmcp.on("Room.Info", function(data)
        if type(data) ~= "table" then return end
        current_info = data
        if DEBUG then dbg("Room.Info uid=%s", tostring(info_uid(data))) end
        local uid = info_uid(data)
        if uid and uid ~= history[1] then
            table.insert(history, 1, uid)
            history[TRAIL_LENGTH + 2] = nil
        end
        request_draw()
    end)
end

if rune.hooks and rune.hooks.on then
    rune.hooks.on("mapper_room_changed", function() request_later_draw() end)
end

write_pane("asciiMapPane loaded; waiting for Room.Info...")