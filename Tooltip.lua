-- SkillScribe: Tooltip.lua
--
-- Adds "Cost to craft" to the tooltip of any item a profession can make:
-- the reagent cost per item, from MarketScribe prices (smelting bars
-- yourself when that's cheaper). Uses SkillScribe's own recipe data, so it
-- works for recipes you haven't learned and for every profession. When
-- several recipes make the item, the cheapest is shown. "~" means some
-- reagents have no price yet, so the real cost is higher.
--
--   /sks tooltip   turn the line on or off

local _, ns = ...

local byOutput

local function Index()
	if byOutput then return byOutput end
	byOutput = {}
	for skill, data in pairs(ns.RECIPES or {}) do
		for _, r in pairs(data) do
			local out = r[5]
			if type(out) == "number" and out > 0 and type(r[8]) == "table" then
				local list = byOutput[out]
				if not list then list = {}; byOutput[out] = list end
				list[#list + 1] = { skill = skill, r = r }
			end
		end
	end
	return byOutput
end

local function CraftCost(itemID)
	local list = Index()[itemID]
	if not (list and ns.CraftCostPerItem) then return nil end
	local best, bestMissing, bestSkill
	for _, e in ipairs(list) do
		local cost, missing = ns.CraftCostPerItem(e.r)
		if cost and cost > 0 then
			-- a fully priced recipe beats an incomplete one; then cheapest
			if not best
				or (bestMissing and not missing)
				or (bestMissing == missing and cost < best) then
				best, bestMissing, bestSkill = cost, missing, e.skill
			end
		end
	end
	return best, bestMissing, bestSkill
end
ns.CraftCost = CraftCost

local function OnItemTooltip(tooltip)
	if ns.db and ns.db.craftTooltip == false then return end
	if not (TooltipUtil and TooltipUtil.GetDisplayedItem) then return end
	local ok, _, _, id = pcall(TooltipUtil.GetDisplayedItem, tooltip)
	if not ok or not id then return end
	local api = ns.MS and ns.MS()
	if not (api and api.FormatMoney) then return end
	local cost, missing, skill = CraftCost(id)
	if not cost then return end
	local prof = ns.PROF_NAMES and ns.PROF_NAMES[skill]
	tooltip:AddLine(("|cff7fd4ffSkillScribe|r Cost to craft: %s%s%s"):format(
		api.FormatMoney(math.floor(cost + 0.5)),
		missing and " |cff888888~|r" or "",
		prof and (" |cff888888(" .. prof .. ")|r") or ""))
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end
