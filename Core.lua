-- SkillScribe: Core.lua
--
-- Works out what each known recipe costs you per skill point, using
-- MarketScribe's prices (via MarketScribeAPI):
--
--   Raw     = reagent cost                                   (keep/use it)
--   Sell    = reagent cost - what the output sells for       (AH after the
--             5% cut, or the vendor price if that's higher)
--   DE      = reagent cost - expected disenchant value       (greens/blues)
--
-- Each is divided by the expected skill points per craft:
--
--   orange = 1 (or the recipe's numSkillUps), yellow/green = an assumed
--   average chance (see ns.CHANCE), grey = 0, so not ranked.
--
-- Recipes that don't make an item (most Enchanting) only get the Raw
-- figure. The cheapest recipe is highlighted both in our panel and in
-- Blizzard's recipe list.

local addonName, ns = ...

local PREFIX = "|cff7fd4ffSkillScribe|r"
local AH_CUT = 0.95

SkillScribeDB = SkillScribeDB or {}
local db

function ns.Print(msg)
	print(PREFIX .. ": " .. msg)
end

local function MS()
	return _G.MarketScribeAPI
end
ns.MS = MS

-- Enum.TradeskillRelativeDifficulty: Optimal(orange)=0, Medium(yellow)=1,
-- Easy(green)=2, Trivial(grey)=3.
ns.DIFF = { ORANGE = 0, YELLOW = 1, GREEN = 2, GREY = 3 }
local DIFF_ENUM = Enum and Enum.TradeskillRelativeDifficulty
if DIFF_ENUM then
	ns.DIFF.ORANGE = DIFF_ENUM.Optimal or 0
	ns.DIFF.YELLOW = DIFF_ENUM.Medium or 1
	ns.DIFF.GREEN = DIFF_ENUM.Easy or 2
	ns.DIFF.GREY = DIFF_ENUM.Trivial or 3
end

-- Average skill-up chance across each colour band, using the classic
-- formula chance = (grey - skill) / (grey - yellow): it falls from 100% to
-- ~50% across yellow and from ~50% to 0% across green, so the band
-- averages are about 75% and 25%. Adjustable with /sks chance.
ns.DEFAULT_CHANCE = { yellow = 0.75, green = 0.25 }

--------------------------------------------------------------------------
-- Skill-up bonus from Forever's Legacy Tree ("Working Overtime": "Increases
-- your chance to gain a skill increase ... by 20%" at rank 5). Read from the
-- talent's aura or known spell and its description; /sks bonus overrides.
--------------------------------------------------------------------------

local BONUS_NAME = "Working Overtime"

local function Plain(v)
	if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function FindBonusSpell()
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 80 do
			local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
			if not (ok and a) then break end
			if Plain(a.name) == BONUS_NAME then return Plain(a.spellId), "aura" end
		end
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, BONUS_NAME)
		local id = ok and info and Plain(info.spellID)
		if id and (not IsPlayerSpell or IsPlayerSpell(id)) then return id, "spell" end
	end
end

local bonusCache, bonusAt = nil, -100
-- Returns the bonus as a fraction (0.2 for 20%) and how it was found.
function ns.SkillUpBonus()
	if db and db.bonusOverride then return db.bonusOverride / 100, "set by you" end
	if GetTime() - bonusAt < 15 and bonusCache then return bonusCache[1], bonusCache[2] end
	bonusAt = GetTime()
	local pct, how = 0, "not found"
	local ok, id, where = pcall(FindBonusSpell)
	if ok and id then
		local desc = C_Spell and C_Spell.GetSpellDescription and Plain(C_Spell.GetSpellDescription(id))
		local n = type(desc) == "string" and tonumber(desc:match("by (%d+)%%"))
		if n then
			pct, how = n, ("%s (%s)"):format(BONUS_NAME, where)
		else
			how = BONUS_NAME .. " found, but its percentage couldn't be read"
		end
	end
	bonusCache = { pct / 100, how }
	return pct / 100, how
end

-- Apply the bonus to a base yellow/green chance (orange is already 100%,
-- grey can't give points). Additive by default ("by 20%" read as +20
-- percentage points); /sks bonus mult treats it as x1.2 instead.
function ns.ApplyBonus(base)
	if not base or base <= 0 or base >= 1 then return base end
	local b = ns.SkillUpBonus()
	if b <= 0 then return base end
	if db and db.bonusMode == "mult" then
		return math.min(1, base * (1 + b))
	end
	return math.min(1, base + b)
end

local function Chance(info)
	local d = info.relativeDifficulty
	if d == ns.DIFF.ORANGE then
		return 1, true
	elseif d == ns.DIFF.YELLOW then
		return ns.ApplyBonus(db.chance.yellow), false
	elseif d == ns.DIFF.GREEN then
		return ns.ApplyBonus(db.chance.green), false
	end
	return 0, true
end

-- Skill points per successful skill-up (orange recipes can give more than 1).
local function PointsPerSkillUp(info)
	if info.relativeDifficulty == ns.DIFF.ORANGE and info.numSkillUps and info.numSkillUps > 1 then
		return info.numSkillUps
	end
	return 1
end

local function ItemSellValue(itemID)
	-- What one crafted item gets you if you sell it: AH (after cut) or vendor,
	-- whichever pays more. Returns value, label.
	local api = MS()
	local vendor = select(11, C_Item.GetItemInfo(itemID))
	-- Bind on Pickup: never on the AH, so it's worth what a vendor pays
	-- (0 if nothing): the Sell column then shows what crafting it costs you
	if select(14, C_Item.GetItemInfo(itemID)) == 1 then
		return vendor or 0, "vendor, BoP"
	end
	local ah = api and api.GetMarketPrice and api.GetMarketPrice(itemID)
	local ahNet = ah and ah * AH_CUT
	if ahNet and (not vendor or ahNet >= vendor) then
		return ahNet, "AH"
	elseif vendor and vendor > 0 then
		return vendor, "vendor"
	end
	if not ah and api and api.QueueItem then
		api.QueueItem(itemID)
	end
end

--------------------------------------------------------------------------
-- Evaluate every known recipe of the open profession
--------------------------------------------------------------------------

-- Sort modes: "best" = cheapest of the three per recipe, or one method only.
ns.SORT_KEYS = { best = "bestPer", raw = "rawPer", sell = "sellPer", de = "dePer" }
ns.SORT_LABELS = { best = "best method", raw = "keep (raw)", sell = "selling", de = "disenchanting" }

local cache = { results = {}, cheapestID = nil, stamp = 0 }
ns.cache = cache

local function EvaluateRecipe(recipeID, info)
	local api = MS()
	local cost, complete, schematic = api.GetRecipeCost(recipeID)
	if cost == nil or not schematic then
		return nil
	end

	local r = {
		recipeID = recipeID,
		name = info.name,
		icon = info.icon,
		difficulty = info.relativeDifficulty,
		cost = cost,
		complete = complete,
	}
	r.chance, r.chanceExact = Chance(info)
	r.points = r.chance * PointsPerSkillUp(info)

	local outputID = api.GetRecipeOutputItemID(recipeID, schematic)
	local qty = ((schematic.quantityMin or 1) + (schematic.quantityMax or schematic.quantityMin or 1)) / 2
	if qty <= 0 then qty = 1 end
	r.outputID, r.qty = outputID, qty

	if outputID then
		if not C_Item.GetItemInfo(outputID) then
			C_Item.RequestLoadItemDataByID(outputID)
		end
		local sell, sellSource = ItemSellValue(outputID)
		if sell then
			r.sellValue, r.sellSource = sell * qty, sellSource
		end
		-- Enchanting-made wands can't be disenchanted: MarketScribe knows the
		-- four classic ones by ID, and as a fallback any wand crafted with
		-- Enchanting is treated the same way.
		local _, _, _, _, _, _, _, _, _, _, _, classID, subClassID = C_Item.GetItemInfo(outputID)
		local isWand = classID == 2 and subClassID == 19
		local noDE = (api.IsNotDisenchantable and api.IsNotDisenchantable(outputID))
			or (isWand and ns.currentProfession == "Enchanting")
		r.noDE = noDE or nil
		if api.GetDisenchantEV and not noDE then
			local de, deComplete = api.GetDisenchantEV(outputID)
			if de and de > 0 then
				r.deValue, r.deComplete = de * qty, deComplete
			end
		end
	end

	if r.points > 0 then
		r.rawPer = cost / r.points
		if r.sellValue then
			r.sellPer = (cost - r.sellValue) / r.points
		end
		if r.deValue then
			r.dePer = (cost - r.deValue) / r.points
		end
		-- best (lowest) of the three
		r.bestPer, r.bestKind = r.rawPer, "raw"
		if r.sellPer and r.sellPer < r.bestPer then
			r.bestPer, r.bestKind = r.sellPer, "sell"
		end
		if r.dePer and r.dePer < r.bestPer then
			r.bestPer, r.bestKind = r.dePer, "de"
		end
	end
	return r
end

function ns.Evaluate()
	wipe(cache.results)
	cache.cheapestID = nil
	local api = MS()
	if not (api and api.GetRecipeCost and C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then
		return cache
	end
	local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not ok or not recipeIDs then
		return cache
	end
	ns.currentProfession = nil
	if C_TradeSkillUI.GetBaseProfessionInfo then
		local okP, prof = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
		ns.currentProfession = okP and prof and prof.professionName or nil
	end

	for _, recipeID in ipairs(recipeIDs) do
		local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
		if info and info.learned and not info.isRecraft and (db.showGrey or info.relativeDifficulty ~= ns.DIFF.GREY) then
			local okEval, r = pcall(EvaluateRecipe, recipeID, info)
			if okEval and r then
				table.insert(cache.results, r)
			end
		end
	end

	-- Sort by the chosen disposal method (/sks sort, or click a column
	-- header). Recipes with no value for that method go to the bottom.
	local key = ns.SORT_KEYS[db.sortBy] or "bestPer"
	table.sort(cache.results, function(a, b)
		local av, bv = a[key], b[key]
		if av and bv then
			if av ~= bv then
				return av < bv
			end
			return a.name < b.name
		elseif av or bv then
			return av ~= nil
		end
		if a.bestPer and b.bestPer and a.bestPer ~= b.bestPer then
			return a.bestPer < b.bestPer
		end
		return a.name < b.name
	end)

	-- "Cheapest" follows the sort: cheapest to level by selling, by
	-- disenchanting, etc.
	local first = cache.results[1]
	if first and first[key] then
		cache.cheapestID = first.recipeID
	end
	cache.stamp = GetTime()
	return cache
end

function ns.ProfessionLabel()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) then
		return ""
	end
	local ok, prof = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
	if ok and prof and prof.professionName then
		return ("%s %d/%d"):format(prof.professionName, prof.skillLevel or 0, prof.maxSkillLevel or 0)
	end
	return ""
end

--------------------------------------------------------------------------
-- Highlight the cheapest recipe in Blizzard's own recipe list
--------------------------------------------------------------------------

local function DecorateRow(_, row, node)
	local data = node and node:GetData()
	local info = data and data.recipeInfo
	local glow = row.SkillScribeGlow
	if not glow then
		glow = row:CreateTexture(nil, "BACKGROUND", nil, 1)
		glow:SetAllPoints()
		glow:SetColorTexture(1, 0.82, 0, 0.18)
		row.SkillScribeGlow = glow
	end
	glow:SetShown(db.highlightList and info and info.recipeID and info.recipeID == cache.cheapestID or false)
end

local attached = false
function ns.AttachListHighlight()
	if attached then
		return
	end
	local list = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
	if list and list.ScrollBox and ScrollUtil then
		ScrollUtil.AddInitializedFrameCallback(list.ScrollBox, DecorateRow, ns)
		attached = true
	end
end

function ns.RefreshListHighlight()
	local list = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
	if not (list and list.ScrollBox and list.ScrollBox.ForEachFrame) then
		return
	end
	list.ScrollBox:ForEachFrame(function(row)
		local node = row.GetElementData and row:GetElementData()
		DecorateRow(nil, row, node)
	end)
end

function ns.SetSort(mode)
	db.sortBy = mode
	ns.Print("sorting by cost per point when " .. ns.SORT_LABELS[mode] .. ".")
	ns.Refresh()
end

function ns.SelectRecipe(recipeID)
	if C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then
		pcall(C_TradeSkillUI.OpenRecipe, recipeID)
	end
end

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_SKILLSCRIBE1 = "/sks"
SLASH_SKILLSCRIBE2 = "/skillscribe"
SlashCmdList.SKILLSCRIBE = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "" then
		ns.TogglePanel()
	elseif msg == "plan" then
		ns.TogglePlan()
	elseif msg == "de" or msg == "disenchant" then
		ns.ToggleDE()
	elseif msg:match("^ahcap") then
		local n = tonumber(msg:match("^ahcap%s+(%d+)$") or "")
		if n then db.ahCap = math.max(0, n) end
		ns.Print(("Smart counts AH sales for the first %d of each item that doesn't stack (halved when the AH is crowded). Usage: /sks ahcap <number>"):format(db.ahCap))
		if ns.PlanVisible and ns.PlanVisible() then ns.RefreshPlan() end
	elseif msg:match("^ahstacks") then
		local n = tonumber(msg:match("^ahstacks%s+(%d+)$") or "")
		if n then db.ahStacks = math.max(0, n) end
		ns.Print(("Smart counts AH sales for the first %d full stack(s) of stackable items (halved when the AH is crowded). Usage: /sks ahstacks <number>"):format(db.ahStacks))
		if ns.PlanVisible and ns.PlanVisible() then ns.RefreshPlan() end
	elseif msg:match("^ahage") then
		local n = tonumber(msg:match("^ahage%s+(%d+)$") or "")
		if n then db.ahMaxAge = math.max(1, n) end
		ns.Print(("Smart ignores AH prices older than %d day(s). Usage: /sks ahage <days>"):format(db.ahMaxAge))
		if ns.PlanVisible and ns.PlanVisible() then ns.RefreshPlan() end
	elseif msg == "unexclude" then
		local n = 0
		for _ in pairs(db.noAH) do n = n + 1 end
		for _ in pairs(db.excluded) do n = n + 1 end
		wipe(db.noAH); wipe(db.excluded)
		ns.Print(("cleared %d exclusion(s)."):format(n))
		if ns.PlanVisible and ns.PlanVisible() then ns.RefreshPlan() end
	elseif msg:match("^bonus") then
		local arg = msg:match("^bonus%s+(.+)$")
		if arg == "auto" then
			db.bonusOverride = nil
		elseif arg == "add" or arg == "mult" then
			db.bonusMode = arg
		elseif arg and tonumber((arg:gsub("%%", ""))) then
			db.bonusOverride = tonumber((arg:gsub("%%", "")))
		elseif arg then
			ns.Print("usage: /sks bonus <percent|auto|add|mult>")
			return
		end
		bonusAt = -100
		local b, how = ns.SkillUpBonus()
		ns.Print(("skill-up bonus: %d%% (%s), applied %s to yellow and green recipes."):format(b * 100, how,
			db.bonusMode == "mult" and "as a multiplier (x" .. (1 + b) .. ")" or "as extra percentage points"))
		ns.Refresh()
		if ns.PlanVisible and ns.PlanVisible() then ns.RefreshPlan() end
	elseif msg:match("^chance") then
		local color, pct = msg:match("^chance (%a+) (%d+)$")
		if (color == "yellow" or color == "green") and tonumber(pct) then
			db.chance[color] = math.max(0.01, math.min(1, tonumber(pct) / 100))
			ns.Print(("assuming %d%% skill-up chance on %s recipes."):format(db.chance[color] * 100, color))
			ns.Refresh()
		else
			ns.Print(("current: yellow %d%%, green %d%%. Usage: /sks chance <yellow|green> <percent>"):format(
				db.chance.yellow * 100, db.chance.green * 100))
		end
	elseif msg:match("^sort") then
		local mode = msg:match("^sort%s+(%a+)$")
		if mode == "disenchant" then mode = "de" end
		if mode and ns.SORT_KEYS[mode] then
			ns.SetSort(mode)
		else
			ns.Print("usage: /sks sort <best|raw|sell|de>  (or click a column header)")
		end
	elseif msg == "grey" or msg == "gray" then
		db.showGrey = not db.showGrey
		ns.Print("grey recipes " .. (db.showGrey and "shown (unranked)." or "hidden."))
		ns.Refresh()
	elseif msg == "spec" or msg:match("^spec%s") then
		local arg = (msg:match("^spec%s+(.-)%s*$") or ""):lower()
		local prof = ns.db.planProf
		if not (prof and ns.SPECS[prof]) then
			ns.Print("Open the plan on Leatherworking or Engineering first (the specialization applies to the profession shown).")
		elseif arg == "" then
			local names = {}
			for _, sp in ipairs(ns.SPECS[prof]) do names[#names + 1] = sp[2]:lower() end
			ns.Print(("%s specialization: %s. Use /sks spec <%s|none>."):format(ns.PROF_NAMES[prof], ns.SpecName(prof) or "none", table.concat(names, "|")))
		else
			local sid, found = nil, (arg == "none")
			for _, sp in ipairs(ns.SPECS[prof]) do
				if sp[2]:lower() == arg then sid, found = sp[1], true end
			end
			if not found then ns.Print("Unknown specialization: " .. arg) else
				ns.SetSpec(prof, sid)
				ns.Print(ns.PROF_NAMES[prof] .. " specialization: " .. (ns.SpecName(prof) or "none") .. ".")
				if ns.RefreshPlan then ns.RefreshPlan() end
			end
		end
	elseif msg == "tooltip" then
		db.craftTooltip = (db.craftTooltip == false)
		ns.Print("\"Cost to craft\" line in item tooltips " .. (db.craftTooltip and "on." or "off."))
	elseif msg == "highlight" then
		db.highlightList = not db.highlightList
		ns.Print("highlight in the recipe list " .. (db.highlightList and "on." or "off."))
		ns.RefreshListHighlight()
	elseif msg:match("^debug") then
		-- dump the raw recipe info for one recipe, to see which skill-up
		-- fields this client actually exposes
		local needle = msg:match("^debug%s+(.+)$")
		if not needle then
			ns.Print("usage: /sks debug <part of a recipe name>")
			return
		end
		for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
			local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
			if info and info.name and info.name:lower():find(needle, 1, true) then
				ns.Print(("%s (%d):"):format(info.name, recipeID))
				local keys = {}
				for k in pairs(info) do table.insert(keys, k) end
				table.sort(keys)
				for _, k in ipairs(keys) do
					local v = info[k]
					if type(v) ~= "table" then
						print(("  %s = %s"):format(k, tostring(v)))
					end
				end
				return
			end
		end
		ns.Print("no known recipe matches that.")
	else
		ns.Print("/sks (toggle panel), /sks plan (what to learn next), /sks de (disenchant window), /sks ahcap <n>, /sks ahstacks <n>, /sks ahage <days>, /sks unexclude, /sks bonus [percent|auto|add|mult] (Working Overtime skill-up bonus), /sks sort <best|raw|sell|de>, /sks chance <yellow|green> <percent>, /sks grey, /sks highlight, /sks spec [name|none], /sks debug <recipe>")
	end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local pendingRefresh
local function QueueRefresh()
	if pendingRefresh then
		return
	end
	pendingRefresh = true
	C_Timer.After(0.5, function()
		pendingRefresh = nil
		ns.Refresh()
	end)
end
ns.QueueRefresh = QueueRefresh

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("TRAINER_SHOW")
frame:RegisterEvent("TRAINER_UPDATE")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, a)
	if event == "ADDON_LOADED" and a == addonName then
		SkillScribeDB = SkillScribeDB or {}
		db = SkillScribeDB
		db.chance = db.chance or { yellow = ns.DEFAULT_CHANCE.yellow, green = ns.DEFAULT_CHANCE.green }
		if db.highlightList == nil then db.highlightList = true end
		db.panelShown = nil -- the window no longer opens by itself
		db.sortBy = db.sortBy or "best"
		-- 1.2.0: "disenchant" stopped being a Crafts mode and became a toggle
		if db.planOutput == "de" then
			db.planOutput, db.planDE = "vendor", true
		end
		db.planOutput = db.planOutput or "vendor"
		if db.planDE == nil then db.planDE = false end
		db.ahCap = db.ahCap or 5            -- crafts per item Smart assumes sell on the AH
		db.ahStacks = db.ahStacks or 2      -- ...or this many full stacks, for stackable items
		db.ahMaxAge = db.ahMaxAge or 3      -- days; older AH prices are ignored by Smart
		db.noAH = db.noAH or {}             -- [itemID] = true: never count AH sales
		db.excluded = db.excluded or {}     -- [spellID] = true: leave the recipe out of the plan
		ns.db = db
		if not MS() then
			ns.Print("MarketScribe (with MarketScribeAPI) not found -- SkillScribe needs it for prices.")
		end
	elseif event == "TRADE_SKILL_SHOW" then
		ns.AttachListHighlight()
		ns.OnProfessionShow()
		C_Timer.After(1, function() pcall(ns.RecordKnown) end)
	elseif event == "TRADE_SKILL_LIST_UPDATE" then
		QueueRefresh()
		pcall(ns.RecordKnown)
	elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
		local ok, saved = pcall(ns.RecordTrainer)
		if ok and saved and saved > 0 and event == "TRAINER_SHOW" then
			ns.Print(("saved %d recipe costs from this trainer for /sks plan."):format(saved))
		end
		if ns.PlanVisible and ns.PlanVisible() then ns.RefreshPlan() end
	elseif event == "PLAYER_LOGIN" then
		C_Timer.After(2, function() pcall(ns.ReadSkillLevels) end)
	elseif event == "SKILL_LINES_CHANGED" then
		pcall(ns.ReadSkillLevels)
		if ns.PlanVisible and ns.PlanVisible() then C_Timer.After(0.5, ns.RefreshPlan) end
	elseif event == "TRADE_SKILL_CLOSE" then
		ns.OnProfessionHide()
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if ns.PanelVisible and ns.PanelVisible() then
			QueueRefresh()
		end
		if ns.PlanVisible and ns.PlanVisible() and not ns.planRefreshPending then
			ns.planRefreshPending = true
			C_Timer.After(1, function() ns.planRefreshPending = nil; ns.RefreshPlan() end)
		end
	end
end)
