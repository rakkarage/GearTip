local inspectCache = {}
local pendingInspects = {}

local function CalculateItemLevel(unit)
    local totalItemLevel = 0
    local itemCount = 0

    local slots = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }

    for _, slotId in ipairs(slots) do
        local itemLink = GetInventoryItemLink(unit, slotId)
        if itemLink then
            local itemLevel = C_Item.GetDetailedItemLevelInfo(itemLink)
            if itemLevel and itemLevel > 0 then
                totalItemLevel = totalItemLevel + itemLevel
                itemCount = itemCount + 1
            end
        end
    end

    if itemCount > 0 then
        return totalItemLevel / itemCount
    end
    return nil
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("INSPECT_READY")
frame:SetScript("OnEvent", function(self, event, guid)
    if event == "INSPECT_READY" then
        local unit = pendingInspects[guid]
        if unit then
            local ilvl = CalculateItemLevel(unit)
            if ilvl then
                inspectCache[guid] = {
                    ilvl = ilvl,
                    time = GetTime()
                }
            end
            pendingInspects[guid] = nil
            ClearInspectPlayer()
        end
    end
end)

local function RequestItemLevel(unit)
    if not unit or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then
        return nil
    end

    local guid = UnitGUID(unit)
    if not guid then
        return nil
    end

    local cached = inspectCache[guid]
    if cached and (GetTime() - cached.time) < 300 then
        return cached.ilvl
    end

    if not CheckInteractDistance(unit, 1) then
        return nil
    end

    if pendingInspects[guid] then
        return nil
    end

    if CanInspect(unit) then
        NotifyInspect(unit)
        pendingInspects[guid] = unit
    end

    return nil
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
    if not tooltip or tooltip ~= GameTooltip then
        return
    end

    local _, unit = tooltip:GetUnit()

    if not unit then
        return
    end

    if not UnitIsPlayer(unit) then
        return
    end

    local ilvl

    if UnitIsUnit(unit, "player") then
        local _, equipped = GetAverageItemLevel()
        ilvl = equipped
    else
        ilvl = RequestItemLevel(unit)
    end

    if ilvl then
        local ilvlText = string.format("Item Level: %.1f", ilvl)
        tooltip:AddLine(ilvlText, 1, 1, 0.5)
        tooltip:Show()
    end
end)
