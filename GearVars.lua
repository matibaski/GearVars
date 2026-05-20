--[[
    GearVars
    Store your MH / OH / Shield item names once. Macros that contain
    {MH} / [OH] / <SH> tokens auto-update whenever you change gear.

    Slash:  /gv  (or /gearvars).  See /gv help for the full surface.
]]

local ADDON_NAME = ...

-- ===================================================================
-- Saved variables
-- ===================================================================
GearVarsDB = GearVarsDB or {}
GearVarsDB.gear      = GearVarsDB.gear      or {}
GearVarsDB.templates = GearVarsDB.templates or {}
GearVarsDB.minimap   = GearVarsDB.minimap   or { hide = false, angle = 200 }

-- ===================================================================
-- Helpers
-- ===================================================================
local function msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd700GearVars:|r " .. text)
end

local function getEquipLoc(itemLink)
    if not itemLink then return nil end
    local _, _, _, _, _, _, _, _, loc = GetItemInfo(itemLink)
    return loc
end

local function isTwoHand(itemLink)
    return getEquipLoc(itemLink) == "INVTYPE_2HWEAPON"
end

local function validForSlot(slotKey, itemLink)
    local loc = getEquipLoc(itemLink)
    if not loc then return false end
    if slotKey == "MH" then
        return loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONMAINHAND" or loc == "INVTYPE_2HWEAPON"
    elseif slotKey == "OH" then
        return loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONOFFHAND"
            or loc == "INVTYPE_HOLDABLE" or loc == "INVTYPE_SHIELD"
    elseif slotKey == "SH" then
        return loc == "INVTYPE_SHIELD"
    end
    return false
end

local function nameOf(itemLink)
    if not itemLink then return nil end
    return (GetItemInfo(itemLink))
end

local function escapePattern(s)
    return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

-- ===================================================================
-- Template engine
-- ===================================================================
local function expandTemplate(body)
    local g = GearVarsDB.gear
    local function sub(token, value)
        local v = value or ""
        body = body:gsub("{"  .. token .. "}",  v)
        body = body:gsub("%[" .. token .. "%]", v)
        body = body:gsub("<"  .. token .. ">",  v)
    end
    sub("MH", g.MH)
    sub("OH", g.OH)
    sub("SH", g.SH)
    return body
end

local function countTokens(body)
    local n = 0
    for _, t in ipairs({"MH", "OH", "SH"}) do
        for _ in body:gmatch("{"  .. t .. "}")  do n = n + 1 end
        for _ in body:gmatch("%[" .. t .. "%]") do n = n + 1 end
        for _ in body:gmatch("<"  .. t .. ">")  do n = n + 1 end
    end
    return n
end

-- ===================================================================
-- Combat-safe macro writes
-- EditMacro is blocked during combat lockdown. If an update is
-- requested mid-combat, queue it and flush on PLAYER_REGEN_ENABLED.
-- ===================================================================
local pendingApply = false

local function applyToAllMacros()
    if InCombatLockdown() then
        pendingApply = true
        return nil
    end
    local count, missing = 0, {}
    for name, template in pairs(GearVarsDB.templates) do
        local idx = GetMacroIndexByName(name)
        if idx and idx > 0 then
            local mname, iconTex = GetMacroInfo(idx)
            EditMacro(idx, mname, iconTex, expandTemplate(template))
            count = count + 1
        else
            table.insert(missing, name)
        end
    end
    return count, missing
end

local function reportApply(count, missing)
    if count == nil then
        msg("|cffff8888in combat — macro update queued, will apply when combat ends.|r")
        return
    end
    if missing then
        for _, m in ipairs(missing) do
            msg("|cffff5555orphan template (no matching macro):|r " .. m)
        end
    end
end

-- ===================================================================
-- Macro scanning
-- ===================================================================
-- Returns (converted, alreadyTokenized):
--   converted          — macros whose literal item names were rewritten into tokens
--   alreadyTokenized   — macros that already contained tokens; they're now bound too
local function autoBindMacros()
    local g = GearVarsDB.gear
    local subs = {}
    if g.MH and g.MH ~= "" then table.insert(subs, {key="MH", name=g.MH}) end
    if g.OH and g.OH ~= "" then table.insert(subs, {key="OH", name=g.OH}) end
    if g.SH and g.SH ~= "" then table.insert(subs, {key="SH", name=g.SH}) end
    table.sort(subs, function(a, b) return #a.name > #b.name end)

    local converted, alreadyTokenized = 0, 0
    local maxIdx = (MAX_ACCOUNT_MACROS or 120) + (MAX_CHARACTER_MACROS or 18)
    for i = 1, maxIdx do
        local name, _, body = GetMacroInfo(i)
        if name and body then
            local newBody = body
            for _, s in ipairs(subs) do
                newBody = newBody:gsub(escapePattern(s.name), "{" .. s.key .. "}")
            end
            if newBody ~= body then
                GearVarsDB.templates[name] = newBody
                converted = converted + 1
            elseif countTokens(body) > 0 and not GearVarsDB.templates[name] then
                -- Macro was written with tokens but never bound — bind it now.
                GearVarsDB.templates[name] = body
                alreadyTokenized = alreadyTokenized + 1
            end
        end
    end
    return converted, alreadyTokenized
end

local function detectFromCharacter()
    local mhLink = GetInventoryItemLink("player", 16)
    local ohLink = GetInventoryItemLink("player", 17)
    local changed = false

    if mhLink then
        local n = (GetItemInfo(mhLink))
        if n then
            GearVarsDB.gear.MH     = n
            GearVarsDB.gear.MHLink = mhLink
            changed = true
            if isTwoHand(mhLink) then
                GearVarsDB.gear.OH = nil
                GearVarsDB.gear.OHLink = nil
                ohLink = nil
            end
        end
    end

    if ohLink then
        local n, _, _, _, _, _, _, _, loc = GetItemInfo(ohLink)
        if n then
            if loc == "INVTYPE_SHIELD" then
                GearVarsDB.gear.SH     = n
                GearVarsDB.gear.SHLink = ohLink
            else
                GearVarsDB.gear.OH     = n
                GearVarsDB.gear.OHLink = ohLink
            end
            changed = true
        end
    end

    return changed
end

-- ===================================================================
-- Assignment helper (shared by click + drag-drop)
-- ===================================================================
local refreshAll  -- forward decl
local rebuildList -- forward decl

local function assignToSlot(slotKey, itemLink, label)
    if not validForSlot(slotKey, itemLink) then
        msg("|cffff5555that item is not valid for " .. label .. ".|r")
        return false
    end

    if slotKey == "OH"
    and GearVarsDB.gear.MHLink
    and isTwoHand(GearVarsDB.gear.MHLink) then
        msg("|cffff5555off-hand is locked: main-hand is two-handed.|r")
        return false
    end

    GearVarsDB.gear[slotKey]         = nameOf(itemLink)
    GearVarsDB.gear[slotKey.."Link"] = itemLink

    if slotKey == "MH" and isTwoHand(itemLink) then
        GearVarsDB.gear.OH     = nil
        GearVarsDB.gear.OHLink = nil
    end

    reportApply(applyToAllMacros())
    refreshAll()
    msg(string.format("%s = %s", label, GearVarsDB.gear[slotKey]))
    return true
end

-- ===================================================================
-- Main window
-- ===================================================================
local frame = CreateFrame("Frame", "GearVarsFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(580, 340)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetClampedToScreen(true)
frame:Hide()
frame.TitleText:SetText("GearVars")

tinsert(UISpecialFrames, "GearVarsFrame")  -- ESC closes

local slots = {}

local function makeSlot(label, slotKey, yOffset)
    local btn = CreateFrame("Button", "GearVarsSlot"..slotKey, frame)
    btn:SetSize(40, 40)
    btn:SetPoint("TOPLEFT", 20, yOffset)
    btn.slotKey = slotKey
    btn.labelStr = label

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints()
    btn.icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetPoint("TOPLEFT", -4, 4)
    border:SetPoint("BOTTOMRIGHT", 4, -4)

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints()

    local labelText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    labelText:SetPoint("LEFT", btn, "RIGHT", 12, 10)
    labelText:SetText(label)

    local nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", btn, "RIGHT", 12, -6)
    nameText:SetWidth(200)
    nameText:SetJustifyH("LEFT")
    btn.nameText = nameText

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local function tryAssignFromCursor()
        local infoType, _, itemLink = GetCursorInfo()
        if infoType ~= "item" or not itemLink then return false end
        if assignToSlot(slotKey, itemLink, label) then
            ClearCursor()
            return true
        end
        return false
    end

    btn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            GearVarsDB.gear[slotKey]         = nil
            GearVarsDB.gear[slotKey.."Link"] = nil
            reportApply(applyToAllMacros())
            refreshAll()
            msg(label .. " cleared.")
            return
        end
        if CursorHasItem() then
            tryAssignFromCursor()
        else
            msg("pick up an item from your bag first, or drag it onto this slot.")
        end
    end)

    btn:SetScript("OnReceiveDrag", function(self)
        tryAssignFromCursor()
    end)

    btn:SetScript("OnEnter", function(self)
        local link = GearVarsDB.gear[slotKey.."Link"]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if link then
            GameTooltip:SetHyperlink(link)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffffd700Right-click to clear|r")
        else
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine("Drag an item here, or click while holding one.", 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Right-click to clear.", 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    slots[slotKey] = btn
    return btn
end

local function refreshSlot(slot)
    local key  = slot.slotKey
    local link = GearVarsDB.gear[key.."Link"]
    local name = GearVarsDB.gear[key]

    if link then
        slot.icon:SetTexture(GetItemIcon(link))
        slot.nameText:SetText(name or "|cff888888(loading…)|r")
    else
        slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        slot.nameText:SetText("|cff888888(empty)|r")
    end

    if key == "OH" then
        local mhLink = GearVarsDB.gear.MHLink
        if mhLink and isTwoHand(mhLink) then
            slot:Disable()
            slot.icon:SetDesaturated(true)
            slot.nameText:SetText("|cff888888(disabled — 2H main-hand)|r")
        else
            slot:Enable()
            slot.icon:SetDesaturated(false)
        end
    end
end

refreshAll = function()
    for _, s in pairs(slots) do refreshSlot(s) end
    if rebuildList then rebuildList() end
end

makeSlot("Main Hand", "MH",  -32)
makeSlot("Off Hand",  "OH",  -82)
makeSlot("Shield",    "SH", -132)

local detectBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
detectBtn:SetSize(240, 22)
detectBtn:SetPoint("BOTTOMLEFT", 20, 92)
detectBtn:SetText("Detect from Currently Equipped")
detectBtn:SetScript("OnClick", function()
    if detectFromCharacter() then
        reportApply(applyToAllMacros())
        refreshAll()
        msg("filled slots from your currently equipped items.")
    else
        msg("|cffff5555nothing detected — equip something first.|r")
    end
end)

local autoBindBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
autoBindBtn:SetSize(240, 22)
autoBindBtn:SetPoint("BOTTOMLEFT", 20, 65)
autoBindBtn:SetText("Auto-Bind Macros (Convert to Tokens)")
autoBindBtn:SetScript("OnClick", function()
    local g = GearVarsDB.gear
    if not ((g.MH and g.MH ~= "") or (g.OH and g.OH ~= "") or (g.SH and g.SH ~= "")) then
        msg("|cffff5555set at least one of MH/OH/SH first.|r")
        return
    end
    local conv, already = autoBindMacros()
    reportApply(applyToAllMacros())
    if conv + already > 0 then
        msg(string.format("bound %d macro%s (%d converted, %d already had tokens).",
            conv + already, (conv + already) == 1 and "" or "s", conv, already))
    else
        msg("no macros matched — none contained item names or tokens.")
    end
    if rebuildList then rebuildList() end
end)

local applyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
applyBtn:SetSize(240, 22)
applyBtn:SetPoint("BOTTOMLEFT", 20, 38)
applyBtn:SetText("Re-apply Macros")
applyBtn:SetScript("OnClick", function()
    local n, missing = applyToAllMacros()
    reportApply(n, missing)
    if n then msg(string.format("updated %d macro%s.", n, n == 1 and "" or "s")) end
end)

local help = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
help:SetPoint("BOTTOMLEFT", 20, 15)
help:SetText("Tokens: |cffffd700{MH}|r |cffffd700[OH]|r |cffffd700<SH>|r")

-- ===================================================================
-- Bound macros list panel (right side)
-- ===================================================================
local listPanel = CreateFrame("Frame", nil, frame)
listPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 290, -32)
listPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 14)

local listBg = listPanel:CreateTexture(nil, "BACKGROUND")
listBg:SetColorTexture(0, 0, 0, 0.3)
listBg:SetAllPoints()

local listHeader = listPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
listHeader:SetPoint("TOPLEFT", 8, -6)
listHeader:SetText("Bound Macros")

local listHint = listPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
listHint:SetPoint("BOTTOMLEFT", 8, 4)
listHint:SetText("Hover for template · Right-click to unbind")

local scroll = CreateFrame("ScrollFrame", "GearVarsListScroll", listPanel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 4, -24)
scroll:SetPoint("BOTTOMRIGHT", -26, 18)

local listContent = CreateFrame("Frame", nil, scroll)
listContent:SetSize(200, 1)
scroll:SetScrollChild(listContent)

local rowPool = {}

rebuildList = function()
    local names = {}
    for n in pairs(GearVarsDB.templates) do table.insert(names, n) end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)

    listHeader:SetText(string.format("Bound Macros (%d)", #names))

    for _, r in ipairs(rowPool) do r:Hide() end

    local y = 0
    for i, n in ipairs(names) do
        local row = rowPool[i]
        if not row then
            row = CreateFrame("Button", nil, listContent)
            row:SetHeight(18)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.text:SetPoint("LEFT", 6, 0)
            row.text:SetPoint("RIGHT", -6, 0)
            row.text:SetJustifyH("LEFT")
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetColorTexture(1, 1, 1, 0.1)
            hl:SetAllPoints()
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(self, button)
                if button == "RightButton" and self.macroName then
                    GearVarsDB.templates[self.macroName] = nil
                    msg("unbound '" .. self.macroName .. "'.")
                    rebuildList()
                end
            end)
            row:SetScript("OnEnter", function(self)
                if not self.macroName then return end
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetText(self.macroName, 1, 1, 1)
                local tmpl = GearVarsDB.templates[self.macroName]
                if tmpl then
                    GameTooltip:AddLine(" ")
                    for line in tmpl:gmatch("[^\n]+") do
                        GameTooltip:AddLine(line, 0.7, 0.75, 0.95, true)
                    end
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            rowPool[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row:Show()

        row.macroName = n
        local idx = GetMacroIndexByName(n)
        if not idx or idx == 0 then
            row.text:SetText("|cffff5555" .. n .. " (orphan)|r")
        else
            row.text:SetText(n)
        end
        y = y + 18
    end

    listContent:SetHeight(math.max(y, 1))
end

-- ===================================================================
-- Reset confirmation
-- ===================================================================
StaticPopupDialogs["GEARVARS_RESET"] = {
    text = "Reset GearVars?\n\nThis wipes stored gear and all templates.\nYour macros' current bodies are left as-is.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        GearVarsDB.gear = {}
        GearVarsDB.templates = {}
        GearVarsDB.welcomed = nil
        refreshAll()
        msg("reset complete.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ===================================================================
-- Minimap button (no external libs)
-- ===================================================================
local minimap = CreateFrame("Button", "GearVarsMinimapButton", Minimap)
minimap:SetFrameStrata("MEDIUM")
minimap:SetFrameLevel(8)
minimap:SetSize(31, 31)

local mIcon = minimap:CreateTexture(nil, "BACKGROUND")
mIcon:SetSize(20, 20)
mIcon:SetTexture("Interface\\Icons\\INV_Misc_Wrench_01")
mIcon:SetPoint("TOPLEFT", 7, -5)
mIcon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

local mBorder = minimap:CreateTexture(nil, "OVERLAY")
mBorder:SetSize(53, 53)
mBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mBorder:SetPoint("TOPLEFT")

minimap:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local function placeMinimap()
    local angle = math.rad(GearVarsDB.minimap.angle or 200)
    local r = 80
    minimap:ClearAllPoints()
    minimap:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

minimap:RegisterForDrag("LeftButton")
minimap:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        GearVarsDB.minimap.angle = math.deg(math.atan2(py - my, px - mx))
        placeMinimap()
    end)
end)
minimap:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

minimap:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimap:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        StaticPopup_Show("GEARVARS_RESET")
    else
        if frame:IsShown() then
            frame:Hide()
        else
            refreshAll()
            frame:Show()
        end
    end
end)

minimap:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("GearVars", 1, 1, 1)
    GameTooltip:AddLine("Left-click: open window",                 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: reset (with confirmation)",  0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag to move",                            0.8, 0.8, 0.8)
    GameTooltip:Show()
end)
minimap:SetScript("OnLeave", function() GameTooltip:Hide() end)

placeMinimap()
if GearVarsDB.minimap.hide then minimap:Hide() end

-- ===================================================================
-- Slash commands
-- ===================================================================
SLASH_GEARVARS1 = "/gv"
SLASH_GEARVARS2 = "/gearvars"
SlashCmdList.GEARVARS = function(input)
    input = input or ""
    local cmd, rest = input:match("^(%S*)%s*(.-)$")
    cmd  = (cmd or ""):lower()
    rest = rest or ""

    if cmd == "" or cmd == "show" then
        refreshAll(); frame:Show()

    elseif cmd == "hide" or cmd == "close" then
        frame:Hide()

    elseif cmd == "minimap" then
        GearVarsDB.minimap.hide = not GearVarsDB.minimap.hide
        if GearVarsDB.minimap.hide then minimap:Hide() else minimap:Show() end
        msg("minimap button " .. (GearVarsDB.minimap.hide and "hidden" or "shown") .. ".")

    elseif cmd == "bind" then
        if rest == "" then msg("usage: /gv bind <macroname>") return end
        local idx = GetMacroIndexByName(rest)
        if not idx or idx == 0 then
            msg("|cffff5555macro not found:|r " .. rest)
            return
        end
        local mname, iconTex, body = GetMacroInfo(idx)
        GearVarsDB.templates[mname] = body
        local tc = countTokens(body)
        if InCombatLockdown() then
            pendingApply = true
            msg(string.format("bound '%s' (%d token%s). Will expand when combat ends.",
                mname, tc, tc == 1 and "" or "s"))
        else
            EditMacro(idx, mname, iconTex, expandTemplate(body))
            msg(string.format("bound '%s' — %d token%s expanded.", mname, tc, tc == 1 and "" or "s"))
        end
        if tc == 0 then
            msg("|cffff5555warning:|r no tokens in that macro — nothing will change.")
        end
        if rebuildList then rebuildList() end

    elseif cmd == "unbind" then
        if rest == "" then msg("usage: /gv unbind <macroname>") return end
        if GearVarsDB.templates[rest] then
            GearVarsDB.templates[rest] = nil
            msg("unbound '" .. rest .. "'.")
            if rebuildList then rebuildList() end
        else
            msg("no template for '" .. rest .. "'.")
        end

    elseif cmd == "edit" then
        if rest == "" then msg("usage: /gv edit <macroname>") return end
        local idx  = GetMacroIndexByName(rest)
        local tmpl = GearVarsDB.templates[rest]
        if not idx or idx == 0 then msg("|cffff5555macro not found:|r " .. rest) return end
        if not tmpl then msg("|cffff5555no template for:|r " .. rest) return end
        if InCombatLockdown() then msg("|cffff5555can't edit macros in combat.|r") return end
        local _, iconTex = GetMacroInfo(idx)
        EditMacro(idx, rest, iconTex, tmpl)
        msg("template restored in '" .. rest .. "'. Re-run /gv bind " .. rest .. " when done.")

    elseif cmd == "list" then
        msg("bound templates:")
        local any = false
        for n, _ in pairs(GearVarsDB.templates) do
            any = true
            local idx = GetMacroIndexByName(n)
            local mark = (idx and idx > 0) and "" or " |cffff5555(orphan)|r"
            DEFAULT_CHAT_FRAME:AddMessage("   - " .. n .. mark)
        end
        if not any then DEFAULT_CHAT_FRAME:AddMessage("   (none)") end

    elseif cmd == "apply" then
        local n, missing = applyToAllMacros()
        reportApply(n, missing)
        if n then msg(string.format("updated %d macro%s.", n, n == 1 and "" or "s")) end

    elseif cmd == "detect" then
        if detectFromCharacter() then
            reportApply(applyToAllMacros())
            refreshAll()
            msg("filled slots from currently equipped items.")
        else
            msg("|cffff5555nothing detected — equip something first.|r")
        end

    elseif cmd == "autobind" then
        local g = GearVarsDB.gear
        if not ((g.MH and g.MH ~= "") or (g.OH and g.OH ~= "") or (g.SH and g.SH ~= "")) then
            msg("|cffff5555set MH/OH/SH first (try /gv detect).|r")
            return
        end
        local conv, already = autoBindMacros()
        reportApply(applyToAllMacros())
        msg(string.format("bound %d (%d converted, %d already tokenized).",
            conv + already, conv, already))
        if rebuildList then rebuildList() end

    elseif cmd == "reset" then
        StaticPopup_Show("GEARVARS_RESET")

    else
        msg("commands:")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv                 open the window")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv detect          fill MH/OH/SH from currently equipped items")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv autobind        scan all macros, replace item names with tokens")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv bind <name>     capture one macro as a template")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv edit <name>     restore template body in macro for editing")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv unbind <name>   forget a template")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv list            list bound templates")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv apply           re-write all bound macros with current gear")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv minimap         toggle minimap button")
        DEFAULT_CHAT_FRAME:AddMessage("   /gv reset           wipe gear + templates (confirmation popup)")
    end
end

-- ===================================================================
-- Events
-- ===================================================================
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        refreshAll()
        if not GearVarsDB.welcomed then
            GearVarsDB.welcomed = true
            msg("welcome! Two-click setup: |cffffd700/gv|r → Detect → Auto-Bind.")
            msg("Full command list: |cffffd700/gv help|r")
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingApply then
            pendingApply = false
            local n = applyToAllMacros()
            if n then
                msg(string.format("combat ended — updated %d queued macro%s.", n, n == 1 and "" or "s"))
            end
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        refreshAll()
    end
end)
