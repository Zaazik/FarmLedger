-- Game/Main.lua (tracking + window) against a mocked WoW API. Event order and message / link shapes copied from
-- QuestieTrace records of this client (2026-11-18).
return function(_, T)
	local BEAR = "Creature-0-4170-0-12345-1131-0000ABCDEF"
	local VEIN = "GameObject-0-4170-0-12345-1731-0000ABCDEF"
	local function link(id) return "|cnIQ1:|Hitem:" .. id .. "::::::::59:1485:::::::::|h[x]|h|r" end

	local function client(opts)
		opts = opts or {}
		local m = { now = 0, chat = {}, loot = {}, texts = {}, radios = {}, frames = {}, money = 100000, tickers = {} }
		local env = setmetatable({}, { __index = _G })
		m.env = env
		local handler
		-- any frame / texture / font string: every method exists; size, text, shown and scripts are remembered
		local function stub(kind, name)
			local o = { kind = kind, w = 480, h = 10, shown = kind ~= "Frame" and kind ~= "Button", scripts = {}, text = "" }
			if name then env[name] = o end
			return setmetatable(o, { __index = function(_, k)
				local f = ({
					SetScript = function(self, ev, fn) self.scripts[ev] = fn; if ev == "OnEvent" and not handler then handler = fn end end,
					Show = function(self) self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end,
					Hide = function(self) self.shown = false end,
					SetShown = function(self, v) self.shown = v and true or false end,
					IsShown = function(self) return self.shown end,
					SetText = function(self, t) self.text = t; m.texts[#m.texts + 1] = t end,
					GetText = function(self) return self.text end,
					SetWidth = function(self, v) self.w = v end, SetHeight = function(self, v) self.h = v end,
					SetSize = function(self, w, h) self.w, self.h = w, h end,
					GetWidth = function(self) return self.w end, GetHeight = function(self) return self.h end,
					GetStringWidth = function(self) return #self.text * 6 end,
					GetUnboundedStringWidth = function(self) return #self.text * 6 end,
					GetVerticalScroll = function(self) return rawget(self, "vs") or 0 end,
					SetVerticalScroll = function(self, v) self.vs = v end,
					GetVerticalScrollRange = function(self) return rawget(self, "range") or 0 end,
					CreateTexture = function() return stub("Texture") end,
					CreateFontString = function() return stub("FontString") end,
					GenerateMenu = function() m.generated = (m.generated or 0) + 1 end,
					SetupMenu = function(self, fn)
						m.menuFn = function()
							m.radios = {}
							fn(self, { CreateRadio = function(_, label, isSel, onSel, key)
								m.radios[#m.radios + 1] = { label = label, isSel = isSel, pick = function() onSel(key) end, key = key }
							end })
						end
						m.menuFn()
					end,
				})[k]
				return f or function() end
			end })
		end
		env.CreateFrame = function(kind, name) local f = stub(kind, name); m.frames[#m.frames + 1] = f; return f end
		env.UIParent = stub("Frame"); env.UIParent.h = 1080
		env.UISpecialFrames = {}
		env.tinsert = table.insert
		env.MenuUtil = opts.menu ~= false and {} or nil
		if opts.menu == false then
			env.UIDropDownMenu_SetWidth = function() end
			env.UIDropDownMenu_Initialize = function(_, fn) m.ddInit = fn end
			env.UIDropDownMenu_CreateInfo = function() return {} end
			env.UIDropDownMenu_AddButton = function(info) m.radios[#m.radios + 1] = { label = info.text, pick = info.func } end
			env.UIDropDownMenu_SetText = function(_, t) m.ddText = t end
		end
		env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) m.chat[#m.chat + 1] = msg end }
		env.GetTime = function() return m.now end
		m.later = {}
		env.C_Timer = { After = function(_, fn) m.later[#m.later + 1] = fn end, NewTicker = function(_, fn) m.tickers[#m.tickers + 1] = fn end }
		function m.flush() local l = m.later; m.later = {}; for _, fn in ipairs(l) do fn() end end -- the next frame
		env.C_Spell = { GetSpellName = function(id)
			return ({ [8613] = "Снятие шкур", [10768] = "Снятие шкур", [2575] = "Горное дело", [2366] = "Сбор трав" })[id]
		end }
		local items = opts.items or {}
		env.C_Item = {
			GetItemInfo = function(id) local it = items[id]; if it then return it.name, nil, 1, nil, nil, nil, nil, nil, nil, nil, it.sell, nil, nil, it.bind end end,
			GetItemIconByID = function() return 134257 end,
			GetItemQualityByID = function() return 1 end,
			GetItemInfoInstant = function(id)
				local c = (opts.classes or {})[id]
				if c then return id, "", "", "", 0, c[1], c[2] end
				return id, "", "", "", 0, 15, 0
			end,
			RequestLoadItemDataByID = function(id) m.requested = id end,
		}
		env.GetItemQualityColor = function() return 1, 1, 1, "ffffffff" end
		env.GameTooltip = { SetOwner = function() end, SetItemByID = function(_, id) m.tipItem = id end,
			Show = function() m.tipShown = true end, Hide = function() m.tipShown = false end }
		env.GetNumLootItems = function() return #m.loot end
		env.GetLootSlotLink = function(s) return m.loot[s] and link(m.loot[s].id) end
		env.GetLootSlotInfo = function(s) local l = m.loot[s]; return "tex", l.name, l.qty end
		env.GetLootSourceInfo = function(s) return m.loot[s].guid, m.loot[s].qty end
		env.UnitGUID = function() return nil end
		env.UnitName = function() return nil end
		env.GetMoney = function() return m.money end
		env.GetRealmName = function() return "CAMWOW EU5 Realm 8 PvP" end
		env.UnitFactionGroup = function() return "Horde" end
		if opts.ah then -- Auctionator's public API with fixed prices (lowest buyout for one) and ages in days
			env.Auctionator = { API = { v1 = {
				GetAuctionPriceByItemID = function(_, id) return opts.ah[id] end,
				GetAuctionAgeByItemID = function(_, id) return (opts.ages or {})[id] or 0 end,
			} } }
		end
		env.StaticPopupDialogs = {}
		env.StaticPopup_Show = function(name) m.popup = name end
		env.date = os.date
		env.issecretvalue = function(v) return v == "SECRET" end
		env.LOOT_ITEM_SELF = "Ваша добыча: %s."
		env.LOOT_ITEM_SELF_MULTIPLE = "Ваша добыча: %sx%d."
		env.LOOT_ITEM_PUSHED_SELF = "Вы получили предмет: %s."
		env.LOOT_ITEM_PUSHED_SELF_MULTIPLE = "Вы получили предмет: %sx%d."
		env.SlashCmdList = {}
		env.SkinLedgerDB = opts.saved
		local ns = {}
		for _, f in ipairs({ "Core/Ledger.lua", "Game/Main.lua" }) do
			assert(loadfile(T.root .. "/" .. f, "t", env))("FarmLedger", ns)
		end
		m.ns = ns
		function m.event(e, ...) handler(nil, e, ...) end
		function m.db() return env.SkinLedgerDB end
		function m.sess() return ns.Track.session.book end
		function m.got(id, qty, who)
			local msg = (who and (who .. " получает добычу: ") or "Ваша добыча: ") .. link(id) .. ((qty or 1) > 1 and ("x" .. qty) or "") .. "."
			handler(nil, "CHAT_MSG_LOOT", msg)
		end
		function m.pushed(id, qty)
			handler(nil, "CHAT_MSG_LOOT", "Вы получили предмет: " .. link(id) .. ((qty or 1) > 1 and ("x" .. qty) or "") .. ".")
		end
		function m.slash(s) env.SlashCmdList.FARMLEDGER(s) end
		m.event("ADDON_LOADED", "FarmLedger")
		m.event("PLAYER_ENTERING_WORLD")
		return m
	end

	-- one gathering with auto loot, in this client's order: LOOT_READY, LOOT_OPENED, LOOT_READY, LOOT_CLOSED x2,
	-- then one "Ваша добыча" line per taken slot
	local function gather(m, target, spellID, items, opts)
		opts = opts or {}
		m.event("UNIT_SPELLCAST_SENT", "player", target, "cast" .. m.now, spellID)
		m.now = m.now + 1.5
		if not opts.lootFirst then m.event("UNIT_SPELLCAST_SUCCEEDED", "player", "cast" .. (m.now - 1.5), spellID) end
		m.loot = items
		m.event("LOOT_READY", true)
		m.event("LOOT_OPENED", true, false)
		m.event("LOOT_READY", true)
		if opts.lootFirst then m.event("UNIT_SPELLCAST_SUCCEEDED", "player", "cast" .. (m.now - 1.5), spellID) end
		m.event("LOOT_CLOSED")
		m.event("LOOT_CLOSED")
		for s = 1, #items - (opts.leave or 0) do m.got(items[s].id, items[s].qty) end
		m.loot = {}
		m.now = m.now + 5
	end
	local function corpse(m, items)
		m.loot = items
		m.event("LOOT_READY", true)
		m.event("LOOT_CLOSED")
		for _, it in ipairs(items) do m.got(it.id, it.qty) end
		m.loot = {}
		m.now = m.now + 3
	end

	return {
		{ "skinning: mob counted once, items in Skins and Total, in both session and statistics", function()
			local m = client()
			gather(m, "Bear", 10768, { { id = 2318, qty = 2, name = "Light Leather", guid = BEAR }, { id = 783, qty = 1, guid = BEAR } })
			gather(m, "Bear", 10768, { { id = 2318, qty = 3, guid = BEAR } })
			for _, book in ipairs({ m.sess(), m.db().stats }) do
				local b = book.skins[1131]
				T.eq(b.count, 2, "two skins"); T.eq(b.items[2318], 5, "leather"); T.eq(b.items[783], 1, "hide")
				T.eq(b.name, "Bear", "name"); T.eq(book.total.items[2318], 5, "total has it too")
			end
		end },
		{ "mining and herbs: by node entry, in their own tabs", function()
			local m = client()
			gather(m, "Медная жила", 2575, { { id = 2770, qty = 3, guid = VEIN }, { id = 774, qty = 1, guid = VEIN } })
			gather(m, "Сребролист", 2366, { { id = 765, qty = 2, guid = "GameObject-0-1-2-3-1617-AB" } })
			local b = m.sess()
			T.eq(b.mining[1731].count, 1, "vein"); T.eq(b.mining[1731].items[2770], 3, "ore"); T.eq(b.mining[1731].items[774], 1, "gem")
			T.eq(b.mining[1731].name, "Медная жила", "vein name")
			T.eq(b.herbs[1617].items[765], 2, "herb"); T.eq(next(b.skins), nil, "no skins")
			T.eq(b.total.items[2770], 3, "total ore")
		end },
		{ "a node without a recognised cast: a game object's window with a herb / ore counts in its tab", function()
			local m = client({ classes = { [2447] = { 7, 9 }, [2770] = { 7, 7 }, [6303] = { 7, 8 } } })
			m.event("UNIT_SPELLCAST_SENT", "player", "Мироцвет", "c1", 55555) -- a spell this addon doesn't know
			m.now = 1.5
			corpse(m, { { id = 2447, qty = 2, guid = "GameObject-0-1-2-3-1618-AB" } })
			T.eq(m.sess().herbs[1618].count, 1, "herb node"); T.eq(m.sess().herbs[1618].items[2447], 2, "herb")
			T.eq(m.sess().herbs[1618].name, "Мироцвет", "named after the last cast's target")
			corpse(m, { { id = 2770, qty = 1, guid = VEIN } })
			T.eq(m.sess().mining[1731].items[2770], 1, "ore node")
			corpse(m, { { id = 6303, qty = 1, guid = "GameObject-0-1-2-3-180582-AB" } }) -- a fishing pool: raw fish
			T.eq(m.sess().herbs[180582], nil, "fish: not a node"); T.eq(m.sess().mining[180582], nil, "not mining")
			corpse(m, { { id = 2447, qty = 1, guid = BEAR } }) -- a herb from a mob corpse
			T.eq(m.sess().herbs[1131], nil, "corpse: not a herb node")
			T.eq(m.sess().total.items[2447], 3, "all of it in Total")
		end },
		{ "Auctionator: prices with source and age; no data yet / not loaded is said in the window", function()
			local items = { [2318] = { name = "Light Leather", sell = 10 }, [4304] = { name = "Thick Leather", sell = 10 },
				[783] = { name = "Light Hide", sell = 10 } }
			local m = client({ ah = { [2318] = 2000, [4304] = 1000 }, ages = { [4304] = 3, [2318] = 0 }, items = items })
			corpse(m, { { id = 2318, qty = 1, guid = BEAR }, { id = 4304, qty = 1, guid = BEAR } })
			m.slash("print")
			local all = table.concat(m.chat, " | ")
			T.truthy(all:find("19с 0м (АХ)", 1, true), "AH price after cut: " .. all)
			m.texts = {}
			m.slash("")
			all = table.concat(m.texts, " | ")
			T.truthy(all:find("Auctionator", 1, true), "source shown")
			T.truthy(all:find("(3 дн.)", 1, true), "an old price says its age")
			-- Auctionator loaded but never scanned
			local m2 = client({ ah = {}, items = items })
			corpse(m2, { { id = 783, qty = 1, guid = BEAR } })
			m2.slash("")
			T.truthy(table.concat(m2.texts, " | "):find("в Auctionator ещё нет цен", 1, true), "asks for a scan")
			-- no Auctionator at all
			local m3 = client({ items = items })
			corpse(m3, { { id = 783, qty = 1, guid = BEAR } })
			m3.slash("")
			T.truthy(table.concat(m3.texts, " | "):find("Auctionator не загружен", 1, true), "says it's missing")
			T.truthy(table.concat(m3.texts, " | "):find("торг.", 1, true), "vendor price used")
		end },
		{ "closing the auction house redraws the window (Auctionator may have new prices)", function()
			local m = client({ ah = {} })
			m.slash("")
			local before = #m.texts
			m.event("AUCTION_HOUSE_SHOW"); m.event("AUCTION_HOUSE_CLOSED")
			T.truthy(#m.texts > before, "redrawn")
		end },
		{ "corpse loot: Total only; someone else's loot ignored", function()
			local m = client()
			corpse(m, { { id = 4306, qty = 2, guid = BEAR } })
			m.got(4306, 5, "Вася")
			T.eq(m.sess().total.items[4306], 2, "only my loot"); T.eq(next(m.sess().skins), nil, "not a skin")
		end },
		{ "real sequence - window 2084.1 (Плотная кожа from Старый щербозуб)", function()
			local m = client()
			local G = "Creature-0-6847-1-31-7445-FCDC538750"
			m.event("UNIT_SPELLCAST_SENT", "player", "Старый щербозуб", "c1", 10768)
			m.now = 2; m.event("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", 10768)
			m.loot = { { id = 4304, qty = 1, name = "Плотная кожа", guid = G } }
			m.event("LOOT_READY", true)
			m.now = 2.25; m.event("LOOT_OPENED", true, false); m.event("LOOT_READY", true)
			m.now = 2.63; m.event("LOOT_CLOSED"); m.event("LOOT_CLOSED")
			m.loot = {}
			m.event("CHAT_MSG_LOOT", "Ваша добыча: |cnIQ1:|Hitem:4304::::::::59:1485:::::::::|h[Плотная кожа]|h|r.")
			T.eq(m.sess().skins[7445].count, 1, "one skin"); T.eq(m.sess().skins[7445].items[4304], 1, "leather")
		end },
		{ "coins: money gained + coin line; merchant sales and money without the line are not coins", function()
			local m = client()
			m.event("LOOT_READY", true); m.event("LOOT_CLOSED")
			m.money = m.money + 298; m.now = 0.16; m.event("PLAYER_MONEY")
			m.now = 1.0; m.event("CHAT_MSG_MONEY", "Ваша добыча: 2 |4серебряная:серебряные:серебряных;, 98 |4медная монета:медные монеты:медных монет;.")
			T.eq(m.sess().total.coins, 298, "coins")
			m.event("MERCHANT_SHOW"); m.money = m.money + 5000; m.event("PLAYER_MONEY"); m.event("MERCHANT_CLOSED")
			m.event("CHAT_MSG_MONEY", "x")
			T.eq(m.sess().total.coins, 298, "vendor sale not counted")
			m.event("MAIL_SHOW") -- this client never sends MAIL_CLOSED (QuestieTrace): a mailbox visit must not block coins
			m.now = 10; m.money = m.money + 700; m.event("PLAYER_MONEY") -- mail money: no coin line
			m.now = 20; m.event("CHAT_MSG_MONEY", "late")
			T.eq(m.sess().total.coins, 298, "no line within 2.5 s: not coins")
			m.now = 30; m.money = m.money + 55; m.event("PLAYER_MONEY")
			m.now = 30.9; m.event("CHAT_MSG_MONEY", "Ваша добыча: 55 медных")
			T.eq(m.sess().total.coins, 353, "coins after a mailbox visit still count")
		end },
		{ "quests: gold from QUEST_TURNED_IN; its money gain is not coins; reward items within 1 s, before or after", function()
			local m = client()
			m.now = 100; m.money = m.money + 10200; m.event("PLAYER_MONEY")
			m.now = 100.01; m.event("QUEST_TURNED_IN", 4120, 4100, 10200)
			m.now = 100.5; m.event("CHAT_MSG_MONEY", "x")
			T.eq(m.sess().total.quest, 10200, "quest gold"); T.eq(m.sess().total.coins, 0, "not coins")
			m.now = 100.03; m.pushed(15706)
			T.eq(m.sess().total.items[15706], 1, "reward after turn-in")
			m.now = 200.00; m.pushed(15708)
			m.now = 200.06; m.event("QUEST_TURNED_IN", 5242, 9300, 0)
			T.eq(m.sess().total.items[15708], 1, "reward 0.06 s before turn-in")
			m.now = 205.5; m.pushed(11617) -- a quest-start item 5.5 s later
			m.now = 300; m.pushed(8952, 13) -- a vendor purchase
			m.now = 310; m.event("QUEST_TURNED_IN", 1, 1, 0)
			T.eq(m.sess().total.items[11617], nil, "quest-start item not counted")
			T.eq(m.sess().total.items[8952], nil, "purchase not counted")
		end },
		{ "leftovers from a gathered node opened again count to its tab", function()
			local m = client()
			gather(m, "Медная жила", 2575, { { id = 2770, qty = 2, guid = VEIN }, { id = 774, qty = 1, guid = VEIN } }, { leave = 1 })
			m.loot = { { id = 774, qty = 1, guid = VEIN } }
			m.event("LOOT_READY"); m.event("LOOT_CLOSED"); m.got(774, 1)
			T.eq(m.sess().mining[1731].items[774], 1, "gem counted"); T.eq(m.sess().mining[1731].count, 1, "no extra node")
		end },
		{ "an interrupted / stale / other-spell-failed cast", function()
			local m = client()
			m.event("UNIT_SPELLCAST_SENT", "player", "Bear", "c1", 8613)
			m.event("UNIT_SPELLCAST_INTERRUPTED", "player", "c1", 8613)
			corpse(m, { { id = 2318, qty = 1, guid = BEAR } })
			T.eq(next(m.sess().skins), nil, "interrupted: not a skin")
			m.event("UNIT_SPELLCAST_SENT", "player", "Bear", "SECRET", 8613)
			m.event("UNIT_SPELLCAST_FAILED", "player", "SECRET", 133)
			gather(m, "Bear", 8613, { { id = 2318, qty = 1, guid = BEAR } })
			T.eq(m.sess().skins[1131].count, 1, "other spell's failure kept it")
			m.event("UNIT_SPELLCAST_SENT", "player", "Bear", "c9", 8613)
			m.event("UNIT_SPELLCAST_SUCCEEDED", "player", "c9", 8613)
			m.now = m.now + 30
			corpse(m, { { id = 2318, qty = 1, guid = BEAR } })
			T.eq(m.sess().skins[1131].count, 1, "stale cast expired")
		end },
		{ "unreadable slots retried at LOOT_OPENED; still unreadable is reported", function()
			local m = client()
			m.event("UNIT_SPELLCAST_SENT", "player", "Bear", "c1", 8613)
			m.loot = { { id = 2318, qty = "SECRET", guid = BEAR } }
			m.event("LOOT_READY"); m.loot[1].qty = 2; m.event("LOOT_OPENED")
			T.eq(m.sess().skins[1131].count, 1, "retried")
			m.event("LOOT_CLOSED"); m.now = m.now + 5
			m.event("UNIT_SPELLCAST_SENT", "player", "Bear", "c2", 8613)
			m.loot = { { id = 2318, qty = "SECRET", guid = BEAR } }
			m.event("LOOT_READY"); m.event("LOOT_OPENED")
			T.truthy(m.chat[#m.chat]:find("не записан"), "warned")
		end },
		{ "session vs statistics: a new session leaves statistics; stats Reset clears only Total; wipe clears all", function()
			local m = client()
			gather(m, "Bear", 8613, { { id = 2318, qty = 1, guid = BEAR } })
			m.event("QUEST_TURNED_IN", 1, 1, 500)
			m.slash("reset"); T.eq(m.popup, "FARMLEDGER_RESET", "asks")
			m.env.StaticPopupDialogs.FARMLEDGER_RESET.OnAccept()
			T.eq(next(m.sess().skins), nil, "session cleared"); T.eq(m.db().stats.skins[1131].count, 1, "stats kept")
			m.db().mode = "stats"
			m.slash("reset")
			m.env.StaticPopupDialogs.FARMLEDGER_RESET.OnAccept()
			T.eq(m.db().stats.total.quest, 0, "stats total cleared"); T.eq(next(m.db().stats.total.items), nil, "items cleared")
			T.eq(m.db().stats.skins[1131].count, 1, "skins stay")
			m.slash("wipe"); T.eq(m.popup, "FARMLEDGER_WIPE", "asks to wipe")
			m.env.StaticPopupDialogs.FARMLEDGER_WIPE.OnAccept()
			T.eq(next(m.db().stats.skins), nil, "wiped")
		end },
		{ "Reset asks about the mode shown then; switching mode while it's open doesn't change what it clears", function()
			local m = client()
			m.event("QUEST_TURNED_IN", 1, 1, 500)
			m.slash("reset") -- asked in Session mode
			m.db().mode = "stats"
			m.env.StaticPopupDialogs.FARMLEDGER_RESET.OnAccept()
			T.eq(m.db().stats.total.quest, 500, "statistics untouched")
			T.eq(m.sess().total.quest, 0, "the session was reset")
		end },
		{ "a new session doesn't cut off a gathering window in progress (statistics still get its items)", function()
			local m = client()
			m.event("UNIT_SPELLCAST_SENT", "player", "Bear", "c1", 8613)
			m.event("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", 8613)
			m.loot = { { id = 2318, qty = 2, guid = BEAR } }
			m.event("LOOT_READY", true); m.event("LOOT_CLOSED")
			m.slash("reset"); m.env.StaticPopupDialogs.FARMLEDGER_RESET.OnAccept()
			m.got(2318, 2)
			T.eq(m.db().stats.skins[1131].items[2318], 2, "statistics card got the leather")
		end },
		{ "hidden (secret) loot line / quest money / slots are reported, not dropped silently", function()
			local m = client()
			m.event("CHAT_MSG_LOOT", "SECRET")
			T.truthy(m.chat[#m.chat]:find("скрыл строку добычи"), "loot line warned")
			m.event("QUEST_TURNED_IN", 1, 1, "SECRET")
			T.truthy(m.chat[#m.chat]:find("скрыл награду"), "quest money warned")
			m.event("UNIT_SPELLCAST_SENT", "player", "Bear", "c1", 8613)
			m.loot = { { id = 2318, qty = 1, guid = BEAR }, { id = 783, qty = "SECRET", guid = BEAR } }
			m.event("LOOT_READY", true)
			T.truthy(m.chat[#m.chat]:find("не дал прочитать"), "partly unreadable window warned")
		end },
		{ "items the game hasn't loaded yet have no price until they load", function()
			local m = client({ ah = { [2318] = 1000 } })
			corpse(m, { { id = 2318, qty = 1, guid = BEAR } })
			m.slash("print")
			T.truthy(table.concat(m.chat, " | "):find("нет цены", 1, true), "unloaded: no price yet")
		end },
		{ "a /reload starts a new session; statistics survive; SkinLedger's 128 skins move over once", function()
			-- first start: the saved table is still SkinLedger's own (v1, mobs)
			local v1 = { version = 1, mobs = { [7458] = { name = "Йети", skins = 16, items = { [4304] = 10 } } } }
			local m = client({ saved = v1 })
			T.eq(m.db().stats.skins[7458].count, 16, "migrated from the saved table"); T.eq(m.db().mobs, nil, "v1 shape gone")
			T.eq(m.db().stats.skins[7444], nil, "the code's copy not added on top")
			gather(m, "Bear", 8613, { { id = 2318, qty = 1, guid = BEAR } })
			local m2 = client({ saved = m.db() })
			T.eq(next(m2.sess().skins), nil, "fresh session"); T.eq(m2.db().stats.skins[1131].count, 1, "stats kept")
			T.eq(m2.db().stats.skins[7458].count, 16, "not migrated twice")
		end },
		{ "the running client's /reload writes an empty v2 table: the skins come from the copy in the code", function()
			local m = client({ saved = { version = 2, stats = {}, itemNames = {} } })
			local n, skins = 0, 0
			for _, g in pairs(m.db().stats.skins) do n = n + 1; skins = skins + g.count end
			T.eq(n, 13, "13 mobs"); T.eq(skins, 128, "128 skins")
			T.eq(m.db().stats.skins[7458].items[4304], 10, "Йети: 10 Плотная кожа")
			local m2 = client({ saved = m.db() })
			skins = 0
			for _, g in pairs(m2.db().stats.skins) do skins = skins + g.count end
			T.eq(skins, 128, "once only")
		end },
		{ "ui: tabs, mode switch, item prices with source, tooltip, sort dropdown", function()
			local items = { [2318] = { name = "Light Leather", sell = 50 }, [774] = { name = "Malachite", sell = 400 } }
			local m = client({ ah = { [2318] = 1000 }, items = items })
			gather(m, "Bear", 8613, { { id = 2318, qty = 4, guid = BEAR } })
			gather(m, "Медная жила", 2575, { { id = 774, qty = 1, guid = VEIN } })
			m.slash("")
			local all = table.concat(m.texts, " | ")
			for _, want in ipairs({ "Light Leather", "4 шт", "АХ", "Malachite", "торг.", "Монеты с мобов", "Золото с заданий", "Доход:", "Сессия 0:" }) do
				T.truthy(all:find(want, 1, true), "Total shows " .. want)
			end
			T.eq(m.env.FarmLedgerFrame.shown, true, "window shown")
			-- tooltip on an item row
			local hit
			for _, f in ipairs(m.frames) do if rawget(f, "itemID") == 2318 and f.scripts.OnEnter then hit = f end end
			T.truthy(hit, "row hover"); hit.scripts.OnEnter(hit); T.eq(m.tipItem, 2318, "tooltip item")
			-- the Mining tab
			m.texts = {}
			m.db().tab = "mining"; m.ns.Refresh()
			all = table.concat(m.texts, " | ")
			T.truthy(all:find("Медная жила", 1, true) and all:find("в среднем с жилы", 1, true), all)
			m.menuFn()
			T.eq(#m.radios, 3, "three sorts"); T.eq(m.radios[1].label, "по числу жил", "mining wording")
			m.radios[3].pick(); T.eq(m.db().sort, "avg", "sort picked")
			-- statistics mode: no gold per hour
			m.texts = {}
			m.db().mode = "stats"; m.ns.Refresh()
			all = table.concat(m.texts, " | ")
			T.truthy(all:find("Статистика за всё время", 1, true), "stats line")
			T.truthy(not all:find("в час", 1, true), "no gold per hour in statistics")
		end },
		{ "ui: minimize to the mini window with session numbers; a click opens the full window; a drag does not", function()
			local m = client()
			m.event("QUEST_TURNED_IN", 1, 1, 10200)
			m.now = 120
			m.slash("")
			m.ns.Minimize()
			T.eq(m.env.FarmLedgerFrame.shown, false, "full hidden"); T.eq(m.db().minimized, true, "remembered")
			local mini = m.env.FarmLedgerMini
			T.eq(mini.shown, true, "mini shown")
			local all = table.concat(m.texts, " | ")
			T.truthy(all:find("сессия 0:02", 1, true), "session clock"); T.truthy(all:find("в час", 1, true), "gold per hour")
			mini.scripts.OnDragStart(mini); mini.scripts.OnDragStop(mini); mini.scripts.OnClick(mini)
			T.eq(mini.shown, true, "a click that ends a drag doesn't open")
			m.flush()
			mini.scripts.OnClick(mini)
			T.eq(mini.shown, false, "click: mini hidden"); T.eq(m.env.FarmLedgerFrame.shown, true, "full shown")
			T.eq(m.db().minimized, false, "remembered")
			local m2 = client({ saved = { minimized = true } })
			T.eq(m2.env.FarmLedgerMini.shown, true, "minimized state comes back after a reload")
			T.truthy(#m2.tickers > 0, "a clock keeps the numbers live")
		end },
		{ "ui: smooth wheel scrolling", function()
			local m = client()
			m.slash("")
			local sc
			for _, f in ipairs(m.frames) do if f.kind == "ScrollFrame" then sc = f end end
			sc.range = 100
			sc.scripts.OnMouseWheel(sc, -1)
			T.eq(m.env.FarmLedgerFrame.scrollTarget(), 48, "one notch")
			sc.scripts.OnUpdate(sc, 0.016)
			T.truthy(sc.vs > 0 and sc.vs < 48, "partway")
			for _ = 1, 200 do if rawget(sc.scripts, "OnUpdate") then sc.scripts.OnUpdate(sc, 0.016) end end
			T.eq(sc.vs, 48, "arrives")
		end },
		{ "ui: the old dropdown where MenuUtil is missing", function()
			local m = client({ menu = false })
			m.db().tab = "skins"
			m.slash("")
			m.ddInit(nil, 1)
			T.eq(#m.radios, 3, "three"); m.radios[1].pick(); T.eq(m.db().sort, "count", "picked")
			T.eq(m.ddText, "по числу мобов", "label")
		end },
		{ "/farm print and /farm sort", function()
			local m = client()
			gather(m, "Bear", 8613, { { id = 2318, qty = 2, guid = BEAR } })
			m.db().tab = "skins"
			m.slash("print")
			local all = table.concat(m.chat, " | ")
			T.truthy(all:find("Шкуры (сессия)", 1, true) and all:find("Bear", 1, true), all)
			m.slash("sort avg"); T.eq(m.db().sort, "avg", "sort")
			m.slash("sort junk"); T.truthy(m.chat[#m.chat]:find("count | total | avg", 1, true), "usage")
		end },
		{ "no globals leak", function()
			local m = client()
			for _, k in ipairs({ "pending", "loot", "gathered", "window", "mini", "cards" }) do
				T.eq(rawget(m.env, k), nil, k)
			end
		end },
	}
end
