-- Farm Ledger, the game side: tracking (what comes in) and the window. One file, because the running client keeps
-- the TOC it started with (Core\Ledger.lua, Game\Main.lua; SavedVariables SkinLedgerDB) until a restart, and the
-- addon must work after a plain /reload.
--
-- What comes in: gathering casts and their loot windows, every looted item, coins, quest gold and quest reward items.
-- Writes into two books: the session (memory only, from a /reload to the next or to Reset) and the statistics (saved).
-- WoW Forever (Interface 16001) modern client API; event order checked against QuestieTrace records (2026-11-18).
local addonName, ns = ...
local Ledger = ns.Ledger
local T = {}
ns.Track = T

local PREFIX = "|cff33ff99FarmLedger|r: "
function ns.say(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end
local say = ns.say

local CAST_WINDOW = 10 -- seconds from the cast being sent to its loot window (loot can come before SUCCEEDED)
local AFTER_CAST = 3   -- seconds after the cast succeeded
local LOOT_GRACE = 2   -- a window's items are still expected this long after it closes (auto loot: lines come after)
local COIN_WINDOW = 2.5 -- the coin line comes ~1 s after PLAYER_MONEY
local QUEST_WINDOW = 1  -- reward items come within this of QUEST_TURNED_IN, before or after it

T.db = nil           -- SkinLedgerDB (the saved data)
T.session = nil      -- { book, events, startedAt }
local pending        -- { kind, target, castGUID, at, doneAt }: our gathering cast
local lastSent       -- { target, at }: the target of the player's last cast of any spell (a node's name)
local loot           -- { kind, key, want = { [itemID] = qty }, names, closedAt }: its loot window, items not yet received
local gathered = {}  -- source GUID -> { kind, key }: nodes / corpses gathered this session (leftovers opened again)
local lastMoney      -- GetMoney() at the last PLAYER_MONEY
local coinGains = {} -- { t, c }: money gained, waiting for the coin line
local pushes = {}    -- { t, id, qty }: "you received" items, waiting to see whether a quest was turned in
local lastTurnIn     -- GetTime() of the last QUEST_TURNED_IN
-- merchant / auction house open: money gained there is a sale, not coins. Only these two: both their open and close
-- events are in QuestieTrace's records; MAIL_CLOSED never showed up there (a mail flag would stay set and drop every
-- coin after a mailbox visit), and mail / trade money never comes with a coin line anyway.
local isOpen = { merchant = false, auction = false }

local function changed() if ns.Refresh then ns.Refresh() end end

-- a hidden (secret) value means something is not counted: say so, at most once per 10 s per kind
local warnedAt = {}
local function warn(kind, msg)
	local now = GetTime()
	if warnedAt[kind] and now - warnedAt[kind] < 10 then return end
	warnedAt[kind] = now
	say("|cffff4040" .. msg .. "|r")
end

-- A new session: only the session's own book and log. A cast, loot window, coin or reward still on its way keeps
-- going, so the statistics (and the new session) still get it.
function T.NewSession()
	T.session = { book = Ledger.NewBook(), events = {}, startedAt = GetTime() }
end

-- The client can hide a value from addons (issecretvalue): such a value can't be compared or kept.
local function hidden(...)
	if issecretvalue == nil then return false end
	local values = { n = select("#", ...), ... }
	for i = 1, values.n do
		if issecretvalue(values[i]) then return true end
	end
	return false
end
-- fn(...) or nil when it fails or its result is hidden
local function safe(fn, ...)
	if not fn then return nil end
	local ok, result = pcall(fn, ...)
	if ok and not hidden(result) then return result end
	return nil
end

---------------------------------------------------------------------------
-- Gathering casts: the profession spells by ID, as Wowhead's WoW Forever database lists them
-- (nether.wowhead.com/forever/tooltip/spell/<id>, checked 2026-11-21: Skinning / Mining / Herbalism, the ranks for
-- skill 75, 150, 225, 300), and any spell named like one of them in the client's own language.
---------------------------------------------------------------------------
local PROFESSION_SPELLS = {
	skins = { 8613, 8617, 8618, 10768 },
	mining = { 2575, 2576, 3564, 10248 },
	herbs = { 2366, 2368, 3570, 11993 },
}
local function nameOfSpell(id)
	if C_Spell and C_Spell.GetSpellName then
		local name = C_Spell.GetSpellName(id)
		return name
	end
	if GetSpellInfo then
		local name = GetSpellInfo(id)
		return name
	end
end
local kindById, kindByName -- filled on first use (the client knows spell names once the player is in the world)
function T.GatherKind(spellID)
	if type(spellID) ~= "number" then return nil end
	if not kindById then
		kindById, kindByName = {}, {}
		for kind, ids in pairs(PROFESSION_SPELLS) do
			for _, id in ipairs(ids) do
				kindById[id] = kind
				local name = nameOfSpell(id)
				if type(name) == "string" and name ~= "" then kindByName[name] = kind end
			end
		end
	end
	if kindById[spellID] then return kindById[spellID] end
	local name = nameOfSpell(spellID)
	return name and kindByName[name] or nil
end

-- A node's loot window without a recognised cast (the herb / ore cast may be a spell other than the profession's):
-- a window from a game object holding a herb or ore / stone is that node. Item class 7 (trade goods), subclass 9 = herb,
-- 7 = metal & stone (warcraft.wiki.gg "ItemType"; GetItemInfoInstant gives classID 6th and subclassID 7th).
local TRADE_GOODS, HERB, METAL_STONE = 7, 9, 7
local function nodeKind(slots)
	local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not instant then return nil end
	for _, it in pairs(slots) do
		local classID, subclassID = select(6, instant(it.id))
		if classID == TRADE_GOODS and subclassID == HERB then return "herbs" end
		if classID == TRADE_GOODS and subclassID == METAL_STONE then return "mining" end
	end
	return nil
end

---------------------------------------------------------------------------
-- Chat lines. The game builds them from its own format strings: LOOT_ITEM_SELF "Ваша добыча: %s." and
-- LOOT_ITEM_SELF_MULTIPLE "Ваша добыча: %sx%d." for loot, LOOT_ITEM_PUSHED_SELF[_MULTIPLE] "Вы получили предмет: ..."
-- for items handed to you (seen in QuestieTrace records: "Ваша добыча: |cnIQ1:|Hitem:4304:...|h[Плотная кожа]|h|r." and
-- "...|h|rx2."). A line of a kind starts with the text before the item; the count follows the link after the text
-- the "multiple" format puts between the item and the number.
---------------------------------------------------------------------------
local function splitFormat(fmt)
	if type(fmt) ~= "string" then return nil end
	local at, stop = fmt:find("%s", 1, true)
	if not at then at, stop = fmt:find("%1$s", 1, true) end
	if not at then return nil end
	local before = fmt:sub(1, at - 1)
	local after = fmt:sub(stop + 1)
	local num = after:find("%d", 1, true) or after:find("%2$d", 1, true)
	return before, num and after:sub(1, num - 1) or nil
end
local LOOT_START = splitFormat(LOOT_ITEM_SELF)
local _, LOOT_COUNT = splitFormat(LOOT_ITEM_SELF_MULTIPLE)
local PUSH_START = splitFormat(LOOT_ITEM_PUSHED_SELF)
local _, PUSH_COUNT = splitFormat(LOOT_ITEM_PUSHED_SELF_MULTIPLE)

-- itemID, count of a line that starts with `start`; nil for other lines
local function readLine(msg, start, countMark)
	if not start or msg:sub(1, #start) ~= start then return nil end
	local id = tonumber(msg:match("|Hitem:(%d+)"))
	if not id then return nil end
	local count = 1
	local linkEnd = select(2, msg:find("|h|r", #start + 1, true))
	if linkEnd and countMark and msg:sub(linkEnd + 1, linkEnd + #countMark) == countMark then
		count = tonumber(msg:match("^%d+", linkEnd + #countMark + 1)) or 1
	end
	return id, count
end

---------------------------------------------------------------------------
-- Writing into both books
---------------------------------------------------------------------------
local function books() return T.session.book, T.db.stats end
local function log(e)
	e.t = GetTime()
	local ev = T.session.events
	ev[#ev + 1] = e
	if #ev > 2000 then T.session.events = Ledger.Prune(ev, e.t) end
end

local function creditItem(id, qty, tab, name)
	for _, b in ipairs({ books() }) do Ledger.AddItem(b, id, qty) end
	if tab then for _, b in ipairs({ books() }) do Ledger.AddGatherItem(b, tab, loot.key, id, qty) end end
	if name then T.db.itemNames[id] = name end
	log({ what = "item", id = id, qty = qty, tab = tab })
end

---------------------------------------------------------------------------
-- Loot windows
---------------------------------------------------------------------------
-- Readable item slots, the source GUID, the slot count, and how many item-like slots couldn't be read.
local function lootSlots()
	local slots, guid, n, unread = {}, nil, GetNumLootItems(), 0
	for slot = 1, n do
		local link = safe(GetLootSlotLink, slot)
		local ok, _, name, qty = pcall(GetLootSlotInfo, slot)
		local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
		if id and ok and not hidden(name, qty) then
			slots[slot] = { id = id, qty = tonumber(qty) or 1, name = type(name) == "string" and name or nil }
			guid = guid or safe(GetLootSourceInfo, slot)
		elseif not (type(link) == "string" and not id) then -- a coin slot has a link without an item ID: not an item
			unread = unread + 1
		end
	end
	return slots, guid, n, unread
end

local function expect(kind, key, slots)
	local want, names = {}, {}
	for _, it in pairs(slots) do
		want[it.id] = (want[it.id] or 0) + it.qty
		names[it.id] = it.name
	end
	loot = { kind = kind, key = key, want = want, names = names }
end

local startGather -- below

-- final: LOOT_OPENED (the last chance for this window); LOOT_READY may come before the slots are readable.
-- LOOT_READY and LOOT_CLOSED each come twice per window in this client.
local function readLoot(final)
	if loot and not loot.closedAt then return end -- the same window
	loot = nil
	local slots, guid, n, unread = lootSlots()

	if not pending then
		-- the window of a node / corpse gathered earlier: what was left on it (bags were full) counts now
		local g = guid and gathered[guid]
		if g then
			if next(slots) then expect(g.kind, g.key, slots) end
			return
		end
		-- a node gathered with a cast not recognised above
		local kind = Ledger.EntryID(guid) == "GameObject" and nodeKind(slots)
		if not kind then return end
		local target = lastSent and GetTime() - lastSent.at <= CAST_WINDOW and lastSent.target or nil
		startGather(kind, guid, slots, unread, target)
		return
	end
	local now = GetTime()
	if (pending.doneAt and now - pending.doneAt > AFTER_CAST) or (not pending.doneAt and now - pending.at > CAST_WINDOW) then
		pending = nil
		return
	end
	if not next(slots) then
		if final and n > 0 then
			pending = nil
			say("|cffff4040окно добычи открылось, но клиент не дал прочитать предметы - этот сбор не записан|r")
		end
		return
	end
	local cast = pending
	pending = nil
	startGather(cast.kind, guid, slots, unread, cast.target)
end

-- A gathering window: the node / mob counted once in its tab, the window's items expected.
startGather = function(kind, guid, slots, unread, target)
	if unread > 0 then
		warn("slots", string.format("%d предм. в окне добычи клиент не дал прочитать - они попадут только в 'Итого', не на карточку", unread))
	end
	local name = target
	if type(name) ~= "string" or name == "" then name = nil end
	if not name and guid and safe(UnitGUID, "target") == guid then
		local n2 = safe(UnitName, "target")
		if type(n2) == "string" and n2 ~= "" then name = n2 end
	end
	local _, entry = Ledger.EntryID(guid)
	local key = entry or name
	if not key then
		say("|cffff4040не удалось узнать, с чего добыча (нет GUID и имени) - записано как '?'|r")
		key = "?"
	end
	for _, b in ipairs({ books() }) do Ledger.AddGather(b, kind, key, name) end
	if guid then gathered[guid] = { kind = kind, key = key } end
	expect(kind, key, slots)
	changed()
end

local function onLootLine(msg)
	local id, qty = readLine(msg, LOOT_START, LOOT_COUNT)
	if not id then return false end
	local tab, name
	if loot and loot.closedAt and GetTime() - loot.closedAt > LOOT_GRACE then loot = nil end
	local left = loot and loot.want[id]
	if left and left > 0 then
		-- this window's item: its gathering tab gets what the window held, Total gets everything received
		local take = math.min(qty, left)
		loot.want[id] = left - take
		tab, name = loot.kind, loot.names[id]
		if take < qty then
			creditItem(id, take, tab, name)
			creditItem(id, qty - take, nil, nil)
			return true
		end
	end
	creditItem(id, qty, tab, name)
	return true
end

---------------------------------------------------------------------------
-- Quests: gold from QUEST_TURNED_IN's money; reward items = "you received" lines within QUEST_WINDOW of it.
---------------------------------------------------------------------------
local function creditPushes(now)
	local keep = {}
	for _, p in ipairs(pushes) do
		if lastTurnIn and math.abs(p.t - lastTurnIn) <= QUEST_WINDOW then
			for _, b in ipairs({ books() }) do Ledger.AddItem(b, p.id, p.qty) end
			log({ what = "item", id = p.id, qty = p.qty })
		elseif now - p.t <= QUEST_WINDOW then
			keep[#keep + 1] = p
		end
	end
	pushes = keep
end

local function onPushLine(msg)
	local id, qty = readLine(msg, PUSH_START, PUSH_COUNT)
	if not id then return end
	local now = GetTime()
	pushes[#pushes + 1] = { t = now, id = id, qty = qty }
	creditPushes(now)
	changed()
end

local function onTurnIn(money)
	local now = GetTime()
	lastTurnIn = now
	-- the PLAYER_MONEY of the reward came just before: it's quest gold, not coins
	local keep = {}
	for _, g in ipairs(coinGains) do if now - g.t > 0.5 then keep[#keep + 1] = g end end
	coinGains = keep
	if type(money) == "number" and money > 0 then
		for _, b in ipairs({ books() }) do Ledger.AddQuest(b, money) end
		log({ what = "quest", c = money })
	end
	creditPushes(now)
	changed()
end

---------------------------------------------------------------------------
-- Coins: money gained (PLAYER_MONEY) is coins from loot once the coin line (CHAT_MSG_MONEY) confirms it.
---------------------------------------------------------------------------
local function onMoney()
	local m = GetMoney()
	local delta = lastMoney and (m - lastMoney) or 0
	lastMoney = m
	if delta <= 0 then return end
	if isOpen.merchant or isOpen.auction then return end
	coinGains[#coinGains + 1] = { t = GetTime(), c = delta }
end

local function onCoinLine()
	local now, sum = GetTime(), 0
	for _, g in ipairs(coinGains) do if now - g.t <= COIN_WINDOW then sum = sum + g.c end end
	coinGains = {}
	if sum <= 0 then return end
	for _, b in ipairs({ books() }) do Ledger.AddCoins(b, sum) end
	log({ what = "coins", c = sum })
	changed()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED",
	"UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_LOOT",
	"CHAT_MSG_MONEY", "PLAYER_MONEY", "QUEST_TURNED_IN", "MERCHANT_SHOW", "MERCHANT_CLOSED", "AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED", "GET_ITEM_INFO_RECEIVED" }) do
	pcall(frame.RegisterEvent, frame, e) -- an event this client doesn't have is skipped
end
local OPENS = { MERCHANT_SHOW = "merchant", AUCTION_HOUSE_SHOW = "auction" }
local CLOSES = { MERCHANT_CLOSED = "merchant", AUCTION_HOUSE_CLOSED = "auction" }

frame:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
	if event == "ADDON_LOADED" then
		if a1 ~= addonName then return end
		-- SkinLedgerDB (the TOC's saved variable) holds Farm Ledger's data; SkinLedger's old skins move in once
		SkinLedgerDB = Ledger.Init(SkinLedgerDB, ns.LEGACY_SKINS)
		T.db = SkinLedgerDB
		T.NewSession()
		if not (LOOT_START and LOOT_COUNT) then
			say("|cffff4040в клиенте нет строк LOOT_ITEM_SELF / LOOT_ITEM_SELF_MULTIPLE - предметы не будут считаться|r")
		end
		if ns.OnLoaded then ns.OnLoaded() end
	elseif not T.db then
		return
	elseif event == "PLAYER_ENTERING_WORLD" then
		lastMoney = GetMoney()
	elseif event == "UNIT_SPELLCAST_SENT" then
		-- unit, target name, castGUID, spellID
		if hidden(a1) or a1 ~= "player" then return end
		lastSent = { target = not hidden(a2) and a2 or nil, at = GetTime() }
		if hidden(a4) then return end
		local kind = T.GatherKind(a4)
		if not kind then return end
		pending = { kind = kind, target = not hidden(a2) and a2 or nil, castGUID = not hidden(a3) and a3 or nil, at = GetTime() }
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- unit, castGUID, spellID
		if hidden(a1) or a1 ~= "player" or not pending or pending.doneAt then return end
		if pending.castGUID and not hidden(a2) and a2 then
			if a2 ~= pending.castGUID then return end
		elseif hidden(a3) or T.GatherKind(a3) ~= pending.kind then
			return
		end
		pending.doneAt = GetTime()
	elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
		-- unit, castGUID, spellID: the same cast by its GUID when both are known, else by the spell
		if hidden(a1) or a1 ~= "player" or not pending then return end
		if pending.castGUID and not hidden(a2) and a2 then
			if a2 == pending.castGUID then pending = nil end
		elseif not hidden(a3) and T.GatherKind(a3) == pending.kind then
			pending = nil
		end
	elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
		readLoot(event == "LOOT_OPENED")
	elseif event == "LOOT_CLOSED" then
		if loot and not loot.closedAt then loot.closedAt = GetTime() end
	elseif event == "CHAT_MSG_LOOT" then
		if hidden(a1) then
			warn("lootline", "клиент скрыл строку добычи - этот предмет не записан")
			return
		end
		if type(a1) ~= "string" then return end
		if onLootLine(a1) then changed() else onPushLine(a1) end
	elseif event == "CHAT_MSG_MONEY" then
		onCoinLine()
	elseif event == "PLAYER_MONEY" then
		onMoney()
	elseif event == "QUEST_TURNED_IN" then
		-- questID, xpReward, moneyReward
		if hidden(a3) then warn("questmoney", "клиент скрыл награду за задание - это золото не записано") end
		onTurnIn(not hidden(a3) and a3 or nil)
	elseif OPENS[event] then
		isOpen[OPENS[event]] = true
	elseif CLOSES[event] then
		isOpen[CLOSES[event]] = false
		lastMoney = GetMoney()
		if event == "AUCTION_HOUSE_CLOSED" then changed() end -- Auctionator may have new prices from this visit
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if ns.ItemInfoArrived then ns.ItemInfoArrived() end
	end
end)

---------------------------------------------------------------------------
-- SkinLedger's statistics (SavedVariables/SkinLedger.lua, 2026-11-19 04:20: 128 skins on 13 mobs), moved into Statistics > Skins
-- once by Ledger.Init. Kept in the code because a /reload in the client that was running when the addon was renamed
-- writes over FarmLedger's saved file before reading it.
---------------------------------------------------------------------------
ns.LEGACY_SKINS = {
["sort"] = "avg",
["version"] = 1,
["mobs"] = {
[269275] = {
["skins"] = 1,
["name"] = "Курома",
["items"] = {
[8170] = 1,
},
},
[7457] = {
["skins"] = 14,
["name"] = "Ледополох-разбойник",
["items"] = {
[8170] = 8,
[4304] = 4,
[8169] = 1,
[8171] = 1,
},
},
[7458] = {
["skins"] = 16,
["name"] = "Йети с Холмов ледополоха",
["items"] = {
[8170] = 4,
[4304] = 10,
[249428] = 3,
[8169] = 1,
},
},
[7444] = {
["skins"] = 13,
["name"] = "Медведь-щербозуб",
["items"] = {
[8170] = 6,
[4304] = 4,
[8169] = 1,
[8171] = 2,
},
},
[7460] = {
["skins"] = 11,
["name"] = "Патриарх ледополохов",
["items"] = {
[8170] = 9,
[8171] = 1,
[4304] = 1,
},
},
[7447] = {
["skins"] = 16,
["name"] = "Стылодых-слеток",
["items"] = {
[15423] = 3,
[4304] = 6,
[249429] = 3,
[8170] = 6,
},
},
[7448] = {
["skins"] = 2,
["name"] = "Хладноветрая химера",
["items"] = {
[8170] = 1,
[15423] = 1,
},
},
[7449] = {
["skins"] = 17,
["name"] = "Хладновей-опустошитель",
["items"] = {
[15423] = 10,
[249429] = 2,
[8170] = 6,
},
},
[7445] = {
["skins"] = 12,
["name"] = "Старый щербозуб",
["items"] = {
[8170] = 8,
[4304] = 1,
[15419] = 2,
[8171] = 1,
},
},
[7459] = {
["skins"] = 12,
["name"] = "Матриарх ледополохов",
["items"] = {
[8170] = 12,
},
},
[13136] = {
["skins"] = 11,
["name"] = "Трутень из улья Аши",
["items"] = {
[20498] = 5,
[20499] = 10,
[20500] = 1,
},
},
[269276] = {
["skins"] = 1,
["name"] = "Камуро",
["items"] = {
[8170] = 1,
},
},
[7443] = {
["skins"] = 2,
["name"] = "Могучий щербозуб",
["items"] = {
[8170] = 2,
},
},
},
["itemNames"] = {
[249429] = "Нетронутая чешуя",
[20498] = "Хитин силитида",
[15419] = "Кожа боевого медведя",
[8169] = "Плотная шкура",
[8170] = "Грубая кожа",
[8171] = "Прочная шкура",
[20500] = "Легкий силитидский панцирь",
[249428] = "Нетронутая шкура",
[4304] = "Плотная кожа",
[15423] = "Кожа химеры",
[20499] = "Сломанный хитиновый силитидский панцирь",
},
}

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
-- The window (canvas design "Skin Ledger - окно", grown into Farm Ledger): header with minimize and close, tabs with
-- icons (Total, Mining, Herbalism, Skins), the Session / Statistics switch, a price line, cards, a footer with totals,
-- gold per hour (Session), Reset, the sort dropdown and Refresh; the mini window with the session's numbers.

local WHITE = "Interface\\Buttons\\WHITE8x8"
local C = {
	ground = "17140f", panel = "1f1a12", border = "5a4a2c", line = "3a3021", lineSoft = "2b241a",
	muted = "b8ad95", text = "e8e2d4", resetBg = "3a1712", resetBorder = "7a2a1f", resetText = "ffd8d0",
	refreshBg = "5a1a12", refreshBorder = "b8862a", gold = "ffd100", income = "9dff8a", bad = "ff8a7a", src = "8f8a80",
}
-- tab icons: coins, ore, herb, pelt (icon files other addons in this client also use: ForeverGuide, GearQuestForever)
local TAB_ICONS = {
	total = "Interface\\Icons\\INV_Misc_Coin_02", mining = "Interface\\Icons\\INV_Ore_Copper_01",
	herbs = "Interface\\Icons\\Trade_Herbalism", skins = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
}
local QUEST_ICON = "Interface\\Icons\\INV_Misc_Note_01"

local function rgb(hex)
	return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end
local function boxed(frame, bg, border, edge)
	frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = edge or 1 })
	frame:SetBackdropColor(rgb(bg))
	frame:SetBackdropBorderColor(rgb(border))
end
local function hline(parent, color)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetColorTexture(rgb(color))
	t:SetHeight(1)
	return t
end
local function text(parent, template, color)
	local fs = parent:CreateFontString(nil, "OVERLAY", template)
	if color then fs:SetTextColor(rgb(color)) end
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end
local function width(fs)
	return math.ceil(fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth())
end
local function button(parent, label, bg, border, color, w, h)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(w, h or 24)
	boxed(b, bg, border)
	b.label = text(b, "GameFontHighlightSmall", color)
	b.label:SetPoint("CENTER")
	b.label:SetText(label)
	b.border = border
	b:SetScript("OnEnter", function() b:SetBackdropBorderColor(rgb(C.gold)) end)
	b:SetScript("OnLeave", function() b:SetBackdropBorderColor(rgb(b.border)) end)
	return b
end

---------------------------------------------------------------------------
-- Item facts from the game: name, icon, quality colour, vendor price, soulbound
---------------------------------------------------------------------------
-- name, vendor sell price, bind type (1 = soulbound on pickup); nil while the game hasn't loaded the item - then it is
-- asked for, and GET_ITEM_INFO_RECEIVED redraws the window
local function info(id)
	local fetch = C_Item and C_Item.GetItemInfo
	if not fetch then fetch = GetItemInfo end
	local name, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = fetch(id)
	if name == nil and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
	return name, sellPrice, bindType
end
local function itemName(id)
	local name = info(id)
	return name or T.db.itemNames[id] or ("item:" .. id)
end
local function vendorOf(id) return select(2, info(id)) end
local function boundOf(id) return select(3, info(id)) == 1 end
local function itemIcon(id)
	local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	return icon or (GetItemIcon and GetItemIcon(id)) or "Interface\\Icons\\INV_Misc_QuestionMark"
end
local function itemColor(id)
	local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
	if q and GetItemQualityColor then
		local r, g, b = GetItemQualityColor(q)
		if r then return r, g, b end
	end
	return 1, 1, 1
end

-- auction prices: Auctionator's public API
local function priceSource()
	local api = type(Auctionator) == "table" and type(Auctionator.API) == "table" and Auctionator.API.v1 or nil
	return Ledger.AuctionatorPrices(api)
end

-- the book of the shown mode, and the valuer for the current prices
local function shown()
	local prices, err = priceSource()
	local book = T.db.mode == "session" and T.session.book or T.db.stats
	return book, Ledger.Valuer(prices, vendorOf, boundOf), prices, err
end

local function sessionClock()
	local s = math.floor(GetTime() - T.session.startedAt)
	return string.format("%d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60)
end

local function rateText(tab, value)
	local r = Ledger.Rate(T.session.events, GetTime(), T.session.startedAt, value, tab)
	if not r then return "в час: считаю (меньше минуты)" end
	local span = GetTime() - T.session.startedAt
	return string.format("в час: |cff%s%s|r%s", C.income, Ledger.MoneyColored(r),
		span < 3600 and string.format(" |cff%s(по %d мин)|r", C.src, math.floor(span / 60)) or "")
end

---------------------------------------------------------------------------
-- Cards: a title, a count, item rows (icon, name, qty, price source, sum) and a footer line
---------------------------------------------------------------------------
local PAD, ROW, GAP = 8, 18, 6
local cards = {}
local window, mini

local function card(i, parent)
	local c = cards[i]
	if c then return c end
	c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	boxed(c, C.panel, C.line)
	c.title = text(c, "GameFontNormal")
	c.title:SetPoint("TOPLEFT", PAD, -6)
	c.count = text(c, "GameFontHighlightSmall", C.muted)
	c.count:SetPoint("BOTTOMLEFT", c.title, "BOTTOMRIGHT", 8, 0)
	c.divider = hline(c, C.line)
	c.foot = text(c, "GameFontHighlightSmall", C.muted)
	c.rows = {}
	cards[i] = c
	return c
end

local function row(c, j)
	local r = c.rows[j]
	if r then return r end
	r = {}
	r.icon = c:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(16, 16)
	r.name = text(c, "GameFontHighlight")
	r.qty = text(c, "GameFontHighlight", C.text)
	r.qty:SetJustifyH("RIGHT")
	r.src = text(c, "GameFontHighlightSmall", C.src)
	r.sum = text(c, "GameFontHighlight", C.text)
	r.sum:SetJustifyH("RIGHT")
	-- the item's own tooltip on hover, as in the bags (GameTooltip:SetItemByID, as Baganator/CatQuest use here)
	r.hit = CreateFrame("Button", nil, c)
	r.hit:SetScript("OnEnter", function(self)
		if not self.itemID then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(self.itemID)
		GameTooltip:Show()
	end)
	r.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
	c.rows[j] = r
	return r
end

local function itemRow(it)
	local unitSrc = it.unit and (it.src == "vendor" and "торг." or "АХ") or ""
	local sum
	if it.unit then
		local old = ""
		if it.src == "auction" then
			if it.age == nil then old = " |cff999999(цене больше 3 недель)|r"
			elseif it.age > 0 then old = string.format(" |cff999999(%d дн.)|r", it.age) end
		end
		sum = Ledger.MoneyColored(it.sum) .. old
	else
		sum = "|cff" .. C.bad .. "нет цены|r"
	end
	local r, g, b = itemColor(it.id)
	return { id = it.id, icon = itemIcon(it.id), name = it.name, r = r, g = g, b = b, qty = it.qty .. " шт", src = unitSrc, sum = sum }
end

-- spec = { title, count, rows = { { id?, icon, name, r, g, b, qty, src, sum } }, foot }
local function fillCard(c, spec, w)
	c:SetWidth(w)
	c.title:SetText(spec.title)
	c.count:SetText(spec.count or "")
	local nameW, qtyW, srcW, sumW = 0, 0, 0, 0
	for j, it in ipairs(spec.rows) do
		local r = row(c, j)
		r.icon:SetTexture(it.icon)
		r.name:SetText(it.name)
		r.name:SetTextColor(it.r or 1, it.g or 1, it.b or 1)
		r.qty:SetText(it.qty or "")
		r.src:SetText(it.src or "")
		r.sum:SetText(it.sum)
		nameW, qtyW = math.max(nameW, width(r.name)), math.max(qtyW, width(r.qty))
		srcW, sumW = math.max(srcW, width(r.src)), math.max(sumW, width(r.sum))
	end
	-- columns as wide as their longest text, side by side (no stretched gaps)
	local top = -6 - 16 - 4
	local xQty = PAD + 24 + nameW + 10
	local xSrc = xQty + qtyW + (qtyW > 0 and 8 or 0)
	local xSum = xSrc + srcW + (srcW > 0 and 8 or 0)
	for j, r in ipairs(c.rows) do
		local on = j <= #spec.rows
		for _, part in ipairs({ r.icon, r.name, r.qty, r.src, r.sum, r.hit }) do part:SetShown(on) end
		if on then
			local y = top - (j - 1) * ROW
			r.icon:SetPoint("TOPLEFT", PAD, y)
			r.name:SetPoint("TOPLEFT", PAD + 24, y - 2)
			r.qty:SetWidth(qtyW)
			r.qty:SetPoint("TOPLEFT", xQty, y - 2)
			r.src:SetPoint("TOPLEFT", xSrc, y - 3)
			r.sum:SetWidth(sumW)
			r.sum:SetPoint("TOPLEFT", xSum, y - 2)
			r.hit.itemID = spec.rows[j].id
			r.hit:SetPoint("TOPLEFT", PAD, y + 1)
			r.hit:SetSize(xSum + sumW - PAD, ROW)
		end
	end
	local y = top - math.max(#spec.rows, 1) * ROW - 2
	c.divider:SetShown(spec.foot ~= nil)
	c.foot:SetShown(spec.foot ~= nil)
	if spec.foot then
		c.divider:SetPoint("TOPLEFT", PAD, y)
		c.divider:SetPoint("TOPRIGHT", -PAD, y)
		c.foot:SetPoint("TOPLEFT", PAD, y - 5)
		c.foot:SetText(spec.foot)
		c:SetHeight(-(y - 5) + 14 + 6)
	else
		c:SetHeight(-y + 4)
	end
	c:Show()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function cardSpecs(tab, book, value)
	local specs, footer, unpriced = {}, nil, 0
	if tab == "total" then
		local r = Ledger.BuildTotal(book.total, value, itemName)
		local rows = {}
		for _, it in ipairs(r.items) do rows[#rows + 1] = itemRow(it) end
		specs[1] = { title = "Предметы", count = #rows > 0 and string.format("|cff%s%d|r %s", C.text, #rows,
			Ledger.Plural(#rows, "вид", "вида", "видов")) or "пока нет", rows = rows,
			foot = string.format("на сумму |cff%s%s|r", C.income, Ledger.MoneyColored(r.itemsTotal)) }
		specs[2] = { title = "Деньги", rows = {
			{ icon = TAB_ICONS.total, name = "Монеты с мобов", sum = Ledger.MoneyColored(r.coins) },
			{ icon = QUEST_ICON, name = "Золото с заданий", sum = Ledger.MoneyColored(r.quest) },
		} }
		footer = string.format("Доход: |cff%s%s|r", C.income, Ledger.MoneyColored(r.total))
		unpriced = r.unpriced
	else
		local r = Ledger.BuildGather(book[tab], value, itemName, T.db.sort)
		for _, b in ipairs(r.blocks) do
			local rows = {}
			for _, it in ipairs(b.items) do rows[#rows + 1] = itemRow(it) end
			local tail = b.unpriced > 0 and string.format("  |cff%s(+%d без цены)|r", C.bad, b.unpriced) or ""
			specs[#specs + 1] = { title = b.name,
				count = string.format("|cff%s%d|r %s", C.text, b.count, Ledger.Plural(b.count, "раз", "раза", "раз")),
				rows = rows,
				foot = string.format("доход |cff%s%s|r    в среднем %s |cff%s%s|r%s", C.income, Ledger.MoneyColored(b.total),
					Ledger.Per(tab), C.text, Ledger.MoneyColored(b.avg), tail) }
		end
		footer = string.format("Всего %d %s, доход |cff%s%s|r, в среднем %s |cff%s%s|r", r.count,
			Ledger.Plural(r.count, "раз", "раза", "раз"), C.text, Ledger.MoneyColored(r.total), Ledger.Per(tab), C.text,
			Ledger.MoneyColored(r.avg))
		unpriced = r.unpriced
	end
	return specs, footer, unpriced
end

local function updateRate()
	if not window or not window:IsShown() then return end
	local _, value = shown()
	if T.db.mode == "session" then
		window.rate:SetText(string.format("Сессия %s, %s", sessionClock(), rateText(T.db.tab, value)))
	else
		window.rate:SetText("Статистика за всё время")
	end
end

local function updateMini()
	if not mini or not mini:IsShown() then return end
	local _, value = shown()
	local r = Ledger.BuildTotal(T.session.book.total, value, itemName)
	mini.line1:SetText("Farm Ledger - сессия " .. sessionClock())
	mini.line2:SetText(string.format("доход |cff%s%s|r", C.income, Ledger.MoneyColored(r.total)))
	mini.line3:SetText(rateText("total", value))
end

function ns.Refresh()
	updateMini()
	if not window or not window:IsShown() then return end
	local tab = T.db.tab
	local book, value, prices, err = shown()
	if prices then
		-- Auctionator loaded but none of these items in its data yet: it hasn't scanned the auction house
		local any, priced = false, false
		for id in pairs(book.total.items) do
			any = true
			if prices.price(id) then priced = true break end
		end
		if any and not priced then
			window.info:SetText("|cffff4040в Auctionator ещё нет цен|r |cff" .. C.muted
				.. "- отсканируй аукцион в Auctionator; пока считаю по цене торговца|r")
		else
			window.info:SetText("Цены АХ: |cff" .. C.text .. "Auctionator|r    АХ после 5%, иначе цена торговца")
		end
	else
		window.info:SetText("|cffff4040" .. err .. "|r |cff" .. C.muted .. "- считаю по цене торговца|r")
	end
	for key, b in pairs(window.tabs) do
		local on = key == tab
		b.border = on and C.gold or C.line
		b:SetBackdropBorderColor(rgb(b.border))
		b.label:SetTextColor(rgb(on and C.gold or C.muted))
	end
	for key, b in pairs(window.modes) do
		local on = key == T.db.mode
		b.border = on and C.gold or C.line
		b:SetBackdropBorderColor(rgb(b.border))
		b.label:SetTextColor(rgb(on and C.gold or C.muted))
	end

	local specs, footer, unpriced = cardSpecs(tab, book, value)
	local child, w = window.child, window.child:GetWidth()
	local y = 0
	for i, spec in ipairs(specs) do
		local c = card(i, child)
		fillCard(c, spec, w)
		c:ClearAllPoints()
		c:SetPoint("TOPLEFT", 0, -y)
		y = y + c:GetHeight() + GAP
	end
	for i = #specs + 1, #cards do cards[i]:Hide() end
	window.empty:SetShown(#specs == 0)
	window.note:SetShown(unpriced > 0)
	if unpriced > 0 then
		window.note:ClearAllPoints()
		window.note:SetPoint("TOPLEFT", PAD, -y - 2)
		y = y + 18
	end
	child:SetHeight(math.max(y, 1))
	window.total:SetText(footer)
	window.sortBox:SetShown(tab ~= "total")
	if window.sortText then window.sortText() end
	updateRate()
end
local refresh = ns.Refresh

local pendingRefresh = false
function ns.ItemInfoArrived()
	if pendingRefresh then return end
	pendingRefresh = true
	C_Timer.After(0.3, function()
		pendingRefresh = false
		refresh()
	end)
end

---------------------------------------------------------------------------
-- Reset / wipe confirmations
---------------------------------------------------------------------------
StaticPopupDialogs.FARMLEDGER_RESET = {
	text = "",
	button1 = YES or "Да",
	button2 = NO or "Нет",
	OnAccept = function(self)
		local mode = StaticPopupDialogs.FARMLEDGER_RESET.askedMode or T.db.mode
		if mode == "session" then
			T.NewSession()
			say("новая сессия")
		else
			Ledger.ResetTotal(T.db.stats)
			say("вкладка 'Итого' в статистике очищена; руда, травы и шкуры остались")
		end
		refresh()
	end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}
StaticPopupDialogs.FARMLEDGER_WIPE = {
	text = "Farm Ledger: стереть ВСЮ статистику (итого, руда, травы, шкуры)? Это не отменить.",
	button1 = YES or "Да",
	button2 = NO or "Нет",
	OnAccept = function()
		T.db.stats = Ledger.NewBook()
		say("вся статистика стёрта")
		refresh()
	end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}
local function askReset()
	StaticPopupDialogs.FARMLEDGER_RESET.askedMode = T.db.mode
	StaticPopupDialogs.FARMLEDGER_RESET.text = T.db.mode == "session"
		and "Farm Ledger: начать новую сессию? Текущая сессия обнулится."
		or "Farm Ledger: очистить вкладку 'Итого' в статистике? Руда, травы и шкуры останутся."
	StaticPopup_Show("FARMLEDGER_RESET")
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------
local function buildWindow()
	local W = 520
	local H = math.min(720, math.floor(UIParent:GetHeight() - 60))
	local f = CreateFrame("Frame", "FarmLedgerFrame", UIParent, "BackdropTemplate")
	f:SetSize(W, H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	boxed(f, C.ground, C.border, 2)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:Hide()
	tinsert(UISpecialFrames, "FarmLedgerFrame") -- Esc closes it

	-- header: icon, title, minimize, close
	local head = CreateFrame("Frame", nil, f, "BackdropTemplate")
	head:SetPoint("TOPLEFT", 2, -2)
	head:SetPoint("TOPRIGHT", -2, -2)
	head:SetHeight(28)
	head:SetBackdrop({ bgFile = WHITE })
	head:SetBackdropColor(rgb(C.panel))
	local headLine = hline(f, C.line)
	headLine:SetPoint("TOPLEFT", head, "BOTTOMLEFT")
	headLine:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT")
	local icon = head:CreateTexture(nil, "ARTWORK")
	icon:SetSize(16, 16)
	icon:SetPoint("LEFT", 10, 0)
	icon:SetTexture(TAB_ICONS.total)
	local title = text(head, "GameFontNormal")
	title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	title:SetText("Farm Ledger")
	local close = button(head, "X", C.resetBg, C.resetBorder, C.resetText, 20, 20)
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function()
		T.db.minimized = false
		f:Hide()
	end)
	local minimize = button(head, "_", C.panel, C.border, C.gold, 20, 20)
	minimize:SetPoint("RIGHT", close, "LEFT", -4, 0)
	minimize:SetScript("OnClick", function() ns.Minimize() end)

	-- tabs (left) and the Session / Statistics switch (right)
	f.tabs = {}
	local prev
	for _, key in ipairs(Ledger.TABS) do
		local b = button(f, "", C.panel, C.line, C.muted, 10, 24)
		b.label:ClearAllPoints()
		local ic = b:CreateTexture(nil, "ARTWORK")
		ic:SetSize(16, 16)
		ic:SetPoint("LEFT", 6, 0)
		ic:SetTexture(TAB_ICONS[key])
		b.label:SetPoint("LEFT", ic, "RIGHT", 4, 0)
		b.label:SetText(Ledger.TAB_LABELS[key])
		b:SetWidth(6 + 16 + 4 + width(b.label) + 8)
		if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 8, -6) end
		b:SetScript("OnClick", function()
			T.db.tab = key
			refresh()
		end)
		f.tabs[key] = b
		prev = b
	end
	f.modes = {}
	local statsBtn = button(f, "Статистика", C.panel, C.line, C.muted, 78, 20)
	statsBtn:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", -8, -8)
	local sessBtn = button(f, "Сессия", C.panel, C.line, C.muted, 58, 20)
	sessBtn:SetPoint("RIGHT", statsBtn, "LEFT", -2, 0)
	f.modes.session, f.modes.stats = sessBtn, statsBtn
	for key, b in pairs(f.modes) do
		b:SetScript("OnClick", function()
			T.db.mode = key
			refresh()
		end)
	end

	-- price line
	f.info = text(f, "GameFontHighlightSmall", C.muted)
	f.info:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 10, -38)
	f.info:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", -10, -38)
	local infoLine = hline(f, C.lineSoft)
	infoLine:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -54)
	infoLine:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", 0, -54)

	-- footer: totals, gold per hour, Reset, sort, Refresh
	local foot = CreateFrame("Frame", nil, f, "BackdropTemplate")
	foot:SetPoint("BOTTOMLEFT", 2, 2)
	foot:SetPoint("BOTTOMRIGHT", -2, 2)
	foot:SetHeight(74)
	foot:SetBackdrop({ bgFile = WHITE })
	foot:SetBackdropColor(rgb(C.panel))
	local footLine = hline(f, C.line)
	footLine:SetPoint("BOTTOMLEFT", foot, "TOPLEFT")
	footLine:SetPoint("BOTTOMRIGHT", foot, "TOPRIGHT")
	f.total = text(foot, "GameFontHighlightSmall", C.muted)
	f.total:SetPoint("TOPLEFT", 10, -7)
	f.total:SetPoint("TOPRIGHT", -10, -7)
	f.rate = text(foot, "GameFontHighlightSmall", C.muted)
	f.rate:SetPoint("TOPLEFT", 10, -22)
	f.rate:SetPoint("TOPRIGHT", -10, -22)

	local reset = button(foot, "Сброс", C.resetBg, C.resetBorder, C.resetText, 80)
	reset:SetPoint("BOTTOMLEFT", 8, 7)
	reset:SetScript("OnClick", askReset)
	local upd = button(foot, "Обновить", C.refreshBg, C.refreshBorder, C.gold, 90)
	upd:SetPoint("BOTTOMRIGHT", -8, 7)
	upd:SetScript("OnClick", refresh)

	-- sort (gather tabs): a dropdown (MenuUtil in this client, as Baganator/BetterNamePlates use; UIDropDownMenu otherwise)
	local box = CreateFrame("Frame", nil, foot)
	box:SetSize(240, 28)
	box:SetPoint("BOTTOM", 10, 5)
	f.sortBox = box
	local function setSort(key)
		T.db.sort = key
		refresh()
	end
	local sortLabel = text(box, "GameFontHighlightSmall", C.muted)
	sortLabel:SetText("Сортировка")
	sortLabel:SetPoint("LEFT", 0, 0)
	if MenuUtil then
		local dd = CreateFrame("DropdownButton", nil, box, "WowStyle1DropdownTemplate")
		dd:SetSize(170, 24)
		dd:SetPoint("RIGHT", 0, 0)
		dd:SetupMenu(function(_, root)
			for _, key in ipairs(Ledger.SORTS) do
				root:CreateRadio(Ledger.SortLabel(T.db.tab ~= "total" and T.db.tab or "skins", key),
					function(k) return T.db.sort == k end, setSort, key)
			end
		end)
		-- the shown label follows the tab and a sort changed elsewhere; never while the menu is open - rebuilding it
		-- then would swap the menu being clicked (Questie QuestieOptionsControls.lua, Baganator Components.lua)
		f.sortText = function()
			if not (dd.IsMenuOpen and dd:IsMenuOpen()) then dd:GenerateMenu() end
		end
	else
		local dd = CreateFrame("Frame", "FarmLedgerSort", box, "UIDropDownMenuTemplate")
		dd:SetPoint("RIGHT", 16, -2)
		UIDropDownMenu_SetWidth(dd, 140)
		UIDropDownMenu_Initialize(dd, function(_, level)
			for _, key in ipairs(Ledger.SORTS) do
				local item = UIDropDownMenu_CreateInfo()
				item.text = Ledger.SortLabel(T.db.tab ~= "total" and T.db.tab or "skins", key)
				item.checked = T.db.sort == key
				item.func = function() setSort(key) end
				UIDropDownMenu_AddButton(item, level)
			end
		end)
		f.sortText = function()
			UIDropDownMenu_SetText(dd, Ledger.SortLabel(T.db.tab ~= "total" and T.db.tab or "skins", T.db.sort))
		end
	end

	-- the cards, scrolling between the price line and the footer
	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 8, -60)
	scroll:SetPoint("BOTTOMRIGHT", foot, "TOPRIGHT", -28, 6)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(W - 4 - 8 - 28, 1)
	scroll:SetScrollChild(child)
	f.child = child
	-- smooth wheel scrolling (as Details' scrollbox does here): the wheel moves a target, each frame eases toward it
	local STEP, EASE = 48, 14
	local target -- where the wheel asked to go; nil when not gliding
	local function glide(self, elapsed)
		local cur = self:GetVerticalScroll()
		local nextPos = cur + (target - cur) * math.min(1, elapsed * EASE)
		if math.abs(target - nextPos) < 0.5 then
			nextPos = target
			target = nil
			self:SetScript("OnUpdate", nil)
		end
		self:SetVerticalScroll(nextPos)
	end
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local origin = target or self:GetVerticalScroll()
		target = math.max(0, math.min(origin - delta * STEP, self:GetVerticalScrollRange()))
		self:SetScript("OnUpdate", glide)
	end)
	f.scrollTarget = function() return target end
	f.empty = text(child, "GameFontHighlight", C.muted)
	f.empty:SetPoint("TOPLEFT", PAD, -4)
	f.empty:SetText("Пока пусто.")
	f.note = text(child, "GameFontHighlightSmall", C.muted)
	f.note:SetText("Предмет без цены: |cff" .. C.bad .. "не входит в доход|r")

	f:SetScript("OnShow", refresh)
	return f
end

-- the mini window: the session's income and gold per hour; a click opens the full window
local function buildMini()
	local m = CreateFrame("Button", "FarmLedgerMini", UIParent, "BackdropTemplate")
	m:SetSize(210, 52)
	m:SetPoint("TOP", 0, -120)
	m:SetFrameStrata("MEDIUM")
	boxed(m, C.ground, C.border, 2)
	m:SetMovable(true)
	m:SetClampedToScreen(true)
	m:RegisterForDrag("LeftButton")
	m:SetScript("OnDragStart", function(self) self.dragged = true; self:StartMoving() end)
	m:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		-- a click that ends this drag (if the client sends one) is ignored; the next real click opens the window
		C_Timer.After(0, function() self.dragged = false end)
	end)
	m.line1 = text(m, "GameFontNormalSmall")
	m.line1:SetPoint("TOPLEFT", 8, -6)
	m.line2 = text(m, "GameFontHighlightSmall", C.muted)
	m.line2:SetPoint("TOPLEFT", 8, -20)
	m.line3 = text(m, "GameFontHighlightSmall", C.muted)
	m.line3:SetPoint("TOPLEFT", 8, -34)
	m:SetScript("OnClick", function(self)
		if self.dragged then self.dragged = false return end -- the end of a move, not a click
		ns.Restore()
	end)
	m:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(rgb(C.gold)) end)
	m:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(rgb(C.border)) end)
	m:SetScript("OnShow", updateMini)
	m:Hide()
	return m
end

function ns.Minimize()
	T.db.minimized = true
	if window then window:Hide() end
	mini = mini or buildMini()
	mini:Show()
end
function ns.Restore()
	T.db.minimized = false
	if mini then mini:Hide() end
	window = window or buildWindow()
	window:Show()
end
local function toggle()
	if window and window:IsShown() then
		window:Hide()
	else
		ns.Restore()
	end
end

-- after the saved data loaded: the mini window comes back if it was left minimized; a clock for the live numbers
function ns.OnLoaded()
	if T.db.minimized then ns.Minimize() end
	if C_Timer and C_Timer.NewTicker then
		C_Timer.NewTicker(1, function()
			updateMini()
			updateRate()
		end)
	end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_FARMLEDGER1 = "/farm"
SLASH_FARMLEDGER2 = "/farmledger"
SLASH_FARMLEDGER3 = "/skins"
SlashCmdList.FARMLEDGER = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "" then
		toggle()
	elseif msg == "mini" then
		ns.Minimize()
	elseif msg == "print" then
		local book, value = shown()
		local tab = T.db.tab
		local lines = tab == "total" and Ledger.ReportTotal(Ledger.BuildTotal(book.total, value, itemName))
			or Ledger.ReportGather(tab, Ledger.BuildGather(book[tab], value, itemName, T.db.sort))
		DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd100Farm Ledger - %s (%s)|r", Ledger.TAB_LABELS[tab],
			T.db.mode == "session" and "сессия" or "статистика"))
		for _, line in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage(line) end
	elseif msg == "reset" then
		askReset()
	elseif msg == "wipe" then
		StaticPopup_Show("FARMLEDGER_WIPE")
	elseif msg:match("^sort") then
		local key = msg:match("^sort%s+(%a+)$")
		if key ~= "count" and key ~= "total" and key ~= "avg" then
			say("сортировка: /farm sort count | total | avg")
			return
		end
		T.db.sort = key
		say("сортировка изменена")
		refresh()
	else
		say("команды: /farm - окно, /farm mini - мини-окно, /farm print - в чат, /farm sort count|total|avg,"
			.. " /farm reset - сброс, /farm wipe - стереть всю статистику")
	end
end
