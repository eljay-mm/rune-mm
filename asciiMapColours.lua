-- Filename: eljayPlugins/asciiMapColours.lua
-- Purpose: Colour schemes and colour editing for asciiMapPane, loaded only when `amp colours` is used.
-- Version: 1.2
-- Date: 2026-Oct-23
--
--[[ Todo:
- insert planning notes here between revisions.
--]]
--
-- Changelog:
--   1.2   Tabs; dropped colour-family and four themed schemes (size < 16000).
--   1.1   Brought to standard; compact scheme data, shorter code converter.
--   1.0   Split out of asciiMapPane.lua (v2.25).
-- How it works:
--   * asciiMapPane requires this file the first time `amp colours` is typed and calls run(words, api); the colour codes live in the shared api.CODES table the map draws from. Debug and on/off live in asciiMapPane.
--   * Schemes: basic (default, 16 colours only), steel, vivid, soft, primary, pastel, deep, six earth tones, six themed, and custom, which is fully yours: `colours scheme custom` copies the scheme in use, then `colours <colour> <code>` changes any scheme colour.
--   * Fixed in every scheme: room number and name bold white, exits and stairs cyan, shops deep green, roads grey (basic uses 16-colour forms). Schemes colour you, unexplored, pk, trainer, safe, plain rooms, links and dark rooms. The trail is the colour of you, fading.
--   * Codes are c<N> for 256 colours (c208), names (red, bright-red, grey) and bold-, faint-, reverse-, on- prefixes (bold-c16-on-c226). Needs `export TERM=xterm-256color`.
--   * The chosen scheme, your custom colours and the resulting codes are saved in rune.store under asciiMapPane.colours (shared by all characters), read fresh before each save; asciiMapPane applies them at startup without loading this file.
--
-- Commands (through asciiMapPane):
--   asciiMapPane colours|colors           list the map colours (c<N> codes)
--   asciiMapPane colours <colour> <code>  change one colour in custom (e.g. unexplored c215)
--   asciiMapPane colours reset [colour]   restore from custom's base scheme
--   asciiMapPane colours scheme [scheme]  switch scheme; no name lists them all
--   asciiMapPane colours scheme custom [base]  start custom from a scheme
--   asciiMapPane colours palette          show sample colour codes

local M = {}

local A, CODES

local FIXED = { header = "1;37", exits = "36", road = "38;5;250",
	stairs = "36", shop = "38;5;28" }
local FIXED16 = { header = "1;37", exits = "36", road = "37",
	stairs = "36", shop = "32" }

local COLOR_ITEMS, COLOR_BY_KEY = {}, {}

for _, key in ipairs({ "you", "unexplored", "pk", "trainer", "safe", "room",
	"links", "dark" }) do
	COLOR_BY_KEY[key] = { key = key,
		get = function() return CODES[key] end,
		set = function(c) CODES[key] = c end }
	COLOR_ITEMS[#COLOR_ITEMS + 1] = COLOR_BY_KEY[key]
end

local color_scheme = "basic"
local custom, custom_base = nil, "basic"

local function make(n)
	local function f(c) return "38;5;" .. c end

	return {
		you = n[1] and ("1;38;5;" .. n[1] .. ";48;5;" .. n[2]) or ("1;7;" .. f(n[2])),
		unexplored = "1;" .. f(n[3]), pk = "1;" .. f(n[4]), trainer = f(n[5]),
		room = f(n[6]), links = f(n[7]), safe = "1;" .. f(n[8]), dark = "2",
	}
end

local SCHEMES = {
	steel = {
		you = "1;38;5;236;48;5;110", unexplored = "1;38;5;215", pk = "38;5;222",
		trainer = "1;38;5;167", safe = "1;38;5;108", room = "38;5;67",
		links = "38;5;240", dark = "2",
	},
	basic = {
		you = "1;30;43", unexplored = "1;91", pk = "1;91", trainer = "93",
		room = "37", links = "90", safe = "92", dark = "2", sixteen = true,
	},
}
local SCHEME_ORDER = { "basic", "steel" }

-- name, you-text (- = reverse), you-bg, unexplored, pk, trainer, room, links, safe
local PRESETS = "vivid 16 226 196 196 220 248 244 154;"
	.. "soft 234 223 167 167 179 245 240 150;"
	.. "primary - 226 196 196 208 250 244 120;"
	.. "pastel - 229 210 210 216 250 244 193;deep - 220 160 160 172 246 240 76;"
	.. "ember - 202 231 196 220 166 94 114;"
	.. "mahogany - 180 202 196 214 137 94 108;"
	.. "campfire - 214 196 160 226 208 130 119;"
	.. "charcoal - 208 214 196 172 244 238 114;"
	.. "moss - 172 202 196 178 101 58 150;sepia - 223 202 160 178 137 94 107;"
	.. "nord 236 110 167 167 222 253 240 114;"
	.. "gruvbox 235 223 167 167 214 223 239 142;"
	.. "solarized 234 230 160 160 136 246 240 106;"
	.. "dracula 235 141 203 203 228 253 61 84;"
	.. "ocean 16 51 203 203 229 195 24 48;"
	.. "autumn 16 208 160 160 214 223 238 143"

for name, rest in PRESETS:gmatch("(%a+)([^;]*)") do
	local n = {}
	for t in rest:gmatch("%S+") do n[#n + 1] = t ~= "-" and tonumber(t) end
	SCHEMES[name] = make(n)
	SCHEME_ORDER[#SCHEME_ORDER + 1] = name
end

local function copy_scheme(src)
	local t = {}
	for _, it in ipairs(COLOR_ITEMS) do
		t[it.key] = src[it.key] or SCHEMES.basic[it.key]
	end
	t.sixteen = src.sixteen   -- a copy of basic stays 16-colour
	return t
end

local function apply_scheme(name)
	local set = (name == "custom") and custom or SCHEMES[name]
	if not set then return false end

	color_scheme = name
	for k, v in pairs(set.sixteen and FIXED16 or FIXED) do CODES[k] = v end
	for _, it in ipairs(COLOR_ITEMS) do
		it.set(set[it.key] or SCHEMES.basic[it.key])
	end
	return true
end

local COLOR_NAMES = { black = 30, red = 31, green = 32, yellow = 33,
	blue = 34, magenta = 35, cyan = 36, white = 37, grey = 90, gray = 90 }

-- c<N>, names, bold- faint- reverse- bright- on- prefixes, or plain SGR
-- numbers typed 1.97.45 (Rune splits input at ;). Only digits and ; are kept.
local function valid_code(c)
	if #c > 40 then return nil end

	c = c:gsub("[.:]", ";")

	if c:match("^%d[%d;]*$") then
		if c:find(";;", 1, true) or c:sub(-1) == ";" then return nil end
		for num in c:gmatch("%d+") do
			if tonumber(num) > 255 then return nil end
		end
		return c
	end

	local out, bright, bg = {}, false, false

	for tok in c:gmatch("[^%-]+") do
		if tok == "bold" then
			out[#out + 1] = "1"
		elseif tok == "faint" then
			out[#out + 1] = "2"
		elseif tok == "reverse" or tok == "inverse" then
			out[#out + 1] = "7"
		elseif tok == "bright" then
			bright = true
		elseif tok == "on" then
			bg = true
		else
			local idx = tok:match("^c(%d+)$")
			local n = COLOR_NAMES[tok]

			if idx then
				if tonumber(idx) > 255 then return nil end
				out[#out + 1] = (bg and "48;5;" or "38;5;") .. tonumber(idx)
			elseif n then
				if bright and n < 90 then n = n + 60 end
				out[#out + 1] = tostring(bg and n + 10 or n)
			else
				return nil
			end

			bright, bg = false, false
		end
	end

	if bright or bg or #out == 0 then return nil end
	return table.concat(out, ";")
end

local BASIC_NAMES = { "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" }
local SGR_WORDS = { [1] = "bold", [2] = "faint", [7] = "reverse" }
local SGR_PREFIX = { [3] = "", [4] = "on-", [9] = "bright-", [10] = "on-bright-" }

local function simple(code)
	local nums, out, i = {}, {}, 1
	for n in code:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end

	while i <= #nums do
		local n = nums[i]
		local w = SGR_WORDS[n]
		local p, k = SGR_PREFIX[math.floor(n / 10)], n % 10

		if not w then
			if (n == 38 or n == 48) and nums[i + 1] == 5 and nums[i + 2] then
				w = (n == 48 and "on-c" or "c") .. nums[i + 2]
				i = i + 2
			elseif p and k < 8 then
				w = (k == 0 and n >= 90) and (n == 90 and "grey" or "on-grey")
					or (p .. BASIC_NAMES[k + 1])
			else
				return (code:gsub(";", "."))
			end
		end

		out[#out + 1] = w
		i = i + 1
	end

	return table.concat(out, "-")
end

local function shown(codes)
	local out = {}
	for piece in codes:gmatch("[^,]+") do out[#out + 1] = simple(piece) end
	return table.concat(out, " ")
end

local function normalize(it, text)
	local pieces = {}
	for piece in tostring(text):gmatch("[^,]+") do
		local code = valid_code(piece)
		if not code then
			return nil, "'" .. A.clean(piece):sub(1, 20) .. "' is not a colour (try: colours palette)"
		end
		pieces[#pieces + 1] = code
	end

	if #pieces ~= 1 then
		return nil, it.key .. " takes one code"
	end

	return table.concat(pieces, ",")
end

local function echo(text) rune.echo(text) end

local function colours_list(note)
	local h, P = A.helpstyle(), A.SHORT .. " colours"
	local fixed = color_scheme ~= "custom"
	local base = SCHEMES[custom_base] or SCHEMES.basic

	if note then echo(A.paint(note)) end

	echo(h.title(A.NAME .. " colours"))
	echo(h.section("Colours, scheme " .. color_scheme
		.. (fixed and " (fixed):" or " (* = changed):")))

	for _, it in ipairs(COLOR_ITEMS) do
		local cur = it.get()
		local mark = (not fixed and cur ~= base[it.key]) and " *" or ""

		echo(h.line(it.key, A.paint_text("sample", cur) .. "  " .. shown(cur) .. mark))
	end

	echo(h.section("Change:"))
	echo(h.line(P .. " <colour> <code>", "custom only, e.g. you c110"))
	echo(h.line(P .. " reset [colour]", "restore from custom's base scheme"))
	echo(h.line(P .. " scheme [scheme]", "switch scheme; no name lists all"))
	echo(h.line(P .. " scheme custom [base]", "start custom from a scheme"))
	echo(h.line(P .. " palette", "show sample colour codes"))
	echo(h.section("Codes:"))
	echo(h.line("c<N>", "256-colour text, N 0-255 (c208)"))
	echo(h.line("on-<code>", "background (bold-c16-on-c226)"))
	echo(h.line("bold- faint- bright-", "prefixes (bold-c226, bright-red)"))
	echo(h.line("red green grey ...", "names also work"))
	echo(h.foot(A.help_status()))
end

local STRIP = { { "@", "you" }, { "?", "unexplored" }, { "x", "pk" },
	{ "T", "trainer" }, { "$", "shop" }, { "s", "safe" }, { "^", "stairs" },
	{ "#", "road" }, { "o", "room" } }

local function schemes_list(note)
	local h = A.helpstyle()

	if note then echo(A.paint(note)) end

	echo(h.title(A.NAME .. " colour schemes"))

	for i = 1, #SCHEME_ORDER + (custom and 1 or 0) do
		local name = SCHEME_ORDER[i] or "custom"
		local set = (name == "custom") and custom or SCHEMES[name]
		local fx, cells = set.sixteen and FIXED16 or FIXED, {}

		for _, cell in ipairs(STRIP) do
			cells[#cells + 1] = A.paint_text(cell[1], set[cell[2]] or fx[cell[2]])
		end
		echo(h.line(name .. (name == color_scheme and " *" or ""), table.concat(cells, " ")))
	end

	echo(h.line(A.SHORT .. " colours scheme <scheme>", "switch (* = in use)"))
	echo(h.foot(A.help_status()))
end

local function swatch_fg(n)
	if n < 16 then
		return (n == 0 or n == 1 or n == 4 or n == 5 or n == 8) and "97" or "30"
	end

	local v = n - 16
	local r, g, b = math.floor(v / 36), math.floor(v / 6) % 6, v % 6
	return (2 * r + 3 * g + b > 12) and "30" or "97"
end

local function colours_palette()
	echo(A.helpstyle().title(A.NAME .. " colour samples"))

	local function row(label, list)
		local cells = {}
		for _, n in ipairs(list) do
			cells[#cells + 1] = A.paint_text(string.format(" %-4s", "c" .. n),
				swatch_fg(n) .. ";48;5;" .. n)
		end
		echo(string.format("%-12s", label) .. table.concat(cells, " "))
	end

	row("c0-c7", { 0, 1, 2, 3, 4, 5, 6, 7 })
	row("c8-c15", { 8, 9, 10, 11, 12, 13, 14, 15 })
	row("warm", { 196, 202, 208, 214, 220, 226, 190, 154, 118, 82 })
	row("cool", { 46, 47, 48, 49, 51, 45, 39, 33, 27, 21 })
	row("violet", { 57, 93, 129, 165, 201, 199, 197, 160, 124, 88 })
	row("grey", { 232, 236, 240, 244, 248, 252, 255 })

	echo("Text cN (c208); background on-cN; prefixes bold- faint-.")
	echo("Names: black red green yellow blue magenta cyan white grey.")
	echo("c0-c15 follow your terminal theme; c16-c255 are fixed.")
end

local function colours_command(words)
	local key = words[2]

	if not key then
		colours_list()
	elseif key == "palette" or key == "codes" then
		colours_palette()
	elseif key == "scheme" then
		local name, base = words[3], words[4]

		if name == nil then
			schemes_list()
			return
		elseif name == "custom" then
			if base ~= nil and not SCHEMES[base] then
				A.say("base must be a scheme name (" .. A.SHORT .. " colours scheme)")
				return
			end

			-- First use, or an explicit base: start custom from a scheme.
			if base or not custom then
				local from = base or (SCHEMES[color_scheme] and color_scheme) or custom_base
				custom, custom_base = copy_scheme(SCHEMES[from]), from
			end

			apply_scheme("custom")
		elseif SCHEMES[name] then
			apply_scheme(name)
		else
			schemes_list("unknown scheme '" .. A.clean(name):sub(1, 20) .. "'")
			return
		end

		A.redraw()
		A.say("colour scheme " .. color_scheme)
	elseif key == "reset" then
		if color_scheme ~= "custom" then
			A.say(color_scheme .. " is a fixed scheme; nothing to reset")
			return
		end

		local name = words[3]
		local base = SCHEMES[custom_base]

		if name == nil or name == "all" then
			custom = copy_scheme(base)
		elseif COLOR_BY_KEY[name] then
			custom[name] = base[name]
		else
			colours_list("unknown colour '" .. A.clean(name):sub(1, 20) .. "'")
			return
		end

		apply_scheme("custom")
		A.redraw()
		A.say("custom colours reset" .. ((name and name ~= "all") and (": " .. name) or ""))
	else
		local it = COLOR_BY_KEY[key]
		if not it then
			colours_list("unknown colour '" .. A.clean(key):sub(1, 20) .. "'")
			return
		end

		if not words[3] then
			A.say(key .. " = " .. shown(it.get()))
			return
		end

		if color_scheme ~= "custom" then
			A.say(color_scheme .. " is fixed; use: " .. A.SHORT .. " colours scheme custom")
			return
		end

		local code, err = normalize(it, table.concat(words, ",", 3))
		if not code then
			A.say(err)
			return
		end

		custom[key] = code
		it.set(code)
		A.redraw()
		A.say(key .. " = " .. shown(it.get()))
	end
end

-----------------------------------------------------------------------
-- Saved state (rune.store): scheme, custom and the resulting codes
-----------------------------------------------------------------------

local KEY = "asciiMapPane.colours"
local saved_sig

local function ser(t)
	local k = {}
	for key, v in pairs(t) do k[#k + 1] = key .. "=" .. tostring(v) end
	table.sort(k)
	return table.concat(k, ";")
end

local function codes_copy()
	local codes = {}
	for k, v in pairs(CODES) do codes[k] = v end
	return codes
end

local function sig_of(codes)
	return table.concat({ color_scheme, custom_base, ser(codes),
		custom and ser(custom) or "" }, "|")
end

local function load_state()
	color_scheme, custom, custom_base = "basic", nil, "basic"

	local ok, saved = pcall(rune.store.get, KEY)
	if not ok or type(saved) ~= "table" then
		-- v2.24 kept the custom scheme in the shared settings
		local ok2, old = pcall(rune.store.get, "asciiMapPane.settings")
		if not (ok2 and type(old) == "table" and type(old.custom) == "table") then return end
		saved = { custom = old.custom, custom_base = old.custom_base }
	end

	if type(saved.custom) == "table" then
		custom = copy_scheme({})
		for k, v in pairs(saved.custom) do
			local it = COLOR_BY_KEY[k]
			local code = it and type(v) == "string" and normalize(it, v)
			if code then custom[k] = code end
		end
		custom.sixteen = (saved.custom.sixteen == true) or nil
		if SCHEMES[saved.custom_base] then custom_base = saved.custom_base end
	end

	if (saved.scheme == "custom" and custom) or SCHEMES[saved.scheme] then
		color_scheme = saved.scheme
	end
end

local function save_state()
	local codes = codes_copy()
	local sig = sig_of(codes)
	if sig == saved_sig then return end

	local ok, cur = pcall(rune.store.get, KEY)
	if not ok or type(cur) ~= "table" then cur = {} end

	cur.scheme, cur.custom_base, cur.codes = color_scheme, custom_base, codes
	cur.custom = custom and copy_scheme(custom) or false

	if pcall(rune.store.set, KEY, cur) then saved_sig = sig end
end

-- api: CODES, NAME, SHORT, say, paint, paint_text, clean, helpstyle,
-- help_status, redraw (supplied by asciiMapPane).
function M.run(words, api)
	A, CODES = api, api.CODES
	load_state()
	saved_sig = sig_of(codes_copy())
	colours_command(words)
	save_state()
end

return M