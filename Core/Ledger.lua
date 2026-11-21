-- Pure logic, no WoW API: the books (session / statistics), prices, gold per hour, the report data and chat text.
local _, ns = ...
local Ledger = {}
ns.Ledger = Ledger

local floor = math.floor

Ledger.GATHER = { "mining", "herbs", "skins" } -- the per-node / per-mob tabs
Ledger.TABS = { "total", "mining", "herbs", "skins" }
Ledger.TAB_LABELS = { total = "Итого", mining = "Горное дело", herbs = "Травничество", skins = "Шкуры" }
Ledger.SORTS = { "count", "total", "avg" }
local PER = { mining = "с жилы", herbs = "с травы", skins = "с моба" }
local OF = { mining = "по числу жил", herbs = "по числу трав", skins = "по числу мобов" }
function Ledger.SortLabel(tab, key)
	if key == "count" then return OF[tab] end
	if key == "total" then return "по общему доходу" end
	return "по доходу " .. PER[tab]
end
function Ledger.Per(tab) return PER[tab] end

-- A book: what one mode has counted.
--   mining / herbs / skins: { [key] = { name, count, items = { [itemID] = qty } } }  key = node entry / NPC ID, or name
--   total: { items = { [itemID] = qty }, coins = copper looted, quest = copper from quests }
function Ledger.NewBook()
	return { mining = {}, herbs = {}, skins = {}, total = { items = {}, coins = 0, quest = 0 } }
end

local function fixBook(b)
	b = type(b) == "table" and b or {}
	for _, k in ipairs(Ledger.GATHER) do b[k] = type(b[k]) == "table" and b[k] or {} end
	local t = type(b.total) == "table" and b.total or {}
	t.items, t.coins, t.quest = t.items or {}, t.coins or 0, t.quest or 0
	b.total = t
	return b
end

-- Saved data: { version = 2, stats = book, itemNames, sort, mode, tab, minimized, migratedSkinLedger }.
-- SkinLedger's data ({ version = 1, mobs = { [key] = { name, skins, items } }, itemNames }) moves its skins into
-- stats once: from the saved table itself when it is still SkinLedger's, else from `legacy` (a copy kept in the code).
function Ledger.Init(db, legacy)
	db = type(db) == "table" and db or {}
	if type(db.mobs) == "table" then -- still SkinLedger's table: it is the source, and becomes Farm Ledger's
		legacy = { mobs = db.mobs, itemNames = db.itemNames }
		db = { itemNames = db.itemNames }
	end
	db.version = 2
	db.stats = fixBook(db.stats)
	db.itemNames = db.itemNames or {}
	if type(legacy) == "table" and type(legacy.mobs) == "table" and not db.migratedSkinLedger then
		for key, m in pairs(legacy.mobs) do
			local into = db.stats.skins[key] or { name = m.name, count = 0, items = {} }
			into.count = into.count + (m.skins or 0)
			for id, q in pairs(m.items or {}) do into.items[id] = (into.items[id] or 0) + q end
			db.stats.skins[key] = into
		end
		for id, n in pairs(legacy.itemNames or {}) do db.itemNames[id] = db.itemNames[id] or n end
		db.migratedSkinLedger = true
	end
	if db.sort ~= "count" and db.sort ~= "total" and db.sort ~= "avg" then db.sort = "total" end
	if db.mode ~= "session" and db.mode ~= "stats" then db.mode = "session" end
	if not Ledger.TAB_LABELS[db.tab] then db.tab = "total" end
	db.priceBook = nil -- a Mastercraft price book picked by an earlier version
	return db
end

local function group(book, kind, key, name)
	local g = book[kind][key]
	if not g then
		g = { name = name, count = 0, items = {} }
		book[kind][key] = g
	end
	if name then g.name = name end
	return g
end

function Ledger.AddGather(book, kind, key, name)
	local g = group(book, kind, key, name)
	g.count = g.count + 1
end
function Ledger.AddGatherItem(book, kind, key, itemID, qty)
	local g = group(book, kind, key, nil)
	g.items[itemID] = (g.items[itemID] or 0) + qty
end
function Ledger.AddItem(book, itemID, qty)
	book.total.items[itemID] = (book.total.items[itemID] or 0) + qty
end
function Ledger.AddCoins(book, c) book.total.coins = book.total.coins + c end
function Ledger.AddQuest(book, c) book.total.quest = book.total.quest + c end
function Ledger.ResetTotal(book) book.total = { items = {}, coins = 0, quest = 0 } end

-- "Creature-0-6847-1-31-7445-FCDC538750" -> "Creature", 7445; GameObject the same; nil for players, items.
function Ledger.EntryID(guid)
	if type(guid) ~= "string" then return nil end
	local kind, id = guid:match("^(%a+)%-[^-]*%-[^-]*%-[^-]*%-[^-]*%-(%d+)")
	if kind ~= "Creature" and kind ~= "Vehicle" and kind ~= "GameObject" then return nil end
	return kind, tonumber(id)
end

-- Russian plural: Ledger.Plural(n, "раз", "раза", "раз")
function Ledger.Plural(n, one, few, many)
	local m10, m100 = n % 10, n % 100
	if m10 == 1 and m100 ~= 11 then return one end
	if m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then return few end
	return many
end

function Ledger.Money(c)
	c = floor(c + 0.5)
	local g, s, k = floor(c / 10000), floor(c / 100) % 100, c % 100
	if g > 0 then return string.format("%dз %dс %dм", g, s, k) end
	if s > 0 then return string.format("%dс %dм", s, k) end
	return string.format("%dм", k)
end

-- Money with coloured units, as the window shows it: "15|cffffd100 з|r 8|cffe0a070 м|r" (zero parts left out).
function Ledger.MoneyColored(c)
	c = floor(c + 0.5)
	local g, s, k = floor(c / 10000), floor(c / 100) % 100, c % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "|cffffd100 з|r" end
	if s > 0 then parts[#parts + 1] = s .. "|cffc7c7cf с|r" end
	if k > 0 or #parts == 0 then parts[#parts + 1] = k .. "|cffe0a070 м|r" end
	return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Auction prices from Auctionator, through its public API (Auctionator.API.v1, Auctionator 349):
--   GetAuctionPriceByItemID(callerID, itemID) -> the lowest buyout for ONE item its scans saw (copper), nil if never
--   GetAuctionAgeByItemID(callerID, itemID)   -> days since that price was seen; nil past 21 days or never
-- Nothing of Auctionator is kept in this addon.
---------------------------------------------------------------------------
local AH_CUT = 0.05 -- the auction house keeps 5% of every sale
local CALLER = "FarmLedger"

-- api: Auctionator.API.v1 or nil. Returns { name, price = fn(itemID) -> copper for one item after the cut (nil when
-- Auctionator has no price), and the price's age in days as a second value (nil = older than 21 days) } - or nil and
-- what is wrong.
function Ledger.AuctionatorPrices(api)
	if type(api) ~= "table" or type(api.GetAuctionPriceByItemID) ~= "function" then
		return nil, "Auctionator не загружен - цен АХ нет"
	end
	return {
		name = "Auctionator",
		price = function(itemID)
			local buyout = api.GetAuctionPriceByItemID(CALLER, itemID)
			if type(buyout) ~= "number" or buyout <= 0 then return nil end
			local age = type(api.GetAuctionAgeByItemID) == "function" and api.GetAuctionAgeByItemID(CALLER, itemID) or nil
			return floor(buyout * (1 - AH_CUT)), age
		end,
	}
end

-- What one item is worth - the rule agreed with the user (2026-11-19): the auction price (after the cut) when it beats
-- the vendor by more than 15% - an auction takes time and may not sell; otherwise the vendor price. Soulbound items
-- and items without an auction price go to the vendor; an item no vendor buys goes by the auction price alone.
-- vendorOf(itemID) -> sell price (0 = no vendor buys it), nil while the game hasn't loaded the item (then it has no
-- value yet; the window redraws when the item loads); boundOf(itemID) -> true for soulbound.
-- Returns fn(itemID) -> copper for one | nil, "auction" | "vendor", the auction price's age in days (auction only).
local AUCTION_MARGIN = 1.15
function Ledger.Valuer(prices, vendorOf, boundOf)
	return function(itemID)
		local vendor = vendorOf(itemID)
		if vendor == nil then return nil end
		local auction, age
		if prices and not boundOf(itemID) then auction, age = prices.price(itemID) end
		if auction and auction > vendor * AUCTION_MARGIN then return auction, "auction", age end
		if vendor > 0 then return vendor, "vendor" end
		if auction then return auction, "auction", age end
		return nil
	end
end

local function itemRows(items, value, nameOf)
	local rows, total, unpriced = {}, 0, 0
	for id, qty in pairs(items) do
		local unit, src, age = value(id)
		local r = { id = id, name = nameOf(id), qty = qty, unit = unit, src = src, age = age, sum = unit and unit * qty }
		if unit then total = total + r.sum else unpriced = unpriced + 1 end
		rows[#rows + 1] = r
	end
	table.sort(rows, function(x, y)
		if (x.sum or -1) ~= (y.sum or -1) then return (x.sum or -1) > (y.sum or -1) end
		return x.name < y.name
	end)
	return rows, total, unpriced
end

-- A gather tab: { blocks = { { name, count, items, total, avg, unpriced } }, count, total, avg, unpriced }
function Ledger.BuildGather(groups, value, nameOf, sortBy)
	local blocks = {}
	for key, g in pairs(groups) do
		local b = { name = g.name or ("#" .. tostring(key)), count = g.count }
		b.items, b.total, b.unpriced = itemRows(g.items, value, nameOf)
		b.avg = b.count > 0 and b.total / b.count or 0
		blocks[#blocks + 1] = b
	end
	local order = ({ count = { "count", "total" }, total = { "total", "count" }, avg = { "avg", "total" } })[sortBy or "total"]
	assert(order, "unknown sort: " .. tostring(sortBy))
	table.sort(blocks, function(x, y)
		for _, k in ipairs(order) do
			if x[k] ~= y[k] then return x[k] > y[k] end
		end
		return x.name < y.name
	end)
	local r = { blocks = blocks, count = 0, total = 0, unpriced = 0 }
	for _, b in ipairs(blocks) do
		r.count, r.total, r.unpriced = r.count + b.count, r.total + b.total, r.unpriced + b.unpriced
	end
	r.avg = r.count > 0 and r.total / r.count or 0
	return r
end

-- The Total tab: { items, itemsTotal, coins, quest, total, unpriced }
function Ledger.BuildTotal(t, value, nameOf)
	local r = { coins = t.coins, quest = t.quest }
	r.items, r.itemsTotal, r.unpriced = itemRows(t.items, value, nameOf)
	r.total = r.itemsTotal + r.coins + r.quest
	return r
end

---------------------------------------------------------------------------
-- Gold per hour (Session mode). The session logs what came in:
--   { t = seconds, what = "item", id, qty, tab = "mining"|"herbs"|"skins"|nil } or { t, what = "coins"|"quest", c }
-- An item from a gathering window counts in its tab and in Total; coins and quest gold only in Total.
-- Rate = value of the last 60 minutes; a session shorter than that is extrapolated to an hour.
---------------------------------------------------------------------------
local HOUR = 3600
function Ledger.Rate(events, now, startedAt, value, tab)
	local from, sum = now - HOUR, 0
	for _, e in ipairs(events) do
		if e.t >= from and e.t <= now then
			if e.what == "item" and (tab == "total" or e.tab == tab) then
				local unit = value(e.id)
				if unit then sum = sum + unit * e.qty end
			elseif e.what ~= "item" and tab == "total" then
				sum = sum + e.c
			end
		end
	end
	local span = math.min(HOUR, now - startedAt)
	if span < 60 then return nil end -- under a minute: too short to say
	return sum / span * HOUR
end

-- Drops log entries older than an hour (they no longer count for the rate).
function Ledger.Prune(events, now)
	local keep = {}
	for _, e in ipairs(events) do if e.t >= now - HOUR then keep[#keep + 1] = e end end
	return keep
end

---------------------------------------------------------------------------
-- Chat text (/farm print): the shown tab.
---------------------------------------------------------------------------
local function itemLine(it)
	if it.unit then
		return string.format("   %s - %d шт x %s (%s) = %s", it.name, it.qty, Ledger.Money(it.unit),
			it.src == "vendor" and "торговец" or "АХ", Ledger.Money(it.sum))
	end
	return string.format("   %s - %d шт x |cffff4040нет цены|r", it.name, it.qty)
end

function Ledger.ReportGather(tab, r)
	local lines = {}
	for _, b in ipairs(r.blocks) do
		lines[#lines + 1] = string.format("|cffffd100%s|r - %d %s", b.name, b.count, Ledger.Plural(b.count, "раз", "раза", "раз"))
		for _, it in ipairs(b.items) do lines[#lines + 1] = itemLine(it) end
		lines[#lines + 1] = string.format("   |cff33ff99доход %s, в среднем %s %s|r%s", Ledger.Money(b.total), PER[tab],
			Ledger.Money(b.avg), b.unpriced > 0 and string.format(" |cffff4040(+%d без цены)|r", b.unpriced) or "")
	end
	if #r.blocks == 0 then lines[#lines + 1] = "Пока пусто." end
	lines[#lines + 1] = string.format("|cffffffffВсего: %d %s, доход %s, в среднем %s %s|r", r.count,
		Ledger.Plural(r.count, "раз", "раза", "раз"), Ledger.Money(r.total), PER[tab], Ledger.Money(r.avg))
	return lines
end

function Ledger.ReportTotal(r)
	local lines = {}
	for _, it in ipairs(r.items) do lines[#lines + 1] = itemLine(it) end
	lines[#lines + 1] = "   Монеты с мобов: " .. Ledger.Money(r.coins)
	lines[#lines + 1] = "   Золото с заданий: " .. Ledger.Money(r.quest)
	lines[#lines + 1] = string.format("|cffffffffДоход: %s|r%s", Ledger.Money(r.total),
		r.unpriced > 0 and string.format(" |cffff4040(+%d предм. без цены)|r", r.unpriced) or "")
	return lines
end

return Ledger
