-- SkillScribe: Disenchant.lua
--
-- A window (/sks de, or the "Disenchant" button above the profession
-- window) listing every green or blue weapon/armor piece in your bags:
--   - the big button disenchants the next one, one click per item
--   - left-click a row to disenchant that item instead
--   - right-click a row to mark it "keep" (to sell); kept items are skipped
--     and remembered by item
-- Underneath, everything you've disenchanted is tallied (this session and
-- all time): materials, what they'd sell for on the AH after the 5% cut,
-- and the average per disenchant.
--
-- Clicking runs "/cast Disenchant" + "/use <bag> <slot>" through a secure
-- button, so it only updates out of combat.

local addonName, ns = ...

local WIDTH, HEIGHT, ROW_H = 520, 560, 20
local AH_CUT = 0.95
local DISENCHANT = "Disenchant"

local frame, mainBtn, listChild, resultChild, statusText, sessionText, totalText
local rows, resultRows = {}, {}
local items = {} -- current bag scan
local dirty = true

local function MS() return _G.MarketScribeAPI end
local function Grey(s) return "|cff888888" .. s .. "|r" end
local function Money(c)
	if not c then return Grey("?") end
	return MS() and MS().FormatMoney(c) or tostring(c)
end

local function DB()
	local db = ns.db
	db.deKeep = db.deKeep or {}
	db.deLog = db.deLog or { total = { n = 0, items = {} }, session = { n = 0, items = {}, started = time() } }
	return db
end

local function Plain(v)
	if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
	return v
end

--------------------------------------------------------------------------
-- Bag scan
--------------------------------------------------------------------------

local function CanDisenchant(itemID, quality)
	if not itemID or not quality or quality < 2 or quality > 4 then return false end
	local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
	if classID ~= 2 and classID ~= 4 then return false end
	local api = MS()
	if api and api.IsNotDisenchantable and api.IsNotDisenchantable(itemID) then return false end
	return true
end

local function Scan()
	wipe(items)
	local db = DB()
	for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local id = info and Plain(info.itemID)
			if id and CanDisenchant(id, Plain(info.quality)) then
				local name, link, quality, ilvl = C_Item.GetItemInfo(info.hyperlink or id)
				local api = MS()
				local ev = api and api.GetDisenchantEV and api.GetDisenchantEV(id)
				local ah = api and api.GetMarketPrice and api.GetMarketPrice(id)
				items[#items + 1] = {
					bag = bag, slot = slot, id = id, link = info.hyperlink or link, name = name or ("item " .. id),
					quality = quality or info.quality, ilvl = ilvl or 0, icon = info.iconFileID,
					ev = ev, vendor = select(11, C_Item.GetItemInfo(id)), ah = ah, keep = db.deKeep[id] and true or false,
				}
			end
		end
	end
	-- items to disenchant first (by value), kept ones last
	table.sort(items, function(a, b)
		if a.keep ~= b.keep then return not a.keep end
		if (a.ev or 0) ~= (b.ev or 0) then return (a.ev or 0) > (b.ev or 0) end
		return a.name < b.name
	end)
	dirty = false
end

local function Next()
	for _, it in ipairs(items) do
		if not it.keep then return it end
	end
end

--------------------------------------------------------------------------
-- What was disenchanted, and what it gave
--------------------------------------------------------------------------

local pending -- { id, ilvl, quality, t } set when we start a disenchant

local function Macro(it)
	return ("/cast %s\n/use %d %d"):format(DISENCHANT, it.bag, it.slot)
end

local function Arm(button, it)
	-- secure attributes can't change in combat
	if InCombatLockdown() then return end
	if it then
		button:SetAttribute("type1", "macro")
		button:SetAttribute("macrotext1", Macro(it))
	else
		button:SetAttribute("type1", nil)
		button:SetAttribute("macrotext1", nil)
	end
	button.item = it
end

local function NoteStart(it)
	if it then pending = { id = it.id, ilvl = it.ilvl, quality = it.quality, ev = it.ev, t = GetTime() } end
end

local deCast = 0
local lootDone = false

local function Record(slots)
	local db = DB()
	local log = db.deLog
	for _, part in ipairs({ log.total, log.session }) do
		part.n = part.n + 1
		part.ev = (part.ev or 0) + (pending and pending.ev or 0)
		for id, qty in pairs(slots) do
			part.items[id] = (part.items[id] or 0) + qty
		end
	end
	pending = nil
end

local function OnLoot()
	if lootDone then return end
	if GetTime() - deCast > 6 then return end
	local slots, fromItem = {}, false
	for slot = 1, GetNumLootItems() or 0 do
		local link = GetLootSlotLink(slot)
		local id = link and tonumber(link:match("item:(%d+)"))
		if id then
			local _, _, qty = GetLootSlotInfo(slot)
			slots[id] = (slots[id] or 0) + (Plain(qty) or 1)
		end
		if GetLootSourceInfo then
			local guid = Plain((GetLootSourceInfo(slot)))
			if type(guid) == "string" and guid:find("^Item") then fromItem = true end
		end
	end
	if not next(slots) then return end
	if not fromItem and GetLootSourceInfo then return end
	lootDone = true
	deCast = 0
	Record(slots)
	if ns.RefreshDE then ns.RefreshDE() end
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

local function ItemTooltip(self)
	local it = self.item
	if not it then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if it.link then GameTooltip:SetHyperlink(it.link) else GameTooltip:SetItemByID(it.id) end
	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("Disenchant (expected)", Money(it.ev), 1, 0.82, 0, 1, 1, 1)
	if it.ah then GameTooltip:AddDoubleLine("AH price (after cut)", Money(it.ah * AH_CUT), 1, 0.82, 0, 1, 1, 1) end
	if it.vendor and it.vendor > 0 then GameTooltip:AddDoubleLine("Vendor price", Money(it.vendor), 1, 0.82, 0, 1, 1, 1) end
	GameTooltip:AddLine(it.keep and "Right-click: disenchant it again (unmark keep)" or "Left-click: disenchant   Right-click: keep it (to sell)", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function ItemRow(i)
	local row = rows[i]
	if row then return row end
	row = CreateFrame("Button", nil, listChild, "SecureActionButtonTemplate")
	row:SetSize(WIDTH - 50, ROW_H)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	row:RegisterForClicks("AnyUp", "AnyDown")
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(0.5, 0.8, 1, 0.12)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 2, 0)
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 22, 0)
	row.name:SetWidth(240)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.cols = {}
	local x = 266
	for c, w in ipairs({ 36, 70, 70, 70 }) do
		local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", x, 0)
		fs:SetWidth(w - 4)
		fs:SetJustifyH("RIGHT")
		row.cols[c] = fs
		x = x + w
	end
	row:SetScript("OnEnter", ItemTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide)
	-- left click is the secure macro; right click (and recording) happens here
	row:SetScript("PreClick", function(self, button, down)
		if button == "LeftButton" and down then NoteStart(self.item) end
	end)
	row:SetScript("PostClick", function(self, button, down)
		if button == "RightButton" and not down and self.item then
			local db = DB()
			db.deKeep[self.item.id] = (not db.deKeep[self.item.id]) or nil
			dirty = true
			ns.RefreshDE()
		end
	end)
	rows[i] = row
	return row
end

local function ResultRow(i)
	local row = resultRows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, resultChild)
	row:SetSize(WIDTH - 50, 16)
	row:SetPoint("TOPLEFT", 0, -(i - 1) * 16)
	row.a = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.a:SetPoint("LEFT", 4, 0)
	row.a:SetWidth(260)
	row.a:SetJustifyH("LEFT")
	row.b = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.b:SetPoint("LEFT", 266, 0)
	row.b:SetWidth(100)
	row.b:SetJustifyH("RIGHT")
	row.c = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.c:SetPoint("LEFT", 370, 0)
	row.c:SetWidth(96)
	row.c:SetJustifyH("RIGHT")
	resultRows[i] = row
	return row
end

-- AH value (after the cut) of a set of materials
local function Value(list)
	local api, total, missing = MS(), 0, 0
	for id, qty in pairs(list) do
		local p = api and api.GetPrice and api.GetPrice(id)
		if p then total = total + p * AH_CUT * qty else missing = missing + 1 end
	end
	return total, missing
end

local function Summary(part)
	local v, missing = Value(part.items)
	if part.n == 0 then return Grey("nothing yet") end
	local expected = (part.ev or 0) > 0 and Grey((", expected %s"):format(Money(part.ev))) or ""
	return ("%d disenchants: |cff40ff40%s|r (|cff40ff40%s|r each%s)%s"):format(part.n, Money(v), Money(v / part.n), expected,
		missing > 0 and Grey((" -- %d material(s) unpriced"):format(missing)) or "")
end

function ns.RefreshDE()
	if not (frame and frame:IsShown()) then return end
	if InCombatLockdown() then
		statusText:SetText("|cffff6060In combat -- the list updates when combat ends.|r")
		return
	end
	if dirty then Scan() end
	local known = IsPlayerSpell and IsPlayerSpell(13262) or (C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(DISENCHANT) ~= nil)

	-- item rows
	local evSum, count = 0, 0
	for i, it in ipairs(items) do
		local row = ItemRow(i)
		Arm(row, it.keep and nil or it)
		row.item = it
		row.icon:SetTexture(it.icon)
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality or 2]
		row.name:SetText((it.keep and Grey("[keep] ") or "") .. (color and color.hex or "") .. it.name .. "|r")
		row.icon:SetDesaturated(it.keep)
		row.cols[1]:SetText(tostring(it.ilvl))
		row.cols[2]:SetText(it.ev and ("|cff40ff40" .. Money(it.ev) .. "|r") or Grey("?"))
		row.cols[3]:SetText(it.ah and Money(it.ah * AH_CUT) or Grey("--"))
		row.cols[4]:SetText(it.vendor and it.vendor > 0 and Money(it.vendor) or Grey("--"))
		row:Show()
		if not it.keep then
			count = count + 1
			evSum = evSum + (it.ev or 0)
		end
	end
	for i = #items + 1, #rows do
		Arm(rows[i], nil)
		rows[i]:Hide()
	end
	listChild:SetHeight(math.max(1, #items * ROW_H))

	local nxt = Next()
	Arm(mainBtn, nxt)
	if not known then
		mainBtn:SetText("You don't know Disenchant")
		mainBtn:Disable()
	elseif nxt then
		mainBtn:SetText(("Disenchant %s  (%d left)"):format(nxt.name, count))
		mainBtn:Enable()
	else
		mainBtn:SetText("Nothing to disenchant")
		mainBtn:Disable()
	end
	statusText:SetText(("%d to disenchant, expected |cff40ff40%s|r in materials"):format(count, Money(evSum)) ..
		Grey("   (right-click an item to keep it)"))

	-- results
	local log = DB().deLog
	sessionText:SetText("|cffffd100This session|r  " .. Summary(log.session))
	totalText:SetText("|cffffd100All time|r  " .. Summary(log.total))
	local mats = {}
	for id, qty in pairs(log.session.items) do mats[#mats + 1] = { id = id, qty = qty } end
	local api = MS()
	for _, m in ipairs(mats) do
		local p = api and api.GetPrice and api.GetPrice(m.id)
		m.value = p and p * AH_CUT * m.qty
	end
	table.sort(mats, function(a, b) return (a.value or 0) > (b.value or 0) end)
	for i, m in ipairs(mats) do
		local row = ResultRow(i)
		local name, _, quality = C_Item.GetItemInfo(m.id)
		if not name then C_Item.RequestLoadItemDataByID(m.id) end
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
		row.a:SetText((color and color.hex or "") .. (name or ("item " .. m.id)) .. "|r")
		row.b:SetText("x" .. m.qty)
		row.c:SetText(m.value and ("|cff40ff40" .. Money(m.value) .. "|r") or Grey("no price"))
		row:Show()
	end
	if #mats == 0 then
		local row = ResultRow(1)
		row.a:SetText(Grey("Materials from this session's disenchants show up here."))
		row.b:SetText("")
		row.c:SetText("")
		row:Show()
	end
	for i = math.max(#mats, 1) + 1, #resultRows do resultRows[i]:Hide() end
	resultChild:SetHeight(math.max(1, math.max(#mats, 1) * 16))
end

local function Header(parent, y, labels)
	local x = 266
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", 36, y)
	fs:SetText(labels[1])
	for c, w in ipairs({ 36, 70, 70, 70 }) do
		local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		h:SetPoint("TOPLEFT", 14 + x, y)
		h:SetWidth(w - 4)
		h:SetJustifyH("RIGHT")
		h:SetText(labels[c + 1])
		x = x + w
	end
end

local function Build()
	frame = CreateFrame("Frame", "SkillScribeDEFrame", UIParent, "BasicFrameTemplateWithInset")
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
		ns.db.dePos = { p, rp, x, y }
	end)
	tinsert(UISpecialFrames, "SkillScribeDEFrame")
	local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not frame.TitleText then title:SetPoint("TOP", 0, -5) end
	title:SetText("SkillScribe -- Disenchant")

	mainBtn = CreateFrame("Button", "SkillScribeDEButton", frame, "SecureActionButtonTemplate,UIPanelButtonTemplate")
	mainBtn:SetSize(WIDTH - 28, 28)
	mainBtn:SetPoint("TOP", 0, -30)
	mainBtn:RegisterForClicks("AnyUp", "AnyDown")
	mainBtn:SetScript("PreClick", function(self, button, down)
		if down then NoteStart(self.item) end
	end)
	mainBtn:SetScript("OnEnter", ItemTooltip)
	mainBtn:SetScript("OnLeave", GameTooltip_Hide)

	statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statusText:SetPoint("TOPLEFT", 14, -64)

	Header(frame, -82, { "Item", "ilvl", "Disenchant", "AH", "Vendor" })

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -96)
	scroll:SetPoint("TOPRIGHT", -30, -96)
	scroll:SetHeight(220)
	listChild = CreateFrame("Frame", nil, scroll)
	listChild:SetSize(WIDTH - 46, 1)
	scroll:SetScrollChild(listChild)

	sessionText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sessionText:SetPoint("TOPLEFT", 14, -326)
	sessionText:SetWidth(WIDTH - 120)
	sessionText:SetJustifyH("LEFT")
	totalText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	totalText:SetPoint("TOPLEFT", sessionText, "BOTTOMLEFT", 0, -4)
	totalText:SetWidth(WIDTH - 40)
	totalText:SetJustifyH("LEFT")

	local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	reset:SetSize(90, 18)
	reset:SetPoint("TOPRIGHT", -12, -322)
	reset:SetText("New session")
	reset:GetFontString():SetFontObject("GameFontNormalSmall")
	reset:SetScript("OnClick", function()
		DB().deLog.session = { n = 0, items = {}, started = time() }
		ns.RefreshDE()
	end)

	local matsHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	matsHeader:SetPoint("TOPLEFT", 14, -362)
	matsHeader:SetText("Materials this session" .. Grey("  (value = AH price after the 5% cut)"))

	local rscroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	rscroll:SetPoint("TOPLEFT", 10, -378)
	rscroll:SetPoint("BOTTOMRIGHT", -30, 12)
	resultChild = CreateFrame("Frame", nil, rscroll)
	resultChild:SetSize(WIDTH - 46, 1)
	rscroll:SetScrollChild(resultChild)

	frame:SetScript("OnShow", function()
		dirty = true
		ns.RefreshDE()
	end)
	frame:Hide()
end

function ns.ToggleDE()
	if InCombatLockdown() then
		ns.Print("can't open the disenchant window in combat.")
		return
	end
	if not frame then Build() end
	if frame:IsShown() then
		frame:Hide()
		return
	end
	frame:ClearAllPoints()
	local pos = ns.db.dePos
	if pos then
		frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		frame:SetPoint("CENTER", 200, 0)
	end
	frame:Show()
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:RegisterEvent("LOOT_READY")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_CLOSED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
local refreshQueued
ev:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		spellID = Plain(spellID)
		if unit == "player" and spellID and (spellID == 13262 or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) == DISENCHANT)) then
			deCast = GetTime()
		end
		return
	elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
		pcall(OnLoot)
		return
	elseif event == "LOOT_CLOSED" then
		lootDone = false
		return
	end
	if not (frame and frame:IsShown()) then return end
	if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_REGEN_ENABLED" then dirty = true end
	if refreshQueued then return end
	refreshQueued = true
	C_Timer.After(0.3, function()
		refreshQueued = nil
		ns.RefreshDE()
	end)
end)
