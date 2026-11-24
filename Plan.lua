-- SkillScribe: Plan.lua
--
-- Works out what to learn next and the cheapest route to your skill cap,
-- using the bundled Forever recipe data (Recipes.lua, from Wowhead) and
-- MarketScribe prices.
--
--   Known recipes      saved per character whenever a profession window
--                      opens, so the plan works with the window closed.
--   Trainers           every trainer you open is read and saved (cost and
--                      required skill), which overrides the bundled data.
--   Learn costs        trainer cost, vendor price, or the recipe item's AH
--                      price from MarketScribe. Drops nobody has listed and
--                      quest rewards are shown but not planned with.
--
-- The route is greedy: start from what you know, then keep adding the
-- recipe whose savings over the skill range it covers beat its learning
-- cost by the most, until nothing pays for itself.

local addonName, ns = ...

local AH_CUT = 0.95
local BIG = 1e12

ns.PROF_IDS = {
	Alchemy = 171, Blacksmithing = 164, Enchanting = 333, Engineering = 202,
	Leatherworking = 165, Tailoring = 197, Cooking = 185, ["First Aid"] = 129, Mining = 186,
}
ns.PROF_NAMES = {}
for name, id in pairs(ns.PROF_IDS) do ns.PROF_NAMES[id] = name end

-- Wowhead Forever gives no yellow/green thresholds for ~55 recipes (stones,
-- rods, keys, leathers...): they arrive as 0/0. Taken literally the chance
-- runs from 0 to grey, i.e. ~3% per craft, and the plan asks for hundreds of
-- crafts. Estimate them from the grey level with the usual spacing (yellow 25
-- below grey, green 12 below). ns.RecipeGuessed[r] marks them.
ns.RecipeGuessed = {}
for _, byRecipe in pairs(ns.RECIPES or {}) do
	for _, r in pairs(byRecipe) do
		if (r[2] or 0) == 0 and (r[3] or 0) == 0 and (r[4] or 0) > 0 then
			r[2] = math.max(r[4] - 25, 1)
			r[3] = math.max(r[4] - 12, 1)
			ns.RecipeGuessed[r] = true
		end
	end
end

local function MS() return _G.MarketScribeAPI end

function ns.MySide()
	local f = UnitFactionGroup and UnitFactionGroup("player")
	return f == "Alliance" and "A" or (f == "Horde" and "H" or "B")
end
local function Str(i) return (i and ns.RSTR[i]) or "" end

--------------------------------------------------------------------------
-- Per-character saved state
--------------------------------------------------------------------------

local function CharKey()
	return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

function ns.Char()
	local db = ns.db
	db.chars = db.chars or {}
	local key = CharKey()
	db.chars[key] = db.chars[key] or { profs = {} }
	return db.chars[key]
end

local function Prof(skill)
	local c = ns.Char()
	c.profs[skill] = c.profs[skill] or { known = {} }
	return c.profs[skill]
end
ns.ProfState = Prof

-- name -> spellID per profession, for matching recipes and trainer lines by name
local byName = {}
local function NameIndex(skill)
	if byName[skill] then return byName[skill] end
	local t = {}
	for id, r in pairs(ns.RECIPES[skill] or {}) do
		t[r[1]] = id
	end
	byName[skill] = t
	return t
end

-- Skill levels for every profession you have, without needing its window.
-- Professions this character doesn't have (for example one saved from
-- someone else's linked window by 1.3.0 and earlier) are dropped.
function ns.ReadSkillLevels()
	local found = false
	local seen = {}
	if GetProfessions and GetProfessionInfo then
		local list = { GetProfessions() }
		for i = 1, 6 do
			local index = list[i]
			if index then
				local ok, name, _, rank, maxRank, _, _, skillLine = pcall(GetProfessionInfo, index)
				local id = ok and ((skillLine and ns.RECIPES[skillLine] and skillLine) or ns.PROF_IDS[name])
				if id then
					local p = Prof(id)
					p.rank, p.max, p.has = rank, maxRank, true
					seen[id] = true
					found = true
				end
			end
		end
	end
	if not found and GetNumSkillLines then
		for i = 1, GetNumSkillLines() do
			local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
			local id = not isHeader and ns.PROF_IDS[name]
			if id then
				local p = Prof(id)
				p.rank, p.max, p.has = rank, maxRank, true
				seen[id] = true
				found = true
			end
		end
	end
	-- Only prune when the game actually gave us a profession list, so a
	-- failed read never wipes real data.
	if found then
		local profs = ns.Char().profs
		for id in pairs(profs) do
			if not seen[id] then profs[id] = nil end
		end
	end
	return found
end

-- True when the open profession window is someone else's (a chat link,
-- a guild list or an NPC crafting window), not your own.
local function ForeignWindow()
	local api = C_TradeSkillUI
	if not api then return false end
	for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting", "IsTradeSkillGuildMember" }) do
		if api[fn] then
			local ok, yes = pcall(api[fn])
			if ok and yes then return true end
		end
	end
	return false
end
ns.ForeignWindow = ForeignWindow

-- Called when a profession window opens: remember what you know.
function ns.RecordKnown()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) then return end
	if ForeignWindow() then return end
	local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
	if not (ok and info and info.professionName) then return end
	local skill = ns.PROF_IDS[info.professionName]
	if not skill then return end
	local okIDs, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not (okIDs and ids and #ids > 0) then return end
	local p = Prof(skill)
	local names = NameIndex(skill)
	local known = {}
	for _, recipeID in ipairs(ids) do
		local r = C_TradeSkillUI.GetRecipeInfo(recipeID)
		if r and r.learned then
			if ns.RECIPES[skill] and ns.RECIPES[skill][recipeID] then
				known[recipeID] = true
			elseif r.name and names[r.name] then
				known[names[r.name]] = true
			end
		end
	end
	p.known, p.has, p.knownTime = known, true, time()
	if info.skillLevel then p.rank = info.skillLevel end
	if info.maxSkillLevel and info.maxSkillLevel > 0 then p.max = info.maxSkillLevel end
end

-- Called while a trainer window is open.
function ns.RecordTrainer()
	if not GetNumTrainerServices then return end
	ns.db.trainer = ns.db.trainer or {}
	local npc = UnitName("npc")
	local n = GetNumTrainerServices() or 0
	local saved = 0
	for i = 1, n do
		local name, _, category = GetTrainerServiceInfo(i)
		if name and category ~= "header" then
			local skillName, skillLevel = nil, nil
			if GetTrainerServiceSkillReq then
				skillName, skillLevel = GetTrainerServiceSkillReq(i)
			end
			local skill = skillName and ns.PROF_IDS[skillName]
			local candidates = skill and { skill } or {}
			if not skill then
				for id in pairs(ns.RECIPES) do candidates[#candidates + 1] = id end
			end
			for _, sk in ipairs(candidates) do
				local id = NameIndex(sk)[name]
				if id then
					local cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or nil
					ns.db.trainer[id] = { cost = cost, req = skillLevel, npc = npc, t = time() }
					saved = saved + 1
					break
				end
			end
		end
	end
	if saved > 0 then
		ns.ResetTrainerCoverage()
		if ns.ClearPlanCache then ns.ClearPlanCache() end
	end
	return saved
end

--------------------------------------------------------------------------
-- Prices
--------------------------------------------------------------------------

local function ItemPrice(id)
	local api = MS()
	return api and api.GetPrice and api.GetPrice(id)
end

local function VendorSell(id)
	local sell = select(11, C_Item.GetItemInfo(id))
	if sell == nil then C_Item.RequestLoadItemDataByID(id) end
	return sell
end

local function IsBoP(id)
	local bind = select(14, C_Item.GetItemInfo(id))
	return bind == 1
end

-- What one crafted item is worth, broken down by way of getting rid of it.
-- Crafts mode (ns.db.planOutput):
--   vendor   vendor price (or disenchant value, if the Disenchant toggle is on)
--   ah       the AH price after the 5% cut whenever it beats that, no limits
--   smart    like ah, but only for AH prices newer than ahMaxAge days, and
--            only for the first ahCap items of each kind in the route (half
--            that when the AH was crowded); the rest fall back to
--            disenchant/vendor
-- Items you right-clicked "don't count on AH sales" never get an AH value.
-- Returns a table:
--   { vendor, de, ah, fallback, fallbackHow, cap, why }
--   fallback = best of vendor and (if on) disenchant, per item
--   ah       = AH value per item if it may be used (nil otherwise)
--   cap      = how many items get the AH value (math.huge = all)
local function ItemValue(id)
	local v = { vendor = 0, fallback = 0, fallbackHow = "vendor" }
	if not id or id == 0 then return v end
	local db = ns.db
	local api = MS()
	v.vendor = VendorSell(id) or 0
	v.fallback = v.vendor
	if db.planDE and api and api.GetDisenchantEV then
		local noDE = api.IsNotDisenchantable and api.IsNotDisenchantable(id)
		local ev = not noDE and api.GetDisenchantEV(id)
		if ev and ev > 0 then
			v.de = ev
			if ev > v.fallback then v.fallback, v.fallbackHow = ev, "disenchant" end
		end
	end
	local mode = db.planOutput
	if mode ~= "ah" and mode ~= "smart" then return v end
	if db.noAH[id] then v.why = "excluded from AH" return v end
	if IsBoP(id) then v.why = "Bind on Pickup" return v end
	local ah, when = nil, nil
	if api and api.GetMarketPrice then ah, when = api.GetMarketPrice(id) end
	if not ah then v.why = "no AH price" return v end
	ah = ah * AH_CUT
	if ah <= v.fallback then v.why = "AH pays less" return v end
	if mode == "ah" then
		v.ah, v.cap = ah, math.huge
		return v
	end
	-- smart
	local maxAge = (db.ahMaxAge or 3) * 86400
	if when and (time() - when) > maxAge then v.why = "AH price too old" return v end
	-- stackables (stones, potions, bars...) sell by the stack: allow ahStacks
	-- full stacks; everything else ahCap items
	local cap = db.ahCap or 5
	local stack = select(8, C_Item.GetItemInfo(id))
	if stack and stack > 1 then
		cap = (db.ahStacks or 2) * stack
		v.stack = stack
	end
	local listed, listedAt = nil, nil
	if api.GetListings then listed, listedAt = api.GetListings(id) end
	if listed and listedAt and (time() - listedAt) <= maxAge then
		v.listed = listed
		if listed >= 4 * cap then
			cap = math.ceil(cap / 2)
			v.crowded = true
		end
	end
	if cap <= 0 then v.why = "AH cap is 0" return v end
	v.ah, v.cap = ah, cap
	return v
end
ns.ItemValue = ItemValue

-- Average value per item when `units` of it are made: the first `cap` go
-- to the AH, the rest to the fallback. Also returns how many go each way.
local function Blend(v, units)
	if not v.ah then return v.fallback, 0, units end
	units = math.max(units or 1, 1e-6)
	local onAH = math.min(units, v.cap)
	local rest = units - onAH
	return (onAH * v.ah + rest * v.fallback) / units, onAH, rest
end
ns.BlendValue = Blend

-- Old single-number API (vendor/AH/DE mode as one figure, no cap)
function ns.OutputValue(id)
	local v = ItemValue(id)
	if v.ah then return v.ah, "AH" end
	return v.fallback, v.fallbackHow
end

-- Bars you can smelt yourself: bar item -> smelting recipe, for the
-- smelting recipes your Mining skill allows.
local function SmeltRecipes()
	local out = {}
	local mining = ns.Char().profs[186]
	if not (ns.db.planSmelt ~= false and mining and mining.has and mining.rank) then return out end
	for id, r in pairs(ns.RECIPES[186] or {}) do
		local lvl = 999
		for _, s in ipairs(r[9]) do
			if (s[2] or 1) < lvl then lvl = s[2] or 1 end
		end
		if (mining.known and mining.known[id]) or lvl <= mining.rank then
			out[r[5]] = r
		end
	end
	return out
end

local smelt = {}

-- Price of one reagent: the cheaper of buying it and (if you smelt) making
-- it from ore. Returns price, "smelt" when smelting it is cheaper.
local function ReagentPrice(id, depth)
	local buy = ItemPrice(id)
	local r = smelt[id]
	if r and (depth or 0) < 3 then
		local total = 0
		for i = 1, #r[8], 2 do
			local p = ReagentPrice(r[8][i], (depth or 0) + 1)
			if not p then total = nil break end
			total = total + p * r[8][i + 1]
		end
		if total then
			total = total / (r[6] or 1)
			if not buy or total < buy then return total, "smelt" end
		end
	end
	return buy
end
ns.ReagentPrice = ReagentPrice

local function Count(id)
	local f = (C_Item and C_Item.GetItemCount) or GetItemCount
	return f and f(id, true) or 0 -- bags and bank
end

-- Shopping list for a plan: every reagent for the route's crafts (rounded
-- up per step), minus what earlier steps of the route make (e.g. the Cured
-- Medium Hides you craft for skill-ups feed the later recipes that use
-- them) and what's in your bags and bank. Bars that are cheaper to smelt
-- are broken down into their ore (and coal).
-- Returns a list of { id, need, made, have, buy, price, smeltInto, smelted } sorted by cost.
function ns.ShoppingList(plan)
	local rows, order = {}, {}
	local left = {} -- bag counts not yet used up
	local pool = {} -- items earlier steps of the route have made and nothing has used yet
	local function Row(id)
		local r = rows[id]
		if not r then
			r = { id = id, need = 0, made = 0, have = 0, buy = 0, smelted = 0 }
			rows[id] = r
			order[#order + 1] = r
			left[id] = Count(id)
		end
		return r
	end
	local function Need(id, qty, into, depth)
		if qty <= 0 then return end
		local r = Row(id)
		r.need = r.need + qty
		if into then r.into = into end
		local fromRoute = math.min(pool[id] or 0, qty)
		if fromRoute > 0 then
			pool[id] = pool[id] - fromRoute
			r.made = r.made + fromRoute
			qty = qty - fromRoute
			if qty <= 0 then return end
		end
		local use = math.min(left[id], qty)
		left[id] = left[id] - use
		r.have = r.have + use
		local rest = qty - use
		if rest <= 0 then return end
		local _, how = ReagentPrice(id)
		local sm = smelt[id]
		if how == "smelt" and sm and (depth or 0) < 3 then
			r.smelted = r.smelted + rest
			local runs = math.ceil(rest / (sm[6] or 1))
			for i = 1, #sm[8], 2 do
				Need(sm[8][i], runs * sm[8][i + 1], id, (depth or 0) + 1)
			end
		else
			r.buy = r.buy + rest
		end
	end
	for _, st in ipairs(plan.steps or {}) do
		if st.id then
			local e = plan.recipes[st.id]
			local crafts = math.ceil(st.crafts - 0.01)
			local reag = e.r[8]
			for i = 1, #reag, 2 do
				Need(reag[i], crafts * reag[i + 1])
			end
			-- what this step makes is there for the steps after it
			local out = e.r[5]
			if out and out ~= 0 then
				pool[out] = (pool[out] or 0) + crafts * (e.r[6] or 1) -- minimum yield, to be safe
			end
		end
	end
	local total, unpriced = 0, 0
	for _, r in ipairs(order) do
		r.price = ItemPrice(r.id)
		local api = MS()
		if api and api.GetPrice then
			local _, _, source = api.GetPrice(r.id)
			r.vendor = source == "vendor"
		end
		if r.buy > 0 then
			if r.price then total = total + r.price * r.buy else unpriced = unpriced + 1 end
		end
	end
	table.sort(order, function(a, b)
		local ac, bc = (a.price or 0) * a.buy, (b.price or 0) * b.buy
		if ac ~= bc then return ac > bc end
		return a.id < b.id
	end)
	return order, total, unpriced
end

local function MatsCost(r)
	local reag = r[8]
	local total, missing = 0, false
	for i = 1, #reag, 2 do
		local p = ReagentPrice(reag[i])
		if p then
			total = total + p * reag[i + 1]
		else
			missing = true
		end
	end
	return total, missing
end

-- Reagent cost of ONE crafted item (cost per craft / yield), for the item
-- tooltip. Smelts bars yourself when that's cheaper, like the plan does.
-- Returns cost, missing (true when a reagent has no price yet).
function ns.CraftCostPerItem(r)
	smelt = SmeltRecipes()
	local total, missing = MatsCost(r)
	local yield = r[6] or 1
	if yield <= 0 then yield = 1 end
	return total / yield, missing
end

--------------------------------------------------------------------------
-- How each recipe can be learned
--------------------------------------------------------------------------

local KIND_LABEL = { K = "Known", S = "Known", T = "Trainer", V = "Vendor", A = "AH", D = "Drop", Q = "Quest", U = "Unknown" }
ns.KIND_LABEL = KIND_LABEL

-- Wowhead lists a recipe as "learned from a trainer" without saying which
-- trainer, so specialization recipes (Dragonscale, Goblin and Gnomish
-- Engineering...) and other trainers' recipes look like ordinary trainer
-- recipes. Every trainer window you open is saved (ns.db.trainer), so we know
-- how far up each profession the trainers you have seen teach: a trainer
-- recipe at or below that level that none of them offered is NOT taught by
-- them, and the plan must not count on learning it there.
local idProf, maxSeen
local function TrainerCoverage()
	if not idProf then
		idProf = {}
		for skill, byRecipe in pairs(ns.RECIPES or {}) do
			for rid in pairs(byRecipe) do idProf[rid] = skill end
		end
	end
	if not maxSeen then
		maxSeen = {}
		-- Compare like with like: the Wowhead level of the highest trainer recipe
		-- a trainer has offered (the trainer's own requirement is on another scale).
		for rid in pairs((ns.db and ns.db.trainer) or {}) do
			local skill = idProf[rid]
			local r = skill and ns.RECIPES[skill][rid]
			if r then
				for _, src in ipairs(r[9]) do
					if src[1] == "T" and (src[2] or 0) > (maxSeen[skill] or 0) then maxSeen[skill] = src[2] end
				end
			end
		end
	end
	return idProf, maxSeen
end
function ns.ResetTrainerCoverage() maxSeen = nil end

-- Specialization recipes (Dragonscale/Elemental/Tribal Leatherworking, Goblin/Gnomish
-- Engineering). Wowhead's Forever data marks them with a "specialization" field; they are
-- taught by the specialty trainers, never by the ordinary profession trainers.
-- Source: wowhead.com/forever/spells/professions/{leatherworking,engineering}, 23 Nov 2026.
local SPEC_DEFS = {
	[10656]={10619, 10650, 19050, 19054, 19060, 19077, 19085, 19089, 19094, 19107, 20855, 22926, 23708, 24654, 24655},
	[10658]={10630, 10632, 16661, 16746, 19059, 19061, 19067, 19076, 19078, 19079, 19090, 19095, 19101, 20854, 22928, 23710, 26279},
	[10660]={10621, 10647, 16650, 16728, 19053, 19062, 19063, 19066, 19068, 19073, 19074, 19080, 19081, 19084, 19086, 19087, 19097, 19104, 20853, 22927, 23709},
	[20222]={8895, 12715, 12716, 12717, 12718, 12754, 12755, 12758, 12760, 12908, 13240, 15628, 23078, 23486},
	[20219]={12759, 12895, 12897, 12899, 12902, 12903, 12905, 12906, 12907, 15633, 23096, 23129, 23489},
}
local SPEC_RECIPES = {}
for sid, ids in pairs(SPEC_DEFS) do for _, rid in ipairs(ids) do SPEC_RECIPES[rid] = sid end end

-- Specializations a profession can take, in the order the button cycles through them.
ns.SPECS = {
	[165] = { { 10656, "Dragonscale" }, { 10658, "Elemental" }, { 10660, "Tribal" } },
	[202] = { { 20222, "Goblin" }, { 20219, "Gnomish" } },
}
function ns.SpecOf(prof)
	local c = ns.Char()
	return c.spec and c.spec[prof]
end
function ns.SpecName(prof)
	local sid = ns.SpecOf(prof)
	for _, sp in ipairs(ns.SPECS[prof] or {}) do if sp[1] == sid then return sp[2] end end
end
function ns.SetSpec(prof, sid)
	local c = ns.Char()
	c.spec = c.spec or {}
	c.spec[prof] = sid
	if ns.ClearPlanCache then ns.ClearPlanCache() end
	if ns.ResetPlanLock then ns.ResetPlanLock(prof) end
end

local function NotAtSeenTrainers(id, level)
	local prof, seen = TrainerCoverage()
	local skill = prof[id]
	if not skill then return false end
	if ns.db.trainer and ns.db.trainer[id] then return false end
	return seen[skill] ~= nil and (level or 0) <= seen[skill]
end

-- Returns the cheapest plannable way to learn it (or nil) and every way.
local function LearnOptions(id, r, known)
	local opts = {}
	if known[id] then
		opts[1] = { kind = "K", level = 1, cost = 0 }
		return opts[1], opts
	end
	local api = MS()
	local trainer = ns.db.trainer and ns.db.trainer[id]
	local mySide = ns.MySide()
	-- A specialization recipe is out of reach (by trainer, vendor pattern or AH pattern alike)
	-- unless you have that specialization, or the game has already shown you the recipe.
	local specOf = SPEC_RECIPES[id]
	local mine = specOf and ns.SpecOf((TrainerCoverage())[id])
	if specOf and specOf ~= mine and not trainer then
		local lvl = r[9][1] and r[9][1][2] or 0
		opts[1] = { kind = "U", level = lvl,
			note = mine and "needs another specialization" or "needs a specialization (choose one with the Specialization button)" }
		return nil, opts
	end
	for _, s in ipairs(r[9]) do
		local k = s[1]
		local side = (k == "V" and s[7]) or (k == "Q" and s[6]) or "B"
		if side ~= "B" and side ~= mySide then
			-- the other faction's vendor or quest
		elseif k == "S" then
			opts[#opts + 1] = { kind = "S", level = 1, cost = 0 }
		elseif k == "T" then
			if specOf and specOf == mine then
				opts[#opts + 1] = { kind = "T", level = (trainer and trainer.req) or s[2], cost = (trainer and trainer.cost) or s[3],
					seen = trainer ~= nil, npc = trainer and trainer.npc }
			elseif NotAtSeenTrainers(id, s[2]) then
				-- the trainers you've opened don't teach it (specialization or another trainer)
				opts[#opts + 1] = { kind = "U", level = s[2], note = "not taught by the trainers you have opened" }
			else
				opts[#opts + 1] = { kind = "T", level = (trainer and trainer.req) or s[2], cost = (trainer and trainer.cost) or s[3],
					seen = trainer ~= nil, npc = trainer and trainer.npc }
			end
		elseif k == "V" or k == "D" or k == "Q" then
			local item = s[3]
			if k == "V" then
				local token = s[8] and s[8] > 0 and s[8] or nil
				-- vendors that want tokens or reputation items can't be planned in gold
				opts[#opts + 1] = { kind = "V", level = s[2], cost = (not token and s[4] > 0) and s[4] or nil,
					item = item, npc = Str(s[5]), zone = Str(s[6]), token = token, tokenCount = s[9], limited = s[10] == 1 }
			else
				opts[#opts + 1] = { kind = k, level = s[2], item = item, text = Str(s[4]), zone = Str(s[5]) }
			end
			-- anything someone has listed on the AH can be bought there
			local ah, when = nil, nil
			if api and api.GetMarketPrice then ah, when = api.GetMarketPrice(item) end
			if ah then
				opts[#opts + 1] = { kind = "A", level = s[2], cost = ah, item = item, when = when }
			end
		elseif k == "U" then
			opts[#opts + 1] = { kind = "U", level = s[2] }
		end
	end
	local best
	for _, o in ipairs(opts) do
		if o.cost and (o.kind == "S" or o.kind == "T" or o.kind == "V" or o.kind == "A") then
			if not best or o.cost < best.cost then best = o end
		end
	end
	return best, opts
end

-- Skill-up chance at skill s (times points per skill-up when orange).
local function Chance(r, s)
	local y, g, gr = r[2], r[3], r[4]
	if s >= gr then return 0 end
	if s < y then return r[7] or 1 end
	if gr <= y then return 0 end
	local base = (gr - s) / (gr - y)
	return ns.ApplyBonus and ns.ApplyBonus(base) or base
end
ns.Chance = Chance

local function Color(r, s, learnLevel)
	if learnLevel and s < learnLevel then return "|cffff4040" end
	if s >= r[4] then return "|cff808080" end
	if s < r[2] then return "|cffff8040" end
	if s < r[3] then return "|cffffff00" end
	return "|cff40bf40"
end
ns.RecipeColor = Color

--------------------------------------------------------------------------
-- The plan
--------------------------------------------------------------------------

-- Smart's route search is the slow part, so its result is kept until
-- something it depends on changes: skill, settings, exclusions or prices.
local memo = {}
local function SearchKey(skill, S, T)
	local db = ns.db
	local parts = { skill, S, T, db.planDE and 1 or 0, db.planSmelt == false and 0 or 1, db.ahCap, db.ahStacks or 2, db.ahMaxAge }
	local ex = {}
	for id in pairs(db.excluded) do ex[#ex + 1] = id end
	for id in pairs(db.noAH) do ex[#ex + 1] = -id end
	table.sort(ex)
	parts[#parts + 1] = table.concat(ex, ",")
	-- price table fingerprint: how many prices, and the newest one
	local api = MS()
	local store = api and api.Store and api.Store()
	local n, newest = 0, 0
	if store then
		for _, p in pairs(store.prices) do
			n = n + 1
			if (p.time or 0) > newest then newest = p.time end
		end
		for _ in pairs(store.vendor) do n = n + 1 end
	end
	parts[#parts + 1] = n .. ":" .. newest
	-- recipes learned since, and item info (vendor prices) that loaded since
	local p = Prof(skill)
	parts[#parts + 1] = tostring(p.knownTime or 0)
	parts[#parts + 1] = ns.itemInfoTick or 0
	-- the age limit moves with the clock: recheck at least every hour
	parts[#parts + 1] = math.floor(time() / 3600)
	return table.concat(parts, "|")
end
function ns.ClearPlanCache() wipe(memo) end

-- Recalculate: forget the locked plan for a profession (or all of them)
function ns.ResetPlanLock(skill)
	wipe(memo)
	-- marked rather than removed, so the next build can still see which AH
	-- sales the old plan already used
	for sk, p in pairs(ns.Char().profs) do
		if (not skill or sk == skill) and p.lock then p.lock.force = true end
	end
end

-- Vendor prices come from item info, which loads in the background.
local infoFrame = CreateFrame("Frame")
infoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
infoFrame:SetScript("OnEvent", function() ns.itemInfoTick = (ns.itemInfoTick or 0) + 1 end)

-- Builds everything the Plan window shows for one profession.
function ns.BuildPlan(skill)
	local data = ns.RECIPES[skill]
	if not data then return nil end
	ns.ReadSkillLevels()
	local p = Prof(skill)
	local S = p.rank or 1
	local T = p.max or 75
	if T < S then T = S end
	local known = p.known or {}
	local excluded = ns.db.excluded or {}
	local mode = ns.db.planOutput
	smelt = SmeltRecipes()
	local plan = { skill = skill, rank = S, max = T, knownTime = p.knownTime, recipes = {}, steps = {}, learn = {}, excluded = {} }

	-- evaluate every recipe once
	-- In Smart mode a recipe whose output sells on the AH gets a second entry,
	-- its "AH batch": the same recipe valued at the AH price, but only for the
	-- levels its first few sales (the cap) can carry, starting where you can
	-- first make it. The normal entry is valued at vendor/disenchant. The route
	-- can use both, so it might make the first 40 stones for the AH and then
	-- switch to something else, which a single averaged value can't express.
	-- Entries are keyed by spellID (normal) or -spellID (AH batch).
	local evals = {}
	local api = MS()
	for id, r in pairs(data) do
		local best, opts = LearnOptions(id, r, known)
		local mats, missing = MatsCost(r)
		local v = ItemValue(r[5])
		local per = r[6] or 1
		local e = { key = id, id = id, r = r, best = best, opts = opts, mats = mats, missing = missing,
			known = known[id], excluded = excluded[id], value = v, per = per }
		local each = (v.ah and v.cap == math.huge) and v.ah or v.fallback
		e.back = each * per
		e.net = mats - e.back
		-- AH profit per craft (for the learn list). Bind on Pickup can't be
		-- sold there, so for those it's what crafting costs you: materials
		-- minus what a vendor (or disenchanting) gives back.
		if r[5] and r[5] > 0 and not missing then
			if IsBoP(r[5]) then
				e.profit = v.fallback * per - mats
				e.bop = true
			elseif api and api.GetMarketPrice then
				local ah = api.GetMarketPrice(r[5])
				if ah then e.profit = ah * AH_CUT * per - mats end
			end
		end
		evals[id] = e
		plan.recipes[id] = e
		if mode == "smart" and v.ah and v.cap ~= math.huge then
			evals[-id] = { key = -id, id = id, batch = true, r = r, best = best, opts = opts, mats = mats, missing = missing,
				known = known[id], excluded = excluded[id], value = v, per = per,
				back = v.ah * per, net = mats - v.ah * per }
		end
	end

	-- Levels each entry can carry, and its cost per point at each.
	local function CostArray(e)
		local arr = {}
		local from = math.max(S, (e.best and e.best.level) or 1)
		local units = 0
		for s = from, math.min(T, e.r[4]) - 1 do
			local c = Chance(e.r, s)
			if c > 0 then
				if e.batch then
					local u = e.per / c
					if units + u > e.value.cap then break end
					units = units + u
				end
				arr[s] = e.net / c
			end
		end
		return arr
	end
	local costs = {}
	for key, e in pairs(evals) do
		if e.best and not e.missing then costs[key] = CostArray(e) end
	end

	-- One greedy pass: start from what you know, then keep adding the entry
	-- whose savings over the levels it covers beat its learning cost by the
	-- most. `banned` (a spellID) leaves a recipe out, to try alternatives.
	local function Route(banned)
		local chosen, have = {}, {}
		local bestAt, bestBy = {}, {}
		local function Recompute()
			for s = S, T - 1 do bestAt[s], bestBy[s] = BIG, nil end
			for key in pairs(chosen) do
				for s, c in pairs(costs[key]) do
					if c < bestAt[s] then bestAt[s], bestBy[s] = c, key end
				end
			end
		end
		local function Usable(e)
			return costs[e.key] and not e.excluded and e.id ~= banned
		end
		for key, e in pairs(evals) do
			if Usable(e) and (e.known or e.best.kind == "S") then chosen[key] = true; have[e.id] = true end
		end
		Recompute()
		for _ = 1, 80 do
			local pick, pickValue
			for key, e in pairs(evals) do
				if not chosen[key] and Usable(e) then
					local saving = 0
					for s, c in pairs(costs[key]) do
						local cur = bestAt[s]
						if c < cur then
							saving = saving + (cur >= BIG and BIG or (cur - c))
						end
					end
					local value = saving - (have[e.id] and 0 or e.best.cost)
					if saving > 0 and value > 0 and (not pickValue or value > pickValue) then
						pick, pickValue = key, value
					end
				end
			end
			if not pick then break end
			chosen[pick] = true
			have[evals[pick].id] = true
			Recompute()
		end
		-- what it costs, learning included
		local total, learned = 0, {}
		for s = S, T - 1 do
			local key = bestBy[s]
			if key then
				local e = evals[key]
				total = total + bestAt[s]
				if not e.known and e.best.kind ~= "S" and not learned[e.id] then
					learned[e.id] = true
					total = total + (e.best.cost or 0)
				end
			else
				total = total + BIG
			end
		end
		return { at = bestAt, by = bestBy, total = total }
	end

	-- The greedy route can lock in a recipe that looks good early and miss a
	-- cheaper mix, so in Smart mode also try it without each recipe it uses
	-- (as if you'd excluded it) and keep the cheapest. Cached, since it's the
	-- slow part.
	local searchExtra = ""
	local function Search()
		local route
		local memoKey = mode == "smart" and (SearchKey(skill, S, T) .. "|" .. searchExtra)
		if memoKey and memo[memoKey] then return memo[memoKey] end
		route = Route()
		if mode == "smart" then
			for _ = 1, 2 do
				local before = route.total
				local ids, seen = {}, {}
				for s = S, T - 1 do
					local key = route.by[s]
					local id = key and evals[key].id
					if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
				end
				for _, id in ipairs(ids) do
					local alt = Route(id)
					if alt.total < route.total then route = alt end
				end
				if route.total >= before then break end
			end
			memo[memoKey] = route
		end
		return route
	end

	-- The plan is locked once made, so it doesn't shift as you level: which
	-- recipe covers each skill level is saved per character and profession,
	-- and later builds reuse it for the levels you have left (the shopping
	-- list then just counts down). Without this, every skill-up would give
	-- each recipe a fresh AH allowance from your new skill and keep
	-- stretching the plan. It's rebuilt when a setting, an exclusion or your
	-- cap changes, when a locked recipe can't be used any more, or when you
	-- click Recalculate (ns.ResetPlanLock).
	local db = ns.db
	local exl = {}
	for id in pairs(db.excluded) do exl[#exl + 1] = id end
	for id in pairs(db.noAH) do exl[#exl + 1] = -id end
	table.sort(exl)
	local sig = table.concat({ mode, db.planDE and 1 or 0, db.planSmelt == false and 0 or 1, db.ahCap or 5,
		db.ahStacks or 2, db.ahMaxAge or 3, T, table.concat(exl, ",") }, "|")
	local bestAt, bestBy
	local lock = p.lock
	if lock and not lock.force and lock.sig == sig and S >= (lock.from or 0) and S < T then
		bestAt, bestBy = {}, {}
		for s = S, T - 1 do
			local key = lock.by[s]
			local e = key and evals[key]
			local c = e and Chance(e.r, s) or 0
			if key and not (e and c > 0 and not e.excluded and e.best and not e.missing) then
				bestAt = nil -- that recipe can't be used here any more: make a new plan
				break
			end
			bestBy[s] = key
			bestAt[s] = key and (e.net / c) or BIG
		end
		if bestAt then plan.lockedFrom, plan.lockedAt = lock.from, lock.t end
	end
	if not bestAt then
		-- AH sales the old plan already used (the levels you've done since it
		-- was made) count against each item's allowance in the new plan, so
		-- a fresh plan doesn't offer the same 5 sales again. Forgotten after
		-- ahMaxAge days, like old prices.
		p.ahUsed = p.ahUsed or {}
		local now, maxAge = time(), (db.ahMaxAge or 3) * 86400
		for item, u in pairs(p.ahUsed) do
			if now - (u.t or 0) > maxAge then p.ahUsed[item] = nil end
		end
		if lock and lock.by and lock.from and S > lock.from then
			for s = lock.from, S - 1 do
				local key = lock.by[s]
				local r = key and key < 0 and data[-key]
				if r and r[5] and r[5] > 0 then
					local c = Chance(r, s)
					if c > 0 then
						local u = p.ahUsed[r[5]] or { n = 0 }
						u.n, u.t = u.n + (r[6] or 1) / c, now
						p.ahUsed[r[5]] = u
					end
				end
			end
		end
		local usedKey = {}
		for key, e in pairs(evals) do
			local u = e.batch and p.ahUsed[e.r[5]]
			if u then
				local left = e.value.cap - u.n
				if left < e.per then
					evals[key], costs[key] = nil, nil -- its AH allowance is used up
				else
					local v2 = {}
					for k, val in pairs(e.value) do v2[k] = val end
					v2.cap = left
					e.value = v2
					costs[key] = (e.best and not e.missing) and CostArray(e) or nil
				end
				usedKey[#usedKey + 1] = e.r[5] .. ":" .. math.floor(u.n)
			end
		end
		table.sort(usedKey)
		searchExtra = table.concat(usedKey, ",")
		local route = Search()
		bestAt, bestBy = route.at, route.by
		local by = {}
		for s = S, T - 1 do by[s] = bestBy[s] end
		p.lock = { by = by, sig = sig, from = S, t = time() }
		plan.lockedFrom, plan.lockedAt = S, p.lock.t
	end

	-- how many of each item the route makes, and how many go to the AH
	for s = S, T - 1 do
		local key = bestBy[s]
		if key then
			local e = evals[key]
			local real = evals[e.id]
			local u = e.per / Chance(e.r, s)
			real.routeUnits = (real.routeUnits or 0) + u
			if e.batch or (e.value.ah and e.value.cap == math.huge) then
				real.onAH = (real.onAH or 0) + u
			else
				real.rest = (real.rest or 0) + u
			end
		end
	end
	for _, e in pairs(evals) do
		if e.routeUnits then
			e.onAH, e.rest = e.onAH or 0, e.rest or 0
			-- average value per craft along the route, for the tooltip
			local ahV = e.value.ah or 0
			e.back = ((e.onAH * ahV + e.rest * e.value.fallback) / e.routeUnits) * e.per
			e.net = e.mats - e.back
		end
	end

	-- group consecutive levels using the same recipe into steps
	local total, learnTotal, matsTotal, valueTotal = 0, 0, 0, 0
	local learnedInPlan = {}
	local step
	for s = S, T - 1 do
		local key = bestBy[s]
		local e = key and evals[key]
		local id = e and e.id
		if not step or step.id ~= id then
			step = { id = id, from = s, to = s, crafts = 0, cost = 0 }
			plan.steps[#plan.steps + 1] = step
			if id and not e.known and e.best.kind ~= "S" and not learnedInPlan[id] then
				learnedInPlan[id] = true
				step.learn = e.best
				learnTotal = learnTotal + (e.best.cost or 0)
			end
		end
		step.to = s + 1
		if e then
			local c = Chance(e.r, s)
			local value = e.batch and (e.value.ah * e.per) or
				(((e.value.ah and e.value.cap == math.huge) and e.value.ah or e.value.fallback) * e.per)
			step.crafts = step.crafts + 1 / c
			step.cost = step.cost + bestAt[s]
			step.mats = (step.mats or 0) + e.mats / c
			step.value = (step.value or 0) + value / c
			if e.batch then step.onAH = (step.onAH or 0) + e.per / c end
			total = total + bestAt[s]
			matsTotal = matsTotal + e.mats / c
			valueTotal = valueTotal + value / c
		end
	end
	plan.total, plan.learnTotal = total, learnTotal
	plan.matsTotal, plan.valueTotal = matsTotal, valueTotal

	-- recipes worth knowing about: not known, still give points at your skill
	for id, e in pairs(plan.recipes) do
		if e.excluded then
			plan.excluded[#plan.excluded + 1] = e
		elseif not e.known and e.r[4] > S and #e.opts > 0 then
			local lvl
			for _, o in ipairs(e.opts) do
				if not lvl or (o.level or 0) < lvl then lvl = o.level or 0 end
			end
			e.learnLevel = lvl or 0
			if e.learnLevel <= T + 25 then
				e.inPlan = learnedInPlan[id]
				plan.learn[#plan.learn + 1] = e
			end
		end
	end
	table.sort(plan.learn, function(a, b)
		if a.learnLevel ~= b.learnLevel then return a.learnLevel < b.learnLevel end
		return a.r[1] < b.r[1]
	end)
	table.sort(plan.excluded, function(a, b) return a.r[1] < b.r[1] end)
	-- items in this profession you've marked "don't count on AH sales"
	plan.noAH = {}
	local seenItem = {}
	for _, e in pairs(plan.recipes) do
		local item = e.r[5]
		if item and item > 0 and ns.db.noAH[item] and not seenItem[item] then
			seenItem[item] = true
			plan.noAH[#plan.noAH + 1] = e
		end
	end
	table.sort(plan.noAH, function(a, b) return a.r[1] < b.r[1] end)
	return plan
end

--------------------------------------------------------------------------
-- Items MarketScribe's Scan Prices should also search for
--------------------------------------------------------------------------

-- Recipe items that might be on the AH, plus reagents with no price yet,
-- for recipes you could learn soon in each of your professions.
function ns.ExtraWatch()
	local out, seen = {}, {}
	local function Add(id)
		if id and id > 0 and not seen[id] then
			seen[id] = true
			out[#out + 1] = id
		end
	end
	if not ns.db then return out end
	local smeltAll = SmeltRecipes()
	for skill, p in pairs(ns.Char().profs) do
		local data = ns.RECIPES[skill]
		if data and p.has then
			local S, T = p.rank or 1, (p.max or 75)
			local known = p.known or {}
			for id, r in pairs(data) do
				if r[4] > S then
					local lvl, items = 999, {}
					for _, s in ipairs(r[9]) do
						if (s[2] or 1) < lvl then lvl = s[2] or 1 end
						if s[1] == "D" or s[1] == "Q" then items[#items + 1] = s[3] end
					end
					if known[id] or lvl <= T then
						if not known[id] then
							for _, item in ipairs(items) do Add(item) end
						end
						for i = 1, #r[8], 2 do
							local reag = r[8][i]
							if not ItemPrice(reag) then Add(reag) end
							-- the ore (and coal) for bars you can smelt
							local sm = smeltAll[reag]
							if sm then
								for j = 1, #sm[8], 2 do
									if not ItemPrice(sm[8][j]) then Add(sm[8][j]) end
								end
							end
						end
						if ns.db.planOutput == "ah" or ns.db.planOutput == "smart" then Add(r[5]) end
					end
				end
			end
		end
	end
	return out
end

-- Hand it to MarketScribe (its Scan Prices button and /ms scan use it)
local hook = CreateFrame("Frame")
hook:RegisterEvent("PLAYER_LOGIN")
hook:SetScript("OnEvent", function()
	local api = MS()
	if api then
		api.ExtraWatch = function()
			local ok, list = pcall(ns.ExtraWatch)
			return ok and list or {}
		end
	end
	C_Timer.After(3, function() pcall(ns.ReadSkillLevels) end)
end)
