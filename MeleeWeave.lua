--[[ ---------------------------------------------------------------------------
  MeleeWeave  --  a melee-weaving range scale for Hunters (TBC Classic 2.5.x)

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
    The TBC Classic API has NO exact-distance function. All we can ask is
    "is the target within X yards?" via IsItemInRange, using items whose range
    is known (the same trick LibRangeCheck uses; these items report range even
    if you don't own them). We probe a ladder of ranges and estimate the
    distance from the tightest bracket that answers true. The bar is then
    animated smoothly between brackets so it reads like a continuous scale.

    LIMITATION: nothing can measure *below* 5 yards, so once you are in melee
    the bar shows the green "melee" state; it cannot slide smoothly to a literal
    0. The colour (green) is the signal that matters there.
--------------------------------------------------------------------------- ]]

local ADDON = "MeleeWeave"

-- Range ladder: {yards, itemID}. IsItemInRange(itemID, unit) answers whether
-- the target is within that item's range. Items chosen because they report a
-- stable range without needing to be in your bags (LibRangeCheck harm items).
local RANGES = {
	{  5, 37727 }, -- Ruby Acorn
	{  8, 34368 }, -- Attuned Crystal Cores
	{ 10, 32321 }, -- Sparrowhawk Net
	{ 15, 33069 }, -- Sturdy Rope
	{ 20, 10645 }, -- Gnomish Death Ray
	{ 25, 24268 }, -- Netherweave Net
	{ 30,   835 }, -- Large Rope Net
	{ 35, 24269 }, -- Heavy Netherweave Net
	{ 40, 28767 }, -- The Decapitator
}

-- Zone colours (r, g, b)
local COLOR_RED    = { 0.90, 0.16, 0.16 }
local COLOR_BLUE   = { 0.18, 0.45, 0.95 }
local COLOR_YELLOW = { 0.96, 0.83, 0.16 }
local COLOR_GREEN  = { 0.18, 0.85, 0.24 }

local REFRESH   = 0.10  -- seconds between range probes
local ANIM_FILL = 14    -- bar-fill lerp speed
local ANIM_COL  = 12    -- colour lerp speed

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
}

------------------------------------------------------------------------------
-- Range probing
------------------------------------------------------------------------------

-- Normalise IsItemInRange return (true/1 = in, false/0 = out, nil = unknown)
local function itemInRange(itemID, unit)
	local r = IsItemInRange(itemID, unit)
	if r == nil then return nil end
	if r == true or r == 1 then return true end
	return false
end

-- Returns lower, upper bracket bounds (yards). upper == nil means "beyond the
-- ladder" (out of range). Returns nil,nil if nothing could be read at all.
local function probeDistance(unit)
	local lower, upper = 0, nil
	local gotAny = false
	for i = 1, #RANGES do
		local yards, itemID = RANGES[i][1], RANGES[i][2]
		local res = itemInRange(itemID, unit)
		if res ~= nil then
			gotAny = true
			if res == true then
				if upper == nil then upper = yards end
				break -- smallest true bracket is the tightest upper bound
			else
				lower = yards -- confirmed farther than this
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

	-- Middle tick (5 yd transition) at 50% of the inner width
	local tick = f:CreateTexture(nil, "OVERLAY")
	tick:SetColorTexture(1, 1, 1, 0.9)
	tick:SetWidth(2)
	tick:SetPoint("TOP", bar, "TOP", 0, 0)
	tick:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
	tick:SetPoint("CENTER", bar, "CENTER", 0, 0)

	-- Distance text
	local dist = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dist:SetPoint("LEFT", bar, "LEFT", 5, 0)
	dist:SetJustifyH("LEFT")

	-- Status text
	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
	status:SetJustifyH("RIGHT")

	UI.frame  = f
	UI.bar    = bar
	UI.tick   = tick
	UI.dist   = dist
	UI.status = status

	-- animated state
	UI.fill = 1
	UI.r, UI.g, UI.b = COLOR_RED[1], COLOR_RED[2], COLOR_RED[3]
end

local function ApplyLock()
	local locked = MeleeWeaveDB.locked
	UI.frame:EnableMouse(not locked)
	if locked then
		-- normal operation; visibility handled per-frame
	else
		-- show a placeholder so it can be dragged
		UI.frame:SetAlpha(1)
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
	if upper == nil then return ">40 yd" end
	if lower == 0 then return ("0-%d yd"):format(upper) end
	return ("%d-%d yd"):format(lower, upper)
end

------------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------------
local acc = 0

local function Refresh()
	local unlocked = not MeleeWeaveDB.locked

	if not hasAttackableTarget() then
		if unlocked then
			-- placeholder while positioning
			UI.frame:SetAlpha(1)
			UI.targetFill = 1
			UI.targetColor = { 0.4, 0.4, 0.4 }
			UI.dist:SetText("MeleeWeave")
			UI.status:SetText("no target")
		else
			UI.frame:SetAlpha(0)
		end
		return
	end

	UI.frame:SetAlpha(1)

	local lower, upper = probeDistance("target")
	local est
	if lower == nil then
		-- couldn't read (items not cached yet) -- treat as unknown/far
		est = 45
		UI.dist:SetText("...")
		UI.status:SetText("")
	else
		if upper == nil then
			est = 45 -- beyond ladder
		else
			est = (lower + upper) / 2
		end
		UI.dist:SetText(bracketLabel(lower, upper))
		UI.status:SetText(statusForDistance(est))
	end

	UI.targetFill  = fillForDistance(est)
	UI.targetColor = colorForDistance(est)
end

local function Animate(elapsed)
	if not UI.targetFill then return end

	-- fill lerp
	local step = math.min(elapsed * ANIM_FILL, 1)
	UI.fill = UI.fill + (UI.targetFill - UI.fill) * step
	UI.bar:SetValue(UI.fill)

	-- colour lerp
	local c = UI.targetColor
	if c then
		local cstep = math.min(elapsed * ANIM_COL, 1)
		UI.r = UI.r + (c[1] - UI.r) * cstep
		UI.g = UI.g + (c[2] - UI.g) * cstep
		UI.b = UI.b + (c[3] - UI.b) * cstep
		UI.bar:SetStatusBarColor(UI.r, UI.g, UI.b)
	end
end

local function OnUpdate(self, elapsed)
	Animate(elapsed)
	acc = acc + elapsed
	if acc < REFRESH then return end
	acc = 0
	Refresh()
end

------------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------------
SLASH_MELEEWEAVE1 = "/mw"
SLASH_MELEEWEAVE2 = "/meleeweave"
SlashCmdList["MELEEWEAVE"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "lock" then
		MeleeWeaveDB.locked = true;  ApplyLock(); print("|cff33ff99MeleeWeave|r: locked.")
	elseif msg == "unlock" then
		MeleeWeaveDB.locked = false; ApplyLock(); print("|cff33ff99MeleeWeave|r: unlocked -- drag to move.")
	elseif msg == "reset" then
		MeleeWeaveDB.point, MeleeWeaveDB.x, MeleeWeaveDB.y = defaults.point, defaults.x, defaults.y
		UI.frame:ClearAllPoints()
		UI.frame:SetPoint(defaults.point, UIParent, defaults.point, defaults.x, defaults.y)
		print("|cff33ff99MeleeWeave|r: position reset.")
	else
		print("|cff33ff99MeleeWeave|r commands:")
		print("  /mw unlock  - move the bar")
		print("  /mw lock    - lock the bar")
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
		BuildUI()
		ApplyLock()
		-- Warm the item cache so range checks work immediately.
		for i = 1, #RANGES do
			if GetItemInfo then GetItemInfo(RANGES[i][2]) end
		end
		UI.frame:SetScript("OnUpdate", OnUpdate)
	end
end)
