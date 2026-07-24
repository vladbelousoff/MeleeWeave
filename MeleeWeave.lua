--[[ ---------------------------------------------------------------------------
  MeleeWeave  --  a melee-weaving range scale for Hunters

  Runs on every current Classic flavour (Era/Anniversary, TBC, Wrath, Cata,
  Mists) and on retail; see the per-flavour .toc files.

  WHAT IT DOES
    Draws a horizontal bar that tells you how far your target is and, more
    importantly, WHEN to weave in a melee hit and step back out to shoot.

    Colour + fill behaviour (as requested):
      > 35 yd  -> RED,    bar full        (out of ranged range)
      10-35 yd -> BLUE,   bar full        (comfortable shooting range)
       5-10 yd -> YELLOW, bar shrinking   (closing in, approaching melee)
       0-5  yd -> GREEN,  bar shrinking   (melee range -- weave!)
    A vertical tick sits at the middle of the bar. That tick marks the 5 yd
    point: the transition from a ranged attack to a melee (close) one.

  HOW IT MEASURES DISTANCE
    No Classic API returns an exact distance. All we can ask is "is the target
    within X yards?" via IsItemInRange, using items whose range is known (the
    same trick LibRangeCheck uses; these items report range even if you don't
    own them), plus CheckInteractDistance for the ranges no item covers on
    older clients. We probe a ladder of ranges and estimate the distance from
    the tightest bracket that answers true. The bar snaps straight to each new
    bracket, so it always shows the current reading with no lag.

    Which probes exist depends on the client, so the ladder is built at login
    and each rung remembers the first probe that this client can actually
    answer. On Classic Era the ladder is coarser (fewer usable items), so the
    bar steps in bigger jumps -- the colour zones still work.

    LIMITATION: nothing can measure *below* 5 yards, so once you are in melee
    the bar shows the green "melee" state; it cannot slide smoothly to a literal
    0. The colour (green) is the signal that matters there.
--------------------------------------------------------------------------- ]]

local ADDON = "MeleeWeave"

------------------------------------------------------------------------------
-- Cross-version API shims
------------------------------------------------------------------------------
-- The bare globals were moved into C_Item on newer clients (retail 11.0,
-- Mists Classic) and removed from the global namespace there.
local IsItemInRange = (C_Item and C_Item.IsItemInRange) or _G.IsItemInRange
local GetItemInfo   = (C_Item and C_Item.GetItemInfo)   or _G.GetItemInfo

local IS_RETAIL = WOW_PROJECT_ID ~= nil
	and WOW_PROJECT_MAINLINE ~= nil
	and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE

------------------------------------------------------------------------------
-- Range probes
------------------------------------------------------------------------------
-- {yards, {candidate itemIDs}}. Several candidates per rung because the item
-- databases differ per expansion: an item the client does not know answers nil
-- forever and is skipped, so listing items from several expansions is safe.
local ITEM_PROBES = {
	{  5, { 8149, 22432, 15826, 17117, 22259, 37727 } }, -- Voodoo Charm, Devilsaur Barb, ...
	{  8, { 34368 } },                                   -- Attuned Crystal Cores
	{ 10, { 9606, 9618, 9619, 32321 } },                 -- Muisek Vessels, Sparrowhawk Net
	{ 15, { 33069 } },                                   -- Sturdy Rope
	{ 20, { 10645 } },                                   -- Gnomish Death Ray
	{ 25, { 24268 } },                                   -- Netherweave Net
	{ 30, {   835 } },                                   -- Large Rope Net
	{ 35, { 24269 } },                                   -- Heavy Netherweave Net
	{ 40, { 28767 } },                                   -- The Decapitator
}

-- CheckInteractDistance indices and their approximate yardage. These fill the
-- gaps on Classic Era, where almost no range items exist. Retail restricts the
-- API for hostile units (it just answers nil), so it is classic-only.
local INTERACT_PROBES = {
	{ 3,  8 }, -- Duel
	{ 4, 28 }, -- Follow
}

-- Interact distances scale with model size; these two races measure short.
local INTERACT_BY_RACE = {
	Tauren  = { [3] = 6, [4] = 25 },
	Scourge = { [3] = 7, [4] = 27 },
}

-- Zone colours (r, g, b)
local COLOR_RED    = { 0.90, 0.16, 0.16 }
local COLOR_BLUE   = { 0.18, 0.45, 0.95 }
local COLOR_YELLOW = { 0.96, 0.83, 0.16 }
local COLOR_GREEN  = { 0.18, 0.85, 0.24 }
local COLOR_IDLE   = { 0.40, 0.40, 0.40 }

local REFRESH   = 0     -- seconds between range probes (0 = every frame)

-- Text styling
local FONT_FACE = "Fonts\\FRIZQT__.TTF"
local FONT_SIZE = 12

------------------------------------------------------------------------------
-- Saved variables / defaults
------------------------------------------------------------------------------
local defaults = {
	point  = "CENTER",
	x      = 0,
	y      = -140,
	width  = 240,
	height = 26,
	locked = true,
	hidden = false,
}

------------------------------------------------------------------------------
-- Range probing
------------------------------------------------------------------------------

-- The ladder: rungs sorted near -> far. Each rung holds every probe that might
-- work on some client; the first one that ever answers is remembered.
local ladder = {}
local MAX_RANGE = 40

local function makeItemProbe(itemID)
	return function(unit)
		local r = IsItemInRange(itemID, unit)
		if r == nil then return nil end
		return r == true or r == 1
	end
end

local function makeInteractProbe(index)
	-- CheckInteractDistance cannot distinguish "out of range" from "cannot
	-- answer", so it never returns nil and is therefore never memoised --
	-- an item probe on the same rung must always get a chance to win.
	return function(unit)
		return CheckInteractDistance(unit, index) and true or false
	end
end

local function BuildLadder()
	local byRange, rungs = {}, {}

	local function rung(yards)
		local r = byRange[yards]
		if not r then
			r = { yards = yards, probes = {} }
			byRange[yards] = r
			rungs[#rungs + 1] = r
		end
		return r
	end

	if IsItemInRange then
		for i = 1, #ITEM_PROBES do
			local yards, ids = ITEM_PROBES[i][1], ITEM_PROBES[i][2]
			local r = rung(yards)
			for j = 1, #ids do
				r.probes[#r.probes + 1] = { fn = makeItemProbe(ids[j]), memo = true }
			end
		end
	end

	if not IS_RETAIL and CheckInteractDistance then
		local _, race = UnitRace("player")
		local override = INTERACT_BY_RACE[race]
		for i = 1, #INTERACT_PROBES do
			local index, yards = INTERACT_PROBES[i][1], INTERACT_PROBES[i][2]
			if override and override[index] then yards = override[index] end
			local r = rung(yards)
			r.probes[#r.probes + 1] = { fn = makeInteractProbe(index), memo = false }
		end
	end

	table.sort(rungs, function(a, b) return a.yards < b.yards end)
	ladder = rungs
	MAX_RANGE = rungs[#rungs] and rungs[#rungs].yards or 40
end

-- true / false / nil (= this rung cannot be answered on this client)
local function askRung(r, unit)
	if r.chosen then return r.chosen(unit) end
	for i = 1, #r.probes do
		local p = r.probes[i]
		local res = p.fn(unit)
		if res ~= nil then
			if p.memo then r.chosen = p.fn end
			return res
		end
	end
	return nil
end

-- Returns lower, upper bracket bounds (yards). upper == nil means "beyond the
-- ladder" (out of range). Returns nil,nil if nothing could be read at all.
local function probeDistance(unit)
	local lower, upper = 0, nil
	local gotAny = false
	for i = 1, #ladder do
		local res = askRung(ladder[i], unit)
		if res ~= nil then
			gotAny = true
			if res == true then
				upper = ladder[i].yards
				break -- smallest true bracket is the tightest upper bound
			else
				lower = ladder[i].yards -- confirmed farther than this
			end
		end
	end
	if not gotAny then return nil, nil end
	return lower, upper
end

------------------------------------------------------------------------------
-- Scale maths
------------------------------------------------------------------------------

-- Bar fill fraction (0..1) as a function of distance in yards.
--   d >= 10        -> 1.0 (full)
--   5  <= d < 10   -> 1.0 .. 0.5  (top half of the shrink; tick at 0.5 == 5yd)
--   0  <= d < 5    -> 0.5 .. 0.0  (bottom half)
local function fillForDistance(d)
	if d >= 10 then return 1.0 end
	if d >= 5  then return 0.5 + 0.5 * (d - 5) / 5 end
	if d < 0   then d = 0 end
	return 0.5 * (d / 5)
end

-- Zone colour as a function of distance in yards.
local function colorForDistance(d)
	if d > 35 then return COLOR_RED   end
	if d >= 10 then return COLOR_BLUE  end
	if d >= 5  then return COLOR_YELLOW end
	return COLOR_GREEN
end

local function statusForDistance(d)
	if d > 35 then return "OUT OF RANGE" end
	if d >= 10 then return "RANGED" end
	if d >= 5  then return "CLOSING" end
	return "MELEE"
end

------------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------------
local WHITE = "Interface\\Buttons\\WHITE8X8"

local UI = {}

local function BuildUI()
	local db = MeleeWeaveDB

	local f = CreateFrame("Frame", "MeleeWeaveFrame", UIParent)
	f:SetSize(db.width, db.height)
	f:SetPoint(db.point, UIParent, db.point, db.x, db.y)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(false)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) if not MeleeWeaveDB.locked then self:StartMoving() end end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint()
		MeleeWeaveDB.point, MeleeWeaveDB.x, MeleeWeaveDB.y = point, x, y
	end)

	-- Background
	local bg = f:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.55)

	-- Thin border (4 edges)
	local function edge()
		local t = f:CreateTexture(nil, "BORDER")
		t:SetColorTexture(0, 0, 0, 0.9)
		return t
	end
	local top, bottom, left, right = edge(), edge(), edge(), edge()
	top:SetPoint("TOPLEFT");     top:SetPoint("TOPRIGHT");       top:SetHeight(1)
	bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(1)
	left:SetPoint("TOPLEFT");    left:SetPoint("BOTTOMLEFT");    left:SetWidth(1)
	right:SetPoint("TOPRIGHT");  right:SetPoint("BOTTOMRIGHT");  right:SetWidth(1)

	-- The fill bar
	local bar = CreateFrame("StatusBar", nil, f)
	bar:SetPoint("TOPLEFT", 2, -2)
	bar:SetPoint("BOTTOMRIGHT", -2, 2)
	bar:SetStatusBarTexture(WHITE)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(1)

	-- Middle tick (5 yd transition) at 50% of the inner width.
	-- Parented to the bar so it draws ABOVE the bar's fill texture.
	local tick = bar:CreateTexture(nil, "OVERLAY")
	tick:SetColorTexture(1, 1, 1, 0.9)
	tick:SetWidth(2)
	tick:SetPoint("TOP", bar, "TOP", 0, 0)
	tick:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
	tick:SetPoint("CENTER", bar, "CENTER", 0, 0)

	-- Readable text: white with a thick black outline + drop shadow so it
	-- stays legible on top of any bar colour.
	local function styleText(fs)
		fs:SetFont(FONT_FACE, FONT_SIZE, "OUTLINE")
		fs:SetTextColor(1, 1, 1, 1)
		fs:SetShadowColor(0, 0, 0, 1)
		fs:SetShadowOffset(1, -1)
	end

	-- Distance text -- parented to the bar so it draws ABOVE the fill texture.
	local dist = bar:CreateFontString(nil, "OVERLAY")
	dist:SetPoint("LEFT", bar, "LEFT", 5, 0)
	dist:SetJustifyH("LEFT")
	styleText(dist)

	-- Status text
	local status = bar:CreateFontString(nil, "OVERLAY")
	status:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
	status:SetJustifyH("RIGHT")
	styleText(status)

	UI.frame  = f
	UI.bar    = bar
	UI.tick   = tick
	UI.dist   = dist
	UI.status = status

	-- animated state
	UI.fill = 1
	UI.r, UI.g, UI.b = COLOR_RED[1], COLOR_RED[2], COLOR_RED[3]
end

-- Lock only controls dragging; it never affects visibility.
local function ApplyLock()
	UI.frame:EnableMouse(not MeleeWeaveDB.locked)
end

-- Visibility is controlled solely by /mw show and /mw hide. A hidden frame
-- also stops running OnUpdate, so this doubles as the "off switch".
local function ApplyVisibility()
	if MeleeWeaveDB.hidden then
		UI.frame:Hide()
	else
		UI.frame:Show()
	end
end

------------------------------------------------------------------------------
-- Target validity + text
------------------------------------------------------------------------------
local function hasAttackableTarget()
	return UnitExists("target")
		and not UnitIsDeadOrGhost("target")
		and UnitCanAttack("player", "target")
end

local function bracketLabel(lower, upper)
	if upper == nil then return (">%d yd"):format(MAX_RANGE) end
	if lower == 0 then return ("0-%d yd"):format(upper) end
	return ("%d-%d yd"):format(lower, upper)
end

------------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------------
local acc = 0

local function Refresh()
	if not hasAttackableTarget() then
		UI.targetFill  = 1
		UI.targetColor = COLOR_IDLE
		UI.dist:SetText(ADDON)
		UI.status:SetText(MeleeWeaveDB.locked and "no target" or "drag to move")
		return
	end

	local lower, upper = probeDistance("target")
	local est
	if lower == nil then
		-- couldn't read (items not cached yet) -- treat as unknown/far
		est = MAX_RANGE + 5
		UI.dist:SetText("...")
		UI.status:SetText("")
	else
		if upper == nil then
			est = MAX_RANGE + 5 -- beyond ladder
		else
			est = (lower + upper) / 2
		end
		UI.dist:SetText(bracketLabel(lower, upper))
		UI.status:SetText(statusForDistance(est))
	end

	UI.targetFill  = fillForDistance(est)
	UI.targetColor = colorForDistance(est)
end

local function Animate()
	if not UI.targetFill then return end

	-- fill: snap straight to the new bracket
	UI.fill = UI.targetFill
	UI.bar:SetValue(UI.fill)

	-- colour: same, no blend
	local c = UI.targetColor
	if c then
		UI.r, UI.g, UI.b = c[1], c[2], c[3]
		UI.bar:SetStatusBarColor(UI.r, UI.g, UI.b)
	end
end

local function OnUpdate(self, elapsed)
	Animate()
	acc = acc + elapsed
	if acc < REFRESH then return end
	acc = 0
	Refresh()
end

------------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------------
local function say(msg) print("|cff33ff99" .. ADDON .. "|r: " .. msg) end

SLASH_MELEEWEAVE1 = "/mw"
SLASH_MELEEWEAVE2 = "/meleeweave"
SlashCmdList["MELEEWEAVE"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "lock" then
		MeleeWeaveDB.locked = true;  ApplyLock(); say("locked.")
	elseif msg == "unlock" then
		MeleeWeaveDB.locked = false; ApplyLock(); say("unlocked -- drag to move.")
	elseif msg == "show" then
		MeleeWeaveDB.hidden = false; ApplyVisibility(); say("shown.")
	elseif msg == "hide" then
		MeleeWeaveDB.hidden = true;  ApplyVisibility(); say("hidden -- /mw show to bring it back.")
	elseif msg == "toggle" then
		MeleeWeaveDB.hidden = not MeleeWeaveDB.hidden
		ApplyVisibility()
		say(MeleeWeaveDB.hidden and "hidden." or "shown.")
	elseif msg == "reset" then
		MeleeWeaveDB.point, MeleeWeaveDB.x, MeleeWeaveDB.y = defaults.point, defaults.x, defaults.y
		UI.frame:ClearAllPoints()
		UI.frame:SetPoint(defaults.point, UIParent, defaults.point, defaults.x, defaults.y)
		say("position reset.")
	else
		print("|cff33ff99" .. ADDON .. "|r commands:")
		print("  /mw show    - show the bar")
		print("  /mw hide    - hide the bar")
		print("  /mw toggle  - show/hide the bar")
		print("  /mw unlock  - move the bar")
		print("  /mw lock    - lock the bar in place")
		print("  /mw reset   - reset position")
	end
end

------------------------------------------------------------------------------
-- Bootstrap
------------------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		MeleeWeaveDB = MeleeWeaveDB or {}
		for k, v in pairs(defaults) do
			if MeleeWeaveDB[k] == nil then MeleeWeaveDB[k] = v end
		end
	elseif event == "PLAYER_LOGIN" then
		BuildLadder()
		BuildUI()
		ApplyLock()
		ApplyVisibility()
		-- Warm the item cache so range checks work immediately.
		if GetItemInfo then
			for i = 1, #ITEM_PROBES do
				local ids = ITEM_PROBES[i][2]
				for j = 1, #ids do GetItemInfo(ids[j]) end
			end
		end
		UI.frame:SetScript("OnUpdate", OnUpdate)
	end
end)
