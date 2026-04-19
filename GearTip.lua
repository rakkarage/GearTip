-- ⚙️ GearTip: Shows average item level on unit tooltips.

local _inspectCache = {}
local _inspectQueue = {}
local _queuedGuids = {}
local _currentlyInspecting = nil
local _inspectingTime = 0
local _lastInspectTime = 0

local CACHE_TTL = 300
local SELF_CACHE_TTL = 30
local INSPECT_TIMEOUT = 5
local MAX_QUEUE_SIZE = 40

local UNIT_TOKENS = { "player", "target", "mouseover", "focus", "targettarget" }
for i = 1, 4 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "party" .. i end
for i = 1, 40 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "raid" .. i end
for i = 1, 40 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "nameplate" .. i end

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
	return itemCount > 0 and (totalItemLevel / itemCount)
end

local function GetSelfIlvl()
	local selfGuid = UnitGUID("player")
	local cached = _inspectCache[selfGuid]
	if cached and (GetTime() - cached.time) < SELF_CACHE_TTL then
		return cached.ilvl
	end
	local _, equipped = GetAverageItemLevel()
	_inspectCache[selfGuid] = { ilvl = equipped, time = GetTime() }
	return equipped
end

local function GetGradientColor(ilvl, selfIlvl)
	local diff = ilvl - selfIlvl
	local t = math.max(-1, math.min(1, diff / 15)) -- -1 = grey, 0 = white, 1 = green
	local r, g, b
	if t < 0 then
		-- grey (#999999) → white (#ffffff)
		local s = t + 1 -- 0..1
		r = 0.6 + (0.4 * s)
		g = 0.6 + (0.4 * s)
		b = 0.6 + (0.4 * s)
	else
		-- white (#ffffff) → green (#00ff00)
		r = 1 - t
		g = 1
		b = 1 - t
	end
	return r, g, b
end

local function AddIlvlLine(tooltip, ilvl, selfIlvl)
	local r, g, b = GetGradientColor(ilvl, selfIlvl)
	local hex = string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
	local icon = ilvl >= selfIlvl
		and "|TInterface\\Icons\\Inv_10_engineering_manufacturedparts_gear_firey:14|t"
		or "|TInterface\\Icons\\Inv_misc_gear_01:14|t"
	tooltip:AddLine(icon .. "|cFF" .. hex .. string.format(" %.1f", ilvl) .. "|r")
	tooltip:Show()
end

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
	if _inspectCache[guid] and (GetTime() - _inspectCache[guid].time) < CACHE_TTL then return end
	if _queuedGuids[guid] or _currentlyInspecting == guid then return end
	if #_inspectQueue >= MAX_QUEUE_SIZE then return end
	table.insert(_inspectQueue, guid)
	_queuedGuids[guid] = true
end

local function DrainQueue()
	if _currentlyInspecting and (GetTime() - _inspectingTime) > INSPECT_TIMEOUT then
		_queuedGuids[_currentlyInspecting] = nil
		_currentlyInspecting = nil
		_inspectingTime = 0
		ClearInspectPlayer()
	end

	if _currentlyInspecting then return end
	if #_inspectQueue == 0 then return end
	if (GetTime() - _lastInspectTime) < 1 then return end

	local guid, unit
	repeat
		guid = table.remove(_inspectQueue, 1)
		if not guid then return end
		_queuedGuids[guid] = nil
		unit = ResolveGuidToUnit(guid)
		if not unit or not CanInspect(unit) then
			guid = nil
			unit = nil
		end
	until guid or #_inspectQueue == 0
	if not guid then return end

	NotifyInspect(unit)
	_currentlyInspecting = guid
	_inspectingTime = GetTime()
	_lastInspectTime = GetTime()
end

local function InvalidateSelfCache()
	_inspectCache[UnitGUID("player")] = nil
end

local function EnqueueGroupMembers()
	if GetNumGroupMembers() == 0 then return end
	local raid = IsInRaid()
	local prefix = raid and "raid" or "party"
	local limit = raid and 40 or 4
	for i = 1, limit do
		local token = prefix .. i
		if UnitExists(token) then
			EnqueueInspect(token)
		end
	end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("INSPECT_READY")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:SetScript("OnEvent", function(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		EnqueueGroupMembers()
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		if UnitExists("mouseover") and UnitIsPlayer("mouseover") and not UnitIsUnit("mouseover", "player") then
			EnqueueInspect("mouseover")
		end
	elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
		InvalidateSelfCache()
	elseif event == "INSPECT_READY" then
		if not _currentlyInspecting then
			ClearInspectPlayer()
			return
		end
		local unit = ResolveGuidToUnit(_currentlyInspecting)
		local ilvl = unit and CalculateItemLevel(unit)
		if ilvl then
			_inspectCache[_currentlyInspecting] = { ilvl = ilvl, time = GetTime() }
			local mouseGuid = UnitGUID("mouseover")
			if UnitExists("mouseover") and mouseGuid and not issecretvalue(mouseGuid) and mouseGuid == _currentlyInspecting then
				AddIlvlLine(GameTooltip, ilvl, GetSelfIlvl())
			end
		end
		_currentlyInspecting = nil
		_inspectingTime = 0
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
		local cached = _inspectCache[guid]
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
