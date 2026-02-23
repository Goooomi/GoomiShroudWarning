-- goomishroudwarning.lua - Shroud of Concealment countdown module for GoomiUI
-- Uses UNIT_SPELLCAST_SUCCEEDED + UNIT_AURA (12.0 "NeverSecret" APIs)
-- instead of COMBAT_LOG_EVENT_UNFILTERED which returns secret values in 12.0+

if not GoomiUI then
    print("Error: GoomiShroudWarning requires GoomiUI to be installed!")
    return
end

local ShroudWarning = {
    name = "Shroud Warning",
    version = "1.0",
}

GoomiShroudWarningDB = GoomiShroudWarningDB or {}

local SHROUD_SPELL_ID = 114018
local SHROUD_BASE_DURATION = 15
local SHROUD_TALENTED_DURATION = 20

local defaults = {
    countdownStart = 10,        -- 0 = use full buff duration, otherwise start at this number
    countdownOffset = 0.7,      -- Announce numbers this many seconds early for safety buffer
    chatChannel = "SAY",        -- SAY, YELL, PARTY, or RAID

    -- Messages
    activationMsg = "Shroud Activated! (%ds)",
    endMsg = "Shroud Ending",
    showActivation = true,
    showEnd = true,
}

local countdownActive = false
local shroudBuffActive = false
local buffExpirationTime = 0
local lastAnnouncedSecond = 0
local countdownFrame = nil
local countdownStartFrom = 0

-- ========================
-- Database
-- ========================
local function InitDB()
    local db = GoomiShroudWarningDB

    -- Clean up removed settings from older versions
    db.countdownMode = nil
    db.finalThreshold = nil
    db.cancelMsg = nil
    db.showCancel = nil

    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = v end
    end
    db.countdownStart = math.max(0, math.min(20, math.floor(tonumber(db.countdownStart) or 10)))
    db.countdownOffset = math.max(0, math.min(1, tonumber(db.countdownOffset) or 0.7))
    -- Round offset to nearest 0.1
    db.countdownOffset = math.floor(db.countdownOffset * 10 + 0.5) / 10
    -- Validate chat channel
    local validChannels = { SAY = true, YELL = true, PARTY = true, RAID = true }
    if not validChannels[db.chatChannel] then db.chatChannel = "SAY" end
end

-- ========================
-- Countdown Logic
-- ========================

countdownFrame = CreateFrame("Frame")
countdownFrame:Hide()

local function StopCountdown()
    countdownActive = false
    buffExpirationTime = 0
    lastAnnouncedSecond = 0
    countdownStartFrom = 0
    countdownFrame:Hide()
end

local function Say(msg)
    if msg and msg ~= "" then
        local channel = GoomiShroudWarningDB.chatChannel or "SAY"
        SendChatMessage(msg, channel)
    end
end

-- OnUpdate handler: reads real remaining time from the buff each frame
-- Numbers are announced early by the configured offset as a safety buffer
countdownFrame:SetScript("OnUpdate", function(self, elapsed)
    if not countdownActive then
        self:Hide()
        return
    end

    local offset = GoomiShroudWarningDB.countdownOffset or 0.5
    local remaining = buffExpirationTime - GetTime()
    local offsetRemaining = remaining - offset

    if offsetRemaining <= 0 then
        -- Our countdown is done (buff still has offset time left as safety buffer)
        if GoomiShroudWarningDB.showEnd then Say(GoomiShroudWarningDB.endMsg) end
        StopCountdown()
        shroudBuffActive = false
        return
    end

    local currentSecond = math.ceil(offsetRemaining)

    -- Only announce each second once, and only if within our start range
    if currentSecond < lastAnnouncedSecond and currentSecond >= 1 and currentSecond <= countdownStartFrom then
        lastAnnouncedSecond = currentSecond
        Say(tostring(currentSecond))
    end
end)

local function StartCountdown(expirationTime, totalDuration)
    local db = GoomiShroudWarningDB
    StopCountdown()

    buffExpirationTime = expirationTime
    local remaining = expirationTime - GetTime()
    local duration = totalDuration or math.floor(remaining + 0.5)

    -- Determine the number to start counting from
    local startFrom = db.countdownStart
    if startFrom == 0 or startFrom > duration then
        startFrom = math.floor(duration)
    end

    -- Send activation message
    if db.showActivation then
        local msg = db.activationMsg or "Shroud Activated!"
        msg = msg:gsub("%%d", tostring(math.floor(duration)))
        Say(msg)
    end

    countdownActive = true
    shroudBuffActive = true
    countdownStartFrom = startFrom
    lastAnnouncedSecond = startFrom + 1

    countdownFrame:Show()
end

-- ========================
-- Event Handling
-- ========================
local eventFrame

local function SetupEvents()
    if eventFrame then return end

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:RegisterEvent("UNIT_AURA")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_ENTERING_WORLD" then
            InitDB()
            return
        end

        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unitTarget, castGUID, spellID = ...
            if unitTarget ~= "player" or spellID ~= SHROUD_SPELL_ID then return end
            if countdownActive then return end

            C_Timer.After(0.15, function()
                if countdownActive then return end

                local duration = SHROUD_BASE_DURATION
                local expirationTime = GetTime() + duration

                if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                    local aura = C_UnitAuras.GetPlayerAuraBySpellID(SHROUD_SPELL_ID)
                    if aura then
                        if aura.duration and aura.duration > 0 then
                            duration = aura.duration
                        end
                        if aura.expirationTime and aura.expirationTime > 0 then
                            expirationTime = aura.expirationTime
                        end
                    end
                end

                StartCountdown(expirationTime, duration)
            end)
            return
        end

        if event == "UNIT_AURA" then
            local unit = ...
            if unit ~= "player" then return end
            if not shroudBuffActive then return end

            local aura = nil
            if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
                aura = C_UnitAuras.GetPlayerAuraBySpellID(SHROUD_SPELL_ID)
            end

            if not aura then
                if countdownActive then
                    local timeLeft = buffExpirationTime - GetTime()
                    if timeLeft > 2 then
                        -- Significant time remaining = cancelled early
                        StopCountdown()
                        shroudBuffActive = false
                    else
                        -- Natural expiry area
                        StopCountdown()
                        shroudBuffActive = false
                    end
                else
                    shroudBuffActive = false
                end
            end
            return
        end
    end)
end

-- ========================
-- Module Lifecycle
-- ========================
function ShroudWarning:OnLoad()
    InitDB()
    SetupEvents()
end

function ShroudWarning:OnEnable()
    InitDB()
    SetupEvents()
end

function ShroudWarning:OnDisable()
    StopCountdown()
    shroudBuffActive = false
    if eventFrame then
        eventFrame:UnregisterAllEvents()
        eventFrame = nil
    end
end

-- ========================
-- Helper: Create a slider that won't revert its labels
-- Avoids OptionsSliderTemplate's Low/High label reset issue
-- ========================
local function CreateCleanSlider(parent, name, minVal, maxVal, step, width)
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetWidth(width or 200)

    -- Hide the template's Low/High labels (they reset on re-creation)
    local templateLow = slider.Low or (name and _G[name .. "Low"])
    local templateHigh = slider.High or (name and _G[name .. "High"])
    if templateLow then templateLow:Hide() end
    if templateHigh then templateHigh:Hide() end

    -- Create our own persistent labels
    slider.minLabel = slider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slider.minLabel:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, 0)
    slider.minLabel:SetText(tostring(minVal))
    slider.minLabel:SetTextColor(0.8, 0.8, 0.8, 1)

    slider.maxLabel = slider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slider.maxLabel:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, 0)
    slider.maxLabel:SetText(tostring(maxVal))
    slider.maxLabel:SetTextColor(0.8, 0.8, 0.8, 1)

    return slider
end

-- ========================
-- Settings UI
-- ========================
function ShroudWarning:CreateSettings(parentFrame)
    InitDB()
    local db = GoomiShroudWarningDB

    local function CreateBorder(parent, thickness, r, g, b, a)
        thickness, r, g, b, a = thickness or 1, r or 0, g or 0, b or 0, a or 1

        local top = parent:CreateTexture(nil, "OVERLAY")
        top:SetColorTexture(r, g, b, a)
        top:SetHeight(thickness)
        top:SetPoint("TOPLEFT")
        top:SetPoint("TOPRIGHT")

        local bottom = parent:CreateTexture(nil, "OVERLAY")
        bottom:SetColorTexture(r, g, b, a)
        bottom:SetHeight(thickness)
        bottom:SetPoint("BOTTOMLEFT")
        bottom:SetPoint("BOTTOMRIGHT")

        local left = parent:CreateTexture(nil, "OVERLAY")
        left:SetColorTexture(r, g, b, a)
        left:SetWidth(thickness)
        left:SetPoint("TOPLEFT")
        left:SetPoint("BOTTOMLEFT")

        local right = parent:CreateTexture(nil, "OVERLAY")
        right:SetColorTexture(r, g, b, a)
        right:SetWidth(thickness)
        right:SetPoint("TOPRIGHT")
        right:SetPoint("BOTTOMRIGHT")
    end

    -- Title
    local title = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText("SHROUD WARNING")
    title:SetTextColor(1, 1, 1, 1)

    local desc = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    desc:SetPoint("TOPLEFT", 0, -35)
    desc:SetWidth(550)
    desc:SetJustifyH("LEFT")
    desc:SetText("Announces a countdown in /say when you cast Shroud of Concealment. Automatically detects talented duration (15s or 20s).")
    desc:SetTextColor(0.7, 0.7, 0.7, 1)

    local yOffset = 75

    -- ==============================
    -- Section: Countdown Behavior
    -- ==============================
    local behaviorHeader = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    behaviorHeader:SetPoint("TOPLEFT", 0, -yOffset)
    behaviorHeader:SetText("Countdown Behavior")
    behaviorHeader:SetTextColor(1, 1, 1, 1)
    yOffset = yOffset + 30

    -- Countdown Start
    local startContainer = CreateFrame("Frame", nil, parentFrame)
    startContainer:SetSize(600, 60)
    startContainer:SetPoint("TOPLEFT", 0, -yOffset)
    startContainer.bg = startContainer:CreateTexture(nil, "BACKGROUND")
    startContainer.bg:SetAllPoints()
    startContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(startContainer, 1, 0.2, 0.2, 0.2, 0.5)

    local startLabel = startContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    startLabel:SetPoint("TOPLEFT", 10, -10)
    startLabel:SetText("Start Countdown At:")
    startLabel:SetTextColor(1, 1, 1, 1)

    local startSlider = CreateCleanSlider(startContainer, "GoomiShroudStartSlider", 0, 20, 1, 200)
    startSlider:SetPoint("LEFT", 150, 8)
    startSlider:SetValue(db.countdownStart)

    local startBox = CreateFrame("EditBox", nil, startContainer, "InputBoxTemplate")
    startBox:SetSize(50, 24)
    startBox:SetPoint("LEFT", startSlider, "RIGHT", 10, 0)
    startBox:SetAutoFocus(false)
    startBox:SetNumeric(true)
    startBox:SetText(tostring(db.countdownStart))

    local startHint = startContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    startHint:SetPoint("LEFT", startBox, "RIGHT", 10, 0)
    startHint:SetText("0 = max duration")
    startHint:SetTextColor(0.5, 0.5, 0.5, 1)

    local startNote = startContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    startNote:SetPoint("BOTTOMLEFT", 10, 5)
    startNote:SetText("Shroud baseline duration is 15 seconds (20 seconds with 'Shroud of Night' talent).")
    startNote:SetTextColor(0.5, 0.5, 0.5, 1)

    startSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value)
        db.countdownStart = value
        startBox:SetText(tostring(value))
    end)

    local startOriginal
    startBox:SetScript("OnEditFocusGained", function(self) startOriginal = db.countdownStart end)
    startBox:SetScript("OnEnterPressed", function(self)
        local v = math.max(0, math.min(20, math.floor(tonumber(self:GetText()) or 10)))
        db.countdownStart = v
        startSlider:SetValue(v)
        self:ClearFocus()
    end)
    startBox:SetScript("OnEditFocusLost", function(self)
        if not self.escapingFocus then
            local v = math.max(0, math.min(20, math.floor(tonumber(self:GetText()) or 10)))
            db.countdownStart = v
            startSlider:SetValue(v)
        end
        self.escapingFocus = nil
    end)
    startBox:SetScript("OnEscapePressed", function(self)
        self.escapingFocus = true
        db.countdownStart = startOriginal
        self:SetText(tostring(startOriginal))
        startSlider:SetValue(startOriginal)
        self:ClearFocus()
    end)

    yOffset = yOffset + 70

    -- Countdown Offset
    local offsetContainer = CreateFrame("Frame", nil, parentFrame)
    offsetContainer:SetSize(600, 60)
    offsetContainer:SetPoint("TOPLEFT", 0, -yOffset)
    offsetContainer.bg = offsetContainer:CreateTexture(nil, "BACKGROUND")
    offsetContainer.bg:SetAllPoints()
    offsetContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(offsetContainer, 1, 0.2, 0.2, 0.2, 0.5)

    local offsetLabel = offsetContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    offsetLabel:SetPoint("TOPLEFT", 10, -10)
    offsetLabel:SetText("Count Offset:")
    offsetLabel:SetTextColor(1, 1, 1, 1)

    local offsetSlider = CreateCleanSlider(offsetContainer, "GoomiShroudOffsetSlider", 0, 1, 0.1, 200)
    offsetSlider:SetPoint("LEFT", 150, 8)
    offsetSlider:SetValue(db.countdownOffset)

    local offsetBox = CreateFrame("EditBox", nil, offsetContainer, "InputBoxTemplate")
    offsetBox:SetSize(50, 24)
    offsetBox:SetPoint("LEFT", offsetSlider, "RIGHT", 10, 0)
    offsetBox:SetAutoFocus(false)
    offsetBox:SetText(string.format("%.1f", db.countdownOffset))

    local offsetHint = offsetContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    offsetHint:SetPoint("LEFT", offsetBox, "RIGHT", 10, 0)
    offsetHint:SetText("0.1 second increments")
    offsetHint:SetTextColor(0.5, 0.5, 0.5, 1)

    local offsetNote = offsetContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    offsetNote:SetPoint("BOTTOMLEFT", 10, 5)
    offsetNote:SetText("Shifts the countdown earlier by this amount, adding a small buffer between ending message and actual end.")
    offsetNote:SetTextColor(0.5, 0.5, 0.5, 1)

    offsetSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 10 + 0.5) / 10
        db.countdownOffset = value
        offsetBox:SetText(string.format("%.1f", value))
    end)

    local offsetOriginal
    offsetBox:SetScript("OnEditFocusGained", function(self) offsetOriginal = db.countdownOffset end)
    offsetBox:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText()) or 0.5
        v = math.max(0, math.min(1, math.floor(v * 10 + 0.5) / 10))
        db.countdownOffset = v
        offsetSlider:SetValue(v)
        self:SetText(string.format("%.1f", v))
        self:ClearFocus()
    end)
    offsetBox:SetScript("OnEditFocusLost", function(self)
        if not self.escapingFocus then
            local v = tonumber(self:GetText()) or 0.5
            v = math.max(0, math.min(1, math.floor(v * 10 + 0.5) / 10))
            db.countdownOffset = v
            offsetSlider:SetValue(v)
            self:SetText(string.format("%.1f", v))
        end
        self.escapingFocus = nil
    end)
    offsetBox:SetScript("OnEscapePressed", function(self)
        self.escapingFocus = true
        db.countdownOffset = offsetOriginal
        self:SetText(string.format("%.1f", offsetOriginal))
        offsetSlider:SetValue(offsetOriginal)
        self:ClearFocus()
    end)

    yOffset = yOffset + 70

    -- Chat Channel
    local channelContainer = CreateFrame("Frame", nil, parentFrame)
    channelContainer:SetSize(600, 40)
    channelContainer:SetPoint("TOPLEFT", 0, -yOffset)
    channelContainer.bg = channelContainer:CreateTexture(nil, "BACKGROUND")
    channelContainer.bg:SetAllPoints()
    channelContainer.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    CreateBorder(channelContainer, 1, 0.2, 0.2, 0.2, 0.5)

    local channelLabel = channelContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    channelLabel:SetPoint("LEFT", 10, 0)
    channelLabel:SetText("Announce In:")
    channelLabel:SetTextColor(1, 1, 1, 1)

    local channelOptions = {
        { label = "/say",   value = "SAY" },
        { label = "/yell",  value = "YELL" },
        { label = "/party", value = "PARTY" },
        { label = "/raid",  value = "RAID" },
    }

    local channelDropdown = CreateFrame("Frame", "GoomiShroudChannelDropdown", channelContainer, "UIDropDownMenuTemplate")
    channelDropdown:SetPoint("LEFT", 80, 0)
    UIDropDownMenu_SetWidth(channelDropdown, 65)
	GoomiShroudChannelDropdownText:SetJustifyH("CENTER")


    -- Set initial text
    local currentLabel = "/say"
    for _, opt in ipairs(channelOptions) do
        if opt.value == db.chatChannel then
            currentLabel = opt.label
            break
        end
    end
    UIDropDownMenu_SetText(channelDropdown, currentLabel)

    UIDropDownMenu_Initialize(channelDropdown, function(self, level)
        for _, opt in ipairs(channelOptions) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.checked = (db.chatChannel == opt.value)
            info.func = function()
                db.chatChannel = opt.value
                UIDropDownMenu_SetText(channelDropdown, opt.label)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    yOffset = yOffset + 50

    -- ==============================
    -- Section: Messages
    -- ==============================
    local msgHeader = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    msgHeader:SetPoint("TOPLEFT", 0, -yOffset)
    msgHeader:SetText("Chat Messages")
    msgHeader:SetTextColor(1, 1, 1, 1)

    yOffset = yOffset + 10

    local msgNote = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    msgNote:SetPoint("TOPLEFT", 0, -yOffset - 15)
    msgNote:SetWidth(550)
    msgNote:SetJustifyH("LEFT")
    msgNote:SetText("Use %d in the activation message to insert the detected duration.")
    msgNote:SetTextColor(0.5, 0.5, 0.5, 1)

    yOffset = yOffset + 40

    local function CreateMessageRow(label, dbEnabledKey, dbMsgKey)
        local container = CreateFrame("Frame", nil, parentFrame)
        container:SetSize(600, 40)
        container:SetPoint("TOPLEFT", 0, -yOffset)
        container.bg = container:CreateTexture(nil, "BACKGROUND")
        container.bg:SetAllPoints()
        container.bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
        CreateBorder(container, 1, 0.2, 0.2, 0.2, 0.5)

        local cb = CreateFrame("CheckButton", nil, container, "UICheckButtonTemplate")
        cb:SetPoint("LEFT", 10, 0)
        cb:SetSize(24, 24)
        cb:SetChecked(db[dbEnabledKey])

        cb.text:SetText(label)
        cb.text:SetPoint("LEFT", cb, "RIGHT", 5, 0)
        cb.text:SetTextColor(1, 1, 1, 1)
        cb.text:SetFontObject("GameFontNormal")

        local editBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
        editBox:SetSize(280, 24)
        editBox:SetPoint("RIGHT", -10, 0)
        editBox:SetAutoFocus(false)
        editBox:SetText(db[dbMsgKey] or "")

        cb:SetScript("OnClick", function(self)
            db[dbEnabledKey] = self:GetChecked() and true or false
        end)

        local editOriginal
        editBox:SetScript("OnEditFocusGained", function(self)
            editOriginal = db[dbMsgKey]
        end)
        editBox:SetScript("OnEnterPressed", function(self)
            db[dbMsgKey] = self:GetText()
            self:ClearFocus()
        end)
        editBox:SetScript("OnEditFocusLost", function(self)
            if not self.escapingFocus then
                db[dbMsgKey] = self:GetText()
            end
            self.escapingFocus = nil
        end)
        editBox:SetScript("OnEscapePressed", function(self)
            self.escapingFocus = true
            db[dbMsgKey] = editOriginal
            self:SetText(editOriginal)
            self:ClearFocus()
        end)

        yOffset = yOffset + 45

        return cb, editBox
    end

    local activationCB, activationEB = CreateMessageRow("Activation Message:", "showActivation", "activationMsg")
    local endCB, endEB = CreateMessageRow("Shroud Ending Message:", "showEnd", "endMsg")

    yOffset = yOffset + 20

    -- ==============================
    -- Reset Button
    -- ==============================
    local resetBtn = CreateFrame("Button", nil, parentFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(120, 30)
    resetBtn:SetPoint("BOTTOMRIGHT", parentFrame:GetParent(), "BOTTOMRIGHT", -20, 20)
    resetBtn:SetText("Reset to Default")

    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(defaults) do
            db[k] = v
        end

        startSlider:SetValue(db.countdownStart)
        startBox:SetText(tostring(db.countdownStart))
        offsetSlider:SetValue(db.countdownOffset)
        offsetBox:SetText(string.format("%.1f", db.countdownOffset))
        UIDropDownMenu_SetText(channelDropdown, "/say")
        activationCB:SetChecked(db.showActivation)
        activationEB:SetText(db.activationMsg)
        endCB:SetChecked(db.showEnd)
        endEB:SetText(db.endMsg)
    end)
end

-- Register this module with GoomiUI
GoomiUI:RegisterModule("Shroud Warning", ShroudWarning)