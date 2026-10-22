-- HealGrid core: namespace, compat layer, saved variables, event/module
-- system, combat queue, visual toolkit and minimap button factory.
-- Standalone addon — no SentinelUI required.
local addonName, HG = ...
_G.HealGrid = HG

HG.name = addonName
HG.version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(addonName, "Version") or "dev"
HG.accent = { r = 0.92, g = 0.68, b = 0.20 }
HG.accentHex = "ebad33"
HG.modules = {}
HG.moduleOrder = {}

local pairs, ipairs, type, select, floor, max = pairs, ipairs, type, select, math.floor, math.max
local format, tinsert, tremove, unpack = string.format, table.insert, table.remove, unpack
local BLANK = [[Interface\Buttons\WHITE8X8]]

local locale = GetLocale()
local isLatin = locale ~= "koKR" and locale ~= "zhCN" and locale ~= "zhTW"
HG.media = {
	statusbar = BLANK,
	font = isLatin and [[Fonts\ARIALN.TTF]] or STANDARD_TEXT_FONT,
	fontSize = 12,
	borderColor = { 0, 0, 0, 1 },
	backdropColor = { 0.075, 0.08, 0.1, 1 },
	backdropFadeColor = { 0.05, 0.06, 0.08, 0.82 },
}

function HG:Print(...)
	print(format("|cff%s[HealGrid]|r", self.accentHex), ...)
end

function HG:LogError(err, context)
	self:Print(format("|cffff5555%s: %s|r", tostring(context or "?"), tostring(err)))
end

local function SafeCall(context, func, ...)
	if type(func) ~= "function" then return end
	local ok, err = pcall(func, ...)
	if not ok then HG:LogError(err, context) return end
	return err
end
HG.SafeCall = SafeCall

-- API compatibility -----------------------------------------------------------
HG.BackdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil
HG.myClass = select(2, UnitClass("player"))

function HG.IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value) or false
end

function HG.GetSpellInfo(spell)
	if not spell then return end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spell)
		if info then return info.name, nil, info.iconID, info.castTime, info.minRange, info.maxRange, info.spellID end
		return
	end
	if GetSpellInfo then return GetSpellInfo(spell) end
end

HG.IsSpellKnown = (C_Spell and C_Spell.IsSpellKnown) or IsSpellKnown

-- auras: always returns a table similar to C_UnitAuras AuraData
local auraCache = {}
function HG.GetAura(unit, index, filter)
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local a = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
		if a then return a end
	end
	if UnitAura then
		local name, icon, count, debuffType, duration, expirationTime, source, isStealable, _, spellId = UnitAura(unit, index, filter)
		if not name then return nil end
		local a = auraCache
		a.name, a.icon, a.applications, a.dispelName, a.duration, a.expirationTime = name, icon, count, debuffType, duration, expirationTime
		a.sourceUnit, a.isStealable, a.spellId, a.auraInstanceID = source, isStealable, spellId, nil
		a.isHelpful = filter and filter:find("HELPFUL") and true or false
		return a
	end
end

-- range check for Mists/Retail/Classic
function HG.UnitInRange(unit)
	if UnitIsUnit(unit, "player") then return true end
	local inRange, checked = UnitInRange(unit)
	if HG.IsSecret(inRange) then return true end
	if checked and not inRange then return false end
	if not checked and CheckInteractDistance and not UnitIsConnected(unit) then return false end
	return true
end

-- event / module system ---------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local registry = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local handlers = registry[event]
	if not handlers then return end
	for owner, handler in pairs(handlers) do
		local func = type(handler) == "string" and owner[handler] or handler
		SafeCall((owner.name or "Core") .. ":" .. event, func, owner, event, ...)
	end
end)

local Module = {}

function Module:RegisterEvent(event, handler)
	handler = handler or event
	registry[event] = registry[event] or {}
	registry[event][self] = handler
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end

function Module:UnregisterEvent(event)
	local handlers = registry[event]
	if not handlers then return end
	handlers[self] = nil
	if not next(handlers) then
		registry[event] = nil
		eventFrame:UnregisterEvent(event)
	end
end

function Module:Print(...)
	HG:Print("|cffffffff" .. self.name .. ":|r", ...)
end

function HG:NewModule(name)
	local mod = setmetatable({ name = name }, { __index = Module })
	self.modules[name] = mod
	tinsert(self.moduleOrder, mod)
	return mod
end

-- run something as soon as we leave combat (protected frame manipulation)
local combatQueue = {}
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
	for i = 1, #combatQueue do
		local job = combatQueue[i]
		SafeCall("CombatQueue", job.func, unpack(job.args, 1, job.n))
	end
	wipe(combatQueue)
end)

-- color picker (multi-client compat: SetupColorPickerAndShow / OpenColorPicker / ShowColorPicker)
function HG:PickColor(color, onChange)
	local info = {
		r = color.r or 1, g = color.g or 1, b = color.b or 1,
		swatchFunc = function()
			local r, g, b = ColorPickerFrame:GetColorRGB()
			onChange(r, g, b)
		end,
		cancelFunc = function(prev)
			prev = prev or info
			onChange(prev.r, prev.g, prev.b)
		end,
	}
	if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow(info)
	elseif OpenColorPicker then
		OpenColorPicker(info)
	elseif ShowColorPicker then
		ShowColorPicker(info.r, info.g, info.b, function(restore)
			if restore then onChange(restore.r, restore.g, restore.b)
			else local r, g, b = ColorPickerFrame:GetColorRGB() onChange(r, g, b) end
		end)
	end
end

function HG:RunOutOfCombat(func, ...)
	if InCombatLockdown() then
		local a1, a2 = ...
		for _, job in ipairs(combatQueue) do
			if job.func == func and job.args[1] == a1 and job.args[2] == a2 then return end
		end
		tinsert(combatQueue, { func = func, args = { ... }, n = select("#", ...) })
	else
		SafeCall("RunOutOfCombat", func, ...)
	end
end

-- saved variables ---------------------------------------------------------------
HG.defaults = {
	enable = true,
	barW = 64,
	barH = 30,
	spacing = 2,
	groupSpacing = 6,
	scale = 1,
	frameAlpha = 1,
	lockFrame = false,
	growthX = "RIGHT",
	growthY = "DOWN",
	sortMethod = "INDEX",          -- INDEX | NAME | ROLE
	orientation = "HORIZONTAL",    -- HORIZONTAL: groups are columns | VERTICAL: groups are rows
	hideEmpty = true,
	rangeFade = true,
	rangeAlpha = 0.4,
	healthMode = "CLASS",          -- CLASS | GRADIENT | CUSTOM
	customColor = { r = 0.2, g = 0.8, b = 0.2 },
	barStyle = "FLAT",             -- FLAT | DEFAULT statusbar texture
	lifeMode = "PERCENT",          -- PERCENT | DEFICIT | BOTH | NONE
	aggroStyle = "DOT",            -- DOT | BORDER | BOTH | NONE
	nameSize = 10,
	lifeSize = 9,
	nameMaxLen = 0,                -- 0 = no truncation
	powerHeight = 3,
	debuffSize = 12,
	bgAlpha = 0.9,
	showRole = true,
	showRaidIcon = true,
	showResIcon = true,
	hideInCombat = false,
	testSize = 0,                -- 0 = off | 5/10/20/25/40 fake cells for preview
	rangeAlpha = 0.4,
	incColor = { r = 0.2, g = 0.8, b = 0.2 },
	absColor = { r = 1, g = 0.85, b = 0.2 },
	aggroColor = { r = 1, g = 0, b = 0 },
	bgColor = { r = 0.08, g = 0.08, b = 0.08 },
	debuffColors = {
		Magic = { r = 0.2, g = 0.6, b = 1 },
		Curse = { r = 0.6, g = 0, b = 1 },
		Poison = { r = 0, g = 0.6, b = 0 },
		Disease = { r = 0.6, g = 0.4, b = 0 },
		Other = { r = 0.8, g = 0, b = 0 },
	},
	showPower = true,
	showDebuffs = true,
	showIncHeal = true,
	showAbsorb = true,
	showReadyCheck = true,
	targetHighlight = true,
	unitTooltip = true,
	showWhenSolo = true,
	rezOnDead = true,
	visMode = "ALWAYS",   -- ALWAYS | GROUP | RAID
	showPets = true,
	showAFK = true,
	onlyDispellable = false,
	-- click-cast: { button = "1".."5", mod = "none"|"shift"|"ctrl"|"alt",
	--   type = "spell"|"macro"|"item"|"target"|"togglemenu"|"focus", value = "..." }
	-- spell value "dispel"/"heal"/"rez" resolves to the class spell automatically.
	clickCast = { enable = true, bindings = {} },
}

-- every mouse button x modifier combo gets a row by default so bindings only
-- need a spell assigned in the options window; left click targets,
-- right click heals, middle click dispels
do
	local binds = HG.defaults.clickCast.bindings
	for _, mod in ipairs({ "none", "shift", "ctrl", "alt" }) do
		for btn = 1, 5 do
			binds[#binds + 1] = { button = tostring(btn), mod = mod, type = "spell", value = "" }
		end
	end
	binds[1].type, binds[1].value = "target", ""
	binds[2].value = "heal"
	binds[3].value = "dispel"
end

local function Merge(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then
				dst[k] = {}
				Merge(dst[k], v)
			elseif v[1] == nil then
				Merge(dst[k], v)
			end
			-- arrays (e.g. click-cast bindings) are user-owned once present:
			-- merging would shift indices and duplicate rows
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-- pixel-perfect helpers -----------------------------------------------------------
HG.mult = 1

function HG:UpdatePixelScale()
	local scale = UIParent:GetEffectiveScale()
	if not scale or scale <= 0 then scale = 1 end
	self.mult = 1 / scale
end

function HG:Scale(v)
	local m = self.mult
	return m * floor(v / m + 0.5)
end

local function SnapSetPoint(self, point, rel, relPoint, x, y)
	if type(rel) == "number" then
		return self.hgSetPoint(self, point, HG:Scale(rel), relPoint and HG:Scale(relPoint))
	end
	if type(x) == "number" then x = HG:Scale(x) end
	if type(y) == "number" then y = HG:Scale(y) end
	-- forward only the args actually given; explicit nils make the client treat
	-- relativeTo=nil as "screen" -> element lands at screen center
	if rel == nil then
		return self.hgSetPoint(self, point)
	elseif relPoint == nil then
		return self.hgSetPoint(self, point, rel)
	end
	return self.hgSetPoint(self, point, rel, relPoint, x, y)
end
local function SnapSetSize(self, w, h)
	if type(w) == "number" then w = HG:Scale(w) end
	if type(h) == "number" then h = HG:Scale(h) end
	return self.hgSetSize(self, w, h)
end
local function SnapSetWidth(self, w)
	return self.hgSetWidth(self, type(w) == "number" and HG:Scale(w) or w)
end
local function SnapSetHeight(self, h)
	return self.hgSetHeight(self, type(h) == "number" and HG:Scale(h) or h)
end

function HG:EnablePixelSnap(f)
	if not f or f.hgPixelSnap then return end
	-- never wrap methods on protected/secure frames: calling the wrapper during
	-- combat taints the secure call chain (ADDON_ACTION_BLOCKED)
	if f.IsProtected and f:IsProtected() then return end
	f.hgPixelSnap = true
	f.hgSetPoint, f.hgSetSize = f.SetPoint, f.SetSize
	f.hgSetWidth, f.hgSetHeight = f.SetWidth, f.SetHeight
	f.SetPoint, f.SetSize = SnapSetPoint, SnapSetSize
	f.SetWidth, f.SetHeight = SnapSetWidth, SnapSetHeight
end

function HG:SetOutside(obj, anchor, x, y)
	anchor = anchor or obj:GetParent()
	x, y = x or self.mult, y or x or self.mult
	obj:ClearAllPoints()
	obj:SetPoint("TOPLEFT", anchor, "TOPLEFT", -x, y)
	obj:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", x, -y)
end

function HG:SetInside(obj, anchor, x, y)
	anchor = anchor or obj:GetParent()
	x, y = x or self.mult, y or x or self.mult
	obj:ClearAllPoints()
	obj:SetPoint("TOPLEFT", anchor, "TOPLEFT", x, -y)
	obj:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -x, y)
end

-- templates -----------------------------------------------------------------
local function EnsureBackdrop(frame)
	if frame.SetBackdrop then return end
	if not BackdropTemplateMixin then return end
	Mixin(frame, BackdropTemplateMixin)
	if frame.OnBackdropSizeChanged then
		frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged)
	end
end

local function ApplyTemplate(frame)
	local template = frame.hgTemplate
	local m = HG.media
	if template == "NoBackdrop" then
		frame:SetBackdrop(nil)
	else
		frame:SetBackdrop({ bgFile = BLANK, edgeFile = BLANK, edgeSize = HG.mult, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
		if template == "Transparent" then
			frame:SetBackdropColor(unpack(m.backdropFadeColor))
		elseif template == "Clear" then
			frame:SetBackdropColor(0, 0, 0, 0)
		else
			frame:SetBackdropColor(unpack(m.backdropColor))
		end
		frame:SetBackdropBorderColor(unpack(frame.hgBorderColor or m.borderColor))
	end
end

-- template: "Default" | "Transparent" | "Clear" | "NoBackdrop"
function HG:SetTemplate(frame, template, accent, borderColor)
	if not frame then return end
	self:EnablePixelSnap(frame)
	EnsureBackdrop(frame)
	if not frame.SetBackdrop then return end
	frame.hgTemplate = template or "Default"
	frame.hgBorderColor = borderColor
	ApplyTemplate(frame)
end

function HG:CreateBackdrop(frame, template, accent, inset)
	if frame.hgBackdrop then return frame.hgBackdrop end
	local parent = frame.IsObjectType and frame:IsObjectType("Texture") and frame:GetParent() or frame
	local level = parent:GetFrameLevel()
	-- a backdrop at the same level as its parent covers the parent's regions
	-- (e.g. button text) -> bump the parent instead of staying at level 0
	if level == 0 then parent:SetFrameLevel(1) level = 1 end
	local bd = CreateFrame("Frame", nil, parent, self.BackdropTemplate)
	bd:SetFrameLevel(level - 1)
	if inset then self:SetInside(bd, frame, inset, inset) else self:SetOutside(bd, frame) end
	self:SetTemplate(bd, template, accent)
	frame.hgBackdrop = bd
	return bd
end

local stripNames = { "NineSlice", "Bg", "BG", "Background", "TitleBg", "TopTileStreaks", "Inset", "InsetBg", "Border", "BorderFrame", "Left", "Middle", "Right", "Mid", "LeftDisabled", "MiddleDisabled", "RightDisabled", "TopLeft", "TopRight", "BottomLeft", "BottomRight", "Top", "Bottom", "portrait", "PortraitContainer", "PortraitFrame", "TitleContainer" }
local keepNames = { TitleContainer = true, PortraitContainer = false }

function HG:StripTextures(frame, kill, keepText)
	if not frame then return end
	for i = 1, select("#", frame:GetRegions()) do
		local region = select(i, frame:GetRegions())
		if region and region.IsObjectType and region:IsObjectType("Texture") then
			region:SetAlpha(0)
		end
	end
	local name = frame.GetName and frame:GetName()
	for _, key in ipairs(stripNames) do
		local obj = frame[key] or (name and _G[name .. key])
		if obj and type(obj) == "table" and obj ~= frame and obj.GetObjectType then
			if obj:IsObjectType("Texture") then
				obj:SetAlpha(0)
			elseif keepNames[key] then
				self:StripTextures(obj)
			elseif obj.SetAlpha and not obj:IsObjectType("FontString") then
				if key == "NineSlice" or key == "Bg" or key == "Background" or key == "Inset" or key == "PortraitContainer" or key == "BorderFrame" or key == "Border" or key == "TopTileStreaks" or key == "InsetBg" then
					obj:SetAlpha(0)
				end
			end
		end
	end
end

-- fonts ---------------------------------------------------------------------
function HG:SetFont(fs, font, size, outline)
	if not fs or not fs.SetFont then return end
	font = font or self.media.font or STANDARD_TEXT_FONT
	size = self:Scale(size or self.media.fontSize or 12)
	outline = outline or "NONE"
	if outline == "MONOCHROMEOUTLINE" then outline = "MONOCHROME,OUTLINE"
	elseif outline ~= "OUTLINE" and outline ~= "THICKOUTLINE" and outline ~= "MONOCHROME" and outline ~= "MONOCHROME,OUTLINE" then outline = "" end
	local ok, applied = pcall(fs.SetFont, fs, font, size, outline)
	if not ok or applied == false then
		pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, size, outline ~= "" and outline or nil)
	end
	if outline == "" then
		fs:SetShadowColor(0, 0, 0, 0.9)
		fs:SetShadowOffset(self.mult, -self.mult)
	else
		fs:SetShadowColor(0, 0, 0, 0.4)
		fs:SetShadowOffset(0, 0)
	end
end

function HG:FontString(parent, size, outline, font, layer, justify)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	self:EnablePixelSnap(fs)
	self:SetFont(fs, font, size, outline)
	fs:SetJustifyH(type(justify) == "string" and justify or "CENTER")
	fs:SetWordWrap(false)
	return fs
end

-- widget skins --------------------------------------------------------------
local function HoverEnter(self)
	local bd = self.hgBackdrop or self
	if bd.SetBackdropBorderColor then bd:SetBackdropBorderColor(HG.accent.r, HG.accent.g, HG.accent.b, 1) end
end
local function HoverLeave(self)
	local bd = self.hgBackdrop or self
	if bd.SetBackdropBorderColor then bd:SetBackdropBorderColor(unpack(HG.media.borderColor)) end
end
HG.HoverEnter, HG.HoverLeave = HoverEnter, HoverLeave

function HG:AddHover(frame)
	if frame.hgHover then return end
	frame.hgHover = true
	frame:HookScript("OnEnter", HoverEnter)
	frame:HookScript("OnLeave", HoverLeave)
end

local function ClearTex(btn, getter, setter)
	local tex = btn[getter] and btn[getter](btn)
	if tex then tex:SetAlpha(0) end
end

function HG:SkinButton(btn, noTemplate)
	if not btn or btn.hgSkinned then return end
	btn.hgSkinned = true
	for _, key in ipairs({ "Left", "Middle", "Center", "Right", "LeftSeparator", "RightSeparator", "TopLeft", "TopRight", "BottomLeft", "BottomRight", "TopMiddle", "MiddleLeft", "MiddleRight", "BottomMiddle", "MiddleMiddle" }) do
		local t = btn[key] or (btn:GetName() and _G[btn:GetName() .. key])
		-- textures only: on some clients a key can resolve to the button's FontString
		if t and t.SetAlpha and (not t.IsObjectType or t:IsObjectType("Texture")) then t:SetAlpha(0) end
	end
	ClearTex(btn, "GetNormalTexture")
	ClearTex(btn, "GetPushedTexture")
	ClearTex(btn, "GetDisabledTexture")
	local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
	if hl then
		hl:SetTexture(BLANK)
		hl:SetVertexColor(1, 1, 1, 0.08)
		self:SetInside(hl, btn)
	end
	if not noTemplate then
		self:CreateBackdrop(btn, "Default", nil, 0)
		self:AddHover(btn)
	end
	local fs = btn.GetFontString and btn:GetFontString()
	if fs then
		self:SetFont(fs, nil, 12)
		fs:SetAlpha(1)
		fs:Show()
	end
	local bd = btn.hgBackdrop
	if bd then
		-- keep the fill below the caption even if something re-levels the button
		local function KeepBelow()
			local lvl = btn:GetFrameLevel()
			if lvl == 0 then btn:SetFrameLevel(1) lvl = 1 end
			if bd:GetFrameLevel() >= lvl then bd:SetFrameLevel(lvl - 1) end
		end
		KeepBelow()
		btn:HookScript("OnShow", KeepBelow)
	end
end

function HG:SkinCloseButton(btn, point)
	if not btn or btn.hgSkinned then return end
	btn.hgSkinned = true
	self:StripTextures(btn)
	ClearTex(btn, "GetNormalTexture")
	ClearTex(btn, "GetPushedTexture")
	ClearTex(btn, "GetDisabledTexture")
	ClearTex(btn, "GetHighlightTexture")
	btn:SetSize(18, 18)
	local bd = self:CreateBackdrop(btn, "Default", nil, 0)
	-- regions on btn sit below the backdrop child frame -> draw the "x" on bd
	local x = (bd or btn):CreateFontString(nil, "OVERLAY")
	self:SetFont(x, self.media.font, 14, "OUTLINE")
	x:SetPoint("CENTER", 1, 0)
	x:SetText("x")
	btn.hgX = x
	btn:HookScript("OnEnter", function() x:SetTextColor(1, 0.3, 0.3) HoverEnter(btn) end)
	btn:HookScript("OnLeave", function() x:SetTextColor(1, 1, 1) HoverLeave(btn) end)
	if point then
		btn:ClearAllPoints()
		btn:SetPoint("TOPRIGHT", point, "TOPRIGHT", -4, -4)
	end
	return bd
end

function HG:SkinEditBox(eb, height)
	if not eb or eb.hgSkinned then return end
	eb.hgSkinned = true
	local name = eb:GetName()
	for _, k in ipairs({ "Left", "Middle", "Right", "Mid", "LeftTexture", "RightTexture", "MiddleTexture" }) do
		local t = eb[k] or (name and _G[name .. k])
		if t and t.SetAlpha then t:SetAlpha(0) end
	end
	local bd = self:CreateBackdrop(eb, "Default")
	bd:ClearAllPoints()
	bd:SetPoint("TOPLEFT", -3, 0)
	bd:SetPoint("BOTTOMRIGHT", 0, 0)
	if height then eb:SetHeight(height) end
	eb:HookScript("OnEditFocusGained", function() bd:SetBackdropBorderColor(HG.accent.r, HG.accent.g, HG.accent.b) end)
	eb:HookScript("OnEditFocusLost", function() bd:SetBackdropBorderColor(unpack(HG.media.borderColor)) end)
end

function HG:SkinCheckBox(cb)
	if not cb or cb.hgSkinned then return end
	cb.hgSkinned = true
	ClearTex(cb, "GetNormalTexture")
	ClearTex(cb, "GetPushedTexture")
	ClearTex(cb, "GetHighlightTexture")
	local bd = self:CreateBackdrop(cb, "Default", nil, 5)
	if cb.SetCheckedTexture then
		cb:SetCheckedTexture(BLANK)
		local tex = cb:GetCheckedTexture()
		tex:SetVertexColor(HG.accent.r, HG.accent.g, HG.accent.b)
		self:SetInside(tex, bd, 3, 3)
	end
	if cb.SetDisabledCheckedTexture then
		cb:SetDisabledCheckedTexture(BLANK)
		local d = cb:GetDisabledCheckedTexture()
		d:SetVertexColor(0.4, 0.4, 0.4)
		self:SetInside(d, bd, 3, 3)
	end
	self:AddHover(cb)
end

function HG:SkinSlider(slider)
	if not slider or slider.hgSkinned then return end
	slider.hgSkinned = true
	self:StripTextures(slider)
	local bd = self:CreateBackdrop(slider, "Default")
	bd:ClearAllPoints()
	bd:SetPoint("TOPLEFT", 0, -4)
	bd:SetPoint("BOTTOMRIGHT", 0, 4)
	local thumb = slider.GetThumbTexture and slider:GetThumbTexture()
	if thumb then
		thumb:SetAlpha(1) -- StripTextures hid the template thumb region
		thumb:SetTexture(BLANK)
		thumb:SetVertexColor(HG.accent.r, HG.accent.g, HG.accent.b)
		thumb:SetSize(8, 14)
	end
end

function HG:SkinFrame(frame, template, noClose)
	if not frame or frame.hgFrameSkinned then return end
	frame.hgFrameSkinned = true
	self:StripTextures(frame)
	-- backdrop stays below the frame level so stripped-but-kept regions (portrait)
	-- still render above the dark background
	local bd = self:CreateBackdrop(frame, template or "Transparent", "TOP")
	local name = frame:GetName()
	local close = frame.CloseButton or (name and (_G[name .. "CloseButton"])) or (frame.TitleContainer and frame.TitleContainer.CloseButton)
	if close and not noClose then self:SkinCloseButton(close) end
	local portrait = frame.portrait or frame.Portrait or (name and _G[name .. "Portrait"]) or (frame.PortraitContainer and frame.PortraitContainer.portrait)
	if portrait and portrait.SetAlpha then portrait:SetAlpha(0) end
	for _, k in ipairs({ "Inset", "LeftInset", "RightInset", "InsetFrame" }) do
		local inset = frame[k] or (name and _G[name .. k])
		if inset and inset.GetObjectType and not inset:IsObjectType("Texture") then self:StripTextures(inset) end
	end
	return bd
end

-- minimap button --------------------------------------------------------------
function HG:CreateMinimapButton(opts)
	local btn = _G.HealGridMinimapButton
	if btn then
		btn._opts = opts
		return btn
	end
	btn = CreateFrame("Button", "HealGridMinimapButton", Minimap)
	btn:SetSize(26, 26)
	btn:SetFrameStrata("MEDIUM")
	btn:SetFrameLevel(9)
	local icon = HG:FontString(btn, 12, "OUTLINE")
	icon:SetPoint("CENTER", 0, 0)
	icon:SetText(opts.glyph or "HG")
	icon:SetTextColor(HG.accent.r, HG.accent.g, HG.accent.b)
	btn.icon = icon
	HG:CreateBackdrop(btn, "Default")
	HG:AddHover(btn)

	btn._opts = opts
	btn._store = opts.store or {}
	function btn:UpdatePosition()
		local angle = math.rad((self._store and self._store.angle) or (self._opts and self._opts.angle) or 220)
		local r = Minimap:GetWidth() / 2
		self:ClearAllPoints()
		self:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * (r + 3), math.sin(angle) * (r + 3))
	end
	btn:UpdatePosition()

	btn:RegisterForClicks("AnyUp")
	btn:RegisterForDrag("LeftButton")
	btn:SetScript("OnDragStart", function(b)
		b:SetScript("OnUpdate", function()
			b.dragged = true
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local cx, cy = GetCursorPosition()
			cx, cy = cx / scale - mx, cy / scale - my
			if b._store then b._store.angle = math.deg(math.atan2(cy, cx)) end
			b:UpdatePosition()
		end)
	end)
	btn:SetScript("OnDragStop", function(b)
		b:SetScript("OnUpdate", nil)
		C_Timer.After(0, function() b.dragged = nil end)
	end)
	btn:SetScript("OnClick", function(b, button)
		if b.dragged then return end
		local o = b._opts or {}
		if button == "RightButton" then
			if o.onRight then SafeCall("MinimapButton:" .. (o.name or ""), o.onRight) end
		elseif o.onLeft then
			SafeCall("MinimapButton:" .. (o.name or ""), o.onLeft)
		end
	end)
	btn:SetScript("OnEnter", function(b)
		local o = b._opts or {}
		if not o.tooltip then return end
		GameTooltip:SetOwner(b, "ANCHOR_LEFT")
		SafeCall("MinimapButtonTip:" .. (o.name or ""), o.tooltip, b)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return btn
end

-- boot ------------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
pcall(boot.RegisterEvent, boot, "UI_SCALE_CHANGED")
pcall(boot.RegisterEvent, boot, "DISPLAY_SIZE_CHANGED")
boot:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		HealGridDB = type(HealGridDB) == "table" and HealGridDB or {}
		-- migrate the old showDeficit toggle into lifeMode
		if HealGridDB.lifeMode == nil and HealGridDB.showDeficit == true then
			HealGridDB.lifeMode = "DEFICIT"
		end
		-- seed the full button matrix on fresh installs or after the user cleared
		-- every row; partial user edits are left untouched
		local cc = HealGridDB.clickCast
		if not (cc and cc.bindings and #cc.bindings > 0) then
			HealGridDB.clickCast = cc or {}
			cc = HealGridDB.clickCast
			cc.bindings = {}
			for i, b in ipairs(HG.defaults.clickCast.bindings) do
				cc.bindings[i] = { button = b.button, mod = b.mod, type = b.type, value = b.value }
			end
		end
		Merge(HealGridDB, HG.defaults)
		HG.db = HealGridDB
		HealGridCharDB = type(HealGridCharDB) == "table" and HealGridCharDB or {}
		HG.charDb = HealGridCharDB
		HG.myClass = select(2, UnitClass("player"))
		HG:UpdatePixelScale()
		for _, mod in ipairs(HG.moduleOrder) do
			mod.db = HG.db
			if mod.Initialize then
				SafeCall(mod.name .. ":Initialize", mod.Initialize, mod)
				mod.initialized = true
			end
		end
	else
		HG:UpdatePixelScale()
	end
end)
