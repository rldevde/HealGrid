-- HealGrid: healer-oriented raid grid. Members are laid
-- out by raid subgroup as clickable unit cells: class-colored or health-
-- gradient health bar, mana/power bar, name, hp/deficit text, dead/offline/
-- AFK states, aggro dot, dispel-typed debuff icons with colored border,
-- incoming-heal + absorb preview, raid marker, role badge, ready-check
-- state, resurrection icon, pets column, range fade and a full click-cast
-- system. No buff icons are shown — debuffs only.
local _, HG = ...
local L = HG.L
local RG = HG:NewModule("HealGrid")

local _G = _G
local ipairs, pairs, wipe, tinsert, sort = ipairs, pairs, wipe, table.insert, table.sort
local format, lower, strtrim, strrep = string.format, string.lower, strtrim, strrep
local min, max, floor = math.min, math.max, math.floor
local tremove = table.remove
local GetTime, InCombatLockdown = GetTime, InCombatLockdown
local IsInGroup, IsInRaid, GetNumGroupMembers = IsInGroup, IsInRaid, GetNumGroupMembers
local UnitName, UnitClass, UnitExists, UnitIsPlayer = UnitName, UnitClass, UnitExists, UnitIsPlayer
local UnitHealth, UnitHealthMax, UnitIsConnected, UnitIsDeadOrGhost = UnitHealth, UnitHealthMax, UnitIsConnected, UnitIsDeadOrGhost
local UnitIsAFK, UnitInRange, UnitThreatSituation = UnitIsAFK, UnitInRange, UnitThreatSituation
local UnitPower, UnitPowerMax, UnitPowerType = UnitPower, UnitPowerMax, UnitPowerType
local UnitGetIncomingHeals, UnitGetTotalAbsorbs = UnitGetIncomingHeals, UnitGetTotalAbsorbs
local UnitGroupRolesAssigned, UnitIsUnit = UnitGroupRolesAssigned, UnitIsUnit
local UnitHasIncomingResurrection = UnitHasIncomingResurrection
local GetReadyCheckStatus, GetRaidTargetIndex = GetReadyCheckStatus, GetRaidTargetIndex
local Ambiguate, GetRaidRosterInfo, SetRaidTargetIconTexture = Ambiguate, GetRaidRosterInfo, SetRaidTargetIconTexture
local UnitCastingInfo, UnitChannelInfo = UnitCastingInfo, UnitChannelInfo
local PlaySound, PlaySoundFile = PlaySound, PlaySoundFile
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip

local MAX_GROUPS, MAX_ROWS = 8, 5
local MAX_DEBUFFS = 3
local members = {}        -- group -> { unit, name, class }
local ticker
RG.dispelSeen = {}        -- unit -> set of currently dispellable debuff names
RG.castTarget, RG.castEndT, RG.castDur = nil, nil, nil

local DEBUFF_COLORS = {
	Magic = { 0.2, 0.6, 1 }, Curse = { 0.6, 0.0, 1 },
	Disease = { 0.6, 0.4, 0 }, Poison = { 0, 0.6, 0 }, [""] = { 0.8, 0, 0 },
}
-- user-configurable debuff border colors (db.debuffColors) over the defaults
local function DebuffColor(dn)
	local dc = RG.db and RG.db.debuffColors
	local c = dc and (dc[dn] or dc.Other)
	if c and c.r then return { c.r, c.g, c.b } end
	return DEBUFF_COLORS[dn] or DEBUFF_COLORS[""]
end
local ROLE_MARK = { TANK = "|cff8888ffT|r", HEALER = "|cff55ff55H|r", DAMAGER = "" }
-- own heal-over-time effects per class (corner indicator is opt-in)
local OWN_HOTS = {
	PRIEST = { 139, 41635, 33076 },              -- Renew, ProM glyph?, Prayer of Mending
	PALADIN = { 53563, 156910 },                 -- Beacon of Light, Beacon of Faith
	DRUID = { 774, 8936, 33763, 48438 },         -- Rejuv, Regrowth, Lifebloom, Wild Growth
	SHAMAN = { 61295, 974 },                     -- Riptide, Earth Shield
	MONK = { 115151, 124682, 119611 },           -- Renewing Mist, Enveloping Mist
	EVOKER = { 364343, 355913, 366155 },         -- Echo, Emerald Blossom, Reversion
}
local HOT_SET
local function OwnHotSet()
	if HOT_SET then return HOT_SET end
	HOT_SET = {}
	for _, id in ipairs(OWN_HOTS[HG.myClass] or {}) do
		local n = HG.GetSpellInfo(id)
		if n then HOT_SET[n] = true end
	end
	return HOT_SET
end

-- comma-separated spell-ID list -> set (highlighted debuffs)
local function ParseIDSet(s)
	if type(s) ~= "string" or s == "" then return nil end
	local t = {}
	for id in s:gmatch("%d+") do t[tonumber(id)] = true end
	return next(t) and t or nil
end
local POWER_COLORS = { [0] = { 0, 0.45, 1 }, [1] = { 1, 0.2, 0.2 }, [3] = { 1, 0.6, 0.2 } } -- mana / rage / energy
local DISPEL_SPELLS = { -- first known spell of the player's class wins
	PRIEST = { 527, 988, 552, 528 },
	PALADIN = { 4987, 1152 },
	DRUID = { 8946, 2893, 2782 },          -- Cure Poison, Abolish Poison, Remove Curse
	SHAMAN = { 51886, 526, 2870 },         -- Cleanse Spirit (Wrath+), Cure Poison, Cure Disease
	MAGE = { 475 },
	WARLOCK = { 19505 },
}
-- debuff types each class can remove (used by the "only dispellable" filter)
local DISPEL_TYPES = {
	PRIEST = { Magic = true, Disease = true },
	PALADIN = { Magic = true, Poison = true, Disease = true },
	DRUID = { Curse = true, Poison = true },
	SHAMAN = { Curse = true, Poison = true, Disease = true },
	MAGE = { Curse = true },
	WARLOCK = { Magic = true },
	MONK = { Magic = true, Poison = true, Disease = true },
	EVOKER = { Magic = true, Poison = true, Curse = true, Disease = true },
}
-- click-cast: same binding format as unitframes.clickCast ---------------------
-- { button = "1".."5", mod = "none"|"shift"|"ctrl"|"alt", type = "spell"|"macro"|"item"|"target"|"togglemenu"|"focus", value = "..." }
-- spell value "dispel"/"heal"/"rez" resolves to the class spell automatically.
-- with db.rezOnDead every spell binding becomes a hybrid macro that casts the
-- class rez on dead cells (battle rez while in combat) — no attribute swaps.
local CC_VALUE_ATTR = { spell = "spell", macro = "macrotext", item = "item" }

local function ResolveDispel()
	for _, id in ipairs(DISPEL_SPELLS[HG.myClass] or {}) do
		if HG.IsSpellKnown and HG.IsSpellKnown(id) then
			return HG.GetSpellInfo(id)
		end
	end
end

-- class heal spells (IDs, resolved to localized names; ordered by preference
-- so "heal" picks the main heal). Covers every WoW healer class; entries the
-- client does not know (other expansions/specs) are skipped.
local CLASS_SPELLS = {
	PRIEST = { 2061, 2054, 2050, 2060, 139, 596, 32546, 17 },
	-- Flash Heal, Heal, Lesser Heal, Greater Heal, Renew, Prayer of Healing, Binding Heal, PW: Shield
	PALADIN = { 19750, 635, 20473 },           -- Flash of Light, Holy Light, Holy Shock
	DRUID = { 8936, 5185, 774, 33763, 18562, 48438, 740 },
	-- Regrowth, Healing Touch, Rejuvenation, Lifebloom, Swiftmend, Wild Growth, Tranquility
	SHAMAN = { 8004, 331, 1064, 61295, 974 },  -- Lesser Healing Wave, Healing Wave, Chain Heal, Riptide, Earth Shield
	MONK = { 116670, 124682, 115151, 115175, 115310, 191837 },
	-- Vivify, Enveloping Mist, Renewing Mist, Soothing Mist, Revival, Essence Font
	EVOKER = { 361469, 355913, 355936, 367226, 364343, 360995, 363534 },
	-- Living Flame, Emerald Blossom, Dream Breath, Spiritbloom, Echo, Verdant Embrace, Rewind
}

local function ResolveHeal()
	for _, id in ipairs(CLASS_SPELLS[HG.myClass] or {}) do
		if HG.IsSpellKnown and HG.IsSpellKnown(id) then
			return HG.GetSpellInfo(id)
		end
	end
end

-- class resurrection spells (normal rez first, then battle/mass rez)
local REZ_SPELLS = {
	PRIEST = { 2006, 212036 },               -- Resurrection, Mass Resurrection
	PALADIN = { 7328, 212056 },              -- Redemption, Absolution
	DRUID = { 50769, 212040 },               -- Revive, Revitalize
	SHAMAN = { 2008, 212048 },               -- Ancestral Spirit, Ancestral Vision
	MONK = { 115178, 212051 },               -- Resuscitate, Reawaken
	EVOKER = { 361227, 361178 },             -- Return, Mass Return
	WARLOCK = { 20707 },                     -- Soulstone (rez-capable on later clients)
}
-- battle resurrections: usable in combat, checked FIRST while fighting
local REZ_BATTLE = {
	DRUID = { 20484 },                       -- Rebirth
	DEATHKNIGHT = { 61999 },                 -- Raise Ally
	WARLOCK = { 20707 },                     -- Soulstone on dead targets
}

local function ResolveRez()
	-- in combat the battle rez wins; out of combat the cheaper normal rez
	local first = InCombatLockdown() and REZ_BATTLE or REZ_SPELLS
	local second = InCombatLockdown() and REZ_SPELLS or REZ_BATTLE
	for _, list in ipairs({ first[HG.myClass], second[HG.myClass] }) do
		for _, id in ipairs(list or {}) do
			if HG.IsSpellKnown and HG.IsSpellKnown(id) then
				return HG.GetSpellInfo(id)
			end
		end
	end
end

-- both rez names at once: normal + battle rez (for hybrid macros)
local function ResolveRezSpells()
	local normal, battle
	for _, id in ipairs(REZ_SPELLS[HG.myClass] or {}) do
		if HG.IsSpellKnown and HG.IsSpellKnown(id) then normal = HG.GetSpellInfo(id) break end
	end
	for _, id in ipairs(REZ_BATTLE[HG.myClass] or {}) do
		if HG.IsSpellKnown and HG.IsSpellKnown(id) then battle = HG.GetSpellInfo(id) break end
	end
	return normal, battle
end

-- spell picker list for the options window: keywords first, then every known
-- class heal spell by localized name
local spellPickerList
local function ClassSpellList()
	if spellPickerList then return spellPickerList end
	spellPickerList = { "heal", "dispel", "rez" }
	for _, id in ipairs(CLASS_SPELLS[HG.myClass] or {}) do
		local name = HG.GetSpellInfo(id)
		if name and (not HG.IsSpellKnown or HG.IsSpellKnown(id)) then
			spellPickerList[#spellPickerList + 1] = name
		end
	end
	return spellPickerList
end

-- hidden secure proxy: dead-click macros cannot run the togglemenu action, so
-- the menu is opened through a /click on this button when the unit is alive
local rezProxyN = 0
local function RezMenuProxy(cell)
	if not cell.rezMenuProxy then
		rezProxyN = rezProxyN + 1
		local p = CreateFrame("Button", "HGRezMenu" .. rezProxyN, cell, "SecureActionButtonTemplate")
		p:SetAttribute("type", "togglemenu")
		p:SetAttribute("useparent-unit", true)
		p:RegisterForClicks("AnyUp", "AnyDown")
		p:SetSize(1, 1)
		p:SetAlpha(0)
		p:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT")
		cell.rezMenuProxy = p
	end
	cell.rezMenuProxy:SetAttribute("unit", cell.unit)
	return cell.rezMenuProxy
end

-- hybrid dead-click macro: battle rez in combat, normal rez out of combat,
-- original spell on live units. The battle rez is usable out of combat too, so
-- classes without a normal rez (TBC druids only know Rebirth) still rez.
local function RezMacro(normal, battle, spell)
	local parts = {}
	if battle then parts[#parts + 1] = format("[dead,combat,help] %s", battle) end
	local ooc = normal or battle
	if ooc then parts[#parts + 1] = format("[dead,help] %s", ooc) end
	if spell and spell ~= "" then parts[#parts + 1] = format("[help] %s", spell) end
	-- /cast inside a macro does not unshift automatically the way plain spell
	-- bindings do, so form classes get an explicit cancelform first
	local unshift = (HG.myClass == "DRUID" or HG.myClass == "PRIEST" or HG.myClass == "SHAMAN")
		and "/cancelform\n" or ""
	return unshift .. "/cast " .. table.concat(parts, "; ")
end

function RG:ApplyClicksTo(cell)
	if not cell.ccKeys then cell.ccKeys = {} end
	for _, k in ipairs(cell.ccKeys) do cell:SetAttribute(k, nil) end
	wipe(cell.ccKeys)
	cell:SetAttribute("type1", "target") -- plain left click always targets
	cell.ccKeys[#cell.ccKeys + 1] = "type1"
	local cc = self.db.clickCast
	if not cc or not cc.enable or not cc.bindings then return end
	for _, b in ipairs(cc.bindings) do
		local btn = tonumber(b.button) or 1
		local mod = (b.mod and b.mod ~= "none" and b.mod ~= "") and (b.mod:lower() .. "-") or ""
		local tattr = mod .. "type" .. btn
		cell:SetAttribute(tattr, b.type or "spell")
		cell.ccKeys[#cell.ccKeys + 1] = tattr
		local vname = CC_VALUE_ATTR[b.type or ""]
		local value = b.value
		local normal, battle
		if self.db.rezOnDead then normal, battle = ResolveRezSpells() end
		if b.type == "spell" then
			local lv = lower(value or "")
			if lv == "dispel" or lv == "heal" or lv == "rez" then
				value = lv == "dispel" and ResolveDispel() or (lv == "heal" and ResolveHeal() or ResolveRez())
				if not value then cell:SetAttribute(tattr, "togglemenu") end -- no spell known -> menu
			end
			-- hybrid macro: dead cells cast the class rez automatically (battle
			-- rez while in combat) — attribute swaps are impossible in combat,
			-- so the macro condition does the switch instead of cell.isDead
			if normal or battle then
				cell:SetAttribute(tattr, "macro")
				local vattr = mod .. "macrotext" .. btn
				cell:SetAttribute(vattr, RezMacro(normal, battle, value))
				cell.ccKeys[#cell.ccKeys + 1] = vattr
				value = nil
			end
		elseif b.type == "togglemenu" and (normal or battle) then
			-- dead cells: rez instead of the unit menu; the menu still opens on
			-- live targets via the proxy click
			cell:SetAttribute(tattr, "macro")
			local vattr = mod .. "macrotext" .. btn
			cell:SetAttribute(vattr, format("%s\n/stopmacro [dead,help]\n/click %s",
				RezMacro(normal, battle), RezMenuProxy(cell):GetName()))
			cell.ccKeys[#cell.ccKeys + 1] = vattr
		end
		if vname and value and value ~= "" then
			local vattr = mod .. vname .. btn
			cell:SetAttribute(vattr, value)
			cell.ccKeys[#cell.ccKeys + 1] = vattr
		end
		if cell.unit then
			local uattr = mod .. "unit" .. btn
			cell:SetAttribute(uattr, cell.unit)
			cell.ccKeys[#cell.ccKeys + 1] = uattr
		end
	end
end

function RG:ApplyClicks()
	if InCombatLockdown() or not self.cells then return end
	for _, grp in pairs(self.cells) do
		for _, cell in ipairs(grp) do self:ApplyClicksTo(cell) end
	end
end

-- cell ----------------------------------------------------------------------
local function MakeCell(parent)
	local b = CreateFrame("Button", nil, parent, "SecureUnitButtonTemplate")
	b:RegisterForClicks("AnyUp", "AnyDown")
	b:EnableMouse(true)
	HG:SetTemplate(b, "Default")

	b.hp = CreateFrame("StatusBar", nil, b)
	b.hp:SetPoint("TOPLEFT", 1, -1)
	b.hp:SetPoint("BOTTOMRIGHT", -1, 1)
	b.hp:SetMinMaxValues(0, 1)
	b.hp:SetStatusBarTexture(HG.media.statusbar)
	b.hp.bg = b.hp:CreateTexture(nil, "BACKGROUND")
	b.hp.bg:SetAllPoints()
	b.hp.bg:SetTexture(HG.media.statusbar)
	b.hp.bg:SetVertexColor(0.08, 0.08, 0.08, 0.9)

	-- heal/absorb previews are statusbars so the client itself clips their fill
	-- inside the cell; raw textures can render outside the frame bounds
	b.inc = CreateFrame("StatusBar", nil, b)
	b.inc:SetPoint("TOP", b.hp)
	b.inc:SetPoint("BOTTOM", b.hp)
	b.inc:SetPoint("LEFT", b.hp)
	b.inc:SetPoint("RIGHT", b.hp)
	b.inc:SetMinMaxValues(0, 1)
	b.inc:SetStatusBarTexture(HG.media.statusbar)
	b.inc:SetStatusBarColor(0.2, 0.8, 0.2, 0.4)
	b.inc:SetFrameLevel(b.hp:GetFrameLevel() + 1)
	b.inc:Hide()
	b.abs = CreateFrame("StatusBar", nil, b)
	b.abs:SetAllPoints(b.hp)
	b.abs:SetMinMaxValues(0, 1)
	b.abs:SetStatusBarTexture(HG.media.statusbar)
	b.abs:SetStatusBarColor(1, 0.85, 0.2, 0.45)
	b.abs:SetReverseFill(true)
	b.abs:SetFrameLevel(b.hp:GetFrameLevel() + 2)
	b.abs:Hide()

	b.pow = CreateFrame("StatusBar", nil, b)
	b.pow:SetPoint("BOTTOMLEFT", 1, 1)
	b.pow:SetPoint("BOTTOMRIGHT", -1, 1)
	b.pow:SetHeight(3)
	b.pow:SetMinMaxValues(0, 1)
	b.pow:SetStatusBarTexture(HG.media.statusbar)
	b.pow:SetFrameLevel(b.hp:GetFrameLevel() + 1)

	b.hl = b:CreateTexture(nil, "OVERLAY", nil, 5)
	b.hl:SetAllPoints()
	b.hl:SetColorTexture(1, 1, 1, 0.12)
	b.hl:Hide()

	b.name = HG:FontString(b.hp, 10, "OUTLINE")
	b.name:SetPoint("TOPLEFT", 3, -1)
	b.name:SetWidth(0)
	b.hpText = HG:FontString(b.hp, 9, "OUTLINE")
	b.hpText:SetPoint("BOTTOMRIGHT", -3, 4)

	b.aggro = b:CreateTexture(nil, "OVERLAY", nil, 4)
	b.aggro:SetSize(10, 10)
	b.aggro:SetPoint("TOPLEFT", 2, -2)
	b.aggro:SetColorTexture(1, 0, 0, 0.85)
	b.aggro:Hide()
	b.raidIcon = b:CreateTexture(nil, "OVERLAY", nil, 4)
	b.raidIcon:SetSize(12, 12)
	b.raidIcon:SetPoint("TOP", 0, -2)
	b.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
	b.raidIcon:Hide()
	b.ready = b:CreateTexture(nil, "OVERLAY", nil, 4)
	b.ready:SetSize(12, 12)
	b.ready:SetPoint("CENTER", 0, -2)
	b.ready:Hide()
	b.res = b:CreateTexture(nil, "OVERLAY", nil, 4)
	b.res:SetSize(14, 14)
	b.res:SetPoint("CENTER", 0, 0)
	b.res:SetTexture("Interface\\RaidFrame\\Raid-Icon-Rez")
	b.res:Hide()
	b.role = HG:FontString(b.hp, 9, "OUTLINE")
	b.role:SetPoint("TOPRIGHT", -3, -1)

	-- own-HoT corner dot (opt-in), big whitelisted debuff icon, castbar, flash
	b.hot = b:CreateTexture(nil, "OVERLAY", nil, 4)
	b.hot:SetSize(8, 8)
	b.hot:SetPoint("BOTTOMLEFT", 2, 2)
	b.hot:SetColorTexture(0.2, 0.9, 0.4, 1)
	b.hot:Hide()
	b.bigDebuff = b:CreateTexture(nil, "OVERLAY", nil, 6)
	b.bigDebuff:SetPoint("CENTER")
	b.bigDebuff:SetSize(20, 20)
	b.bigDebuff:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b.bigDebuff:Hide()
	b.cast = CreateFrame("StatusBar", nil, b)
	b.cast:SetPoint("BOTTOMLEFT", b.pow, "TOPLEFT", 0, 1)
	b.cast:SetPoint("BOTTOMRIGHT", b.pow, "TOPRIGHT", 0, 1)
	b.cast:SetHeight(3)
	b.cast:SetStatusBarTexture(HG.media.statusbar)
	b.cast:SetStatusBarColor(1, 0.7, 0.2, 0.9)
	b.cast:SetMinMaxValues(0, 1)
	b.cast:Hide()
	b.cast:SetScript("OnUpdate", function(c)
		local rem = c.endT - GetTime()
		if rem <= 0 then c:Hide() return end
		c:SetValue(c.dur - rem)
	end)
	b.flash = CreateFrame("Frame", nil, b)
	b.flash:SetAllPoints()
	b.flash:Hide()
	b.flash.tex = b.flash:CreateTexture(nil, "OVERLAY", nil, 6)
	b.flash.tex:SetAllPoints()
	b.flash.tex:SetColorTexture(1, 1, 1, 0.4)
	b.flash:SetScript("OnUpdate", function(fr)
		local t = fr.untilT - GetTime()
		if t <= 0 then fr:Hide() return end
		fr.tex:SetAlpha(0.35 * (math.sin(t * 9) * 0.5 + 0.5))
	end)

	b.debuffs = {}
	for i = 1, MAX_DEBUFFS do
		local t = b:CreateTexture(nil, "OVERLAY", nil, 4)
		t:SetSize(12, 12)
		t:SetPoint("TOPRIGHT", -(2 + (i - 1) * 13), -2)
		t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		t:Hide()
		b.debuffs[i] = t
	end
	b:SetScript("OnEnter", function(c)
		c.hl:Show()
		if RG.db.unitTooltip and c.unit then
			GameTooltip:SetOwner(c, "ANCHOR_BOTTOMRIGHT")
			GameTooltip:SetUnit(c.unit)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function(c) c.hl:Hide() GameTooltip:Hide() end)
	b:Hide()
	return b
end

-- frame ---------------------------------------------------------------------
function RG:BuildFrame()
	if self.frame then return end
	local f = CreateFrame("Frame", "HealGridFrame", UIParent, HG.BackdropTemplate)
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetClampedToScreen(true)
	f:SetFrameStrata("MEDIUM")
	HG:SetTemplate(f, "Default")
	f:Hide()
	f:SetScript("OnDragStart", function(fr) if not RG.db.lockFrame then fr:StartMoving() end end)
	f:SetScript("OnDragStop", function(fr)
		fr:StopMovingOrSizing()
		local point, _, rel, x, y = fr:GetPoint(1)
		RG.db.point = { point = point, rel = rel, x = x, y = y }
	end)
	local p = self.db.point
	if p and p.point then f:SetPoint(p.point, UIParent, p.rel or "CENTER", p.x or 0, p.y or 0)
	else f:SetPoint("CENTER", UIParent, "CENTER", -250, -80) end

	-- small move-anchor: a tiny accent tab above the top-left corner so the
	-- whole grid can be dragged without a title bar sitting on top of cells
	f.anchor = CreateFrame("Button", nil, f)
	f.anchor:SetSize(16, 10)
	f.anchor:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, -1)
	f.anchor:EnableMouse(true)
	f.anchor:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	HG:SetTemplate(f.anchor, "Default")
	local at = f.anchor:CreateTexture(nil, "OVERLAY")
	at:SetPoint("CENTER")
	at:SetSize(8, 3)
	at:SetVertexColor(HG.accent.r, HG.accent.g, HG.accent.b, 0.9)
	f.anchor:SetScript("OnMouseDown", function(_, btn)
		if btn == "LeftButton" and not RG.db.lockFrame then f:StartMoving() end
	end)
	f.anchor:SetScript("OnMouseUp", function() f:StopMovingOrSizing()
		local point, _, rel, x, y = f:GetPoint(1)
		RG.db.point = { point = point, rel = rel, x = x, y = y }
	end)
	f.anchor:SetScript("OnEnter", function(a)
		GameTooltip:SetOwner(a, "ANCHOR_TOP")
		GameTooltip:AddLine("HealGrid")
		GameTooltip:AddLine(L["Drag: move  |  Right-click: options"], 1, 1, 1)
		GameTooltip:Show()
	end)
	f.anchor:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.anchor:SetScript("OnClick", function(_, btn)
		if btn == "RightButton" then RG:ToggleConfig() end
	end)

	-- free click zone: a tiny pad next to the anchor running a user macro
	f.pad = CreateFrame("Button", "HealGridMacroPad", f, "SecureActionButtonTemplate")
	f.pad:SetSize(16, 10)
	f.pad:SetPoint("LEFT", f.anchor, "RIGHT", 4, 0)
	f.pad:RegisterForClicks("AnyUp", "AnyDown")
	HG:SetTemplate(f.pad, "Default")
	local pt = HG:FontString(f.pad, 8, "OUTLINE")
	pt:SetPoint("CENTER")
	pt:SetText("|cff" .. HG.accentHex .. "M|r")
	f.pad:Hide()

	self.cells = {}
	for g = 1, MAX_GROUPS do
		self.cells[g] = {}
		for r = 1, MAX_ROWS do
			self.cells[g][r] = MakeCell(f)
		end
	end
	self.frame = f
end

-- roster --------------------------------------------------------------------
-- visibility rule from db.visMode; showWhenSolo governs the ALWAYS case
local TEST_CLASSES = {
	"PALADIN", "PRIEST", "SHAMAN", "DRUID", "MONK", "EVOKER",
	"WARRIOR", "DEATHKNIGHT", "DEMONHUNTER", "ROGUE", "HUNTER", "MAGE", "WARLOCK",
}
local TEST_DISPELS = { "Magic", "Curse", "Poison", "Disease" }
local TEST_SPELLS = { 589, 172, 980, 703 } -- SW:Pain, Corruption, Agony, Garrote — exist on every client
local TEST_ROLES = { [1] = "TANK", [2] = "TANK" }
for i = 3, 8 do TEST_ROLES[i] = "HEALER" end

local function SpellIcon(id)
	if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
	return GetSpellTexture and GetSpellTexture(id)
end

function RG:ShouldShow()
	if (self.db.testSize or 0) > 0 then return true end
	local vis = self.db.visMode or "ALWAYS"
	if vis == "RAID" then return IsInRaid() end
	if vis == "GROUP" then return IsInRaid() or IsInGroup() end
	return true
end

function RG:Collect()
	wipe(members)
	-- test mode: fill the grid with deterministic fake members so the layout
	-- can be previewed without a group; real roster wins when testSize is 0
	local n = min(self.db.testSize or 0, MAX_GROUPS * MAX_ROWS)
	if n > 0 then
		for i = 1, n do
			local g = floor((i - 1) / MAX_ROWS) + 1
			local list = members[g] or {}
			members[g] = list
			list[#list + 1] = {
				unit = "player", test = i,
				name = "Test" .. i,
				class = TEST_CLASSES[((i - 1) % #TEST_CLASSES) + 1],
				role = TEST_ROLES[i] or "DAMAGER",
			}
		end
		return
	end
	if not self:ShouldShow() then return end
	local function Add(unit, grp)
		if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
		grp = min(max(grp or 1, 1), MAX_GROUPS)
		local list = members[grp] or {}
		members[grp] = list
		if #list < MAX_ROWS then
			local _, class = UnitClass(unit)
			list[#list + 1] = { unit = unit, name = Ambiguate(UnitName(unit), "short"), class = class,
				role = (UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)) or "DAMAGER" }
		end
	end
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local _, _, subgroup = GetRaidRosterInfo(i)
			Add("raid" .. i, subgroup)
		end
	elseif IsInGroup() then
		Add("player", 1)
		for i = 1, GetNumGroupMembers() - 1 do Add("party" .. i, 1) end
	elseif self.db.showWhenSolo then
		Add("player", 1)
	end
	-- pets fill the first free column after the last populated group,
	-- colored by their owner's class
	if self.db.showPets then
		local used = 0
		for g = 1, MAX_GROUPS do
			if members[g] and #members[g] > 0 then used = g end
		end
		local col = used + 1
		local function AddPet(unit, ownerClass)
			if col > MAX_GROUPS or not UnitExists(unit) then return end
			local name = UnitName(unit)
			if not name then return end
			local list = members[col] or {}
			if #list >= MAX_ROWS then
				col = col + 1
				if col > MAX_GROUPS then return end
				list = {}
			end
			members[col] = list
			list[#list + 1] = { unit = unit, name = Ambiguate(name, "short"), class = ownerClass }
		end
		if IsInRaid() then
			for i = 1, GetNumGroupMembers() do
				AddPet("raidpet" .. i, select(2, UnitClass("raid" .. i)))
			end
		elseif IsInGroup() then
			AddPet("pet", HG.myClass)
			for i = 1, GetNumGroupMembers() - 1 do
				AddPet("partypet" .. i, select(2, UnitClass("party" .. i)))
			end
		elseif self.db.showWhenSolo then
			AddPet("pet", HG.myClass)
		end
	end
	local method = self.db.sortMethod
	if method == "NAME" or method == "ROLE" then
		local rank = { TANK = 1, HEALER = 2, DAMAGER = 3 }
		for _, list in pairs(members) do
			if method == "NAME" then
				sort(list, function(a, b) return a.name < b.name end)
			else
				sort(list, function(a, b)
					local ra, rb = rank[a.role] or 3, rank[b.role] or 3
					return ra ~= rb and ra < rb or a.name < b.name
				end)
			end
		end
	end
end

-- per-cell paint ------------------------------------------------------------
local function GradColor(frac) -- green -> yellow -> red
	if frac > 0.5 then return (1 - frac) * 2, 1, 0 end
	return 1, frac * 2, 0
end

function RG:Paint(cell, m)
	if m.test then return self:PaintTest(cell, m) end
	local unit = m.unit
	local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
	local dead = UnitIsDeadOrGhost(unit)
	local offline = not UnitIsConnected(unit)
	local afk = self.db.showAFK ~= false and not dead and not offline
		and UnitIsAFK and UnitIsAFK(unit) or false
	if cell.isDead ~= dead then
		cell.isDead = dead
		if InCombatLockdown() then
			HG:RunOutOfCombat(self.ApplyClicksTo, self, cell)
		else
			self:ApplyClicksTo(cell)
		end
	end
	local color = RAID_CLASS_COLORS[m.class] or { r = 0.5, g = 0.5, b = 0.5 }
	local frac = hpMax > 0 and hp / hpMax or 0

	cell.hp:SetMinMaxValues(0, hpMax)
	cell.hp:SetValue(hp)
	if dead or offline then
		cell.hp:SetStatusBarColor(0.18, 0.18, 0.18)
	elseif self.db.healthMode == "GRADIENT" then
		cell.hp:SetStatusBarColor(GradColor(frac))
	elseif self.db.healthMode == "CUSTOM" then
		local c = self.db.customColor or { r = 0.2, g = 0.8, b = 0.2 }
		cell.hp:SetStatusBarColor(c.r, c.g, c.b)
	else
		cell.hp:SetStatusBarColor(color.r, color.g, color.b)
	end

	-- power bar
	if self.db.showPower and not dead and not offline then
		local p, pMax = UnitPower(unit), UnitPowerMax(unit)
		local ptype = UnitPowerType(unit)
		if pMax > 0 then
			local pc = POWER_COLORS[ptype] or POWER_COLORS[0]
			cell.pow:SetMinMaxValues(0, pMax)
			cell.pow:SetValue(p)
			cell.pow:SetStatusBarColor(pc[1], pc[2], pc[3])
			cell.pow:Show()
		else
			cell.pow:Hide()
		end
	else
		cell.pow:Hide()
	end

	local mark = self.db.showRole ~= false and (ROLE_MARK[UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or ""] or "") or ""
	local dispName = m.name
	local maxLen = self.db.nameMaxLen or 0
	if maxLen > 0 and dispName:len() > maxLen then dispName = dispName:sub(1, maxLen) end
	if dead then
		cell.name:SetText("|cff888888" .. dispName .. "|r")
		cell.hpText:SetText(L["Dead"])
	elseif offline then
		cell.name:SetText("|cff888888" .. dispName .. "|r")
		cell.hpText:SetText(L["Offline"])
	elseif afk then
		cell.name:SetText("|cff888888" .. dispName .. "|r")
		cell.hpText:SetText(L["AFK"])
	else
		cell.name:SetText(dispName)
		local lm = self.db.lifeMode or "PERCENT"
		if lm == "NONE" then
			cell.hpText:SetText("")
		elseif lm == "DEFICIT" then
			local def = hp - hpMax
			cell.hpText:SetText(def < 0 and format("|cffff7766%d|r", def) or "")
		elseif lm == "BOTH" then
			local def = hp - hpMax
			cell.hpText:SetText(def < 0 and format("|cffff7766%d|r  %d%%", def, frac * 100) or format("%d%%", frac * 100))
		else
			cell.hpText:SetText(format("%d%%", frac * 100))
		end
	end
	cell.role:SetText(mark)

	-- incoming heals + absorbs preview. secret values (12.x) are skipped
	-- entirely; the statusbars clip their own fill inside the cell
	local w = cell.hp:GetWidth()
	local secret = HG.IsSecret(hp) or HG.IsSecret(hpMax)
	if self.db.showIncHeal and UnitGetIncomingHeals and not dead and not secret and w > 0 then
		local inc = UnitGetIncomingHeals(unit)
		if inc and not HG.IsSecret(inc) and inc > 0 and hpMax > 0 then
			if hpMax > hp then
				-- heal lands inside the missing health: green segment at the hp edge
				-- (right edge stays anchored to the cell so it can never overflow)
				local off = min(w, hp / hpMax * w)
				cell.inc:SetReverseFill(false)
				cell.inc:SetPoint("LEFT", cell.hp, "LEFT", off, 0)
				cell.inc:SetMinMaxValues(0, hpMax - hp)
				cell.inc:SetValue(min(hpMax - hp, inc))
			else
				-- full health: overheal wedge from the right edge, width = heal size
				cell.inc:SetReverseFill(true)
				cell.inc:SetPoint("LEFT", cell.hp, "LEFT", 0, 0)
				cell.inc:SetMinMaxValues(0, hpMax)
				cell.inc:SetValue(min(hpMax, inc))
			end
			cell.inc:Show()
		else
			cell.inc:Hide()
		end
	else
		cell.inc:Hide()
	end
	if self.db.showAbsorb and UnitGetTotalAbsorbs and not dead and not secret and hpMax > 0 then
		local ab = UnitGetTotalAbsorbs(unit)
		if ab and not HG.IsSecret(ab) and ab > 0 then
			cell.abs:SetMinMaxValues(0, hpMax)
			cell.abs:SetValue(min(hpMax, ab))
			cell.abs:Show()
		else
			cell.abs:Hide()
		end
	else
		cell.abs:Hide()
	end

	-- aggro indicator (dot, border or both depending on aggroStyle)
	local threat = not dead and (UnitThreatSituation and UnitThreatSituation(unit) or 0) >= 2
	local aggroStyle = self.db.aggroStyle or "DOT"
	cell.aggro:SetShown(threat and (aggroStyle == "DOT" or aggroStyle == "BOTH"))

	-- raid marker
	local ri = self.db.showRaidIcon ~= false and GetRaidTargetIndex and GetRaidTargetIndex(unit)
	if ri and ri > 0 then
		cell.raidIcon:Show()
		SetRaidTargetIconTexture(cell.raidIcon, ri)
	else
		cell.raidIcon:Hide()
	end

	-- ready check state + incoming resurrection
	if self.db.showReadyCheck and GetReadyCheckStatus then
		local st = GetReadyCheckStatus(unit)
		if st == "ready" then
			cell.ready:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready") cell.ready:Show()
		elseif st == "notready" then
			cell.ready:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady") cell.ready:Show()
		elseif st == "waiting" then
			cell.ready:SetTexture("Interface\\RaidFrame\\ReadyCheck-Waiting") cell.ready:Show()
		else
			cell.ready:Hide()
		end
	else
		cell.ready:Hide()
	end
	cell.res:SetShown(self.db.showResIcon ~= false and not offline and UnitHasIncomingResurrection and UnitHasIncomingResurrection(unit) or false)

	-- auras: debuff icons + dispel border (no buffs shown — decursing only)
	local dN = 0
	local onlyDisp = self.db.onlyDispellable
	local canDispel = DISPEL_TYPES[HG.myClass]
	local curDisp = canDispel and {} or nil
	local bigIcon
	if self.db.showDebuffs then
		local hl = self.hlSet
		for i = 1, 40 do
			local a = HG.GetAura(unit, i, "HARMFUL")
			if not a then break end
			if a.name and not HG.IsSecret(a.name) then
				if hl and not bigIcon and a.spellId and hl[a.spellId] then bigIcon = a.icon end
				if curDisp and canDispel[a.dispelName or ""] then curDisp[a.name] = true end
				if dN < MAX_DEBUFFS
					and (not onlyDisp or (canDispel ~= nil and canDispel[a.dispelName or ""])) then
					dN = dN + 1
					cell.debuffs[dN]:SetTexture(a.icon)
					cell.debuffs[dN].dispel = a.dispelName
					cell.debuffs[dN]:Show()
				end
			end
		end
	end
	for i = dN + 1, MAX_DEBUFFS do cell.debuffs[i]:Hide() cell.debuffs[i].dispel = nil end

	-- whitelisted debuff shown big in the cell center
	if bigIcon then
		cell.bigDebuff:SetTexture(bigIcon)
		cell.bigDebuff:Show()
	else
		cell.bigDebuff:Hide()
	end

	-- dispel alert: sound and/or border flash when a NEW removable debuff appears
	if curDisp then
		local prev = self.dispelSeen[unit]
		if prev and self.db.dispelAlert ~= "NONE" then
			for name in pairs(curDisp) do
				if not prev[name] then
					local mode = self.db.dispelAlert
					if mode == "FLASH" or mode == "BOTH" then
						cell.flash.untilT = GetTime() + 1.4
						cell.flash:Show()
					end
					if (mode == "SOUND" or mode == "BOTH")
						and (not self.lastAlertT or GetTime() - self.lastAlertT > 0.8) then
						self.lastAlertT = GetTime()
						if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
							PlaySound(SOUNDKIT.RAID_WARNING)
						elseif PlaySoundFile then
							pcall(PlaySoundFile, "Sound\\Interface\\RaidWarning.ogg")
						end
					end
					break
				end
			end
		end
		self.dispelSeen[unit] = curDisp
	end

	-- own HoT corner dot (opt-in); turns red in the last 3 seconds
	if self.db.showHotCorner and not dead then
		local set = OwnHotSet()
		local best
		for i = 1, 40 do
			local a = HG.GetAura(unit, i, "HELPFUL|PLAYER")
			if not a then break end
			if a.name and set[a.name] then best = a break end
		end
		if best then
			local c = self.db.hotColor or { r = 0.2, g = 0.9, b = 0.4 }
			local rem = best.expirationTime and (best.expirationTime - GetTime()) or 99
			if rem < 3 then cell.hot:SetColorTexture(1, 0.3, 0.2, 1)
			else cell.hot:SetColorTexture(c.r, c.g, c.b, 1) end
			cell.hot:Show()
		else
			cell.hot:Hide()
		end
	else
		cell.hot:Hide()
	end

	-- the unit the player is currently casting on: castbar + optional border
	local isCT = self.castTarget ~= nil and self.castTarget == m.name
	if isCT and self.castEndT and GetTime() < self.castEndT and self.db.showCastbar ~= false then
		cell.cast.dur = self.castDur or 0.1
		cell.cast.endT = self.castEndT
		cell.cast:SetMinMaxValues(0, cell.cast.dur)
		cell.cast:Show()
	else
		cell.cast:Hide()
	end

	-- border: debuff color > aggro border > cast target > own target > default
	local bcol
	if dN > 0 and self.db.showDebuffs then
		for i = 1, dN do
			local dn = cell.debuffs[i].dispel
			if dn then bcol = DebuffColor(dn) break end
		end
		bcol = bcol or DebuffColor("")
	elseif threat and (aggroStyle == "BORDER" or aggroStyle == "BOTH") then
		local agc = self.db.aggroColor or { r = 1, g = 0, b = 0 }
		bcol = { agc.r, agc.g, agc.b }
	elseif isCT and self.db.castHighlight ~= false then
		local cc = self.db.castColor or { r = 1, g = 0.7, b = 0.2 }
		bcol = { cc.r, cc.g, cc.b }
	elseif self.db.targetHighlight and UnitIsUnit(unit, "target") then
		bcol = { HG.accent.r, HG.accent.g, HG.accent.b }
	end
	if bcol then HG:SetTemplate(cell, "Default", nil, bcol) else HG:SetTemplate(cell, "Default") end

	-- range fade
	if self.db.rangeFade and not dead then
		local inRange = HG.UnitInRange and HG.UnitInRange(unit)
		cell:SetAlpha(inRange == false and (self.db.rangeAlpha or 0.4) or 1)
	else
		cell:SetAlpha(1)
	end
end

-- fake cells for test mode: deterministic values derived from the index so
-- the preview shows the full variety (dead, offline, aggro, debuffs, etc.)
function RG:PaintTest(cell, m)
	local i = m.test
	local db = self.db
	local hpMax, hp = 100, max(6, (i * 31) % 100)
	local dead = i % 11 == 10
	local offline = i % 13 == 12 and not dead
	local afk = db.showAFK ~= false and i % 17 == 15 and not dead and not offline
	if dead or offline then hp = 0 end
	if cell.isDead ~= dead then
		cell.isDead = dead
		if InCombatLockdown() then
			HG:RunOutOfCombat(self.ApplyClicksTo, self, cell)
		else
			self:ApplyClicksTo(cell)
		end
	end
	local color = RAID_CLASS_COLORS[m.class] or { r = 0.5, g = 0.5, b = 0.5 }
	local frac = hp / hpMax
	cell.hp:SetMinMaxValues(0, hpMax)
	cell.hp:SetValue(hp)
	if dead or offline then
		cell.hp:SetStatusBarColor(0.18, 0.18, 0.18)
	elseif db.healthMode == "GRADIENT" then
		cell.hp:SetStatusBarColor(GradColor(frac))
	elseif db.healthMode == "CUSTOM" then
		local c = db.customColor or { r = 0.2, g = 0.8, b = 0.2 }
		cell.hp:SetStatusBarColor(c.r, c.g, c.b)
	else
		cell.hp:SetStatusBarColor(color.r, color.g, color.b)
	end
	if db.showPower and not dead and not offline then
		local pc = POWER_COLORS[i % 3 == 0 and 1 or i % 3 == 1 and 0 or 3] or POWER_COLORS[0]
		cell.pow:SetMinMaxValues(0, 100)
		cell.pow:SetValue((i * 53) % 100)
		cell.pow:SetStatusBarColor(pc[1], pc[2], pc[3])
		cell.pow:Show()
	else
		cell.pow:Hide()
	end
	cell.role:SetText(db.showRole ~= false and (ROLE_MARK[m.role] or "") or "")
	local dispName = m.name
	local maxLen = db.nameMaxLen or 0
	if maxLen > 0 and dispName:len() > maxLen then dispName = dispName:sub(1, maxLen) end
	if dead then
		cell.name:SetText("|cff888888" .. dispName .. "|r")
		cell.hpText:SetText(L["Dead"])
	elseif offline then
		cell.name:SetText("|cff888888" .. dispName .. "|r")
		cell.hpText:SetText(L["Offline"])
	elseif afk then
		cell.name:SetText("|cff888888" .. dispName .. "|r")
		cell.hpText:SetText(L["AFK"])
	else
		cell.name:SetText(dispName)
		local lm = db.lifeMode or "PERCENT"
		if lm == "NONE" then
			cell.hpText:SetText("")
		elseif lm == "DEFICIT" then
			local def = hp - hpMax
			cell.hpText:SetText(def < 0 and format("|cffff7766%d|r", def) or "")
		elseif lm == "BOTH" then
			local def = hp - hpMax
			cell.hpText:SetText(def < 0 and format("|cffff7766%d|r  %d%%", def, frac * 100) or format("%d%%", frac * 100))
		else
			cell.hpText:SetText(format("%d%%", frac * 100))
		end
	end
	-- preview overlays on a subset of cells
	if db.showIncHeal and i % 4 == 1 and hp < hpMax then
		cell.inc:SetReverseFill(false)
		cell.inc:SetPoint("LEFT", cell.hp, "LEFT", min(cell.hp:GetWidth(), frac * cell.hp:GetWidth()), 0)
		cell.inc:SetMinMaxValues(0, hpMax - hp)
		cell.inc:SetValue(min(hpMax - hp, 15))
		cell.inc:Show()
	else
		cell.inc:Hide()
	end
	if db.showAbsorb and i % 9 == 4 then
		cell.abs:SetMinMaxValues(0, hpMax)
		cell.abs:SetValue(20)
		cell.abs:Show()
	else
		cell.abs:Hide()
	end
	local threat = i % 7 == 2
	local aggroStyle = db.aggroStyle or "DOT"
	cell.aggro:SetShown(threat and (aggroStyle == "DOT" or aggroStyle == "BOTH"))
	if db.showRaidIcon ~= false and i % 8 == 1 then
		cell.raidIcon:Show()
		SetRaidTargetIconTexture(cell.raidIcon, ((i - 1) % 8) + 1)
	else
		cell.raidIcon:Hide()
	end
	cell.ready:Hide()
	cell.res:SetShown(db.showResIcon ~= false and dead)
	local dN = 0
	if db.showDebuffs and i % 3 == 1 then
		local cnt = (i % 3) + 1
		for d = 1, min(cnt, MAX_DEBUFFS) do
			local dn = TEST_DISPELS[((i + d - 2) % #TEST_DISPELS) + 1]
			local tex = SpellIcon(TEST_SPELLS[((i + d - 2) % #TEST_SPELLS) + 1])
			dN = dN + 1
			if tex then cell.debuffs[dN]:SetTexture(tex) end
			cell.debuffs[dN].dispel = dn
			cell.debuffs[dN]:Show()
		end
	end
	for d = dN + 1, MAX_DEBUFFS do cell.debuffs[d]:Hide() cell.debuffs[d].dispel = nil end
	-- preview the optional extras on a subset of cells
	if db.showHotCorner and i % 5 == 3 then
		local c = db.hotColor or { r = 0.2, g = 0.9, b = 0.4 }
		cell.hot:SetColorTexture(c.r, c.g, c.b, 1)
		cell.hot:Show()
	else
		cell.hot:Hide()
	end
	if self.hlSet and dN > 0 then
		cell.bigDebuff:SetTexture(cell.debuffs[1]:GetTexture())
		cell.bigDebuff:Show()
	else
		cell.bigDebuff:Hide()
	end
	if db.showCastbar ~= false and i == 7 then
		cell.cast.dur, cell.cast.endT = 3, GetTime() + 1.1
		cell.cast:SetMinMaxValues(0, 3)
		cell.cast:Show()
	else
		cell.cast:Hide()
	end
	local bcol
	if dN > 0 and db.showDebuffs then
		for d = 1, dN do
			local dn = cell.debuffs[d].dispel
			if dn then bcol = DebuffColor(dn) break end
		end
		bcol = bcol or DebuffColor("")
	elseif threat and (aggroStyle == "BORDER" or aggroStyle == "BOTH") then
		local agc = db.aggroColor or { r = 1, g = 0, b = 0 }
		bcol = { agc.r, agc.g, agc.b }
	elseif db.targetHighlight and i == 1 then
		bcol = { HG.accent.r, HG.accent.g, HG.accent.b }
	end
	if bcol then HG:SetTemplate(cell, "Default", nil, bcol) else HG:SetTemplate(cell, "Default") end
	cell:SetAlpha(db.rangeFade and i % 6 == 5 and (db.rangeAlpha or 0.4) or 1)
end

function RG:Layout()
	local f = self.frame
	if not f then return end
	local db = self.db
	local w, h, sp, gsp = db.barW, db.barH, db.spacing, db.groupSpacing
	local scale = db.scale or 1
	local gx = db.growthX == "LEFT" and -1 or 1
	local gy = db.growthY == "UP" and 1 or -1
	local vert = db.orientation == "VERTICAL"
	local tex = db.barStyle == "DEFAULT" and "Interface\\TargetingFrame\\UI-StatusBar" or HG.media.statusbar
	for g = 1, MAX_GROUPS do
		local col = gx == 1 and (g - 1) or (MAX_GROUPS - g)
		for r = 1, MAX_ROWS do
			local cell = self.cells[g][r]
			local row = gy == -1 and (r - 1) or (MAX_ROWS - r)
			cell:SetSize(w, h)
			cell:ClearAllPoints()
			if vert then
				-- groups as rows: cells inside a group grow horizontally
				cell:SetPoint("TOPLEFT", 4 + row * (w + sp), -(4 + col * (h + gsp)))
			else
				cell:SetPoint("TOPLEFT", 4 + col * (w + gsp), -(4 + row * (h + sp)))
			end
			-- per-cell skinning options
			cell.hp:SetStatusBarTexture(tex)
			cell.hp.bg:SetTexture(tex)
			cell.inc:SetStatusBarTexture(tex)
			cell.abs:SetStatusBarTexture(tex)
			cell.pow:SetStatusBarTexture(tex)
			local bgc = db.bgColor or { r = 0.08, g = 0.08, b = 0.08 }
			cell.hp.bg:SetVertexColor(bgc.r, bgc.g, bgc.b, db.bgAlpha or 0.9)
			local ic = db.incColor or { r = 0.2, g = 0.8, b = 0.2 }
			cell.inc:SetStatusBarColor(ic.r, ic.g, ic.b, 0.4)
			local ac = db.absColor or { r = 1, g = 0.85, b = 0.2 }
			cell.abs:SetStatusBarColor(ac.r, ac.g, ac.b, 0.45)
			local agc = db.aggroColor or { r = 1, g = 0, b = 0 }
			cell.aggro:SetColorTexture(agc.r, agc.g, agc.b, 0.85)
			local ccol = db.castColor or { r = 1, g = 0.7, b = 0.2 }
			cell.cast:SetStatusBarColor(ccol.r, ccol.g, ccol.b, 0.9)
			cell.bigDebuff:SetSize((db.debuffSize or 12) * 2, (db.debuffSize or 12) * 2)
			cell.pow:SetHeight(db.powerHeight or 3)
			HG:SetFont(cell.name, nil, db.nameSize or 10, "OUTLINE")
			HG:SetFont(cell.hpText, nil, db.lifeSize or 9, "OUTLINE")
			HG:SetFont(cell.role, nil, db.lifeSize or 9, "OUTLINE")
			local ds = db.debuffSize or 12
			for i = 1, MAX_DEBUFFS do
				local t = cell.debuffs[i]
				t:SetSize(ds, ds)
				t:ClearAllPoints()
				t:SetPoint("TOPRIGHT", -(2 + (i - 1) * (ds + 1)), -2)
			end
		end
	end
	if vert then
		f:SetSize(8 + MAX_ROWS * w + (MAX_ROWS - 1) * sp, 8 + MAX_GROUPS * h + (MAX_GROUPS - 1) * gsp)
	else
		f:SetSize(8 + MAX_GROUPS * w + (MAX_GROUPS - 1) * gsp, 8 + MAX_ROWS * h + (MAX_ROWS - 1) * sp)
	end
	local ctxf = IsInRaid() and (db.scaleRaid or 1)
		or (IsInGroup() and (db.scaleParty or 1) or (db.scaleSolo or 1))
	f:SetScale(scale * ctxf)
	f:SetAlpha(db.frameAlpha or 1)
	f.anchor:SetShown(not db.hideAnchor)
end

function RG:Refresh()
	local f = self.frame
	if not f or not f:IsShown() then return end
	self.hlSet = ParseIDSet(self.db.highlightSpells)
	self:Collect()
	-- visibility rule failed: hide the whole frame; Tick re-shows it when the
	-- rule matches again (wantShown)
	if not self:ShouldShow() then f:Hide() return end
	local maxUsed = 0
	local combat = InCombatLockdown()
	local function PaintCell(cell, m)
		local ok, err = pcall(self.Paint, self, cell, m)
		if not ok and not self.paintErrLogged then
			self.paintErrLogged = true
			HG:LogError(tostring(err), "HealGrid:Paint")
		end
	end
	local count = 0
	for g = 1, MAX_GROUPS do
		local list = members[g]
		if list and #list > 0 then maxUsed = g count = count + #list end
		for r = 1, MAX_ROWS do
			local cell, m = self.cells[g][r], list and list[r]
			if combat then
				-- protected frames: Show/Hide/SetAttribute are blocked in combat.
				-- Repaint slots still showing the same unit, alpha-hide the rest
				-- and re-layout after combat.
				if m and cell:IsShown() and cell.unit == m.unit then
					cell.m = m
					PaintCell(cell, m)
				elseif cell:IsShown() then
					cell:SetAlpha(0)
					self.combatDirty = true
				end
			elseif m then
				if cell.unit ~= m.unit then
					cell.unit = m.unit
					cell:SetAttribute("unit", m.unit)
					self:ApplyClicksTo(cell)
				end
				cell.m = m
				cell:Show()
				PaintCell(cell, m)
			else
				cell:Hide()
			end
		end
	end
	-- hide the grid during combat when requested (alpha only — combat safe)
	f:SetAlpha(combat and self.db.hideInCombat and 0 or (self.db.frameAlpha or 1))
	-- shrink the panel to the populated columns when hideEmpty is on
	if not combat and self.db.hideEmpty and maxUsed > 0 then
		local w, h, sp, gsp = self.db.barW, self.db.barH, self.db.spacing, self.db.groupSpacing
		if self.db.orientation == "VERTICAL" then
			f:SetSize(8 + MAX_ROWS * w + (MAX_ROWS - 1) * sp, 8 + maxUsed * h + (maxUsed - 1) * gsp)
		else
			f:SetSize(8 + maxUsed * w + (maxUsed - 1) * gsp, 8 + MAX_ROWS * h + (MAX_ROWS - 1) * sp)
		end
	end
	-- deferred fixup once combat ends (re-run is throttled: only one queued)
	if combat and self.combatDirty and not self._regenQueued then
		self._regenQueued = true
		HG:RunOutOfCombat(function()
			self._regenQueued, self.combatDirty = nil, nil
			self:Layout()
			self:ApplyClicks()
			self:Refresh()
		end)
	end
	self.lastCount, self.lastGroups = count, maxUsed
	self:UpdateStatus()
end

function RG:UpdateStatus()
	if self.cfg and self.cfg.status then
		self.cfg.status:SetText(format("|cff888888%d %s · %d %s|r",
			self.lastCount or 0, L["cells"], self.lastGroups or 0, L["groups"]))
	end
end

-- dedicated options window (own frame) --------------------------------------
local CC_MOD_ORDER = { "none", "shift", "ctrl", "alt" }
local CC_MOD_LABEL = { none = "–", shift = "Shift", ctrl = "Ctrl", alt = "Alt" }
local CC_BTN_ORDER = { "1", "2", "3", "4", "5" }
local CC_BTN_LABEL = { ["1"] = L["Left Button"], ["2"] = L["Right Button"], ["3"] = L["Middle Button"], ["4"] = "4", ["5"] = "5" }
local CC_TYPE_ORDER = { "spell", "macro", "item", "target", "focus", "togglemenu" }
local CC_TYPE_LABEL = { spell = L["Cast Spell"], macro = L["Run Macro"], item = L["Use Item"], target = L["Target Unit"], focus = L["Set Focus"], togglemenu = L["Toggle Menu"] }

local function CycleVal(order, cur)
	for i, v in ipairs(order) do if v == cur then return order[(i % #order) + 1] end end
	return order[1]
end

local function CycleBtn(parent, w, label, tooltip)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, 20)
	HG:SkinButton(b)
	b.txt = HG:FontString(b, 10, "OUTLINE")
	b.txt:SetPoint("CENTER")
	b.txt:SetText(label)
	return b
end

local function CheckRow(parent, key, label, y)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", 6, y)
	cb:SetSize(20, 20)
	HG:SkinCheckBox(cb)
	cb:SetChecked(HG.db[key] and true or false)
	cb:SetScript("OnClick", function(c)
		HG.db[key] = c:GetChecked() and true or false
		RG:Update()
	end)
	local t = HG:FontString(cb, 10)
	t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
	t:SetText(label)
	return cb
end

local function SliderRow(parent, key, label, mn, mx, step, y, isScale)
	local name = "HealGridSlider" .. key
	local sl = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
	sl:SetPoint("TOPLEFT", 16, y)
	sl:SetSize(190, 14)
	sl:SetMinMaxValues(mn, mx)
	sl:SetValueStep(step)
	sl:SetObeyStepOnDrag(true)
	sl:SetValue(HG.db[key])
	HG:SkinSlider(sl)
	_G[name .. "Text"]:SetText(label .. ": " .. format(isScale and "%.2f" or "%d", HG.db[key]))
	_G[name .. "Low"]:SetText(tostring(mn))
	_G[name .. "High"]:SetText(tostring(mx))
	sl:SetScript("OnValueChanged", function(_, v)
		v = floor(v / step + 0.5) * step
		if HG.db[key] ~= v then
			HG.db[key] = v
			_G[name .. "Text"]:SetText(label .. ": " .. format(isScale and "%.2f" or "%d", v))
			RG:Update()
		end
	end)
	return sl
end

local function BindingRow(parent, idx, y)
	local B = function() return HG.db.clickCast.bindings[idx] end
	local row = CreateFrame("Frame", nil, parent)
	row:SetPoint("TOPLEFT", 0, y)
	row:SetSize(430, 24)

	row.mod = CycleBtn(row, 56, CC_MOD_LABEL[B().mod or "none"] or "–")
	row.mod:SetPoint("LEFT", 0, 0)
	row.mod:SetScript("OnClick", function()
		B().mod = CycleVal(CC_MOD_ORDER, B().mod or "none")
		row.mod.txt:SetText(CC_MOD_LABEL[B().mod])
		RG:Update()
	end)

	row.btn = CycleBtn(row, 64, CC_BTN_LABEL[B().button or "1"] or "1")
	row.btn:SetPoint("LEFT", row.mod, "RIGHT", 4, 0)
	row.btn:SetScript("OnClick", function()
		B().button = CycleVal(CC_BTN_ORDER, B().button or "1")
		row.btn.txt:SetText(CC_BTN_LABEL[B().button])
		RG:Update()
	end)

	row.typ = CycleBtn(row, 84, CC_TYPE_LABEL[B().type or "spell"] or "?")
	row.typ:SetPoint("LEFT", row.btn, "RIGHT", 4, 0)
	row.typ:SetScript("OnClick", function()
		B().type = CycleVal(CC_TYPE_ORDER, B().type or "spell")
		row.typ.txt:SetText(CC_TYPE_LABEL[B().type])
		RG:Update()
	end)

	row.val = CreateFrame("EditBox", nil, row)
	row.val:SetPoint("LEFT", row.typ, "RIGHT", 6, 0)
	row.val:SetSize(150, 20)
	row.val:SetAutoFocus(false)
	row.val:SetText(B().value or "")
	row.val:SetFontObject("GameFontHighlightSmall")
	HG:SkinEditBox(row.val)
	row.val:SetScript("OnEnterPressed", function(e) B().value = strtrim(e:GetText()) e:ClearFocus() row.pick.txt:SetText(row.pick:Label()) RG:Update() end)
	row.val:SetScript("OnEditFocusLost", function(e) B().value = strtrim(e:GetText()) row.pick.txt:SetText(row.pick:Label()) RG:Update() end)

	-- class spell picker: cycles keywords + every known class heal spell
	row.pick = CycleBtn(row, 110, "?")
	row.pick:SetPoint("LEFT", row.val, "RIGHT", 4, 0)
	function row.pick:Label()
		local v = B().value or ""
		if v == "" then return "…" end
		return (v:len() > 18) and (v:sub(1, 17) .. "…") or v
	end
	row.pick.txt:SetText(row.pick:Label())
	row.pick:SetScript("OnClick", function()
		B().value = CycleVal(ClassSpellList(), B().value or "")
		row.val:SetText(B().value)
		row.pick.txt:SetText(row.pick:Label())
		RG:Update()
	end)
	row.pick:SetScript("OnEnter", function(b)
		GameTooltip:SetOwner(b, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Pick class spell"] or "Pick class spell")
		GameTooltip:Show()
	end)
	row.pick:SetScript("OnLeave", function() GameTooltip:Hide() end)

	row.del = CreateFrame("Button", nil, row)
	row.del:SetPoint("LEFT", row.pick, "RIGHT", 4, 0)
	row.del:SetSize(18, 18)
	HG:SkinButton(row.del)
	local dtxt = HG:FontString(row.del, 10, "OUTLINE")
	dtxt:SetPoint("CENTER")
	dtxt:SetText("x")
	row.del:SetScript("OnClick", function()
		tremove(HG.db.clickCast.bindings, idx)
		RG:RefreshConfig() RG:Update()
	end)
	return row
end

local function OptRow(parent, key, label, order, labels, y)
	local t = HG:FontString(parent, 10)
	t:SetPoint("TOPLEFT", 16, y)
	t:SetText(label)
	local b = CycleBtn(parent, 110, labels[HG.db[key]] or HG.db[key])
	b:SetPoint("LEFT", t, "RIGHT", 10, 0)
	b:SetScript("OnClick", function()
		HG.db[key] = CycleVal(order, HG.db[key])
		b.txt:SetText(labels[HG.db[key]] or HG.db[key])
		RG:Update()
	end)
	return b
end

local function ColorRow(parent, key, label, y, container)
	local store = container or HG.db
	local t = HG:FontString(parent, 10)
	t:SetPoint("TOPLEFT", 16, y)
	t:SetText(label)
	local sw = CreateFrame("Button", nil, parent)
	sw:SetSize(22, 20)
	sw:SetPoint("LEFT", t, "RIGHT", 10, 0)
	HG:SkinButton(sw)
	local tex = sw:CreateTexture(nil, "OVERLAY")
	local c = store[key] or { r = 1, g = 1, b = 1 }
	tex:SetColorTexture(c.r, c.g, c.b)
	HG:SetInside(tex, sw, 3, 3)
	sw:SetScript("OnClick", function()
		HG:PickColor(store[key] or {}, function(r, g, b)
			store[key] = { r = r, g = g, b = b }
			tex:SetColorTexture(r, g, b)
			RG:Update()
		end)
	end)
	return sw
end

-- read-only editbox that selects its contents on focus so URLs can be copied
local function LinkRow(parent, label, url, y)
	local t = HG:FontString(parent, 10)
	t:SetPoint("TOPLEFT", 16, y)
	t:SetText(label)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetPoint("LEFT", t, "RIGHT", 10, 0)
	eb:SetSize(190, 20)
	eb:SetAutoFocus(false)
	eb:SetText(url)
	eb:SetFontObject("GameFontHighlightSmall")
	HG:SkinEditBox(eb)
	eb:SetScript("OnEditFocusGained", function(e) e:HighlightText() end)
	eb:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)
	eb:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)
	eb:SetScript("OnTextChanged", function(e, user)
		if user then e:SetText(url) e:HighlightText() end
	end)
	return eb
end

-- free-text editbox writing into a db key (spell id lists, macro text, ...)
local function EditRow(parent, key, label, y)
	local t = HG:FontString(parent, 10)
	t:SetPoint("TOPLEFT", 16, y)
	t:SetText(label)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetPoint("LEFT", t, "RIGHT", 10, 0)
	eb:SetSize(150, 20)
	eb:SetAutoFocus(false)
	eb:SetText(HG.db[key] or "")
	eb:SetFontObject("GameFontHighlightSmall")
	HG:SkinEditBox(eb)
	local function apply(e)
		HG.db[key] = strtrim(e:GetText())
		RG:Update()
	end
	eb:SetScript("OnEnterPressed", function(e) apply(e) e:ClearFocus() end)
	eb:SetScript("OnEditFocusLost", apply)
	eb:SetScript("OnEscapePressed", function(e) e:SetText(HG.db[key] or "") e:ClearFocus() end)
	return eb
end

local function PlainBtn(parent, w, label, x, y)
	local b = CreateFrame("Button", nil, parent)
	b:SetPoint("TOPLEFT", x, y)
	b:SetSize(w, 20)
	HG:SkinButton(b)
	b.txt = HG:FontString(b, 10, "OUTLINE")
	b.txt:SetPoint("CENTER")
	b.txt:SetText(label)
	return b
end

-- rebuild the whole options window (after profile load / reset)
function RG:RebuildConfig()
	if self.cfg then self.cfg:Hide() self.cfg = nil end
	local nf = self:BuildConfig()
	self:RefreshConfig()
	self:Update()
	nf:Show()
end

function RG:BuildConfig()
	if self.cfg then return self.cfg end
	local f = CreateFrame("Frame", "HealGridConfig", UIParent, HG.BackdropTemplate)
	f:SetSize(720, 430)
	f:SetPoint("CENTER")
	f:SetMovable(true) f:EnableMouse(true) f:RegisterForDrag("LeftButton")
	f:SetClampedToScreen(true) f:SetFrameStrata("DIALOG") f:SetToplevel(true)
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	HG:SkinFrame(f, "Default")
	local title = HG:FontString(f, 13, "OUTLINE")
	title:SetPoint("TOP", 0, -10)
	title:SetText("|cff" .. HG.accentHex .. "HealGrid|r  " .. L["Settings"])
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	HG:SkinCloseButton(close)
	close:SetScript("OnClick", function() f:Hide() end)
	tinsert(UISpecialFrames, "HealGridConfig")

	-- tabbed pages --------------------------------------------------------------
	f.pages, f.tabs = {}, {}
	local function SelectTab(i)
		for n, p in ipairs(f.pages) do p:SetShown(n == i) end
		for n, tb in ipairs(f.tabs) do
			tb.txt:SetTextColor(1, 1, 1)
			if n == i then tb.txt:SetTextColor(HG.accent.r, HG.accent.g, HG.accent.b) end
		end
	end
	local tabDefs = { "General", "Layout", "Bars", "Text", "Icons", "Colors", "Click Cast", "Profiles", "About" }
	for i, name in ipairs(tabDefs) do
		local tb = CreateFrame("Button", nil, f)
		tb:SetSize(74, 20)
		tb:SetPoint("TOPLEFT", 8 + (i - 1) * 78, -32)
		HG:SkinButton(tb)
		tb.txt = HG:FontString(tb, 9, "OUTLINE")
		tb.txt:SetPoint("CENTER")
		tb.txt:SetText(L[name])
		tb:SetScript("OnClick", function() SelectTab(i) end)
		f.tabs[i] = tb
		local p = CreateFrame("Frame", nil, f)
		p:SetPoint("TOPLEFT", 8, -60)
		p:SetPoint("BOTTOMRIGHT", -8, 28)
		p:Hide()
		f.pages[i] = p
	end
	SelectTab(1)

	-- footer: live status + global reset
	f.status = HG:FontString(f, 9)
	f.status:SetPoint("BOTTOMLEFT", 10, 9)
	local rst = PlainBtn(f, 70, L["Reset"], 0, 0)
	rst:ClearAllPoints()
	rst:SetPoint("BOTTOMRIGHT", -10, 6)
	rst:SetScript("OnClick", function()
		HG:ResetSettings()
		RG:RebuildConfig()
	end)

	-- two ~296px columns per page; all row helpers anchor inside the column
	local function Col(p, n)
		local c = CreateFrame("Frame", nil, p)
		c:SetPoint("TOPLEFT", (n - 1) * 302, 0)
		c:SetSize(296, 10)
		return c
	end

	-- 1: general ------------------------------------------------------------------
	do
		local p = f.pages[1]
		local c1, c2 = Col(p, 1), Col(p, 2)
		local t = {
			{ "showWhenSolo", L["Show When Solo"] }, { "hideEmpty", L["Hide Empty"] },
			{ "hideInCombat", L["Hide In Combat"] }, { "lockFrame", L["Lock Frame"] },
			{ "unitTooltip", L["Unit Tooltip"] }, { "targetHighlight", L["Target Highlight"] },
			{ "showAFK", L["Show AFK"] }, { "showPets", L["Show Pets"] },
			{ "hideAnchor", L["Hide Anchor"] }, { "macroPad", L["Macro Pad"] },
		}
		for i, v in ipairs(t) do CheckRow(c1, v[1], v[2], -18 - (i - 1) * 24) end
		EditRow(c1, "macroPadText", L["Macro"], -264)
		OptRow(c2, "visMode", L["Visibility"], { "ALWAYS", "GROUP", "RAID" },
			{ ALWAYS = L["Always"], GROUP = L["Group"], RAID = L["Raid"] }, -18)
		OptRow(c2, "testSize", L["Test Mode"], { 0, 5, 10, 20, 25, 40 },
			{ [0] = L["Off"] }, -44)
		SliderRow(c2, "scale", L["Scale"], 0.4, 2, 0.05, -78, true)
		SliderRow(c2, "frameAlpha", L["Opacity"], 0.2, 1, 0.05, -110, true)
	end

	-- 2: layout ---------------------------------------------------------------------
	do
		local p = f.pages[2]
		local c1, c2 = Col(p, 1), Col(p, 2)
		SliderRow(c1, "barW", L["Bar W"], 24, 200, 1, -18)
		SliderRow(c1, "barH", L["Bar H"], 12, 80, 1, -50)
		SliderRow(c1, "spacing", L["Spacing"], 0, 20, 1, -82)
		SliderRow(c1, "groupSpacing", L["Group Spacing"], 0, 40, 1, -114)
		SliderRow(c1, "powerHeight", L["Power Height"], 0, 12, 1, -146)
		OptRow(c2, "growthX", L["Groups grow"], { "RIGHT", "LEFT" },
			{ RIGHT = L["Right"], LEFT = L["Left"] }, -18)
		OptRow(c2, "growthY", L["Cells grow"], { "DOWN", "UP" },
			{ DOWN = L["Down"], UP = L["Up"] }, -44)
		OptRow(c2, "orientation", L["Orientation"], { "HORIZONTAL", "VERTICAL" },
			{ HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] }, -70)
		OptRow(c2, "sortMethod", L["Sort by"], { "INDEX", "NAME", "ROLE" },
			{ INDEX = L["Index"], NAME = L["Name"], ROLE = L["Role"] }, -96)
		SliderRow(c2, "scaleSolo", L["Scale Solo"], 0.4, 2, 0.05, -130, true)
		SliderRow(c2, "scaleParty", L["Scale Party"], 0.4, 2, 0.05, -162, true)
		SliderRow(c2, "scaleRaid", L["Scale Raid"], 0.4, 2, 0.05, -194, true)
	end

	-- 3: bars ------------------------------------------------------------------------
	do
		local p = f.pages[3]
		local c1, c2 = Col(p, 1), Col(p, 2)
		local t = {
			{ "showPower", L["Show Power"] }, { "showIncHeal", L["Show Inc Heal"] },
			{ "showAbsorb", L["Show Absorb"] }, { "rangeFade", L["Range Fade"] },
			{ "castHighlight", L["Cast Highlight"] }, { "showCastbar", L["Show Castbar"] },
			{ "showHotCorner", L["Hot Corner"] },
		}
		for i, v in ipairs(t) do CheckRow(c1, v[1], v[2], -18 - (i - 1) * 24) end
		SliderRow(c1, "rangeAlpha", L["Range Alpha"], 0, 1, 0.05, -202, true)
		SliderRow(c1, "bgAlpha", L["Bg Alpha"], 0, 1, 0.05, -234, true)
		OptRow(c2, "healthMode", L["Health color"], { "CLASS", "GRADIENT", "CUSTOM" },
			{ CLASS = L["Class colored bar"], GRADIENT = L["Health gradient (green to red)"], CUSTOM = L["Custom"] }, -18)
		OptRow(c2, "barStyle", L["Bar Texture"], { "FLAT", "DEFAULT" },
			{ FLAT = L["Flat"], DEFAULT = L["Default"] }, -44)
	end

	-- 4: text --------------------------------------------------------------------------
	do
		local p = f.pages[4]
		local c1, c2 = Col(p, 1), Col(p, 2)
		SliderRow(c1, "nameSize", L["Name Size"], 6, 20, 1, -18)
		SliderRow(c1, "lifeSize", L["Life Size"], 6, 16, 1, -50)
		SliderRow(c1, "nameMaxLen", L["Name Length"], 0, 20, 1, -82)
		OptRow(c2, "lifeMode", L["Life Text"], { "PERCENT", "DEFICIT", "BOTH", "NONE" },
			{ PERCENT = L["Percent"], DEFICIT = L["Deficit"], BOTH = L["Both"], NONE = L["None"] }, -18)
		CheckRow(c2, "showRole", L["Show Role"], -50)
	end

	-- 5: icons --------------------------------------------------------------------------
	do
		local p = f.pages[5]
		local c1, c2 = Col(p, 1), Col(p, 2)
		local t = {
			{ "showDebuffs", L["Show Debuffs"] }, { "onlyDispellable", L["Dispellable Only"] },
			{ "showRaidIcon", L["Show Raid Icon"] }, { "showResIcon", L["Show Res Icon"] },
			{ "showReadyCheck", L["Show Ready Check"] }, { "rezOnDead", L["Rez On Dead"] },
		}
		for i, v in ipairs(t) do CheckRow(c1, v[1], v[2], -18 - (i - 1) * 24) end
		SliderRow(c2, "debuffSize", L["Debuff Size"], 6, 24, 1, -18)
		OptRow(c2, "aggroStyle", L["Aggro"], { "DOT", "BORDER", "BOTH", "NONE" },
			{ DOT = L["Dot"], BORDER = L["Border"], BOTH = L["Both"], NONE = L["None"] }, -52)
		OptRow(c2, "dispelAlert", L["Dispel Alert"], { "NONE", "SOUND", "FLASH", "BOTH" },
			{ NONE = L["None"], SOUND = L["Sound"], FLASH = L["Flash"], BOTH = L["Both"] }, -78)
		EditRow(c2, "highlightSpells", L["Highlight IDs"], -108)
	end

	-- 6: colors ---------------------------------------------------------------------------
	do
		local p = f.pages[6]
		local c1, c2 = Col(p, 1), Col(p, 2)
		local h1 = HG:FontString(c1, 10, "OUTLINE")
		h1:SetPoint("TOPLEFT", 16, -14)
		h1:SetText("|cff" .. HG.accentHex .. (L["Bars"] or "Bars") .. "|r")
		ColorRow(c1, "customColor", L["Custom Color"], -32)
		ColorRow(c1, "bgColor", L["Bg Color"], -58)
		ColorRow(c1, "incColor", L["Inc Heal Color"], -84)
		ColorRow(c1, "absColor", L["Absorb Color"], -110)
		ColorRow(c1, "aggroColor", L["Aggro Color"], -136)
		ColorRow(c1, "hotColor", L["Hot Color"], -162)
		ColorRow(c1, "castColor", L["Cast Color"], -188)
		local h2 = HG:FontString(c2, 10, "OUTLINE")
		h2:SetPoint("TOPLEFT", 16, -14)
		h2:SetText("|cff" .. HG.accentHex .. (L["Debuff Border"] or "Debuff Border") .. "|r")
		local dc = HG.db.debuffColors or {}
		ColorRow(c2, "Magic", L["Magic"], -32, dc)
		ColorRow(c2, "Curse", L["Curse"], -58, dc)
		ColorRow(c2, "Poison", L["Poison"], -84, dc)
		ColorRow(c2, "Disease", L["Disease"], -110, dc)
		ColorRow(c2, "Other", L["Other"], -136, dc)
	end

	-- 8: profiles ----------------------------------------------------------------------------
	do
		local p = f.pages[8]
		local c1, c2 = Col(p, 1), Col(p, 2)
		local nt = HG:FontString(c1, 10)
		nt:SetPoint("TOPLEFT", 16, -14)
		nt:SetText(L["Profile name"])
		local neb = CreateFrame("EditBox", nil, c1)
		neb:SetPoint("TOPLEFT", 16, -32)
		neb:SetSize(170, 20)
		neb:SetAutoFocus(false)
		neb:SetFontObject("GameFontHighlightSmall")
		HG:SkinEditBox(neb)
		neb:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)
		neb:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)
		PlainBtn(c1, 80, L["Save"], 16, -60):SetScript("OnClick", function()
			local n = strtrim(neb:GetText())
			if n == "" then return end
			HealGridDB.profiles[n] = HG:SerializeDB()
			RG:RefreshConfig()
		end)
		PlainBtn(c1, 80, L["Load"], 102, -60):SetScript("OnClick", function()
			local n = strtrim(neb:GetText())
			local t = n ~= "" and HG:DeserializeDB(HealGridDB.profiles and HealGridDB.profiles[n])
			if t then HG:ApplySettings(t) RG:RebuildConfig() end
		end)
		PlainBtn(c1, 80, L["Delete"], 188, -60):SetScript("OnClick", function()
			local n = strtrim(neb:GetText())
			if n ~= "" then HealGridDB.profiles[n] = nil RG:RefreshConfig() end
		end)
		local lh = HG:FontString(c1, 10, "OUTLINE")
		lh:SetPoint("TOPLEFT", 16, -92)
		lh:SetText("|cff" .. HG.accentHex .. (L["Saved profiles"] or "Saved profiles") .. "|r")
		f.profileRows = CreateFrame("Frame", nil, c1)
		f.profileRows:SetPoint("TOPLEFT", 8, -110)
		f.profileRows:SetSize(280, 200)
		-- per-character settings + export/import
		local cb = CreateFrame("CheckButton", nil, c2, "UICheckButtonTemplate")
		cb:SetPoint("TOPLEFT", 6, -14)
		cb:SetSize(20, 20)
		HG:SkinCheckBox(cb)
		cb:SetChecked(HealGridDB.useCharProfile and true or false)
		local cbl = HG:FontString(cb, 10)
		cbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
		cbl:SetText(L["Char Profile"])
		cb:SetScript("OnClick", function(c)
			HG:SetCharProfile(c:GetChecked())
			RG:RebuildConfig()
		end)
		local exB = PlainBtn(c2, 90, L["Export"], 16, -48)
		local eeb = CreateFrame("EditBox", nil, c2)
		eeb:SetPoint("TOPLEFT", 16, -74)
		eeb:SetSize(270, 20)
		eeb:SetAutoFocus(false)
		eeb:SetFontObject("GameFontHighlightSmall")
		HG:SkinEditBox(eeb)
		eeb:SetScript("OnEditFocusGained", function(e) e:HighlightText() end)
		eeb:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)
		exB:SetScript("OnClick", function() eeb:SetText(HG:SerializeDB()) eeb:SetFocus() end)
		local ieb = CreateFrame("EditBox", nil, c2)
		ieb:SetPoint("TOPLEFT", 16, -106)
		ieb:SetSize(270, 20)
		ieb:SetAutoFocus(false)
		ieb:SetFontObject("GameFontHighlightSmall")
		HG:SkinEditBox(ieb)
		ieb:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)
		ieb:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)
		PlainBtn(c2, 90, L["Import"], 16, -134):SetScript("OnClick", function()
			local t = HG:DeserializeDB(ieb:GetText())
			if t then
				HG:ApplySettings(t)
				RG:RebuildConfig()
			else
				HG:Print(L["Invalid import string"] or "Invalid import string")
			end
		end)
	end

	-- 9: about ------------------------------------------------------------------------------
	do
		local p = f.pages[9]
		local c1, c2 = Col(p, 1), Col(p, 2)
		local meta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
		local ver = meta and meta("HealGrid", "Version") or "?"
		local logo = c1:CreateTexture(nil, "ARTWORK")
		logo:SetTexture("Interface\\AddOns\\HealGrid\\logo")
		logo:SetPoint("TOPLEFT", 16, -8)
		logo:SetSize(80, 80)
		local h = HG:FontString(c1, 14, "OUTLINE")
		h:SetPoint("TOPLEFT", logo, "TOPRIGHT", 12, -14)
		h:SetText("|cff" .. HG.accentHex .. "Heal|rGrid  |cff888888v" .. ver .. "|r")
		local a = HG:FontString(c1, 10)
		a:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
		a:SetText("|cff888888" .. (L["by"] or "by") .. "|r xRL-Dev")
		LinkRow(c1, L["Homepage"], "https://xrl-dev.de", -104)
		LinkRow(c1, L["Bugtracker"], "https://xrl-dev.de/bugtracker", -130)
		LinkRow(c1, L["Impressum"], "https://xrl-dev.de/page/impressum", -156)
		LinkRow(c1, L["Repository"], "https://github.com/rldevde/HealGrid", -182)
		local h2 = HG:FontString(c2, 10, "OUTLINE")
		h2:SetPoint("TOPLEFT", 16, -14)
		h2:SetText("|cff" .. HG.accentHex .. (L["Slash Commands"] or "Slash Commands") .. "|r")
		local s = HG:FontString(c2, 10)
		s:SetPoint("TOPLEFT", 16, -34)
		s:SetText("|cffaaaaaa/healgrid, /hg|r — " .. (L["toggle the grid"] or "toggle the grid") .. "\n" ..
			"|cffaaaaaa/healgrid options|r — " .. (L["open this window"] or "open this window") .. "\n" ..
			"|cffaaaaaa/healgrid scan|r — " .. (L["dump visible frames (debug)"] or "dump visible frames (debug)"))
		s:SetSpacing(4)
		local note = HG:FontString(c2, 10)
		note:SetPoint("TOPLEFT", 16, -110)
		note:SetWidth(270)
		note:SetJustifyH("LEFT")
		note:SetText("|cff888888" .. (L["Bugs and feedback go to the bugtracker or GitHub issues. Click a link field and press Ctrl+C to copy."] or "") .. "|r")
	end

	-- 7: click-cast bindings ---------------------------------------------------------------
	local bot = f.pages[7]
	local bh = HG:FontString(bot, 10, "OUTLINE")
	bh:SetPoint("TOPLEFT", 0, 0)
	bh:SetText("|cff888888" .. (L["mod · button · action · spell (click to cycle, 'heal'/'dispel' = class spells)"] or "") .. "|r")
	f.bindScroll = CreateFrame("ScrollFrame", "HealGridBindScroll", bot, "UIPanelScrollFrameTemplate")
	f.bindScroll:SetPoint("TOPLEFT", 0, -18)
	f.bindScroll:SetPoint("BOTTOMRIGHT", -30, 26)
	f.bindRows = CreateFrame("Frame", nil, f.bindScroll)
	f.bindRows:SetSize(560, 1)
	f.bindScroll:SetScrollChild(f.bindRows)
	f.bindScroll:SetScript("OnMouseWheel", function(s, delta)
		local sb = s.ScrollBar or _G[s:GetName() .. "ScrollBar"]
		if sb then sb:SetValue(sb:GetValue() - delta * 26) end
	end)
	local add = CreateFrame("Button", nil, bot)
	add:SetSize(110, 20)
	add:SetPoint("BOTTOMLEFT", 0, 0)
	HG:SkinButton(add)
	local addTxt = HG:FontString(add, 10, "OUTLINE")
	addTxt:SetPoint("CENTER")
	addTxt:SetText(L["Add Binding"])
	add:SetScript("OnClick", function()
		tinsert(HG.db.clickCast.bindings, { button = "3", mod = "none", type = "spell", value = "" })
		RG:RefreshConfig() RG:Update()
	end)
	f:Hide()
	self.cfg = f
	return f
end

function RG:RefreshConfig()
	local f = self.cfg
	if not f then return end
	for _, r in ipairs(f._brows or {}) do r:Hide() end
	wipe(f._brows or {})
	f._brows = f._brows or {}
	local binds = HG.db.clickCast.bindings
	for i, _ in ipairs(binds) do
		local row = BindingRow(f.bindRows, i, -(i - 1) * 26)
		f._brows[i] = row
		row:Show()
	end
	f.bindRows:SetHeight(max(1, #binds * 26))
	-- saved profile quick-load buttons
	for _, b in ipairs(f._prows or {}) do b:Hide() end
	f._prows = {}
	if f.profileRows then
		local names = {}
		for n in pairs(HealGridDB.profiles or {}) do names[#names + 1] = n end
		sort(names)
		for i, n in ipairs(names) do
			local b = PlainBtn(f.profileRows, 260, n, 0, -(i - 1) * 24)
			b:SetScript("OnClick", function()
				local t = HG:DeserializeDB(HealGridDB.profiles[n])
				if t then HG:ApplySettings(t) RG:RebuildConfig() end
			end)
			f._prows[i] = b
		end
	end
	self:UpdateStatus()
end

function RG:ToggleConfig()
	local f = self:BuildConfig()
	if f:IsShown() then f:Hide() else self:RefreshConfig() f:Show() end
end

-- diagnostic: dump every visible region >60px wide near the grid so we can
-- identify stray bars in-game via /healgrid scan
local function DumpRegions(obj, depth, tag)
	if depth > 5 or not obj then return end
	for i = 1, obj.GetNumRegions and select("#", obj:GetRegions()) or 0 do
		local r = select(i, obj:GetRegions())
		if r and r.IsShown and r:IsShown() then
			local w = r.GetWidth and r:GetWidth() or 0
			if w and w > 60 then
				local vr, vg, vb = r.GetVertexColor and r:GetVertexColor()
				HG:Print(format("%s[%s] %s w=%.0f h=%.0f col=%s",
					strrep("  ", depth), tag, tostring(r:GetObjectType()),
					w, r.GetHeight and r:GetHeight() or 0,
					vr and format("%.2f/%.2f/%.2f", vr, vg or 0, vb or 0) or "-"))
			end
		end
	end
	for _, child in ipairs({ obj.GetChildren and obj:GetChildren() }) do
		if child.IsShown and child:IsShown() then DumpRegions(child, depth + 1, tag) end
	end
end

function RG:ScanRegions()
	local f = self.frame
	if not f then HG:Print("HealGrid: no frame") return end
	HG:Print("HealGrid regions >60px wide:")
	DumpRegions(f, 0, "f")
	for g = 1, MAX_GROUPS do for r = 1, MAX_ROWS do
		local c = self.cells[g][r]
		if c:IsShown() then DumpRegions(c, 1, "cell" .. g .. "," .. r) end
	end end
end

-- driver ---------------------------------------------------------------------
local function Tick()
	if not RG.frame then return end
	if not RG.frame:IsShown() then
		-- hidden by a visibility rule: come back once the rule matches again
		if RG.wantShown and RG:ShouldShow() then RG.frame:Show() else return end
	end
	local ok, err = pcall(RG.Refresh, RG)
	if not ok and not RG.tickErrLogged then
		RG.tickErrLogged = true
		HG:LogError(tostring(err), "HealGrid:Refresh")
	end
end

function RG:Toggle()
	if InCombatLockdown() and not self.frame then
		-- protected cells cannot be configured in combat; defer the first show
		return HG:RunOutOfCombat(self.Toggle, self)
	end
	local ok, err = pcall(function()
		self:BuildFrame()
		if self.frame:IsShown() then
			self.wantShown = false
			self.frame:Hide()
			if ticker then ticker:Cancel() ticker = nil end
		else
			self.wantShown = true
			self.frame:Show()
			if InCombatLockdown() then
				HG:RunOutOfCombat(self.Layout, self)
				HG:RunOutOfCombat(self.ApplyClicks, self)
			else
				self:Layout()
				self:ApplyClicks()
			end
			self:Refresh()
			if not ticker then ticker = C_Timer.NewTicker(0.2, Tick) end
		end
	end)
	if not ok then
		HG:LogError(tostring(err), "HealGrid:Toggle")
		HG:Print("|cffff5555HealGrid: error - /healgrid to retry|r")
	end
end

function RG:GROUP_ROSTER_UPDATE()
	if self.frame and self.frame:IsShown() then self:Refresh() end
end

function RG:READY_CHECK_FINISHED()
	if self.frame and self.frame:IsShown() then self:Refresh() end
end

-- the macro pad needs protected attributes; defer in combat like clicks
function RG:ApplyMacroPad()
	local p = self.frame and self.frame.pad
	if not p then return end
	if InCombatLockdown() then return HG:RunOutOfCombat(self.ApplyMacroPad, self) end
	p:SetAttribute("type", "macro")
	p:SetAttribute("macrotext", self.db.macroPadText or "")
	p:SetShown(self.db.macroPad and (self.db.macroPadText or "") ~= "")
end

-- per-unit repaint: events carry the unit, so only matching cells get painted
function RG:OnUnitEvent(_, unit)
	if not self.cells or type(unit) ~= "string" then return end
	for g = 1, MAX_GROUPS do
		for r = 1, MAX_ROWS do
			local c = self.cells[g][r]
			if c:IsShown() and c.unit == unit and c.m then
				pcall(self.Paint, self, c, c.m)
			end
		end
	end
end

local function PlayerCastTimes()
	local _, _, _, s, e = UnitCastingInfo("player")
	if not e and UnitChannelInfo then _, _, _, s, e = UnitChannelInfo("player") end
	if e then return e / 1000, (e - s) / 1000 end
end

function RG:UNIT_SPELLCAST_SENT(_, unit, target)
	if unit ~= "player" then return end
	self.castTarget = (target and target ~= "") and Ambiguate(target, "short") or UnitName("target") and Ambiguate(UnitName("target"), "short") or nil
	self.castEndT, self.castDur = PlayerCastTimes()
end

local function ClearCast(unit)
	if unit == "player" then RG.castTarget = nil end
end
function RG:UNIT_SPELLCAST_STOP(_, unit) ClearCast(unit) end
function RG:UNIT_SPELLCAST_FAILED(_, unit) ClearCast(unit) end
function RG:UNIT_SPELLCAST_INTERRUPTED(_, unit) ClearCast(unit) end
function RG:UNIT_SPELLCAST_CHANNEL_STOP(_, unit) ClearCast(unit) end

function RG:Update()
	-- test mode forces the grid visible so it can be previewed solo
	if (self.db.testSize or 0) > 0 and (not self.frame or not self.frame:IsShown()) then
		if InCombatLockdown() then return HG:RunOutOfCombat(self.Update, self) end
		self:BuildFrame()
		self.wantShown = true
		self.frame:Show()
		self:Layout()
		self:ApplyClicks()
		self:Refresh()
		if not ticker then ticker = C_Timer.NewTicker(0.2, Tick) end
		return
	end
	if self.frame and self.frame:IsShown() then
		if InCombatLockdown() then
			-- Layout moves/sizes protected cells — defer everything to combat end
			HG:RunOutOfCombat(self.Layout, self)
			HG:RunOutOfCombat(self.ApplyClicks, self)
		else
			self:Layout()
			self:ApplyClicks()
		end
		self:ApplyMacroPad()
		self:Refresh()
	end
end

function RG:Initialize()
	self.db = HG.db
	if self.db.enable == false then return end

	HG.charDb.minimap = HG.charDb.minimap or {}
	self.minimapBtn = HG:CreateMinimapButton({
		name = "healgrid", icon = "Interface\\AddOns\\HealGrid\\icon",
		store = HG.charDb.minimap, angle = 330,
		onLeft = function() RG:Toggle() end,
		onRight = function() RG:ToggleConfig() end,
		tooltip = function()
			GameTooltip:AddLine("HealGrid")
			GameTooltip:AddLine(L["Left-click: toggle  |  Right-click: options  |  Drag: move"], 1, 1, 1)
		end,
	})

	self:RegisterEvent("GROUP_ROSTER_UPDATE")
	self:RegisterEvent("READY_CHECK_FINISHED")
	-- the class rez resolves from the spellbook: rebind once it has loaded
	self:RegisterEvent("SPELLS_CHANGED", function()
		if InCombatLockdown() then HG:RunOutOfCombat(RG.ApplyClicks, RG) else RG:ApplyClicks() end
	end)
	-- event-driven per-cell repaint instead of relying on the ticker alone
	for _, ev in ipairs({
		"UNIT_HEALTH_FREQUENT", "UNIT_MAXHEALTH", "UNIT_POWER_FREQUENT",
		"UNIT_AURA", "UNIT_FLAGS", "UNIT_CONNECTION", "UNIT_THREAT_SITUATION_UPDATE",
		"INCOMING_RESURRECT_CHANGED", "UNIT_HEAL_PREDICTION", "UNIT_ABSORB_AMOUNT_CHANGED",
	}) do
		self:RegisterEvent(ev, "OnUnitEvent")
	end
	-- track the player's spellcast target for the castbar + highlight
	self:RegisterEvent("UNIT_SPELLCAST_SENT")
	self:RegisterEvent("UNIT_SPELLCAST_STOP")
	self:RegisterEvent("UNIT_SPELLCAST_FAILED")
	self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
	self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

	-- healer classes get the grid automatically at login; everyone else
	-- toggles it manually via /healgrid or the minimap button
	if CLASS_SPELLS[HG.myClass] then
		self:Toggle()
	end

	SlashCmdList.HEALGRID = function(arg)
		arg = strtrim(arg or ""):lower()
		if arg == "options" or arg == "config" or arg == "opt" then
			RG:ToggleConfig()
		elseif arg == "scan" then
			RG:ScanRegions()
		else
			RG:Toggle()
		end
	end
	SLASH_HEALGRID1 = "/healgrid"
	SLASH_HEALGRID2 = "/hg"
end
