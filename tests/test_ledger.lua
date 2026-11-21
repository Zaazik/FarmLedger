-- Core/Ledger.lua: books, price books, the value rule, reports, gold per hour, migration.
return function(ns, T)
	local L = ns.Ledger
	local NAMES = { [2318] = "Light Leather", [783] = "Light Hide", [4304] = "Thick Leather", [2770] = "Copper Ore" }
	local function names(id) return NAMES[id] or ("item:" .. id) end
	local function find(lines, pat)
		for i, l in ipairs(lines) do if l:find(pat) then return i, l end end
	end
	local function flat(units) -- a valuer from fixed unit prices
		return function(id) local u = units[id]; return u, u and "auction" end
	end

	return {
		{ "EntryID: creatures and game objects, not players", function()
			local k, id = L.EntryID("Creature-0-6847-1-31-7445-FCDC538750")
			T.eq(k, "Creature", "kind"); T.eq(id, 7445, "npc")
			k, id = L.EntryID("GameObject-0-6847-1-31-1731-0000ABCDEF")
			T.eq(k, "GameObject", "node kind"); T.eq(id, 1731, "node entry")
			T.eq(L.EntryID("Player-4170-0ABCDEF"), nil, "player")
			T.eq(L.EntryID(nil), nil, "nil")
		end },
		{ "Russian plurals", function()
			local function f(n) return L.Plural(n, "раз", "раза", "раз") end
			T.eq(f(1), "раз", "1"); T.eq(f(2), "раза", "2"); T.eq(f(5), "раз", "5"); T.eq(f(12), "раз", "12"); T.eq(f(22), "раза", "22")
		end },
		{ "Money formats", function()
			T.eq(L.Money(201503), "20з 15с 3м", "gold")
			T.eq(L.Money(603), "6с 3м", "silver")
			T.eq(L.MoneyColored(150008), "15|cffffd100 з|r 8|cffe0a070 м|r", "zero silver left out")
			T.eq(L.MoneyColored(0), "0|cffe0a070 м|r", "zero")
		end },
		{ "Auctionator prices: lowest buyout for one, after the 5% cut, with its age; missing API is an error", function()
			local calls = {}
			local api = {
				GetAuctionPriceByItemID = function(caller, id) calls[#calls + 1] = caller; return ({ [2318] = 1000, [4304] = 603, [9] = 0 })[id] end,
				GetAuctionAgeByItemID = function(_, id) return ({ [2318] = 0, [4304] = 3 })[id] end,
			}
			local src = assert(L.AuctionatorPrices(api))
			local u, age = src.price(2318)
			T.eq(u, 950, "after cut"); T.eq(age, 0, "seen today")
			u, age = src.price(4304)
			T.eq(u, 572, "floor(603 * 0.95)"); T.eq(age, 3, "3 days old")
			T.eq(src.price(9), nil, "zero price: none"); T.eq(src.price(1), nil, "never seen")
			T.eq(calls[1], "FarmLedger", "callerID is the addon's name")
			T.eq(src.name, "Auctionator", "name")
			local none, err = L.AuctionatorPrices(nil)
			T.eq(none, nil, "no Auctionator"); T.truthy(err:find("Auctionator не загружен", 1, true), err)
			T.eq(L.AuctionatorPrices({}), nil, "API without the price function")
		end },
		{ "value rule: AH (after the cut) when it beats the vendor by over 15%, else vendor; soulbound / no-AH go to vendor", function()
			local ah = { [1] = 950, [2] = 950, [3] = 950, [5] = 950 } -- already after the cut, as AuctionatorPrices gives them
			local prices = { price = function(id) return ah[id], id == 5 and 4 or 0 end }
			local vendor = { [1] = 100, [2] = 900, [3] = 100, [4] = 250, [5] = 0 }
			local bound = { [3] = true }
			local v = L.Valuer(prices, function(id) return vendor[id] end, function(id) return bound[id] end)
			local u, src = v(1)
			T.eq(u, 950, "AH"); T.eq(src, "auction", "AH chosen")
			u, src = v(2)
			T.eq(u, 900, "950 < 900 * 1.15: vendor"); T.eq(src, "vendor", "vendor chosen")
			u, src = v(3)
			T.eq(u, 100, "soulbound: vendor"); T.eq(src, "vendor", "soulbound source")
			u, src = v(4)
			T.eq(u, 250, "no AH price: vendor"); T.eq(src, "vendor", "vendor only")
			local g
			u, src, g = v(5)
			T.eq(u, 950, "can't be sold to a vendor: AH"); T.eq(g, 4, "price age passed on")
			T.eq(v(6), nil, "no price at all")
			T.eq(L.Valuer(prices, function() return nil end, function() return false end)(1), nil, "not loaded yet: no value")
			local noAh = L.Valuer(nil, function() return 40 end, function() return false end)
			T.eq(noAh(1), 40, "without Auctionator: vendor")
		end },
		{ "gather tab: three sorts, averages, totals", function()
			local groups = {
				[1] = { name = "A", count = 10, items = { [1] = 10 } }, -- 1з total, 10с each
				[2] = { name = "B", count = 2, items = { [2] = 2 } },   -- 60с, 30с each
				[3] = { name = "C", count = 5, items = { [3] = 5 } },   -- 2з, 40с each
			}
			local v = flat({ 1000, 3000, 4000 })
			local function order(s)
				local out = {}
				for _, b in ipairs(L.BuildGather(groups, v, names, s).blocks) do out[#out + 1] = b.name end
				return table.concat(out)
			end
			T.eq(order("count"), "ACB", "by count"); T.eq(order("total"), "CAB", "by total"); T.eq(order("avg"), "CBA", "by avg")
			local r = L.BuildGather(groups, v, names, "total")
			T.eq(r.count, 17, "count"); T.eq(r.total, 36000, "total")
			T.truthy(not pcall(L.BuildGather, groups, v, names, "bogus"), "unknown sort is an error")
			local lines = L.ReportGather("mining", r)
			T.truthy(find(lines, "в среднем с жилы"), "mining wording")
		end },
		{ "total tab: items + coins + quest gold; unpriced items flagged and left out", function()
			local t = { items = { [2318] = 4, [9] = 1 }, coins = 500, quest = 10200 }
			local r = L.BuildTotal(t, flat({ [2318] = 100 }), names)
			T.eq(r.itemsTotal, 400, "items"); T.eq(r.total, 400 + 500 + 10200, "total"); T.eq(r.unpriced, 1, "unpriced")
			local lines = L.ReportTotal(r)
			T.truthy(find(lines, "Золото с заданий: 1з 2с 0м"), "quest line")
			T.truthy(find(lines, "%+1 предм%. без цены"), "unpriced flag")
		end },
		{ "gold per hour: extrapolated under an hour, last 60 min after, per tab", function()
			local v = flat({ [1] = 100, [2] = 1000 })
			local ev = {
				{ t = 100, what = "item", id = 1, qty = 3, tab = "mining" }, -- 300
				{ t = 200, what = "coins", c = 50 },
				{ t = 300, what = "quest", c = 1000 },
				{ t = 400, what = "item", id = 2, qty = 1 },                 -- 1000, corpse loot (total only)
			}
			T.eq(L.Rate(ev, 600, 0, v, "total"), 2350 / 600 * 3600, "total extrapolated")
			T.eq(L.Rate(ev, 600, 0, v, "mining"), 1800, "mining only its items")
			T.eq(L.Rate(ev, 600, 0, v, "skins"), 0, "skins nothing")
			T.eq(L.Rate(ev, 30, 0, v, "total"), nil, "under a minute: not said")
			T.eq(L.Rate(ev, 7200, 0, v, "total"), 0, "old entries out of the window")
			ev[#ev + 1] = { t = 7000, what = "coins", c = 3600 }
			T.eq(L.Rate(ev, 7200, 0, v, "total"), 3600, "last hour, not extrapolated")
			T.eq(#L.Prune(ev, 7200), 1, "prune keeps the last hour")
		end },
		{ "Init drops a Mastercraft price book picked by an earlier version", function()
			T.eq(L.Init({ priceBook = "eu-pvp-Horde" }).priceBook, nil, "gone")
		end },
		{ "Init: defaults, SkinLedger migration once", function()
			local db = L.Init(nil)
			T.eq(db.mode, "session", "mode"); T.eq(db.tab, "total", "tab"); T.eq(db.sort, "total", "sort")
			T.truthy(db.stats.total and db.stats.mining, "book")
			local legacy = { mobs = { [7458] = { name = "Йети", skins = 16, items = { [4304] = 10 } } }, itemNames = { [4304] = "Плотная кожа" } }
			db = L.Init(nil, legacy)
			T.eq(db.stats.skins[7458].count, 16, "skins -> count")
			T.eq(db.stats.skins[7458].items[4304], 10, "items")
			T.eq(db.itemNames[4304], "Плотная кожа", "names")
			db = L.Init(db, legacy)
			T.eq(db.stats.skins[7458].count, 16, "not migrated twice")
		end },
		{ "ResetTotal leaves the gather tabs", function()
			local b = L.NewBook()
			L.AddGather(b, "mining", 1731, "Медная жила"); L.AddItem(b, 2770, 3); L.AddCoins(b, 5); L.AddQuest(b, 7)
			L.ResetTotal(b)
			T.eq(next(b.total.items), nil, "items gone"); T.eq(b.total.coins, 0, "coins"); T.eq(b.total.quest, 0, "quest")
			T.eq(b.mining[1731].count, 1, "mining kept")
		end },
	}
end
