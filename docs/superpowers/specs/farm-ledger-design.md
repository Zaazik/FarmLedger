# Farm Ledger: design

## Why

What a farming session brings in, as in Lineage 2's session counter: everything new taken from mobs and nodes,
priced for the auction house or a vendor, plus the money picked up. Grew out of SkinLedger (skins per mob).

## Rules (from the user, 2026-11-18/19)

- Two modes, switched in the window:
  - **Session**: from a `/reload` (or login) to the next one, or to the Reset button. Kept in memory only.
  - **Statistics**: kept forever (SavedVariables). Reset there clears only the Total tab; mining, herbs and skins
    stay. `/farm wipe` (with a confirmation) clears all statistics.
- Tabs, each in both modes, each with an icon: **Total** (coins), **Mining** (ore), **Herbalism** (herb),
  **Skins** (pelt).
  - Total: no breakdown - every item looted (corpses, skinning, nodes, fishing, chests) and every quest reward item,
    each with its price and where the price comes from (auction / vendor); coins looted from mobs; gold from quests.
    Not counted: money from vendor sales, mail money; items later sold or listed are not taken off the total.
  - Mining / Herbalism / Skins: one card per node type / mob: how many times, the items with prices, income and
    income per node / mob.
- Price per item (agreed 2026-11-19): the auction price after the 5% cut when it beats the vendor price by more than
  15% (an auction takes time and may not sell), otherwise the vendor price; soulbound items and items without an
  auction price go by the vendor price.
- Auction prices come from Auctionator (user, 2026-11-21), through its public API `Auctionator.API.v1`:
  `GetAuctionPriceByItemID(callerID, itemID)` - the lowest buyout for one item its scans saw (its full scan divides
  each buyout by the stack size), and `GetAuctionAgeByItemID` - days since that price was seen (nil past 21 days).
  Farm Ledger contains no code or data of Auctionator or Mastercraft (both licences forbid copying).
- Gold per hour, in every tab, Session mode only: income of the last 60 minutes; a session shorter than an hour is
  extrapolated to an hour. Not shown in Statistics mode.
- A minimize button next to close: a small window with the session's numbers (income, gold per hour); clicking it
  opens the full window.
- Name: Farm Ledger (`/farm`; `/skins` kept as an alias). SkinLedger's saved skins move over.

## How it is detected (QuestieTrace records of this client, 2026-11-18)

- Looted items: the `CHAT_MSG_LOOT` "you receive loot" line (`LOOT_ITEM_SELF`, `LOOT_ITEM_SELF_MULTIPLE`): with auto
  loot it comes right after `LOOT_CLOSED`. `LOOT_READY` and `LOOT_CLOSED` come twice per window.
- Gathering (skin / mining / herb): the cast (`UNIT_SPELLCAST_SENT` .. `SUCCEEDED`), then its loot window; the window's
  items stay expected for 2 s after it closes and are credited from the loot lines. The cast: the profession spells
  by ID as Wowhead's WoW Forever database lists them (nether.wowhead.com/forever/tooltip/spell/<id>, 2026-11-21:
  Skinning 8613/8617/8618/10768, Mining 2575/2576/3564/10248, Herbalism 2366/2368/3570/11993), or any spell with the
  same name in the client's language. A node gathered with a cast not recognised that way: a loot window from a
  game object holding a herb (item class 7, subclass 9) or ore / stone (7 / 7) - warcraft.wiki.gg "ItemType".
  Node / mob key: the entry ID in the loot source GUID (`Creature-…-<npc>-…`, `GameObject-…-<entry>-…`), else the name.
- Coins: `PLAYER_MONEY` comes ~0.16 s after `LOOT_CLOSED`, the "Ваша добыча: N серебряных" line (`CHAT_MSG_MONEY`)
  ~1 s later; vendor sales and mail have no such line. The money gained is credited when that line comes (within
  2.5 s), never while a merchant or the auction house is open.
- Quest gold: `QUEST_TURNED_IN` (questID, xp, money) - its third value is the money (10200 = "1 золотая, 2 серебряных").
- Quest reward items: the "Вы получили предмет" line (`LOOT_ITEM_PUSHED_SELF`) within 1 s of `QUEST_TURNED_IN`, before
  or after it (seen 0.06 s before). The same line also comes for vendor purchases and quest-start items - not counted.

## Calls made by the builder

- Item values are worked out when shown, with the current prices (not the price at loot time).
- The auction price shown is Auctionator's price after the 5% cut; a price seen days ago says "(N дн.)", one older
  than 21 days "(цене больше 3 недель)". Auctionator has no "prices changed" event in its API: the window redraws when
  the auction house closes, and on Refresh. Auctionator loaded but without a price for any shown item: the price
  line asks for a scan; Auctionator not loaded: vendor prices, and the price line says so.
- Gold per hour counts the value of what came in during the last 60 minutes, valued with the current prices.
- The sort dropdown (count / total / per node) is shown on Mining, Herbalism and Skins; Total lists items by value.
- An item the game hasn't loaded yet has no value until it loads (the window redraws on GET_ITEM_INFO_RECEIVED).
- Money gained while a merchant or the auction house is open is never coins. Mail and trade are not checked:
  MAIL_CLOSED never appears in the records (a mail flag would stay set), and their money has no coin line anyway.
- A new session clears only the session's book: a cast, loot window or coin on its way still reaches the statistics.
- Values the client hides (secret) are reported in chat, at most once per 10 s per kind - never dropped silently.
- The TOC keeps SkinLedger's shape: `SavedVariables: SkinLedgerDB` (it holds Farm Ledger's data) and the files
  `Core\Ledger.lua`, `Game\Main.lua` (tracking + window in one file). The client running when the addon was renamed
  had loaded that TOC, and the user wouldn't restart again: a plain /reload must work.
- SkinLedger's skins (128 on 13 mobs, SavedVariables/SkinLedger.lua 2026-11-19 04:20) move into Statistics > Skins
  once: from the saved table itself while it is still SkinLedger's (v1, `mobs`), else from a copy kept in Game/Main.lua
  (`ns.LEGACY_SKINS`) - that running client's /reload writes an empty table over the saved file first.
