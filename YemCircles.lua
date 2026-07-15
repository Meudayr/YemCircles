local addonName = "YemCircles"

-- Default Settings
local defaultDB = {
    size = 32, 
    thickness = 1,
    r = 0.53,  -- Circle Red
    g = 0.53,  -- Circle Green
    b = 0.93,  -- Circle Blue
    a = 0.8,   -- Circle Alpha
    castR = 1, -- Cast Bar Red
    castG = 1, -- Cast Bar Green
    castB = 1, -- Cast Bar Blue
    castA = 1, -- Cast Bar Alpha
    gcdR = 0.2,  -- GCD Sweep Red   (default: teal)
    gcdG = 0.8,  -- GCD Sweep Green
    gcdB = 0.8,  -- GCD Sweep Blue
    gcdA = 0.5,  -- GCD Sweep Alpha (default: 50%)
    trail = false,
    castbar = false,
    gcdbar = false,
    filled = false,
    hideOutOfCombat = false,
    autoClassColor = false,
    showDot = false,
    trailStyleDot = false,
    hideOnRightClick = false
}

-- Performance Cache: Cache frequently used WoW APIs in locals
local GetCursorPosition = GetCursorPosition
local InCombatLockdown = InCombatLockdown
local GetTime = GetTime
local UnitClass = UnitClass
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local UnitSpellHaste = UnitSpellHaste
local CreateFrame = CreateFrame
local math_abs = math.abs
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber

-- Core visual frames
local core = CreateFrame("Frame", "YemCirclesFrame", UIParent)
core:SetFrameStrata("TOOLTIP")

-- Tables to hold dynamic concentric visual layers for thickness support
local circleTextures = {}
local castBars = {}
local gcdBars = {}

-- Trail visual properties
local trailFrames = {}
local trailIndex = 1
local maxTrails = 5
local isCasting = false
local isGCD = false
local currentCastGUID = nil
local isWaitingForCastStart = nil
local activeCastStart = nil
local activeCastDuration = nil
local preemptiveStart = nil
local preemptiveDuration = nil
local activeGCDStart = nil
local activeGCDDuration = nil
-- No pending GCD buffers needed: GCD and cast sweeps run simultaneously

-- UIParent Scale Cache
local scale = 1
local function UpdateScale()
    scale = UIParent and UIParent:GetEffectiveScale() or 1
end

-- Precise Class Colors
local classColors = {
    { name = "Death Knight", r = 0.77, g = 0.12, b = 0.23 },
    { name = "Demon Hunter", r = 0.64, g = 0.19, b = 0.79 },
    { name = "Druid",        r = 1.00, g = 0.49, b = 0.04 },
    { name = "Evoker",       r = 0.20, g = 0.58, b = 0.50 },
    { name = "Hunter",       r = 0.67, g = 0.83, b = 0.45 },
    { name = "Mage",         r = 0.25, g = 0.78, b = 0.92 },
    { name = "Monk",         r = 0.00, g = 1.00, b = 0.60 },
    { name = "Paladin",      r = 0.96, g = 0.55, b = 0.73 },
    { name = "Priest",       r = 1.00, g = 1.00, b = 1.00 },
    { name = "Rogue",        r = 1.00, g = 0.96, b = 0.41 },
    { name = "Shaman",       r = 0.00, g = 0.44, b = 0.87 },
    { name = "Warlock",      r = 0.53, g = 0.53, b = 0.93 },
    { name = "Warrior",      r = 0.78, g = 0.61, b = 0.43 }
}

local function GetCircleTexture(customThickness)
    if YemCirclesDB.filled then
        return "Interface\\CharacterFrame\\TempPortraitAlphaMask"
    else
        local t = customThickness or YemCirclesDB.thickness or 1
        t = math_max(1, math_min(5, math_floor(t)))
        return "Interface\\AddOns\\YemCircles\\ring" .. t .. ".tga"
    end
end

local channeledSpells = {
    [5143] = 3000,   -- Arcane Missiles (3s)
    [12051] = 6000,  -- Evocation (6s)
    [205021] = 3000, -- Ray of Frost (3s)
    [382440] = 4000, -- Shifting Power (4s)
    [15407] = 3000,  -- Mind Flay (3s)
    [391403] = 3000, -- Mind Flay: Insanity (3s)
    [48045] = 3000,  -- Mind Sear (3s)
    [263165] = 3000, -- Void Torrent (3s)
    [47540] = 2000,  -- Penance (2s)
    [64843] = 8000,  -- Divine Hymn (8s)
    [64901] = 4000,  -- Symbol of Hope (4s)
    [234153] = 5000, -- Drain Life (5s)
    [198590] = 5000, -- Drain Soul (5s)
    [2179] = 6000,   -- Health Funnel (6s)
    [740] = 8000,    -- Tranquility (8s)
    [117952] = 4000, -- Crackling Jade Lightning (4s)
    [115175] = 8000, -- Soothing Mist (8s)
    [113656] = 4000, -- Fists of Fury (4s)
    [191837] = 3000, -- Essence Font (3s)
    [198013] = 2000, -- Eye Beam (2s)
    [343311] = 3000, -- Fel Barrage (3s)
    [356995] = 3000, -- Disintegrate (3s)
    [120360] = 3000, -- Barrage (3s)
    [257044] = 3000, -- Rapid Fire (3s)
}

local scannerTooltip
local function GetSpellCastTime(spellID)
    if not spellID then return 0 end
    
    local baseTime = 0
    -- Check if it is a known channeled spell in our lookup table
    if channeledSpells[spellID] then
        baseTime = channeledSpells[spellID]
    elseif C_Spell and C_Spell.GetSpellInfo then
        local spellInfo = C_Spell.GetSpellInfo(spellID)
        if spellInfo and spellInfo.castTime and spellInfo.castTime > 0 then
            baseTime = spellInfo.castTime
        end
    else
        local name, _, _, castTime = GetSpellInfo(spellID)
        if castTime and castTime > 0 then
            baseTime = castTime
        end
    end
    
    -- Check if it's a channeled spell (tooltip scanning fallback)
    if baseTime == 0 then
        local channelText = SPELL_CAST_CHANNELED or "Channeled"
        if C_TooltipInfo and C_TooltipInfo.GetSpellByID then
            local data = C_TooltipInfo.GetSpellByID(spellID)
            if data and data.lines then
                for i = 1, #data.lines do
                    local line = data.lines[i]
                    if line and line.leftText then
                        if line.leftText:find(channelText) then
                            baseTime = 3000 -- Return default 3.0 seconds cast/channel duration
                            break
                        end
                    end
                end
            end
        else
            -- Legacy Tooltip Scanner fallback
            if not scannerTooltip then
                scannerTooltip = CreateFrame("GameTooltip", "YemCirclesScanTooltip", nil, "GameTooltipTemplate")
                scannerTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
            end
            scannerTooltip:ClearLines()
            scannerTooltip:SetSpellByID(spellID)
            for i = 1, scannerTooltip:NumLines() do
                local line = _G["YemCirclesScanTooltipTextLeft"..i]
                if line then
                    local text = line:GetText()
                    if text and text:find(channelText) then
                        baseTime = 3000
                        break
                    end
                end
            end
        end
    end
    
    if baseTime > 0 then
        -- Apply player spell haste percentage
        local haste = (UnitSpellHaste and UnitSpellHaste("player")) or 0
        return baseTime / (1 + haste / 100)
    end
    
    return 0
end

local function UpdateColorWidget(widget, r, g, b, a)
    if widget and widget.bgTex and r and g and b then
        widget.bgTex:SetColorTexture(r, g, b, a or 1)
    end
end

-- Slider and EditBox variables (defined globally to this file for access)
local sliderThickness, thicknessInput
local sliderOpacity, opacityInput
local sliderCastOpacity, castOpacityInput
local sliderGcdOpacity, gcdOpacityInput
local cbTrailDot

-- Gray out and disable Thickness input fields if Solid Filled Circle is selected
local function UpdateThicknessSliderState()
    if not sliderThickness or not thicknessInput then return end
    if YemCirclesDB.filled then
        sliderThickness:Disable()
        thicknessInput:SetEnabled(false)
        local text = _G[sliderThickness:GetName().."Text"]
        if text then text:SetTextColor(0.5, 0.5, 0.5) end
        local low = _G[sliderThickness:GetName().."Low"]
        if low then low:SetTextColor(0.5, 0.5, 0.5) end
        local high = _G[sliderThickness:GetName().."High"]
        if high then high:SetTextColor(0.5, 0.5, 0.5) end
        thicknessInput:SetTextColor(0.5, 0.5, 0.5)
    else
        sliderThickness:Enable()
        thicknessInput:SetEnabled(true)
        local text = _G[sliderThickness:GetName().."Text"]
        if text then text:SetTextColor(1, 1, 1) end
        local low = _G[sliderThickness:GetName().."Low"]
        if low then low:SetTextColor(1, 1, 1) end
        local high = _G[sliderThickness:GetName().."High"]
        if high then high:SetTextColor(1, 1, 1) end
        thicknessInput:SetTextColor(1, 1, 1)
    end
end

-- Gray out and disable Trail Type checkbox if Trail is disabled
local function UpdateTrailCheckboxState()
    if not cbTrailDot then return end
    if YemCirclesDB.trail then
        cbTrailDot:Enable()
        local text = _G[cbTrailDot:GetName().."Text"]
        if text then text:SetTextColor(1, 1, 1) end
    else
        cbTrailDot:Disable()
        local text = _G[cbTrailDot:GetName().."Text"]
        if text then text:SetTextColor(0.5, 0.5, 0.5) end
    end
end

local hideTimerId = 0

local function UpdateVisibility()
    if YemCirclesDB.hideOnRightClick and IsMouseButtonDown("RightButton") then
        core:Hide()
        return
    end

    local shouldHide = YemCirclesDB.hideOutOfCombat and not InCombatLockdown()
    if shouldHide and not isCasting and not isGCD then
        core:Hide()
    else
        core:Show()
    end

    if core:IsShown() then
        local alphaCoeff = 1.0
        if YemCirclesDB.castbar and YemCirclesDB.gcdbar then
            alphaCoeff = isCasting and 0.3 or 1.0
        else
            alphaCoeff = (isCasting or isGCD) and 0.3 or 1.0
        end
        local targetAlpha = (YemCirclesDB.a or 0.8) * alphaCoeff
        for i = 1, #circleTextures do
            if circleTextures[i]:IsShown() then
                circleTextures[i]:SetAlpha(targetAlpha)
            end
        end
    end
end

local function ApplyAutoClassColor()
    if YemCirclesDB.autoClassColor then
        local _, classFileName = UnitClass("player")
        local color = (C_ClassColor and C_ClassColor.GetClassColor(classFileName)) or RAID_CLASS_COLORS[classFileName]
        if color then
            YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b = color.r, color.g, color.b
            YemCirclesDB.castR, YemCirclesDB.castG, YemCirclesDB.castB = color.r, color.g, color.b
        end
    end
end

-- Preview concentric layers definitions
local previewTextures = {}
local previewCastBars = {}
local previewGcdBars = {}

-- Core Cast/GCD triggering functions
local function TriggerCast(startTime, duration)
    if activeCastStart == startTime and activeCastDuration == duration then
        return
    end
    activeCastStart = startTime
    activeCastDuration = duration
    
    local cb = castBars[1]
    if cb then
        cb:SetCooldown(startTime, duration)
    end
end

local function StopCast()
    if activeCastStart == nil and activeCastDuration == nil then return end
    activeCastStart = nil
    activeCastDuration = nil
    for i = 1, #castBars do
        castBars[i]:SetCooldown(0, 0)
    end
end

local function TriggerCastAdjusted(newEndTime)
    local now = GetTime()
    if activeCastStart and activeCastDuration and activeCastDuration > 0 then
        local elapsed = now - activeCastStart
        local progress = elapsed / activeCastDuration
        if progress < 0 then progress = 0 end
        if progress > 0.99 then progress = 0.99 end
        local remainingTime = newEndTime - now
        if remainingTime > 0 then
            local adjustedDuration = remainingTime / (1 - progress)
            local adjustedStart = newEndTime - adjustedDuration
            TriggerCast(adjustedStart, adjustedDuration)
            return
        end
    end
    local duration = newEndTime - now
    if duration > 0 then TriggerCast(now, duration) end
end

local function TriggerGCD(startTime, duration)
    if activeGCDStart and math_abs(activeGCDStart - startTime) < 0.01 and math_abs(activeGCDDuration - duration) < 0.01 then
        return
    end
    activeGCDStart = startTime
    activeGCDDuration = duration
    local gb = gcdBars[1]
    if gb then
        gb:SetCooldown(startTime, duration)
    end
end

local function StopGCD()
    if activeGCDStart == nil and activeGCDDuration == nil then return end
    activeGCDStart = nil
    activeGCDDuration = nil
    for i = 1, #gcdBars do
        gcdBars[i]:SetCooldown(0, 0)
    end
end

local ApplySettings 
ApplySettings = function()
    core:SetSize(YemCirclesDB.size, YemCirclesDB.size)
    local tex = GetCircleTexture()
    
    -- Hide all existing circle textures first
    for i = 1, #circleTextures do
        circleTextures[i]:Hide()
    end
    
    -- Setup single outline/filled texture
    local t = circleTextures[1] or core:CreateTexture(nil, "OVERLAY")
    circleTextures[1] = t
    t:SetTexture(tex)
    t:SetSize(YemCirclesDB.size, YemCirclesDB.size)
    t:ClearAllPoints()
    t:SetPoint("CENTER", core, "CENTER")
    t:SetBlendMode("BLEND")
    t:SetVertexColor(YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, YemCirclesDB.a)
    t:Show()
    
    -- Center dot setup
    if not core.dot then
        core.dot = core:CreateTexture(nil, "OVERLAY", nil, 7)
    end
    if YemCirclesDB.showDot then
        core.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        local dotSize = 6
        core.dot:SetSize(dotSize, dotSize)
        core.dot:ClearAllPoints()
        core.dot:SetPoint("CENTER", core, "CENTER")
        core.dot:SetBlendMode("BLEND")
        core.dot:SetVertexColor(YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, YemCirclesDB.a)
        core.dot:Show()
    else
        core.dot:Hide()
    end

    
    -- Sync Cast Bar Cooldown Frames
    local castSize = YemCirclesDB.size
    local gcdSize = YemCirclesDB.size
    if YemCirclesDB.castbar and YemCirclesDB.gcdbar then
        if YemCirclesDB.filled then
            gcdSize = YemCirclesDB.size * 0.85
        else
            local h = YemCirclesDB.thickness or 1
            h = math_max(1, math_min(5, math_floor(h)))
            gcdSize = YemCirclesDB.size * ((99 - 2 * h) / (99 + 2 * h))
        end
    end

    if YemCirclesDB.castbar then
        for i = 2, #castBars do
            if castBars[i] then castBars[i]:Hide() end
        end
        local cb = castBars[1]
        if not cb then
            cb = CreateFrame("Cooldown", nil, core, "CooldownFrameTemplate")
            cb:SetDrawEdge(false)
            cb:SetDrawBling(false)
            cb:SetHideCountdownNumbers(true)
            cb:SetReverse(true)
            castBars[1] = cb
        end
        cb:SetSize(castSize, castSize)
        cb:ClearAllPoints()
        cb:SetPoint("CENTER", core, "CENTER")
        cb:SetSwipeTexture(tex)
        cb:SetSwipeColor(YemCirclesDB.castR, YemCirclesDB.castG, YemCirclesDB.castB, YemCirclesDB.castA)
        cb:Show()
        if isCasting and activeCastStart and activeCastDuration then
            cb:SetCooldown(activeCastStart, activeCastDuration)
        else
            cb:SetCooldown(0, 0)
        end
    else
        for i = 1, #castBars do
            if castBars[i] then castBars[i]:Hide() end
        end
    end
    
    -- Sync GCD Cooldown Frames
    if YemCirclesDB.gcdbar then
        for i = 2, #gcdBars do
            if gcdBars[i] then gcdBars[i]:Hide() end
        end
        local gb = gcdBars[1]
        if not gb then
            gb = CreateFrame("Cooldown", nil, core, "CooldownFrameTemplate")
            gb:SetDrawEdge(false)
            gb:SetDrawBling(false)
            gb:SetHideCountdownNumbers(true)
            gb:SetReverse(true)
            gcdBars[1] = gb
        end
        gb:SetSize(gcdSize, gcdSize)
        gb:ClearAllPoints()
        gb:SetPoint("CENTER", core, "CENTER")
        gb:SetSwipeTexture(tex)
        gb:SetSwipeColor(YemCirclesDB.gcdR, YemCirclesDB.gcdG, YemCirclesDB.gcdB, YemCirclesDB.gcdA)
        gb:Show()
        if isGCD and activeGCDStart and activeGCDDuration then
            gb:SetCooldown(activeGCDStart, activeGCDDuration)
        else
            gb:SetCooldown(0, 0)
        end
    else
        for i = 1, #gcdBars do
            if gcdBars[i] then gcdBars[i]:Hide() end
        end
    end
    
    -- Disable or reset trail textures immediately to update style changes instantly
    for i = 1, #trailFrames do
        if trailFrames[i] then
            trailFrames[i]:Hide()
        end
    end

    
    UpdateVisibility()
    
    -- Sync Options category view updates if opened
    if YemCirclesOptions and YemCirclesOptions:IsShown() then
        UpdateColorWidget(YemCirclesOptions.ColorBtn, YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, YemCirclesDB.a)
        UpdateColorWidget(YemCirclesOptions.CastColorBtn, YemCirclesDB.castR, YemCirclesDB.castG, YemCirclesDB.castB, YemCirclesDB.castA)
        UpdateColorWidget(YemCirclesOptions.GcdColorBtn, YemCirclesDB.gcdR, YemCirclesDB.gcdG, YemCirclesDB.gcdB, YemCirclesDB.gcdA)
        
        -- Sync Live Preview Circle
        for i = 1, #previewTextures do
            previewTextures[i]:Hide()
        end
        
        local pt = previewTextures[1] or YemCirclesOptions.previewBox:CreateTexture(nil, "OVERLAY")
        previewTextures[1] = pt
        pt:SetTexture(tex)
        pt:SetSize(YemCirclesDB.size, YemCirclesDB.size)
        pt:ClearAllPoints()
        pt:SetPoint("CENTER", YemCirclesOptions.previewBox, "CENTER")
        pt:SetBlendMode("BLEND")
        pt:SetVertexColor(YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, YemCirclesDB.a)
        pt:Show()

        if not YemCirclesOptions.previewBox.dot then
            YemCirclesOptions.previewBox.dot = YemCirclesOptions.previewBox:CreateTexture(nil, "OVERLAY", nil, 7)
        end
        if YemCirclesDB.showDot then
            local pDot = YemCirclesOptions.previewBox.dot
            pDot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
            local dotSize = 6
            pDot:SetSize(dotSize, dotSize)
            pDot:ClearAllPoints()
            pDot:SetPoint("CENTER", YemCirclesOptions.previewBox, "CENTER")
            pDot:SetBlendMode("BLEND")
            pDot:SetVertexColor(YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, YemCirclesDB.a)
            pDot:Show()
        else
            YemCirclesOptions.previewBox.dot:Hide()
        end

        
        -- Sync Live Preview Cast Bar
        for i = 1, #previewCastBars do
            previewCastBars[i]:Hide()
        end
        
        if YemCirclesDB.castbar then
            local pcb = previewCastBars[1]
            if not pcb then
                pcb = CreateFrame("Cooldown", nil, YemCirclesOptions.previewBox, "CooldownFrameTemplate")
                pcb:SetDrawEdge(false)
                pcb:SetDrawBling(false)
                pcb:SetHideCountdownNumbers(true)
                pcb:SetReverse(true)
                previewCastBars[1] = pcb
            end
            pcb:SetSize(castSize, castSize)
            pcb:ClearAllPoints()
            pcb:SetPoint("CENTER", YemCirclesOptions.previewBox, "CENTER")
            pcb:SetSwipeTexture(tex)
            pcb:SetSwipeColor(YemCirclesDB.castR, YemCirclesDB.castG, YemCirclesDB.castB, YemCirclesDB.castA)
            pcb:Show()
        end
        
        -- Sync Live Preview GCD Bar
        for i = 1, #previewGcdBars do
            previewGcdBars[i]:Hide()
        end
        
        if YemCirclesDB.gcdbar then
            local pgb = previewGcdBars[1]
            if not pgb then
                pgb = CreateFrame("Cooldown", nil, YemCirclesOptions.previewBox, "CooldownFrameTemplate")
                pgb:SetDrawEdge(false)
                pgb:SetDrawBling(false)
                pgb:SetHideCountdownNumbers(true)
                pgb:SetReverse(true)
                previewGcdBars[1] = pgb
            end
            pgb:SetSize(gcdSize, gcdSize)
            pgb:ClearAllPoints()
            pgb:SetPoint("CENTER", YemCirclesOptions.previewBox, "CENTER")
            pgb:SetSwipeTexture(tex)
            pgb:SetSwipeColor(YemCirclesDB.gcdR, YemCirclesDB.gcdG, YemCirclesDB.gcdB, YemCirclesDB.gcdA)
            pgb:Show()
        end
        
        UpdateThicknessSliderState()
    end
end

-------------------------------------------------
-- OPTIONS MENU UI SETUP
-------------------------------------------------
local options = CreateFrame("Frame", "YemCirclesOptions", UIParent)
options:Hide()
options.name = "Yem Circles"

options.ColorBtn = nil
options.CastColorBtn = nil
options.cbAutoClass = nil

local title = options:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Yem Circles Configuration")

local previewBox = CreateFrame("Frame", nil, options, "BackdropTemplate")
previewBox:SetSize(180, 180)
previewBox:SetPoint("TOPRIGHT", options, "TOPRIGHT", -30, -50)
previewBox:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
previewBox:SetBackdropColor(0, 0, 0, 0.6)
options.previewBox = previewBox

local previewLabel = options:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
previewLabel:SetPoint("BOTTOM", previewBox, "TOP", 0, 5)
previewLabel:SetText("Live Preview")

-- Preview animation timer logic mapping to single layer
previewBox:SetScript("OnUpdate", function(self, elapsed)
    if not self.timer then self.timer = 0 end
    self.timer = self.timer + elapsed
    
    local showCast = YemCirclesDB.castbar or YemCirclesDB.gcdbar
    if showCast then
        if self.timer >= 3.0 then
            self.timer = 0
            local now = GetTime()
            if YemCirclesDB.castbar then
                local pcb = previewCastBars[1]
                if pcb then
                    pcb:SetCooldown(now, 3.0)
                    pcb:Show()
                end
            end
            if YemCirclesDB.gcdbar then
                local pgb = previewGcdBars[1]
                if pgb then
                    pgb:SetCooldown(now, 3.0)
                    pgb:Show()
                end
            end
        end
        local pt = previewTextures[1]
        if pt then
            pt:SetAlpha((YemCirclesDB.a or 0.8) * 0.3)
        end
    else
        self.timer = 3.0 
        for i = 1, #previewCastBars do
            previewCastBars[i]:Hide()
        end
        for i = 1, #previewGcdBars do
            previewGcdBars[i]:Hide()
        end
        for i = 1, #previewTextures do
            if previewTextures[i] then
                previewTextures[i]:SetAlpha(YemCirclesDB.a or 0.8)
            end
        end
    end
end)

local function CreateCheckbox(name, label, xOffset, yOffset, dbKey)
    local cb = CreateFrame("CheckButton", "YemCirclesCB"..name, options, "ChatConfigCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", xOffset, yOffset)
    _G[cb:GetName().."Text"]:SetText(label)
    cb:SetScript("OnClick", function(self)
        YemCirclesDB[dbKey] = self:GetChecked()
        if dbKey == "filled" then
            UpdateThicknessSliderState()
        elseif dbKey == "trail" then
            UpdateTrailCheckboxState()
        end
        ApplySettings()
    end)
    return cb
end

local function CreateClassButton(parent, classData, x, y)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 20)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    
    local tex = btn:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetColorTexture(classData.r, classData.g, classData.b, 1)
    
    local border = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    border:SetAllPoints()
    border:SetBackdrop({edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    border:SetBackdropBorderColor(0, 0, 0, 1)
    
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    label:SetText(classData.name)
    
    btn:SetScript("OnClick", function()
        YemCirclesDB.autoClassColor = false
        if options.cbAutoClass then options.cbAutoClass:SetChecked(false) end
        
        YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, YemCirclesDB.a = classData.r, classData.g, classData.b, 0.8
        YemCirclesDB.castR, YemCirclesDB.castG, YemCirclesDB.castB, YemCirclesDB.castA = classData.r, classData.g, classData.b, 1
        ApplySettings()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

local presetLabel = options:CreateFontString(nil, "ARTWORK", "GameFontNormal")
presetLabel:SetPoint("TOPLEFT", 16, -55)
presetLabel:SetText("Quick Presets (Changes both Circle and Cast Bar)")

local classGridContainer = CreateFrame("Frame", nil, options)
classGridContainer:SetSize(440, 115)
classGridContainer:SetPoint("TOPLEFT", presetLabel, "BOTTOMLEFT", 0, -8)

local buttonX, buttonY = 0, 0
for i, classData in ipairs(classColors) do
    local col = (i - 1) % 3
    local row = math_floor((i - 1) / 3)
    buttonX = col * 148
    buttonY = -(row * 22)
    CreateClassButton(classGridContainer, classData, buttonX, buttonY)
end

local uiOffset = -200

options.cbAutoClass = CreateFrame("CheckButton", "YemCirclesCBAutoClass", options, "ChatConfigCheckButtonTemplate")
options.cbAutoClass:SetPoint("TOPLEFT", 16, uiOffset) 
_G[options.cbAutoClass:GetName().."Text"]:SetText("Auto-Color to Current Character's Class")
options.cbAutoClass:SetScript("OnClick", function(self)
    YemCirclesDB.autoClassColor = self:GetChecked()
    if YemCirclesDB.autoClassColor then ApplyAutoClassColor() end
    ApplySettings()
end)

-- Circle Size Slider
local sliderSize = CreateFrame("Slider", "YemCirclesSliderSize", options, "OptionsSliderTemplate")
sliderSize:SetPoint("TOPLEFT", 16, uiOffset - 40)
sliderSize:SetMinMaxValues(10, 150)
sliderSize:SetValueStep(1)
sliderSize:SetObeyStepOnDrag(true)

_G[sliderSize:GetName().."Text"]:SetText("Circle Size")
_G[sliderSize:GetName().."Low"]:SetText("10")
_G[sliderSize:GetName().."High"]:SetText("150")

local sizeInput = CreateFrame("EditBox", "YemCirclesSizeInput", options, "InputBoxTemplate")
sizeInput:SetSize(40, 20)
sizeInput:SetPoint("LEFT", sliderSize, "RIGHT", 15, 0)
sizeInput:SetAutoFocus(false)

sliderSize:SetScript("OnValueChanged", function(self, value)
    value = math_floor(value)
    YemCirclesDB.size = value
    sizeInput:SetText(value)
    ApplySettings()
end)

sizeInput:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then
        val = math_max(10, math_min(150, val)) 
        sliderSize:SetValue(val)
        self:SetText(val)
        self:ClearFocus()
    end
end)
sizeInput:SetScript("OnEscapePressed", function(self)
    self:SetText(math_floor(sliderSize:GetValue()))
    self:ClearFocus()
end)

-- Circle Thickness Slider
sliderThickness = CreateFrame("Slider", "YemCirclesSliderThickness", options, "OptionsSliderTemplate")
sliderThickness:SetPoint("TOPLEFT", 16, uiOffset - 90)
sliderThickness:SetMinMaxValues(1, 5)
sliderThickness:SetValueStep(1)
sliderThickness:SetObeyStepOnDrag(true)

_G[sliderThickness:GetName().."Text"]:SetText("Circle Thickness")
_G[sliderThickness:GetName().."Low"]:SetText("1")
_G[sliderThickness:GetName().."High"]:SetText("5")

thicknessInput = CreateFrame("EditBox", "YemCirclesThicknessInput", options, "InputBoxTemplate")
thicknessInput:SetSize(40, 20)
thicknessInput:SetPoint("LEFT", sliderThickness, "RIGHT", 15, 0)
thicknessInput:SetAutoFocus(false)

sliderThickness:SetScript("OnValueChanged", function(self, value)
    value = math_floor(value)
    YemCirclesDB.thickness = value
    thicknessInput:SetText(value)
    ApplySettings()
end)

thicknessInput:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then
        val = math_max(1, math_min(5, val)) 
        sliderThickness:SetValue(val)
        self:SetText(val)
        self:ClearFocus()
    end
end)
thicknessInput:SetScript("OnEscapePressed", function(self)
    self:SetText(math_floor(sliderThickness:GetValue()))
    self:ClearFocus()
end)

local function CreateColorButton(name, labelText, xOffset, yOffset, rKey, gKey, bKey, aKey)
    local btn = CreateFrame("Button", "YemCircles"..name.."ColorBtn", options)
    btn:SetSize(32, 32)
    btn:SetPoint("TOPLEFT", xOffset, yOffset)
    
    local tex = btn:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    btn.bgTex = tex 
    
    local border = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    border:SetAllPoints()
    border:SetBackdrop({edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    border:SetBackdropBorderColor(1, 1, 1, 0.5)
    
    local label = options:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", btn, "RIGHT", 10, 0)
    label:SetText(labelText)
    
    btn:SetScript("OnClick", function()
        local origR = YemCirclesDB[rKey]
        local origG = YemCirclesDB[gKey]
        local origB = YemCirclesDB[bKey]
        local origA = YemCirclesDB[aKey]
        
        local function OnColorChanged()
            YemCirclesDB.autoClassColor = false
            if options.cbAutoClass then options.cbAutoClass:SetChecked(false) end
            
            local newR, newG, newB, newA
            if ColorPickerFrame.SetupColorPickerAndShow then
                newR, newG, newB = ColorPickerFrame:GetColorRGB()
                newA = ColorPickerFrame:GetColorAlpha()
            else
                -- Fallback for Classic/older client API
                newR, newG, newB = ColorPickerFrame:GetColorRGB()
                newA = 1 - OpacitySliderFrame:GetValue()
            end
            
            YemCirclesDB[rKey], YemCirclesDB[gKey], YemCirclesDB[bKey], YemCirclesDB[aKey] = newR, newG, newB, newA
            UpdateColorWidget(btn, newR, newG, newB, newA)
            
            -- Sync the opacity sliders if they exist
            if aKey == "a" and sliderOpacity then
                sliderOpacity:SetValue(math_floor(newA * 100))
                opacityInput:SetText(math_floor(newA * 100))
            elseif aKey == "castA" and sliderCastOpacity then
                sliderCastOpacity:SetValue(math_floor(newA * 100))
                castOpacityInput:SetText(math_floor(newA * 100))
            elseif aKey == "gcdA" and sliderGcdOpacity then
                sliderGcdOpacity:SetValue(math_floor(newA * 100))
                gcdOpacityInput:SetText(math_floor(newA * 100))
            end
            
            ApplySettings()
        end
        
        local function OnColorCanceled()
            YemCirclesDB[rKey], YemCirclesDB[gKey], YemCirclesDB[bKey], YemCirclesDB[aKey] = origR, origG, origB, origA
            UpdateColorWidget(btn, origR, origG, origB, origA)
            
            -- Sync the opacity sliders if they exist
            if aKey == "a" and sliderOpacity then
                sliderOpacity:SetValue(math_floor(origA * 100))
                opacityInput:SetText(math_floor(origA * 100))
            elseif aKey == "castA" and sliderCastOpacity then
                sliderCastOpacity:SetValue(math_floor(origA * 100))
                castOpacityInput:SetText(math_floor(origA * 100))
            elseif aKey == "gcdA" and sliderGcdOpacity then
                sliderGcdOpacity:SetValue(math_floor(origA * 100))
                gcdOpacityInput:SetText(math_floor(origA * 100))
            end
            
            ApplySettings()
        end
        
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = origR, g = origG, b = origB, opacity = origA,
                hasOpacity = true,
                swatchFunc = OnColorChanged,
                opacityFunc = OnColorChanged,
                cancelFunc = OnColorCanceled
            })
        else
            -- Fallback for Classic/older client API
            ColorPickerFrame.func = OnColorChanged
            ColorPickerFrame.opacityFunc = OnColorChanged
            ColorPickerFrame.cancelFunc = OnColorCanceled
            ColorPickerFrame.hasOpacity = true
            ColorPickerFrame.opacity = 1 - origA
            ColorPickerFrame:SetColorRGB(origR, origG, origB)
            ShowUIPanel(ColorPickerFrame)
        end
    end)
    return btn
end

-- Stack color buttons and opacity controls in a neat 2-column grid layout
options.ColorBtn = CreateColorButton("Main", "Cursor Color", 16, uiOffset - 140, "r", "g", "b", "a")

-- Circle Opacity Slider
sliderOpacity = CreateFrame("Slider", "YemCirclesSliderOpacity", options, "OptionsSliderTemplate")
sliderOpacity:SetPoint("TOPLEFT", 200, uiOffset - 140)
sliderOpacity:SetMinMaxValues(0, 100)
sliderOpacity:SetValueStep(5)
sliderOpacity:SetObeyStepOnDrag(true)

_G[sliderOpacity:GetName().."Text"]:SetText("Circle Opacity")
_G[sliderOpacity:GetName().."Low"]:SetText("0%")
_G[sliderOpacity:GetName().."High"]:SetText("100%")

opacityInput = CreateFrame("EditBox", "YemCirclesOpacityInput", options, "InputBoxTemplate")
opacityInput:SetSize(40, 20)
opacityInput:SetPoint("LEFT", sliderOpacity, "RIGHT", 15, 0)
opacityInput:SetAutoFocus(false)

sliderOpacity:SetScript("OnValueChanged", function(self, value)
    value = math_floor(value)
    YemCirclesDB.a = value / 100
    opacityInput:SetText(value)
    ApplySettings()
end)

opacityInput:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then
        val = math_max(0, math_min(100, val)) 
        sliderOpacity:SetValue(val)
        self:SetText(val)
        self:ClearFocus()
    end
end)
opacityInput:SetScript("OnEscapePressed", function(self)
    self:SetText(math_floor(sliderOpacity:GetValue()))
    self:ClearFocus()
end)


-- Misc checkboxes (compacted now that cast/GCD live in the Sweep box below)
local cbShowDot    = CreateCheckbox("ShowDot",    "Show Center Dot",      16,  uiOffset - 190, "showDot")
local cbFilled     = CreateCheckbox("Filled",     "Solid Filled Circle",  240, uiOffset - 190, "filled")
local cbTrail      = CreateCheckbox("Trail",      "Enable Cursor Trail",  16,  uiOffset - 214, "trail")
local cbHideCombat = CreateCheckbox("HideCombat", "Hide Out of Combat",   240, uiOffset - 214, "hideOutOfCombat")
cbTrailDot         = CreateCheckbox("TrailDot",   "Use Dot for Trail",    16,  uiOffset - 238, "trailStyleDot")
local cbHideRightClick = CreateCheckbox("HideRightClick", "Hide on Right Click", 240, uiOffset - 238, "hideOnRightClick")

-------------------------------------------------
-- SWEEP SETTINGS BOX
-------------------------------------------------
local sweepBox = CreateFrame("Frame", "YemCirclesSweepBox", options, "BackdropTemplate")
sweepBox:SetSize(590, 138)
sweepBox:SetPoint("TOPLEFT", 10, uiOffset - 262)
sweepBox:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
sweepBox:SetBackdropColor(0, 0, 0, 0.35)
sweepBox:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

local sweepTitle = sweepBox:CreateFontString(nil, "ARTWORK", "GameFontNormal")
sweepTitle:SetPoint("TOPLEFT", 10, -8)
sweepTitle:SetText("Sweep Settings")
sweepTitle:SetTextColor(1, 0.82, 0)

-- Helper: enable/disable a sweep row's color button, slider, input, and label
local function SetSweepRowEnabled(enabled, colorBtn, colorLabel, slider, input, inputLabel)
    if enabled then
        colorBtn:EnableMouse(true);  colorBtn:SetAlpha(1)
        if colorLabel then colorLabel:SetTextColor(1, 1, 1) end
        slider:Enable()
        input:SetEnabled(true);  input:SetTextColor(1, 1, 1)
        if inputLabel then inputLabel:SetTextColor(1, 1, 1) end
    else
        colorBtn:EnableMouse(false); colorBtn:SetAlpha(0.35)
        if colorLabel then colorLabel:SetTextColor(0.45, 0.45, 0.45) end
        slider:Disable()
        input:SetEnabled(false); input:SetTextColor(0.45, 0.45, 0.45)
        if inputLabel then inputLabel:SetTextColor(0.45, 0.45, 0.45) end
    end
end

----------- Cast Sweep row (y=-30 inside box) -----------
local cbCastbar = CreateFrame("CheckButton", "YemCirclesCBCastbar", sweepBox, "ChatConfigCheckButtonTemplate")
cbCastbar:SetPoint("TOPLEFT", 8, -24)
_G[cbCastbar:GetName().."Text"]:SetText("Cast Bar Sweep")

options.CastColorBtn = CreateColorButton("CastBar", "", 175, -32, "castR", "castG", "castB", "castA")
-- Re-parent to sweepBox (CreateColorButton anchors to options, fix that)
options.CastColorBtn:ClearAllPoints()
options.CastColorBtn:SetParent(sweepBox)
options.CastColorBtn:SetPoint("TOPLEFT", sweepBox, "TOPLEFT", 175, -24)
options.CastColorBtn:SetSize(22, 22)

local castColorLabel = sweepBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
castColorLabel:SetPoint("LEFT", options.CastColorBtn, "RIGHT", 5, 0)
castColorLabel:SetText("Color")

sliderCastOpacity = CreateFrame("Slider", "YemCirclesSliderCastOpacity", sweepBox, "OptionsSliderTemplate")
sliderCastOpacity:SetPoint("TOPLEFT", 255, -34)
sliderCastOpacity:SetWidth(230)
sliderCastOpacity:SetMinMaxValues(0, 100)
sliderCastOpacity:SetValueStep(5)
sliderCastOpacity:SetObeyStepOnDrag(true)
_G[sliderCastOpacity:GetName().."Text"]:SetText("Opacity")
_G[sliderCastOpacity:GetName().."Low"]:SetText("0%")
_G[sliderCastOpacity:GetName().."High"]:SetText("100%")

castOpacityInput = CreateFrame("EditBox", "YemCirclesCastOpacityInput", sweepBox, "InputBoxTemplate")
castOpacityInput:SetSize(38, 20)
castOpacityInput:SetPoint("LEFT", sliderCastOpacity, "RIGHT", 8, 0)
castOpacityInput:SetAutoFocus(false)

sliderCastOpacity:SetScript("OnValueChanged", function(self, value)
    value = math_floor(value)
    YemCirclesDB.castA = value / 100
    castOpacityInput:SetText(value)
    ApplySettings()
end)
castOpacityInput:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then
        val = math_max(0, math_min(100, val))
        sliderCastOpacity:SetValue(val)
        self:SetText(val); self:ClearFocus()
    end
end)
castOpacityInput:SetScript("OnEscapePressed", function(self)
    self:SetText(math_floor(sliderCastOpacity:GetValue())); self:ClearFocus()
end)

cbCastbar:SetScript("OnClick", function(self)
    YemCirclesDB.castbar = self:GetChecked()
    SetSweepRowEnabled(YemCirclesDB.castbar, options.CastColorBtn, castColorLabel, sliderCastOpacity, castOpacityInput)
    ApplySettings()
end)

----------- GCD Sweep row (y=-62 inside box) -----------
local cbGCD = CreateFrame("CheckButton", "YemCirclesCBGCD", sweepBox, "ChatConfigCheckButtonTemplate")
cbGCD:SetPoint("TOPLEFT", 8, -56)
_G[cbGCD:GetName().."Text"]:SetText("GCD Sweep")

options.GcdColorBtn = CreateColorButton("GCDSweep", "", 175, -66, "gcdR", "gcdG", "gcdB", "gcdA")
options.GcdColorBtn:ClearAllPoints()
options.GcdColorBtn:SetParent(sweepBox)
options.GcdColorBtn:SetPoint("TOPLEFT", sweepBox, "TOPLEFT", 175, -56)
options.GcdColorBtn:SetSize(22, 22)

local gcdColorLabel = sweepBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
gcdColorLabel:SetPoint("LEFT", options.GcdColorBtn, "RIGHT", 5, 0)
gcdColorLabel:SetText("Color")

sliderGcdOpacity = CreateFrame("Slider", "YemCirclesSliderGcdOpacity", sweepBox, "OptionsSliderTemplate")
sliderGcdOpacity:SetPoint("TOPLEFT", 255, -66)
sliderGcdOpacity:SetWidth(230)
sliderGcdOpacity:SetMinMaxValues(0, 100)
sliderGcdOpacity:SetValueStep(5)
sliderGcdOpacity:SetObeyStepOnDrag(true)
_G[sliderGcdOpacity:GetName().."Text"]:SetText("Opacity")
_G[sliderGcdOpacity:GetName().."Low"]:SetText("0%")
_G[sliderGcdOpacity:GetName().."High"]:SetText("100%")

gcdOpacityInput = CreateFrame("EditBox", "YemCirclesGcdOpacityInput", sweepBox, "InputBoxTemplate")
gcdOpacityInput:SetSize(38, 20)
gcdOpacityInput:SetPoint("LEFT", sliderGcdOpacity, "RIGHT", 8, 0)
gcdOpacityInput:SetAutoFocus(false)

sliderGcdOpacity:SetScript("OnValueChanged", function(self, value)
    value = math_floor(value)
    YemCirclesDB.gcdA = value / 100
    gcdOpacityInput:SetText(value)
    ApplySettings()
end)
gcdOpacityInput:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText())
    if val then
        val = math_max(0, math_min(100, val))
        sliderGcdOpacity:SetValue(val)
        self:SetText(val); self:ClearFocus()
    end
end)
gcdOpacityInput:SetScript("OnEscapePressed", function(self)
    self:SetText(math_floor(sliderGcdOpacity:GetValue())); self:ClearFocus()
end)

cbGCD:SetScript("OnClick", function(self)
    YemCirclesDB.gcdbar = self:GetChecked()
    SetSweepRowEnabled(YemCirclesDB.gcdbar, options.GcdColorBtn, gcdColorLabel, sliderGcdOpacity, gcdOpacityInput)
    ApplySettings()
end)

----------- Tip text inside the box -----------
local tipLine1 = sweepBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
tipLine1:SetPoint("TOPLEFT", 12, -98)
tipLine1:SetWidth(566)
tipLine1:SetJustifyH("LEFT")
tipLine1:SetTextColor(0.9, 0.9, 0.9)
tipLine1:SetText("Activating both sweeps will move the GCD sweep to inside the circle.")

-------------------------------------------------
local function UpdateSweepRowStates()
    SetSweepRowEnabled(YemCirclesDB.castbar or false, options.CastColorBtn, castColorLabel, sliderCastOpacity, castOpacityInput)
    SetSweepRowEnabled(YemCirclesDB.gcdbar  or false, options.GcdColorBtn,  gcdColorLabel,  sliderGcdOpacity,  gcdOpacityInput)
end

local function UpdateUIFromDB()
    sliderSize:SetValue(YemCirclesDB.size)
    sizeInput:SetText(math_floor(YemCirclesDB.size))
    
    sliderThickness:SetValue(YemCirclesDB.thickness or 1)
    thicknessInput:SetText(math_floor(YemCirclesDB.thickness or 1))
    
    if sliderOpacity and opacityInput then
        sliderOpacity:SetValue(math_floor((YemCirclesDB.a or 0.8) * 100))
        opacityInput:SetText(math_floor((YemCirclesDB.a or 0.8) * 100))
    end
    
    if sliderCastOpacity and castOpacityInput then
        sliderCastOpacity:SetValue(math_floor((YemCirclesDB.castA or 1.0) * 100))
        castOpacityInput:SetText(math_floor((YemCirclesDB.castA or 1.0) * 100))
    end
    
    if sliderGcdOpacity and gcdOpacityInput then
        sliderGcdOpacity:SetValue(math_floor((YemCirclesDB.gcdA or 0.5) * 100))
        gcdOpacityInput:SetText(math_floor((YemCirclesDB.gcdA or 0.5) * 100))
    end
    
    cbFilled:SetChecked(YemCirclesDB.filled)
    cbTrail:SetChecked(YemCirclesDB.trail)
    cbCastbar:SetChecked(YemCirclesDB.castbar)
    cbGCD:SetChecked(YemCirclesDB.gcdbar)
    cbHideCombat:SetChecked(YemCirclesDB.hideOutOfCombat)
    options.cbAutoClass:SetChecked(YemCirclesDB.autoClassColor)
    cbShowDot:SetChecked(YemCirclesDB.showDot)
    cbTrailDot:SetChecked(YemCirclesDB.trailStyleDot)
    cbHideRightClick:SetChecked(YemCirclesDB.hideOnRightClick)
    
    UpdateColorWidget(options.ColorBtn, YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, YemCirclesDB.a)
    UpdateColorWidget(options.CastColorBtn, YemCirclesDB.castR, YemCirclesDB.castG, YemCirclesDB.castB, YemCirclesDB.castA)
    UpdateColorWidget(options.GcdColorBtn,  YemCirclesDB.gcdR,  YemCirclesDB.gcdG,  YemCirclesDB.gcdB,  YemCirclesDB.gcdA)
    
    UpdateSweepRowStates()
    UpdateThicknessSliderState()
    UpdateTrailCheckboxState()
end

-- Synchronize UI and preview elements when the options panel is opened
options:SetScript("OnShow", function(self)
    UpdateUIFromDB()
    ApplySettings()
end)

options:SetScript("OnHide", function(self)
    self.initializedVisible = false
end)

options:SetScript("OnUpdate", function(self, elapsed)
    if self:IsVisible() then
        if not self.initializedVisible then
            self.initializedVisible = true
            UpdateUIFromDB()
            ApplySettings()
        end
    else
        self.initializedVisible = false
    end
end)

-- Legacy support
options.refresh = function()
    UpdateUIFromDB()
    ApplySettings()
end

local categoryObj
if Settings and Settings.RegisterCanvasLayoutCategory then
    categoryObj = Settings.RegisterCanvasLayoutCategory(options, options.name)
    Settings.RegisterAddOnCategory(categoryObj)
    if categoryObj and categoryObj.OnRefresh then
        categoryObj.OnRefresh = function(self)
            UpdateUIFromDB()
            ApplySettings()
        end
    end
else
    InterfaceOptions_AddCategory(options)
end

-------------------------------------------------
-- EVENT HANDLING & LOGIC
-------------------------------------------------
core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_ENTERING_WORLD")
core:RegisterEvent("UI_SCALE_CHANGED")
core:RegisterEvent("DISPLAY_SIZE_CHANGED")
core:RegisterEvent("PLAYER_REGEN_DISABLED") 
core:RegisterEvent("PLAYER_REGEN_ENABLED")  
core:RegisterEvent("UNIT_SPELLCAST_START")
core:RegisterEvent("UNIT_SPELLCAST_STOP")
core:RegisterEvent("UNIT_SPELLCAST_DELAYED")
core:RegisterEvent("UNIT_SPELLCAST_FAILED")
core:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
core:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
core:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
core:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
core:RegisterEvent("UNIT_SPELLCAST_SENT")
core:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
core:RegisterEvent("SPELL_UPDATE_COOLDOWN")
core:RegisterEvent("GLOBAL_MOUSE_DOWN")
core:RegisterEvent("GLOBAL_MOUSE_UP")

core:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" and arg1 == addonName then
        YemCirclesDB = YemCirclesDB or {}
        for k, v in pairs(defaultDB) do
            if YemCirclesDB[k] == nil then
                YemCirclesDB[k] = v
            end
        end
        UpdateScale()
        ApplyAutoClassColor() 
        ApplySettings()
        UpdateUIFromDB()
        
    elseif event == "PLAYER_ENTERING_WORLD" or event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        UpdateScale()
        ApplySettings()
        
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateVisibility()
        
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        if not YemCirclesDB.gcdbar then
            StopGCD(); isGCD = false
            UpdateVisibility(); return
        end
        
        local start, duration = 0, 0
        if C_Spell and C_Spell.GetSpellCooldown then
            local cdInfo = C_Spell.GetSpellCooldown(61304)
            if cdInfo then start, duration = cdInfo.startTime, cdInfo.duration end
        else
            start, duration = GetSpellCooldown(61304)
        end

        if start and start > 0 and duration > 0 and duration <= 3.0 then
            -- Start (or continue) GCD sweep. TriggerGCD dedup prevents redundant SetCooldown calls.
            -- GCD runs simultaneously with any active cast sweep -- no coordination needed.
            isGCD = true
            TriggerGCD(start, duration)
        else
            isGCD = false
            StopGCD()
        end
        UpdateVisibility()
        
    elseif event == "UNIT_SPELLCAST_SENT" and arg1 == "player" then
        local castGUID, spellID = arg3, arg4
        local castTime = GetSpellCastTime(spellID)
        
        if castTime and castTime > 0 then
            -- Start cast sweep only. GCD is already running (started by SPELL_UPDATE_COOLDOWN
            -- which fired this same frame) and will continue independently until it expires.
            -- We never stop GCD during a cast, so there is no end-of-cast SetCooldown needed.
            isWaitingForCastStart = castGUID
            isCasting = true
            
            if YemCirclesDB.castbar then
                preemptiveStart = GetTime()
                preemptiveDuration = castTime / 1000
                TriggerCast(preemptiveStart, preemptiveDuration)
            else
                preemptiveStart = nil
                preemptiveDuration = nil
            end
        else
            -- Instant cast: GCD already started by SPELL_UPDATE_COOLDOWN, nothing else to do
        end
        UpdateVisibility()

    elseif event:find("UNIT_SPELLCAST") and arg1 == "player" then
        if not YemCirclesDB.castbar then 
            StopCast()
            isCasting = false
            currentCastGUID = nil
            preemptiveStart = nil
            preemptiveDuration = nil
            UpdateVisibility()
            return 
        end
        
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
            local name, text, texture, startTime, endTime = UnitCastingInfo("player")
            if not name then
                name, text, texture, startTime, endTime = UnitChannelInfo("player")
            end

            if name then
                isCasting = true
                -- Do NOT touch GCD state here -- GCD sweep runs independently
                for i = 1, #castBars do
                    if castBars[i] then
                        castBars[i]:SetSwipeColor(YemCirclesDB.castR, YemCirclesDB.castG, YemCirclesDB.castB, YemCirclesDB.castA)
                    end
                end
                
                currentCastGUID = arg2
                isWaitingForCastStart = nil
                
                local actualDuration = (endTime - startTime) / 1000
                if preemptiveDuration and math_abs(preemptiveDuration - actualDuration) < 0.050 then
                    activeCastStart = startTime / 1000
                    activeCastDuration = actualDuration
                else
                    TriggerCastAdjusted(endTime / 1000)
                end
                
                preemptiveStart = nil
                preemptiveDuration = nil
            end
            
        elseif event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            if arg2 == currentCastGUID or (arg2 == isWaitingForCastStart and isWaitingForCastStart ~= nil) then
                local name, text, texture, startTime, endTime = UnitCastingInfo("player")
                if not name then
                    name, text, texture, startTime, endTime = UnitChannelInfo("player")
                end

                if name then
                    isWaitingForCastStart = nil
                    currentCastGUID = arg2
                    
                    local actualDuration = (endTime - startTime) / 1000
                    if preemptiveDuration and math_abs(preemptiveDuration - actualDuration) < 0.050 then
                        activeCastStart = startTime / 1000
                        activeCastDuration = actualDuration
                    else
                        TriggerCastAdjusted(endTime / 1000)
                    end
                    
                    preemptiveStart = nil
                    preemptiveDuration = nil
                end
            end
            
        elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_SUCCEEDED" then
            if arg2 == currentCastGUID or arg2 == isWaitingForCastStart or currentCastGUID == nil then
                isCasting = false
                isWaitingForCastStart = nil
                currentCastGUID = nil
                preemptiveStart = nil
                preemptiveDuration = nil
                -- Stop cast sweep. GCD sweep is left completely alone to expire naturally.
                -- This is the key: only ONE SetCooldown call (StopCast) at cast end, never two.
                StopCast()
            end
        end
        
        UpdateVisibility()
    elseif event == "GLOBAL_MOUSE_DOWN" or event == "GLOBAL_MOUSE_UP" then
        if arg1 == "RightButton" then
            UpdateVisibility()
        end
    end
end)

-------------------------------------------------
-- UPDATE LOOP (Cursor tracking & Trails)
-------------------------------------------------
local lastRawX, lastRawY = 0, 0
local lastTrailX, lastTrailY = 0, 0

core:SetScript("OnUpdate", function(self, elapsed)
    -- Proactively end cast/GCD when their timers expire, preventing the one-frame
    -- flash where the CooldownFrame animation has finished but spell events
    -- haven't fired yet (leaving the circle dimmed with no sweep visible).
    if isCasting and activeCastStart and activeCastDuration and activeCastDuration > 0 then
        if GetTime() >= activeCastStart + activeCastDuration then
            isCasting = false
            currentCastGUID = nil
            isWaitingForCastStart = nil
            preemptiveStart = nil
            preemptiveDuration = nil
            StopCast()
            UpdateVisibility()
        end
    end

    if isGCD and activeGCDStart and activeGCDDuration and activeGCDDuration > 0 then
        if GetTime() >= activeGCDStart + activeGCDDuration then
            isGCD = false
            StopGCD()
            UpdateVisibility()
        end
    end

    local x, y = GetCursorPosition()
    
    -- Optimize: Only position frame if coordinates actually shifted
    if x ~= lastRawX or y ~= lastRawY then
        local adjX, adjY = x / scale, y / scale
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", adjX, adjY)
        
        local isHidden = YemCirclesDB.hideOutOfCombat and not InCombatLockdown() and not isCasting and not isGCD
        
        if YemCirclesDB.trail and not isHidden then
            if math_abs(x - lastTrailX) > 5 or math_abs(y - lastTrailY) > 5 then
                local tf = trailFrames[trailIndex]
                if not tf then
                    tf = core:CreateTexture(nil, "BACKGROUND")
                    trailFrames[trailIndex] = tf
                end
                
                if YemCirclesDB.trailStyleDot then
                    tf:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
                    local dotSize = 6
                    tf:SetSize(dotSize, dotSize)
                else
                    tf:SetTexture(GetCircleTexture())
                    tf:SetSize(YemCirclesDB.size * 0.8, YemCirclesDB.size * 0.8)
                end
                tf:SetBlendMode("BLEND")
                tf:SetVertexColor(YemCirclesDB.r, YemCirclesDB.g, YemCirclesDB.b, (YemCirclesDB.a or 0.8) * 0.5)
                tf:ClearAllPoints()
                tf:SetPoint("CENTER", UIParent, "BOTTOMLEFT", adjX, adjY)
                tf:Show()
                
                tf.timeLeft = 0.4 
                
                trailIndex = trailIndex + 1
                if trailIndex > maxTrails then trailIndex = 1 end
                lastTrailX, lastTrailY = x, y
            end
        end
        lastRawX, lastRawY = x, y
    end

    -- Process trail fading (runs independently to handle active trails disappearing when mouse is stationary)
    if YemCirclesDB.trail then
        for i = 1, maxTrails do
            local tf = trailFrames[i]
            if tf and tf:IsShown() then
                tf.timeLeft = tf.timeLeft - elapsed
                if tf.timeLeft <= 0 then
                    tf:Hide()
                else
                    tf:SetAlpha((tf.timeLeft / 0.4) * ((YemCirclesDB.a or 0.8) * 0.5))
                end
            end
        end
    end
end)

SLASH_YEMCIRCLES1 = "/yc"
SlashCmdList["YEMCIRCLES"] = function()
    if InCombatLockdown() then
        print("|cff00ffffYem Circles:|r Settings cannot be opened while in combat.")
        return
    end
    if Settings and Settings.OpenToCategory and categoryObj then
        Settings.OpenToCategory(categoryObj:GetID())
    else
        InterfaceOptionsFrame_OpenToCategory("Yem Circles")
    end
end