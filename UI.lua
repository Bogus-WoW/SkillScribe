-- SkillScribe: UI.lua
-- A panel docked to the right of the profession window listing every
-- learned, non-grey recipe by cost per skill point, cheapest first.

local addonName, ns = ...

local ROW_H = 18
local COLS = {
	{ key = "name", title = "Recipe", width = 170, justify = "LEFT" },
	{ key = "chance", title = "Chance", width = 46, justify = "RIGHT" },
	{ key = "cost", title = "Mats", width = 58, justify = "RIGHT" },
	{ key = "raw", title = "Raw/pt", width = 62, justify = "RIGHT", sort = "raw" },
	{ key = "sell", title = "Sell/pt", width = 62, justify = "RIGHT", sort = "sell" },
	{ key = "de", title = "DE/pt", width = 62, justify = "RIGHT", sort = "de" },
}
local INNER = 0
for _, c in ipairs(COLS) do INNER = INNER + c.width end
local WIDTH = INNER + 44

local DIFF_COLOR = {}
local panel, scrollChild, rows, header, footer, ticker
local headers = {} -- sort mode -> header FontString

local function Grey(s) return "|cff777777" .. s .. "|r" end

-- Positive = it costs you; negative = you come out ahead (profit).
local function PerPoint(v, isBest, incomplete)
	if v == nil then
		return Grey("--")
	end
	local text
	if v < 0 then
		text = "|cff40ff40+" .. ns.MS().FormatMoney(-v) .. "|r"
	else
		text = ns.MS().FormatMoney(v)
	end
	if isBest then
		text = "|cffffd100[|r" .. text .. "|cffffd100]|r"
	end
	if incomplete then
		text = text .. Grey("~")
	end
	return text
end

local function RowTooltip(row)
	local r = row.result
	if not r then return end
	local fm = ns.MS().FormatMoney
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(r.name, 1, 1, 1)
	GameTooltip:AddDoubleLine("Reagents", fm(r.cost) .. (r.complete and "" or " (some unpriced)"), 1, 1, 1, 1, 1, 1)
	GameTooltip:AddDoubleLine("Skill-up chance", ("%d%%%s"):format(r.chance * 100, r.chanceExact and "" or " (assumed)"),
		1, 1, 1, 1, 1, 1)
	if r.points > r.chance then
		GameTooltip:AddDoubleLine("Points per skill-up", ("%d"):format(r.points / r.chance), 1, 1, 1, 1, 1, 1)
	end
	if r.outputID then
		local qty = r.qty ~= 1 and (" x%g"):format(r.qty) or ""
		if r.sellValue then
			GameTooltip:AddDoubleLine("Sell output" .. qty .. " (" .. r.sellSource .. ")", fm(r.sellValue), 1, 1, 1, 1, 1, 1)
		else
			GameTooltip:AddDoubleLine("Sell output" .. qty, "no price yet", 1, 1, 1, 0.6, 0.6, 0.6)
		end
		if r.noDE then
			GameTooltip:AddLine("Can't be disenchanted.", 0.7, 0.7, 0.7)
		elseif r.deValue then
			GameTooltip:AddDoubleLine("Disenchant output" .. qty .. " (avg)", fm(r.deValue) .. (r.deComplete and "" or " ~"),
				1, 1, 1, 1, 1, 1)
		end
	else
		GameTooltip:AddLine("Makes no item -- raw cost only.", 0.7, 0.7, 0.7)
	end
	if r.bestPer then
		local label = ({ raw = "keep it", sell = "sell it", de = "disenchant it" })[r.bestKind]
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(("Cheapest way: %s, %s per skill point"):format(label,
			r.bestPer < 0 and ("+" .. fm(-r.bestPer) .. " profit") or fm(r.bestPer)), 1, 0.82, 0)
	end
	GameTooltip:AddLine("Click to select this recipe.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function CreateRow(i)
	local row = CreateFrame("Button", nil, scrollChild)
	row:SetSize(INNER + 8, ROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	local stripe = row:CreateTexture(nil, "BACKGROUND")
	stripe:SetAllPoints()
	stripe:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0)
	row.best = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	row.best:SetAllPoints()
	row.best:SetColorTexture(1, 0.82, 0, 0.22)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(0.5, 0.8, 1, 0.12)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(14, 14)
	row.icon:SetPoint("LEFT", 2, 0)

	row.cells = {}
	local x = 4
	for idx, c in ipairs(COLS) do
		local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		local offset = idx == 1 and 16 or 0
		fs:SetPoint("LEFT", x + offset, 0)
		fs:SetWidth(c.width - 6 - offset)
		fs:SetJustifyH(c.justify)
		fs:SetWordWrap(false)
		row.cells[c.key] = fs
		x = x + c.width
	end

	row:SetScript("OnEnter", RowTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnClick", function(self)
		if self.result then ns.SelectRecipe(self.result.recipeID) end
	end)
	return row
end

local function DiffColor(d)
	if d == ns.DIFF.ORANGE then return "|cffff8040"
	elseif d == ns.DIFF.YELLOW then return "|cffffff00"
	elseif d == ns.DIFF.GREEN then return "|cff40bf40" end
	return "|cff808080"
end

function ns.Refresh()
	if not ns.db then return end
	local cache = ns.Evaluate()
	ns.RefreshListHighlight()
	if not (panel and panel:IsShown()) then return end

	header:SetText(ns.ProfessionLabel())
	local mode = ns.db.sortBy or "best"
	ns.sortButton:SetText("Sort: " .. ({ best = "Best", raw = "Raw", sell = "Sell", de = "Disenchant" })[mode])
	for m, h in pairs(headers) do
		if m == mode then
			h.fs:SetText("|cffffffff" .. h.title .. " v|r")
		else
			h.fs:SetText(h.title)
		end
	end
	local fm = ns.MS() and ns.MS().FormatMoney
	for i, r in ipairs(cache.results) do
		local row = rows[i] or CreateRow(i)
		rows[i] = row
		row.result = r
		row.icon:SetTexture(r.icon)
		local name = DiffColor(r.difficulty) .. r.name .. "|r"
		if r.recipeID == cache.cheapestID then
			name = "|cffffd100*|r " .. name
		end
		row.cells.name:SetText(name)
		row.cells.chance:SetText(r.points > 0 and (("%d%%"):format(r.chance * 100) .. (r.chanceExact and "" or Grey("?"))) or Grey("0%"))
		row.cells.cost:SetText(fm(r.cost) .. (r.complete and "" or Grey("~")))
		local inc = not r.complete
		row.cells.raw:SetText(PerPoint(r.rawPer, r.bestKind == "raw", inc))
		row.cells.sell:SetText(r.outputID and PerPoint(r.sellPer, r.bestKind == "sell", inc) or Grey("n/a"))
		row.cells.de:SetText((r.outputID and not r.noDE) and PerPoint(r.dePer, r.bestKind == "de", inc or r.deComplete == false) or Grey("n/a"))
		row.best:SetShown(r.recipeID == cache.cheapestID)
		row:Show()
	end
	for i = #cache.results + 1, #rows do
		rows[i]:Hide()
	end
	scrollChild:SetHeight(math.max(1, #cache.results * ROW_H))

	local best = cache.cheapestID and cache.results[1]
	if best then
		local kind = mode == "best" and best.bestKind or mode
		local value = best[ns.SORT_KEYS[mode]]
		local label = ({ raw = "keep", sell = "sell", de = "disenchant" })[kind]
		local per = value < 0 and ("|cff40ff40+" .. fm(-value) .. " profit|r") or fm(value)
		local prefix = mode == "best" and "Cheapest" or ("Cheapest when you " .. label)
		footer:SetText(("%s: |cffffd100%s|r (%s) -- %s per point"):format(prefix, best.name, label, per))
	elseif #cache.results > 0 and mode ~= "best" then
		footer:SetText(Grey("No recipe has a " .. ({ raw = "raw", sell = "sell", de = "disenchant" })[mode] .. " value yet."))
	elseif #cache.results == 0 then
		footer:SetText(Grey("No rankable recipes -- everything's grey, or no prices yet."))
	else
		footer:SetText(Grey("No reagent prices yet -- scan at the AH with MarketScribe."))
	end
end

local function Build()
	panel = CreateFrame("Frame", "SkillScribePanel", ProfessionsFrame or UIParent, "BasicFrameTemplateWithInset")
	panel:SetSize(WIDTH, 520)
	panel:SetFrameStrata("HIGH")
	panel:EnableMouse(true)
	-- drag it anywhere; the spot is remembered
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		ns.db.panelPos = { p, rp, x, y }
	end)

	local title = panel.TitleText or panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not panel.TitleText then title:SetPoint("TOP", 0, -5) end
	title:SetText("SkillScribe -- cost per skill point")

	header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("TOPLEFT", 14, -30)

	-- Column headers. Raw/Sell/DE are clickable and sort by that method;
	-- clicking the active one again goes back to "best of the three".
	local x = 14
	for _, c in ipairs(COLS) do
		local h
		if c.sort then
			local btn = CreateFrame("Button", nil, panel)
			btn:SetSize(c.width - 6, 16)
			btn:SetPoint("TOPLEFT", x, -48)
			h = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			h:SetAllPoints()
			local hl = btn:CreateTexture(nil, "HIGHLIGHT")
			hl:SetAllPoints()
			hl:SetColorTexture(1, 1, 1, 0.08)
			btn:SetScript("OnClick", function()
				ns.SetSort(ns.db.sortBy == c.sort and "best" or c.sort)
			end)
			btn:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine("Sort by " .. c.title, 1, 1, 1)
				GameTooltip:AddLine("Click again to go back to sorting by the best method per recipe.", nil, nil, nil, true)
				GameTooltip:Show()
			end)
			btn:SetScript("OnLeave", GameTooltip_Hide)
			headers[c.sort] = { fs = h, title = c.title }
		else
			h = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			h:SetPoint("TOPLEFT", x, -50)
		end
		h:SetWidth(c.width - 6)
		h:SetJustifyH(c.justify)
		h:SetText(c.title)
		x = x + c.width
	end

	-- "Sort: ..." button next to the profession label
	local sortBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	sortBtn:SetSize(150, 20)
	sortBtn:SetPoint("TOPRIGHT", -12, -26)
	sortBtn:SetScript("OnClick", function()
		local order = { "best", "raw", "sell", "de" }
		local nextMode = "best"
		for i, m in ipairs(order) do
			if m == ns.db.sortBy then
				nextMode = order[i % #order + 1]
			end
		end
		ns.SetSort(nextMode)
	end)
	ns.sortButton = sortBtn

	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -66)
	scroll:SetPoint("BOTTOMRIGHT", -30, 52)
	scrollChild = CreateFrame("Frame", nil, scroll)
	scrollChild:SetSize(INNER + 8, 1)
	scroll:SetScrollChild(scrollChild)
	rows = {}

	footer = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footer:SetPoint("BOTTOMLEFT", 14, 30)
	footer:SetPoint("BOTTOMRIGHT", -14, 30)
	footer:SetJustifyH("LEFT")
	footer:SetWordWrap(false)

	local legend = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	legend:SetPoint("BOTTOMLEFT", 14, 12)
	legend:SetText(Grey("[x] = cheapest way per recipe   + = profit   ~ = some prices missing   ? = assumed chance"))

	panel:SetScript("OnShow", function()
		ns.Refresh()
		ticker = C_Timer.NewTicker(3, ns.Refresh) -- prices stream in during AH scans
	end)
	panel:SetScript("OnHide", function()
		if ticker then ticker:Cancel() ticker = nil end
	end)
	panel:Hide()
end

local function Dock()
	panel:ClearAllPoints()
	local pos = ns.db.panelPos
	if pos then
		panel:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
		if ProfessionsFrame then panel:SetHeight(math.max(400, ProfessionsFrame:GetHeight())) end
	elseif ProfessionsFrame and ProfessionsFrame:IsShown() then
		panel:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", 2, 0)
		panel:SetHeight(math.max(400, ProfessionsFrame:GetHeight()))
	else
		panel:SetPoint("CENTER")
	end
end

function ns.PanelVisible()
	return panel and panel:IsShown()
end

function ns.OnProfessionShow()
	if not panel then Build() end
	-- a small toggle button on the profession frame itself
	if ProfessionsFrame and not ns.toggleButton then
		local b = CreateFrame("Button", nil, ProfessionsFrame, "UIPanelButtonTemplate")
		b:SetSize(90, 20)
		b:SetText("SkillScribe")
		-- sits just above the profession window's top edge, so it covers nothing
		b:SetPoint("BOTTOMRIGHT", ProfessionsFrame, "TOPRIGHT", -24, 2)
		b:SetFrameLevel(ProfessionsFrame:GetFrameLevel() + 10)
		b:SetScript("OnClick", ns.TogglePanel)
		ns.toggleButton = b
		-- and one for the Plan window, just left of it
		local pb = CreateFrame("Button", nil, ProfessionsFrame, "UIPanelButtonTemplate")
		pb:SetSize(70, 20)
		pb:SetText("Plan")
		pb:SetPoint("RIGHT", b, "LEFT", -2, 0)
		pb:SetFrameLevel(ProfessionsFrame:GetFrameLevel() + 10)
		pb:SetScript("OnClick", function()
			pcall(ns.RecordKnown)
			local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
			local skill = ok and info and ns.PROF_IDS[info.professionName]
			if ns.PlanVisible() and not skill then ns.TogglePlan() else ns.TogglePlan(skill) end
		end)
		pb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("SkillScribe Plan", 1, 1, 1)
			GameTooltip:AddLine("What to learn next and the cheapest route to your skill cap.", nil, nil, nil, true)
			GameTooltip:Show()
		end)
		pb:SetScript("OnLeave", GameTooltip_Hide)
		-- and the Disenchant window, left of Plan
		local db = CreateFrame("Button", nil, ProfessionsFrame, "UIPanelButtonTemplate")
		db:SetSize(90, 20)
		db:SetText("Disenchant")
		db:SetPoint("RIGHT", pb, "LEFT", -2, 0)
		db:SetFrameLevel(ProfessionsFrame:GetFrameLevel() + 10)
		db:SetScript("OnClick", function() ns.ToggleDE() end)
		db:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("SkillScribe Disenchant", 1, 1, 1)
			GameTooltip:AddLine("One-click disenchanting of the greens and blues in your bags, and what they've given you.", nil, nil, nil, true)
			GameTooltip:Show()
		end)
		db:SetScript("OnLeave", GameTooltip_Hide)
	end
	-- the window only opens when you click the SkillScribe button
	ns.QueueRefresh()
end

function ns.OnProfessionHide()
	if panel then panel:Hide() end
end

function ns.TogglePanel()
	if not panel then Build() end
	if panel:IsShown() then
		panel:Hide()
		ns.db.panelShown = false
	else
		ns.db.panelShown = true
		Dock()
		panel:Show()
	end
end
