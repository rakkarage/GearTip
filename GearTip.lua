local inspectCache = {}
local inspectQueue = {}
local queuedGuids = {}
local currentlyInspecting = nil
local inspectingUnit = nil
local inspectingTime = 0
local lastInspectTime = 0
local CACHE_TTL = 300
local SELF_CACHE_TTL = 30
local INSPECT_TIMEOUT = 5

local function CalculateItemLevel(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
	local totalItemLevel, itemCount = 0, 0
	for _, slotId in ipairs({ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }) do
		local itemLink = GetInventoryItemLink(unit, slotId)
		if itemLink then
			local itemLevel = C_Item.GetDetailedItemLevelInfo(itemLink)
			if itemLevel and itemLevel > 0 then
				totalItemLevel = totalItemLevel + itemLevel
				itemCount = itemCount + 1
			end
		end
	end
	return itemCount > 0 and (totalItemLevel / itemCount) or nil
end

local function GetSelfIlvl()
	local selfGuid = UnitGUID("player")
	local cached = inspectCache[selfGuid]
	if cached and (GetTime() - cached.time) < SELF_CACHE_TTL then
		return cached.ilvl
	end
	local _, equipped = GetAverageItemLevel()
	inspectCache[selfGuid] = { ilvl = equipped, time = GetTime() }
	return equipped
end

local function AddIlvlLine(tooltip, ilvl, selfIlvl)
	local icon = ilvl >= selfIlvl
		and "|TInterface\\Icons\\Inv_10_engineering_manufacturedparts_gear_firey:14|t"
		or "|TInterface\\Icons\\Inv_misc_gear_01:14|t"
	local color = ilvl >= selfIlvl and "|cFF1eff00" or "|cFFaaaaaa"
	tooltip:AddLine(icon .. color .. string.format(" %.1f", ilvl) .. "|r")
	tooltip:Show()
end

local UNIT_TOKENS = { "player", "target", "mouseover", "focus", "targettarget" }
for i = 1, 4 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "party" .. i end
for i = 1, 40 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "raid" .. i end
for i = 1, 40 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "nameplate" .. i end

local function ResolveGuidToUnit(guid)
	for _, token in ipairs(UNIT_TOKENS) do
		if UnitExists(token) then
			local tokenGuid = UnitGUID(token)
			if tokenGuid and not issecretvalue(tokenGuid) and tokenGuid == guid then
				return token
			end
		end
	end
	return nil
end

local function EnqueueInspect(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
	if UnitIsUnit(unit, "player") then return end
	if not CanInspect(unit) then return end
	local guid = UnitGUID(unit)
	if not guid or issecretvalue(guid) then return end
	if inspectCache[guid] and (GetTime() - inspectCache[guid].time) < CACHE_TTL then return end
	if queuedGuids[guid] or currentlyInspecting == guid then return end
	-- Store only the GUID; unit token is resolved fresh at drain time
	table.insert(inspectQueue, guid)
	queuedGuids[guid] = true
end

local function DrainQueue()
	if currentlyInspecting and (GetTime() - inspectingTime) > INSPECT_TIMEOUT then
		queuedGuids[currentlyInspecting] = nil
		currentlyInspecting = nil
		inspectingUnit = nil
		inspectingTime = 0
		ClearInspectPlayer()
	end

	if currentlyInspecting then return end
	if #inspectQueue == 0 then return end
	if (GetTime() - lastInspectTime) < 1 then return end

	local guid, unit
	repeat
		guid = table.remove(inspectQueue, 1)
		if not guid then return end
		queuedGuids[guid] = nil
		-- Resolve the GUID to a current live unit token
		unit = ResolveGuidToUnit(guid)
		if not unit or not CanInspect(unit) then
			guid = nil
			unit = nil
		end
	until guid or #inspectQueue == 0
	if not guid then return end

	NotifyInspect(unit)
	currentlyInspecting = guid
	inspectingUnit = unit
	inspectingTime = GetTime()
	lastInspectTime = GetTime()
end

local function InvalidateSelfCache()
	local selfGuid = UnitGUID("player")
	inspectCache[selfGuid] = nil
end

local function EnqueueGroupMembers()
	local groupSize = GetNumGroupMembers()
	if groupSize == 0 then return end
	local prefix = IsInRaid() and "raid" or "party"
	local limit = IsInRaid() and 40 or 4
	for i = 1, limit do
		local token = prefix .. i
		if UnitExists(token) then
			EnqueueInspect(token)
		end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:SetScript("OnEvent", function(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		EnqueueGroupMembers()
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		if UnitExists("mouseover") and UnitIsPlayer("mouseover") and not UnitIsUnit("mouseover", "player") then
			EnqueueInspect("mouseover")
		end
	elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
		InvalidateSelfCache()
	elseif event == "INSPECT_READY" then
		if not currentlyInspecting then
			ClearInspectPlayer()
			return
		end
		-- Re-resolve unit token in case it shifted since NotifyInspect
		local unit = ResolveGuidToUnit(currentlyInspecting)
		local ilvl = unit and CalculateItemLevel(unit) or nil
		if ilvl then
			inspectCache[currentlyInspecting] = { ilvl = ilvl, time = GetTime() }
			-- Only annotate tooltip if mouseover is still this person
			local mouseGuid = UnitGUID("mouseover")
			if UnitExists("mouseover") and mouseGuid and not issecretvalue(mouseGuid) and mouseGuid == currentlyInspecting then
				AddIlvlLine(GameTooltip, ilvl, GetSelfIlvl())
			end
		end
		currentlyInspecting = nil
		inspectingUnit = nil
		inspectingTime = 0
		ClearInspectPlayer()
	end
end)

C_Timer.NewTicker(0.1, DrainQueue)

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
	if tooltip ~= GameTooltip or not data then return end
	local unit = data.unitToken
	if not unit and UnitExists("mouseover") then unit = "mouseover" end
	if not unit or not UnitIsPlayer(unit) then return end

	local ilvl
	if UnitIsUnit(unit, "player") then
		ilvl = GetSelfIlvl()
	else
		local guid = UnitGUID(unit)
		if not guid or issecretvalue(guid) then return end
		local cached = inspectCache[guid]
		if cached and (GetTime() - cached.time) < CACHE_TTL then
			ilvl = cached.ilvl
		else
			EnqueueInspect(unit)
		end
	end

	if ilvl then
		AddIlvlLine(tooltip, ilvl, GetSelfIlvl())
	end
end)
