-- SkillScribe: PlanUI.lua
-- The Plan window: the cheapest route to your skill cap, and every recipe
-- you could learn, grouped by where you get it. /sks plan, or the "Plan"
-- button on the profession window and the SkillScribe panel.

local addonName, ns = ...

local WIDTH, HEIGHT, ROW_H = 680, 560, 18
local frame, scrollChild, header, footer, outputBtn, filterBtn, smeltBtn, deBtn, recalcBtn

local OUTPUT_ORDER = { "vendor", "ah", "smart" }
local OUTPUT_LABEL = { vendor = "Crafts: vendor", ah = "Crafts: sell on AH", smart = "Crafts: Smart" }
local rows, profButtons = {}, {}
local current -- skill line shown
local specBtn

local FILTERS = { "all", "T", "A", "V", "D", "Q", "U" }
local FILTER_LABEL = { all = "All sources", T = "Trainer", A = "On the AH", V = "Vendor", D = "Drop", Q = "Quest", U = "Unknown" }

local function Grey(s) return "|cff888888" .. s .. "|r" end
local function Money(c)
	if c == nil then return Grey("?") end
	local api = ns.MS()
	if c < 0 then return "|cff40ff40+" .. api.FormatMoney(-c) .. "|r" end
	return api.FormatMoney(c)
end

local function Red(c) return c and ("|cffff6060" .. ns.MS().FormatMoney(c) .. "|r") or Grey("?") end
local function Green(c) return c and ("|cff40ff40" .. ns.MS().FormatMoney(c) .. "|r") or Grey("?") end

-- Cost (positive) in red, earnings (negative) in green with a +.
local function Signed(c)
	if c == nil then return Grey("?") end
	local api = ns.MS()
	if c < 0 then return "|cff40ff40+" .. api.FormatMoney(-c) .. "|r" end
	if c == 0 then return api.FormatMoney(0) end
	return "|cffff6060" .. api.FormatMoney(c) .. "|r"
end

local function ItemName(id)
	local name, _, quality = C_Item.GetItemInfo(id)
	if not name then
		C_Item.RequestLoadItemDataByID(id)
		return "item " .. id
	end
	local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
	return (color and color.hex or "|cffffffff") .. name .. "|r"
end

local function SourceText(o)
	if not o then return Grey("--") end
	if o.kind == "K" or o.kind == "S" then return "Known" end
	if o.kind == "T" then return "Trainer" .. (o.seen and "" or Grey("*")) end
	if o.kind == "A" then return "|cff40c0ffAH|r" end
	return ns.KIND_LABEL[o.kind] or o.kind
end

local function Age(t)
	local api = ns.MS()
	return t and api.FormatAge and api.FormatAge(t) or ""
end

--------------------------------------------------------------------------
-- Tooltips
--------------------------------------------------------------------------

local function OptionLine(o)
	if o.kind == "T" then
		return ("Trainer at %d: %s%s"):format(o.level or 0, Money(o.cost), o.seen and (o.npc and (" (" .. o.npc .. ")") or "") or Grey(" (from Wowhead -- open a trainer to confirm)"))
	elseif o.kind == "V" then
		local where = o.npc ~= "" and (o.npc .. (o.zone ~= "" and (", " .. o.zone) or "")) or "a vendor"
		local price = Money(o.cost)
		if o.token then
			price = (o.tokenCount or 1) .. "x " .. ItemName(o.token) .. (o.cost and o.cost > 0 and (" + " .. Money(o.cost)) or "")
		end
		return ("Vendor at %d: %s -- %s%s"):format(o.level or 0, price, where, o.limited and Grey(" (limited stock)") or "")
	elseif o.kind == "A" then
		return ("Auction House at %d: %s %s"):format(o.level or 0, Money(o.cost), Grey("(seen " .. Age(o.when) .. ")"))
	elseif o.kind == "D" then
		return ("Drop at %d: %s%s"):format(o.level or 0, o.text, o.zone ~= "" and (" (" .. o.zone .. ")") or "")
	elseif o.kind == "Q" then
		return ("Quest at %d: %s%s"):format(o.level or 0, o.text, o.zone ~= "" and (" (" .. o.zone .. ")") or "")
	elseif o.kind == "U" then
		return ("Skill %d: Wowhead doesn't say where this is learned yet"):format(o.level or 0)
	elseif o.kind == "S" or o.kind == "K" then
		return "You know this"
	end
	return o.kind
end

-- Hovering an item queues it for a MarketScribe scan when its AH price is too old
-- to use (older than Smart's price-age limit). The scan runs next time you open the AH.
local function QueueStale(id)
	local api = ns.MS()
	if not (api and api.QueueItemsForced and api.GetMarketPrice and id and id > 0) then return false end
	local price, when = api.GetMarketPrice(id)
	if not (price and when) then return false end
	if (time() - when) <= (ns.db.ahMaxAge or 3) * 86400 then return false end
	return api.QueueItemsForced({ id }) > 0
end

local function RecipeTooltip(row)
	if row.item then
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(row.item)
		if QueueStale(row.item) then
			GameTooltip:AddLine("Old AH price: queued for a MarketScribe scan (open the AH).", 0.4, 0.8, 1, true)
		end
		GameTooltip:Show()
		return
	end
	local e = row.eval
	if not e then return end
	local r = e.r
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(r[1], 1, 1, 1)
	if row.learn then
		GameTooltip:AddLine("Learn it first: " .. OptionLine(row.learn), 0.4, 0.8, 1, true)
	end
	GameTooltip:AddLine(("|cffff8040orange|r to %d, |cffffff00yellow|r to %d, |cff40bf40green|r to %d, grey from %d"):format(
		r[2], r[3], r[4], r[4]), 0.8, 0.8, 0.8)
	GameTooltip:AddLine(" ")
	local reag = r[8]
	for i = 1, #reag, 2 do
		local p, how = ns.ReagentPrice(reag[i])
		GameTooltip:AddDoubleLine(ItemName(reag[i]) .. " x" .. reag[i + 1],
			p and (Money(p * reag[i + 1]) .. (how == "smelt" and Grey(" (smelted)") or "")) or Grey("no price"), 1, 1, 1, 1, 1, 1)
	end
	GameTooltip:AddDoubleLine("Materials per craft", Money(e.mats) .. (e.missing and Grey(" (some unpriced)") or ""), 1, 0.82, 0, 1, 1, 1)
	if r[5] and r[5] > 0 then
		local v = e.value or {}
		GameTooltip:AddDoubleLine("Makes " .. ItemName(r[5]) .. ((r[6] or 1) ~= 1 and (" x" .. r[6]) or ""),
			"worth " .. Money(e.back) .. " per craft", 1, 1, 1, 0.8, 0.8, 0.8)
		GameTooltip:AddDoubleLine("   Vendor", Money(v.vendor or 0), 0.8, 0.8, 0.8, 1, 1, 1)
		if ns.db.planDE then
			GameTooltip:AddDoubleLine("   Disenchant", v.de and Money(v.de) or Grey("can't / no price"), 0.8, 0.8, 0.8, 1, 1, 1)
		end
		local api = ns.MS()
		local ah, when = api.GetMarketPrice and api.GetMarketPrice(r[5])
		local listed = api.GetListings and api.GetListings(r[5])
		local ahText = ah and (Money(ah * 0.95) .. Grey((" after cut, %s%s"):format(Age(when), listed and (", " .. listed .. " listed") or ""))) or Grey("no price")
		GameTooltip:AddDoubleLine("   AH", ahText, 0.8, 0.8, 0.8, 1, 1, 1)
		if ns.db.planOutput ~= "vendor" then
			if v.ah then
				if v.cap == math.huge then
					GameTooltip:AddLine("   Counting the AH price for every craft.", 0.5, 1, 0.5)
				else
					GameTooltip:AddLine(("   Smart: AH price for the first %d made%s%s, then %s."):format(v.cap,
						v.stack and (" (stacks of " .. v.stack .. ")") or "",
						v.crowded and " (halved: crowded AH)" or "", v.fallbackHow), 0.5, 1, 0.5, true)
				end
			elseif v.why then
				GameTooltip:AddLine("   Not using the AH price: " .. v.why .. ".", 1, 0.6, 0.4, true)
			end
		end
		if e.routeUnits then
			local how = v.fallbackHow == "disenchant" and "disenchanted" or "vendored"
			if (e.onAH or 0) > 0 then
				GameTooltip:AddLine(("   The route makes ~%d: ~%d sold on the AH, ~%d %s."):format(
					math.ceil(e.routeUnits), math.floor(e.onAH + 0.5), math.ceil(e.rest - 0.5), how), 0.4, 0.8, 1, true)
			else
				GameTooltip:AddLine(("   The route makes ~%d, all %s."):format(math.ceil(e.routeUnits), how), 0.4, 0.8, 1, true)
			end
		end
		if e.profit and not ns.db.noAH[r[5]] then
			GameTooltip:AddDoubleLine(e.bop and ("Bind on Pickup: " .. (e.value.fallbackHow or "vendor") .. " it") or "Selling it on the AH",
				(e.profit >= 0 and "|cff40ff40+" or "|cffff6060-") .. ns.MS().FormatMoney(math.abs(e.profit)) .. "|r per craft", 1, 1, 1, 1, 1, 1)
		end
	end
	if ns.db.excluded[e.id] then
		GameTooltip:AddLine("Excluded from the plan.", 1, 0.4, 0.4)
	end
	if r[5] and r[5] > 0 and ns.db.noAH[r[5]] then
		GameTooltip:AddLine("Not counting AH sales for this item.", 1, 0.4, 0.4)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("How to learn it:", 1, 0.82, 0)
	for _, o in ipairs(e.opts) do
		GameTooltip:AddLine(OptionLine(o), 1, 1, 1, true)
	end
	if e.best and not e.known then
		GameTooltip:AddLine("Cheapest: " .. OptionLine(e.best), 0.5, 1, 0.5, true)
	end
	local queued = 0
	if QueueStale(r[5]) then queued = queued + 1 end
	for i = 1, #reag, 2 do
		if QueueStale(reag[i]) then queued = queued + 1 end
	end
	if queued > 0 then
		GameTooltip:AddLine(("%d item%s with an old AH price queued for a MarketScribe scan (open the AH)."):format(queued, queued == 1 and "" or "s"), 0.4, 0.8, 1, true)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(MenuUtil and "Right-click: exclude options" or
		"Right-click: don't count AH sales  |  Shift+right-click: exclude recipe", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

--------------------------------------------------------------------------
-- Right-click: exclusions
--------------------------------------------------------------------------

local function ToggleNoAH(item)
	ns.db.noAH[item] = not ns.db.noAH[item] or nil
	ns.RefreshPlan()
end

local function ToggleExcluded(id)
	ns.db.excluded[id] = not ns.db.excluded[id] or nil
	ns.RefreshPlan()
end

local function ExcludeMenu(row)
	local e = row.eval
	if not e then return end
	local item = e.r[5] and e.r[5] > 0 and e.r[5] or nil
	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(row, function(_, root)
			root:CreateTitle(e.r[1])
			if item then
				root:CreateButton(ns.db.noAH[item] and "Count AH sales again" or "Don't count on AH sales",
					function() ToggleNoAH(item) end)
			end
			root:CreateButton(ns.db.excluded[e.id] and "Include recipe again" or "Exclude recipe from the plan",
				function() ToggleExcluded(e.id) end)
		end)
	elseif IsShiftKeyDown() or not item then
		ToggleExcluded(e.id)
	else
		ToggleNoAH(item)
	end
end

--------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------

-- column layouts: { width, justify } per column
local ROUTE = { { 56, "LEFT" }, { 196, "LEFT" }, { 46, "RIGHT" }, { 82, "RIGHT" }, { 70, "RIGHT" }, { 66, "RIGHT" }, { 72, "RIGHT" } }
local LEARN = { { 250, "LEFT" }, { 46, "RIGHT" }, { 74, "RIGHT" }, { 70, "RIGHT" }, { 70, "RIGHT" }, { 70, "RIGHT" } }
local SHOP = { { 236, "LEFT" }, { 60, "RIGHT" }, { 60, "RIGHT" }, { 60, "RIGHT" }, { 74, "RIGHT" }, { 98, "RIGHT" } }
local MAXCOLS = 7

local function Row(i)
	local row = rows[i]
	if row then return row end
	row = CreateFrame("Button", nil, scrollChild)
	row:SetSize(WIDTH - 50, ROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(0.5, 0.8, 1, 0.1)
	row.cols = {}
	for c = 1, MAXCOLS do
		local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetWordWrap(false)
		row.cols[c] = fs
	end
	row.wide = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.wide:SetPoint("LEFT", 4, 0)
	row.wide:SetPoint("RIGHT", -4, 0)
	row.wide:SetJustifyH("LEFT")
	row.wide:SetWordWrap(false)
	row:SetScript("OnEnter", RecipeTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			if self.eval then
				GameTooltip:Hide()
				ExcludeMenu(self)
			end
		elseif self.onClick then
			self.onClick()
		end
	end)
	rows[i] = row
	return row
end

local n
-- Put(text) for a full-width line, or Put(nil, cols, eval, layout, opts)
local function Put(text, cols, eval, layout, opts)
	n = n + 1
	local row = Row(n)
	row.eval = eval
	row.learn = opts and opts.learn
	row.item = opts and opts.item
	row.onClick = opts and opts.onClick
	row.bg:SetColorTexture(1, 1, 1, opts and opts.shade or 0)
	if cols then
		row.wide:SetText("")
		layout = layout or LEARN
		local x = 4
		for c = 1, MAXCOLS do
			local fs, l = row.cols[c], layout[c]
			if l then
				fs:ClearAllPoints()
				fs:SetPoint("LEFT", x, 0)
				fs:SetWidth(l[1] - 6)
				fs:SetJustifyH(l[2])
				fs:SetText(cols[c] or "")
				x = x + l[1]
			else
				fs:SetText("")
			end
		end
	else
		for c = 1, MAXCOLS do row.cols[c]:SetText("") end
		row.wide:SetText(text or "")
	end
	row:Show()
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local function MyProfessions()
	ns.ReadSkillLevels()
	local list = {}
	for skill, p in pairs(ns.Char().profs) do
		if p.has and ns.RECIPES[skill] then list[#list + 1] = skill end
	end
	table.sort(list, function(a, b) return ns.PROF_NAMES[a] < ns.PROF_NAMES[b] end)
	return list
end

function ns.RefreshPlan()
	if not (frame and frame:IsShown()) then return end
	local profs = MyProfessions()
	for i, b in ipairs(profButtons) do b:Hide() end
	for i, skill in ipairs(profs) do
		local b = profButtons[i]
		if not b then
			b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
			b:SetSize(104, 20)
			b:SetPoint("TOPLEFT", 12 + (i - 1) * 106, -28)
			profButtons[i] = b
		end
		b:SetText(ns.PROF_NAMES[skill])
		b:SetScript("OnClick", function() current = skill; ns.db.planProf = skill; ns.RefreshPlan() end)
		b:Show()
	end
	if not current or not ns.RECIPES[current] then
		current = ns.db.planProf
		if not (current and ns.Char().profs[current] and ns.Char().profs[current].has) then current = profs[1] end
	end
	for i, skill in ipairs(profs) do
		profButtons[i]:SetEnabled(skill ~= current)
	end
	outputBtn:SetText(OUTPUT_LABEL[ns.db.planOutput] or OUTPUT_LABEL.vendor)
	smeltBtn:SetText(ns.db.planSmelt == false and "Smelt bars: off" or "Smelt bars: on")
	deBtn:SetText(ns.db.planDE and "Disenchant: on" or "Disenchant: off")
	filterBtn:SetText(FILTER_LABEL[ns.db.planFilter or "all"])
	if current and ns.SPECS[current] then
		specBtn:SetText("Specialization: " .. (ns.SpecName(current) or "none"))
		specBtn:Show()
	else
		specBtn:Hide()
	end

	n = 0
	if not current then
		header:SetText("No profession found.")
		Put(Grey("Learn a profession, or open its window once."))
		for i = n + 1, #rows do rows[i]:Hide() end
		return
	end
	local ok, plan = pcall(ns.BuildPlan, current)
	if not ok then
		header:SetText("Error: " .. tostring(plan))
		for i = n + 1, #rows do rows[i]:Hide() end
		return
	end
	local name = ns.PROF_NAMES[current]
	header:SetText(("%s %d/%d"):format(name, plan.rank, plan.max))

	-- Route
	local bonus, bonusHow = ns.SkillUpBonus()
	if bonus > 0 then
		Put(("|cff40ff40Skill-up bonus +%d%%|r %s"):format(bonus * 100, Grey("(" .. bonusHow .. "; applied to yellow and green recipes, /sks bonus to change)")))
	end
	Put("|cffffd100Cheapest route to " .. plan.max .. "|r" .. Grey("  (value = what the crafts are worth to you; net = materials minus value; hover a row for details)"))
	if plan.lockedFrom and plan.lockedFrom < plan.rank then
		Put(Grey(("   Plan made at skill %d and kept as you level; only what's left is shown. Click Recalculate for a fresh one."):format(plan.lockedFrom)))
	end
	if ns.db.planOutput == "smart" then
		Put(Grey(("   Smart: AH price for the first %d of each item, or %d stacks of stackables (prices up to %d days old), then %s. Right-click a row to exclude it."):format(
			ns.db.ahCap, ns.db.ahStacks, ns.db.ahMaxAge, ns.db.planDE and "disenchant or vendor" or "vendor")))
	end
	if not plan.knownTime then
		Put("|cffff8040Open your " .. name .. " window once so SkillScribe knows which recipes you have.|r")
	end
	if plan.rank >= plan.max then
		Put("You're at your cap. Train the next rank (Journeyman, Expert, Artisan) at a " .. name .. " trainer to go further.")
	end
	if #plan.steps > 0 then
		Put(nil, { Grey("Skill"), Grey("Recipe"), Grey("Crafts"), Grey("Training"), Grey("Materials"), Grey("Value"), Grey("Net") }, nil, ROUTE)
	end
	local crafts = 0
	for i, st in ipairs(plan.steps) do
		local range = ("%d-%d"):format(st.from, st.to)
		local shade = (i % 2 == 0) and 0.04 or 0
		if st.id then
			local e = plan.recipes[st.id]
			local label = ns.RecipeColor(e.r, st.from) .. e.r[1] .. "|r"
			local training = ""
			if st.learn then
				local how = ({ T = "train", V = "vendor", A = "AH" })[st.learn.kind] or "learn"
				training = Signed(st.learn.cost) .. Grey(" " .. how)
			end
			crafts = crafts + st.crafts
			Put(nil, { range, label, ("~%d"):format(math.ceil(st.crafts)), training, Red(st.mats),
				(st.value or 0) > 0 and Green(st.value) or Grey("--"), Signed(st.cost) }, e, ROUTE,
				{ learn = st.learn, shade = shade })
		else
			Put(nil, { range, "|cffff6060no recipe with prices|r " .. Grey("(Scan Prices at the AH)") }, nil, ROUTE, { shade = shade })
		end
	end
	if #plan.steps > 0 then
		local all = plan.total + plan.learnTotal
		Put(nil, { "", "|cffffd100Total|r", ("~%d"):format(math.ceil(crafts)), Red(plan.learnTotal), Red(plan.matsTotal),
			Green(plan.valueTotal), Signed(plan.total) }, nil, ROUTE, { shade = 0.08 })
		Put(nil, { "", (all <= 0 and "|cffffd100Total earnings|r" or "|cffffd100Total price|r") .. Grey(" (net + training)"),
			"", "", "", "", Signed(all) }, nil, ROUTE, { shade = 0.08 })
	end

	-- Shopping list (open unless you close it)
	if #plan.steps > 0 then
		Put(" ")
		local shopOpen = ns.db.planShowShop ~= false
		local list, cost, unpriced = ns.ShoppingList(plan)
		Put((shopOpen and "|cffffd100[-]|r " or "|cffffd100[+]|r ") .. "|cffffd100Shopping list|r" ..
			Grey(("  (%s to buy%s -- click to %s)"):format(ns.MS().FormatMoney(cost), unpriced > 0 and (", " .. unpriced .. " unpriced") or "",
				shopOpen and "hide" or "show")), nil, nil, nil,
			{ onClick = function() ns.db.planShowShop = not shopOpen; ns.RefreshPlan() end })
		if shopOpen then
			Put(nil, { Grey("Item"), Grey("Need"), Grey("Have"), Grey("Buy"), Grey("Each"), Grey("Cost") }, nil, SHOP)
			for i, r in ipairs(list) do
				local name = ItemName(r.id)
				if r.into then name = name .. Grey(" > " .. (C_Item.GetItemInfo(r.into) or "bars")) end
				if r.made > 0 then name = name .. Grey((" (%d from your crafts)"):format(r.made)) end
				local buy
				if r.buy > 0 then
					buy = "|cffffffff" .. r.buy .. "|r"
				elseif r.smelted > 0 then
					buy = Grey("smelt " .. r.smelted)
				else
					buy = "|cff40ff400|r"
				end
				local each = r.price and (ns.MS().FormatMoney(r.price) .. (r.vendor and Grey(" v") or "")) or Grey("?")
				local line = (r.buy > 0 and r.price) and Red(r.price * r.buy) or (r.buy > 0 and Grey("?") or "")
				Put(nil, { name, tostring(r.need), r.have > 0 and ("|cff40ff40" .. r.have .. "|r") or Grey("0"), buy, each, line },
					nil, SHOP, { shade = (i % 2 == 0) and 0.04 or 0, item = r.id })
			end
			Put(nil, { "|cffffd100Total to buy|r", "", "", "", "", Red(cost) }, nil, SHOP, { shade = 0.08 })
			Put(Grey("   Crafts are rounded up per step and skill-ups are chance-based, so bring a few spare. Have = bags and bank. v = vendor price."))
			Put(Grey("   Items the route makes itself (like Cured Hides) are used for the later steps that need them, so keep them instead of selling."))
		end
	end

	-- Recipes to learn (collapsed unless you open it)
	Put(" ")
	local open = ns.db.planShowLearn
	Put((open and "|cffffd100[-]|r " or "|cffffd100[+]|r ") .. "|cffffd100Recipes you could learn|r" ..
		Grey(("  (%d -- click to %s)"):format(#plan.learn, open and "hide" or "show")), nil, nil, nil,
		{ onClick = function() ns.db.planShowLearn = not ns.db.planShowLearn; ns.RefreshPlan() end })
	filterBtn:SetShown(open and true or false)
	if open then
		Put(nil, { Grey("Recipe"), Grey("Skill"), Grey("Get it"), Grey("Learn"), Grey("Mats"), Grey("AH +/-") }, nil, LEARN)
		local filter = ns.db.planFilter or "all"
		local shown = 0
		for _, e in ipairs(plan.learn) do
			local pass = filter == "all"
			if not pass then
				for _, o in ipairs(e.opts) do
					if o.kind == filter then pass = true break end
				end
			end
			if pass then
				shown = shown + 1
				local o = e.best or e.opts[1]
				local nameText = ns.RecipeColor(e.r, plan.rank, e.learnLevel) .. e.r[1] .. "|r"
				if e.inPlan then nameText = "|cff40c0ff>|r " .. nameText end
				local profit = Grey("--")
				if e.r[5] and ns.db.noAH[e.r[5]] then
					profit = Grey("excluded")
				elseif e.profit then
					profit = (e.profit >= 0 and "|cff40ff40+" or "|cffff6060-") .. ns.MS().FormatMoney(math.abs(e.profit)) .. "|r"
						.. (e.bop and Grey(" BoP") or "")
				end
				Put(nil, { nameText, tostring(e.learnLevel), SourceText(o), (e.best and Money(e.best.cost)) or Grey("--"),
					e.missing and Grey("?") or Money(e.mats), profit }, e, LEARN)
			end
		end
		if shown == 0 then Put(Grey("   nothing here")) end
	end

	-- Excluded (collapsed unless you open it); right-click a row to undo
	local nEx = #plan.excluded + #plan.noAH
	if nEx > 0 then
		Put(" ")
		local exOpen = ns.db.planShowExcluded
		Put((exOpen and "|cffffd100[-]|r " or "|cffffd100[+]|r ") .. "|cffffd100Excluded|r" ..
			Grey(("  (%d -- click to %s, right-click a row to undo, /sks unexclude clears all)"):format(nEx, exOpen and "hide" or "show")), nil, nil, nil,
			{ onClick = function() ns.db.planShowExcluded = not ns.db.planShowExcluded; ns.RefreshPlan() end })
		if exOpen then
			for _, e in ipairs(plan.excluded) do
				Put(nil, { "|cffff6060x|r " .. e.r[1], "", Grey("recipe left out of the plan") }, e, LEARN)
			end
			for _, e in ipairs(plan.noAH) do
				Put(nil, { "|cffff8040$|r " .. ItemName(e.r[5]), "", Grey("AH sales not counted") }, e, LEARN)
			end
		end
	end

	for i = n + 1, #rows do rows[i]:Hide() end
	scrollChild:SetHeight(math.max(1, n * ROW_H))
	footer:SetText(Grey("|cffff6060red|r = cost   |cff40ff40+green|r = earnings   > = in the route   Trainer* = Wowhead's price until you visit a trainer   Data: Wowhead Forever " .. (ns.RECIPE_BUILD or "")))
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

local function Build()
	frame = CreateFrame("Frame", "SkillScribePlanFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		ns.db.planPos = { p, rp, x, y }
	end)
	tinsert(UISpecialFrames, "SkillScribePlanFrame")
	local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not frame.TitleText then title:SetPoint("TOP", 0, -5) end
	title:SetText("SkillScribe -- what to learn next")

	header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	header:SetPoint("TOPLEFT", 14, -54)

	outputBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	outputBtn:SetSize(130, 20)
	outputBtn:SetPoint("TOPRIGHT", -12, -52)
	outputBtn:SetScript("OnClick", function()
		local cur = ns.db.planOutput or "vendor"
		for i, m in ipairs(OUTPUT_ORDER) do
			if m == cur then ns.db.planOutput = OUTPUT_ORDER[i % #OUTPUT_ORDER + 1] break end
		end
		ns.RefreshPlan()
	end)
	outputBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("What happens to what you craft", 1, 1, 1)
		GameTooltip:AddLine("Click to switch. The route subtracts what each craft is worth to you:", nil, nil, nil, true)
		GameTooltip:AddLine("Vendor: the vendor price (or disenchanting, if that toggle is on and pays more).", 1, 1, 1, true)
		GameTooltip:AddLine("Sell on AH: the AH price after the 5% cut whenever it pays more, for every craft.", 1, 1, 1, true)
		GameTooltip:AddLine(("Smart: the best realistic option per item. The AH price counts only if it's under %d days old, and only for the first %d of each item, or %d full stacks of stackable items (half that if the AH was crowded); the rest are disenchanted or vendored. Bind-on-Pickup items never count the AH."):format(ns.db.ahMaxAge, ns.db.ahCap, ns.db.ahStacks), 1, 1, 1, true)
		GameTooltip:AddLine("Right-click any recipe row to stop counting its AH sales or leave it out of the plan.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	outputBtn:SetScript("OnLeave", GameTooltip_Hide)

	deBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	deBtn:SetSize(110, 20)
	deBtn:SetPoint("RIGHT", outputBtn, "LEFT", -4, 0)
	deBtn:SetScript("OnClick", function()
		ns.db.planDE = not ns.db.planDE
		ns.RefreshPlan()
	end)
	deBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Disenchant what you craft", 1, 1, 1)
		GameTooltip:AddLine("On: a craft that can be disenchanted is worth at least its expected disenchant value (MarketScribe's dust/essence prices), when that beats the vendor price. Needs an enchanter (you or an alt).", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	deBtn:SetScript("OnLeave", GameTooltip_Hide)

	smeltBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	smeltBtn:SetSize(110, 20)
	smeltBtn:SetScript("OnClick", function()
		ns.db.planSmelt = ns.db.planSmelt == false
		ns.RefreshPlan()
	end)
	smeltBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Smelt bars yourself", 1, 1, 1)
		GameTooltip:AddLine("On: bars cost whichever is cheaper, buying the bar or the ore (and coal) to smelt it, for every bar your Mining skill can smelt. Ore is priced at its AH value, since you could sell it instead.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	smeltBtn:SetScript("OnLeave", GameTooltip_Hide)

	filterBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	filterBtn:SetSize(110, 20)
	filterBtn:SetPoint("TOPRIGHT", -12, -28) -- the profession buttons' row

	specBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	specBtn:SetSize(170, 20)
	specBtn:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)
	specBtn:SetScript("OnClick", function()
		if not (current and ns.SPECS[current]) then return end
		local list, cur = ns.SPECS[current], ns.SpecOf(current)
		local nxt
		if not cur then nxt = list[1][1]
		else
			for i, sp in ipairs(list) do
				if sp[1] == cur then nxt = list[i + 1] and list[i + 1][1] break end
			end
		end
		ns.SetSpec(current, nxt)
		ns.RefreshPlan()
	end)
	specBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Specialization", 1, 1, 1)
		GameTooltip:AddLine("Click to cycle. Specialization recipes are taught only by that specialty's trainer, so the plan leaves them out until you pick one. Pick the one you have (or intend to take); it's remembered per character.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	specBtn:SetScript("OnLeave", GameTooltip_Hide)

	recalcBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	recalcBtn:SetSize(96, 20)
	recalcBtn:SetPoint("RIGHT", smeltBtn, "LEFT", -4, 0) -- the settings buttons' row
	recalcBtn:SetText("Recalculate")
	recalcBtn:SetScript("OnClick", function()
		ns.ResetPlanLock(current)
		ns.RefreshPlan()
	end)
	recalcBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Make a fresh plan", 1, 1, 1)
		GameTooltip:AddLine("The plan is kept as you level, so the shopping list stays the same and just counts down. Recalculate builds a new one from your current skill and today's prices. Changing a setting or an exclusion also makes a new plan.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	recalcBtn:SetScript("OnLeave", GameTooltip_Hide)
	smeltBtn:SetPoint("RIGHT", deBtn, "LEFT", -4, 0)
	filterBtn:SetScript("OnClick", function()
		local cur = ns.db.planFilter or "all"
		for i, f in ipairs(FILTERS) do
			if f == cur then ns.db.planFilter = FILTERS[i % #FILTERS + 1] break end
		end
		ns.RefreshPlan()
	end)
	filterBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Filter the recipe list by where you get it", 1, 1, 1)
		GameTooltip:Show()
	end)
	filterBtn:SetScript("OnLeave", GameTooltip_Hide)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -78)
	scroll:SetPoint("BOTTOMRIGHT", -30, 34)
	scrollChild = CreateFrame("Frame", nil, scroll)
	scrollChild:SetSize(WIDTH - 46, 1)
	scroll:SetScrollChild(scrollChild)

	footer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	footer:SetPoint("BOTTOMLEFT", 14, 12)
	footer:SetPoint("BOTTOMRIGHT", -14, 12)
	footer:SetJustifyH("LEFT")
	footer:SetWordWrap(true)

	local ticker
	frame:SetScript("OnShow", function()
		ns.RefreshPlan()
		ticker = C_Timer.NewTicker(5, ns.RefreshPlan) -- prices stream in during AH scans
	end)
	frame:SetScript("OnHide", function()
		if ticker then ticker:Cancel() ticker = nil end
	end)
	frame:Hide()
end

function ns.PlanVisible()
	return frame and frame:IsShown()
end

function ns.TogglePlan(skill)
	if not frame then Build() end
	if skill then current = skill end
	if frame:IsShown() and not skill then
		frame:Hide()
		return
	end
	frame:ClearAllPoints()
	local pos = ns.db.planPos
	if pos then
		frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		frame:SetPoint("CENTER")
	end
	frame:Show()
	ns.RefreshPlan()
end
