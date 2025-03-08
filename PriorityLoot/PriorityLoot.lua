-- PriorityLoot.lua
-- A loot priority system for WoW Classic (Season of Discovery)
-- Core functionality

-- Addon metadata
local addonName, PL = ...
PL.version = "1.0.0"
PL.interfaceVersion = 11506 -- Classic SoD

-- Pull in AceComm
LibStub("AceComm-3.0"):Embed(PL)


-- Initialize variables
PL.isHost = false
PL.sessionActive = false
PL.currentLootItem = nil
PL.participants = {}
PL.playerName = UnitName("player")
PL.playerFullName = nil -- Will store name-server format
PL.sessionHost = nil
PL.initialized = false
PL.timerDuration = 10 -- Default timer duration now 10 seconds
PL.timerLagCompensation = 0.1 -- 100ms lag compensation for initial timer sync
PL.timerActive = false
PL.timerEndTime = 0
PL.timerFrame = nil
PL.playerPriority = nil -- Track current player's selected priority
PL.commPrefixPlayerConst = "PLPlayer"
PL.commPrefixChannels = 20
PL.commPlayerChannel = nil

-- Player ID system
PL.playerIDMap = {} -- Maps player names to IDs
PL.idToPlayerMap = {} -- Maps IDs to player names
PL.playerID = nil -- Current player's ID
PL.nextAvailableID = 1 -- Start IDs from 1 (0-99 possible)

-- Item tracking variables
PL.currentLootItemLink = nil
PL.currentLootItemTexture = nil

-- Communication
PL.COMM_PREFIX_HOST = "PLHost"
PL.COMM_START = "START"
PL.COMM_STOP = "STOP"
PL.COMM_ITEM = "ITEM"   -- For sharing item data
PL.COMM_CLEAR = "CLEAR" -- For clearing item data
PL.COMM_TIMER = "TIMER" -- For timer sync

PL.COMM_PREFIX_PLAYER = nil
PL.COMM_JOIN = "JOIN"
PL.COMM_LEAVE = "LEAVE" -- For removing player from roll
PL.COMM_ID_ASSIGN = "IDA" -- For assigning player IDs
PL.COMM_ID_REQUEST = "IDR" -- For requesting an ID

-- Class colors table
PL.CLASS_COLORS = {
    ["WARRIOR"] = "C79C6E",
    ["PALADIN"] = "F58CBA",
    ["HUNTER"] = "ABD473",
    ["ROGUE"] = "FFF569",
    ["PRIEST"] = "FFFFFF",
    ["SHAMAN"] = "0070DE",
    ["MAGE"] = "69CCF0",
    ["WARLOCK"] = "9482C9",
    ["DRUID"] = "FF7D0A"
}

-- Get player's full name with server
function PL:GetPlayerFullName()
    local name, realm = UnitFullName("player")
    if realm and realm ~= "" then
        return name .. "-" .. realm
    else
        return name
    end
end

-- Get the appropriate distribution channel based on current group
function PL:GetDistributionChannel()
    return IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
end

-- Normalize a name to handle server names
function PL:NormalizeName(name)
    if not name then return nil end
    
    -- If the name contains a dash (indicating server name)
    if name:find("-") then
        return name
    else
        -- No server in the name, use the player's server if available
        local _, playerRealm = UnitFullName("player")
        if playerRealm and playerRealm ~= "" then
            return name .. "-" .. playerRealm
        else
            return name
        end
    end
end

-- Check if player is master looter
function PL:IsMasterLooter()
    if not IsInRaid() then return false end
    
    local lootMethod, masterLooterPartyID, masterlooterRaidID = GetLootMethod()
    if lootMethod ~= "master" then return false end
    
    if masterLooterPartyID == 0 then
        -- Player is master looter
        return true
    else
        -- Get master looter name
        local masterLooterName = UnitName("raid" .. masterlooterRaidID)
        local playerName = UnitName("player")
        return masterLooterName == playerName
    end
end

-- Get display name (without server)
function PL:GetDisplayName(fullName)
    if not fullName then return "" end
    
    local name = fullName
    local dashPos = fullName:find("-")
    if dashPos then
        name = fullName:sub(1, dashPos - 1)
    end
    return name
end

-- Format time as MM:SS
function PL:FormatTime(timeInSeconds)
    local minutes = math.floor(timeInSeconds / 60)
    local seconds = timeInSeconds % 60
    return string.format("%d:%02d", minutes, seconds)
end

-- Broadcast timer information to all raid members
function PL:BroadcastTimerInfo(remainingTime)
    if not self.isHost then return end
    
    PL:SendCommMessage(self.COMM_PREFIX_HOST, self.COMM_TIMER .. ":" .. remainingTime, self:GetDistributionChannel())
end

-- Get class color for a player
function PL:GetClassColor(name)
    -- Default to white if we can't get the class or if player not found
    local defaultColor = "FFFFFF"
    
    -- Extract name without server for comparison
    local displayName = self:GetDisplayName(name)
    
    -- Get color for yourself
    if displayName == self.playerName then
        local _, playerClass = UnitClass("player")
        return self.CLASS_COLORS[playerClass] or defaultColor
    end
    
    -- Try to get color for raid/party members
    local numGroupMembers = IsInRaid() and GetNumGroupMembers() or GetNumGroupMembers()
    
    if IsInRaid() then
        for i = 1, numGroupMembers do
            local raidName, _, _, _, _, raidClass = GetRaidRosterInfo(i)
            -- Extract name without server for comparison
            raidName = self:GetDisplayName(raidName)
            if raidName == displayName then
                return self.CLASS_COLORS[raidClass] or defaultColor
            end
        end
    else
        -- Check party members
        for i = 1, numGroupMembers - 1 do
            local unit = "party" .. i
            local partyName = UnitName(unit)
            if partyName == displayName then
                local _, partyClass = UnitClass(unit)
                return self.CLASS_COLORS[partyClass] or defaultColor
            end
        end
    end
    
    return defaultColor
end

-- Assign a unique ID to a player (host only)
function PL:AssignPlayerID(playerName)
    if not self.isHost then return nil end
    
    -- Normalize player name for consistent keys
    local normalizedName = self:NormalizeName(playerName)
    
    -- Return existing ID if already assigned
    if self.playerIDMap[normalizedName] then
        return self.playerIDMap[normalizedName]
    end
    
    -- Assign new ID (using modulo to keep it within 0-99)
    local newID = self.nextAvailableID % 100
    self.nextAvailableID = self.nextAvailableID + 1
    
    -- Store mappings
    self.playerIDMap[normalizedName] = newID
    self.idToPlayerMap[newID] = normalizedName
    
    -- Broadcast ID assignment to all players
    PL:SendCommMessage(self.COMM_PREFIX_PLAYER, self.COMM_ID_ASSIGN .. ":" .. normalizedName .. "," .. newID, self:GetDistributionChannel())
    
    return newID
end

-- Request an ID from the host
function PL:RequestPlayerID()
    if self.isHost then
        -- If we're the host, just assign ourselves an ID
        self.playerID = self:AssignPlayerID(self.playerFullName)
    else
        -- Request ID from host
        PL:SendCommMessage(self.COMM_PREFIX_PLAYER, self.COMM_ID_REQUEST .. ":" .. self.playerFullName, self:GetDistributionChannel())
    end
end

-- Get player ID (requesting one if needed)
function PL:GetPlayerID(playerName)
    local normalizedName = self:NormalizeName(playerName or self.playerFullName)
    
    -- Try to get existing ID
    local id = self.playerIDMap[normalizedName]
    
    -- If no ID and we're the host, assign one
    if not id and self.isHost then
        id = self:AssignPlayerID(normalizedName)
    end
    
    return id
end

-- Get player name from ID
function PL:GetPlayerNameFromID(id)
    return self.idToPlayerMap[id]
end

-- Update player's priority in the participants list
function PL:UpdatePlayerPriority(newPriority)
    local oldPriority = self.playerPriority
    
    if oldPriority ~= newPriority then
        -- Store player's priority locally
        self.playerPriority = newPriority
        
        -- Ensure player has an ID
        if not self.playerID then
            self:RequestPlayerID()
        end
        
        -- Find and update player in participants list
        local playerEntry = nil
        for i, data in ipairs(self.participants) do
            if self:NormalizeName(data.name) == self:NormalizeName(self.playerFullName) then
                playerEntry = data
                playerEntry.priority = newPriority
                playerEntry.id = self.playerID
                break
            end
        end
        
        -- If not found, add player to list
        if not playerEntry then
            table.insert(self.participants, {
                name = self.playerFullName, 
                priority = newPriority,
                id = self.playerID
            })
        end
        
        -- Broadcast join message with updated priority and ID
        if self.playerID then
            PL:SendCommMessage(self.COMM_PREFIX_PLAYER, self.COMM_JOIN .. ":" .. self.playerFullName .. "," .. newPriority .. "," .. self.playerID, self:GetDistributionChannel())
        else
            -- No ID yet, broadcast without ID (it will be updated once ID is assigned)
            PL:SendCommMessage(self.COMM_PREFIX_PLAYER, self.COMM_JOIN .. ":" .. self.playerFullName .. "," .. newPriority, self:GetDistributionChannel())
        end
    end
    
    -- Update UI
    self:UpdateUI()
end

-- Clear player from the current roll
function PL:ClearPlayerRoll()
    if not self.sessionActive then return end
    
    -- Check if player has already joined
    if not self:HasPlayerJoined(self.playerFullName) then
        print("|cffff9900You have not yet joined this roll.|r")
        return
    end
    
    -- Remove player from participants list
    for i, data in ipairs(self.participants) do
        if self:NormalizeName(data.name) == self:NormalizeName(self.playerFullName) then
            table.remove(self.participants, i)
            break
        end
    end
    
    -- Reset player's priority
    self.playerPriority = nil
    
    -- Broadcast removal to all raid members (using ID if available)
    if self.playerID then
        PL:SendCommMessage(self.COMM_PREFIX_PLAYER, self.COMM_LEAVE .. ":" .. self.playerID, self:GetDistributionChannel())
    else
        PL:SendCommMessage(self.COMM_PREFIX_PLAYER, self.COMM_LEAVE .. ":" .. self.playerFullName, self:GetDistributionChannel())
    end
    
    print("|cffff9900You have removed yourself from the roll.|r")
    
    -- Update UI
    self:UpdateUI()
end

-- Start timer for automatic roll stop
function PL:StartTimer(duration)
    if self.timerActive then
        self:StopTimer()
    end
    
    self.timerActive = true
    self.timerEndTime = GetTime() + duration
    
    -- Create or show timer frame
    if not self.timerFrame then
        self.timerFrame = CreateFrame("Frame")
    end
    
    self.timerFrame:SetScript("OnUpdate", function(frame, elapsed)
        if not self.timerActive then return end
        
        local remainingTime = self.timerEndTime - GetTime()
        if remainingTime <= 0 then
            -- Time's up - stop the roll
            self:StopTimer()
            if self.isHost then
                self:StopRollSession()
            end
            return
        end
        
        -- Update timer display every 0.1 seconds to avoid excessive updates
        if not frame.lastUpdate or (GetTime() - frame.lastUpdate) >= 0.1 then
            frame.lastUpdate = GetTime()
            self:UpdateTimerDisplay(remainingTime)
        end
    end)
    
    -- Initial update
    self:UpdateTimerDisplay(duration)
    
    -- Initial broadcast
    if self.isHost then
        self:BroadcastTimerInfo(duration - self.timerLagCompensation)
    end
end

-- Stop the active timer
function PL:StopTimer()
    if not self.timerActive then return end

    self.timerActive = false

    if self.timerFrame then
        self.timerFrame:SetScript("OnUpdate", nil)
    end
    
    -- Clear the timer display
    if self.timerDisplay then
        self.timerDisplay:SetText("")
    end
    
    -- Force UI update to ensure consistent state
    self:UpdateUI(true)
end

-- Set current item for loot roll
function PL:SetCurrentItem(itemLink)
    if not itemLink then return end
    
    -- Store the item link
    self.currentLootItemLink = itemLink
    
    -- Extract the item texture (for display purposes)
    local _, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemLink)
    self.currentLootItemTexture = itemTexture
    
    -- Broadcast item to other players if you're the host
    if self:IsMasterLooter() then        
        -- Use a specific message format that won't break item links
        PL:SendCommMessage(self.COMM_PREFIX_HOST, self.COMM_ITEM .. ":" .. itemLink, self:GetDistributionChannel())
    end
    
    -- Update UI
    self:UpdateUI()
end

-- Clear the current item and broadcast to all players if host
function PL:ClearCurrentItem()
    -- Only broadcast if we're the host and there's an item to clear
    if self:IsMasterLooter() and self.currentLootItemLink then
        -- Broadcast clear item command
        PL:SendCommMessage(self.COMM_PREFIX_HOST, self.COMM_CLEAR, self:GetDistributionChannel())
        print("|cffff9900Item cleared.|r")
    end
    
    -- Clear local item data
    self.currentLootItemLink = nil
    self.currentLootItemTexture = nil
    
    -- Update UI
    self:UpdateUI()
end

-- Start a roll session
function PL:StartRollSession()
    -- Check if in raid
    if not IsInRaid() then
        print("|cffff0000You must be in a raid to start a roll session.|r")
        return
    end
    
    -- Check if master looter
    if not self:IsMasterLooter() then
        print("|cffff0000Only the master looter can start a roll session.|r")
        return
    end
    
    -- Set host status - critical for the Stop button to work
    self.isHost = true
    self.sessionActive = true
    self.sessionHost = self.playerFullName
    self.participants = {}
    self.playerPriority = nil -- Reset player's priority
    
    -- Reset ID system for new session
    self.playerIDMap = {}
    self.idToPlayerMap = {}
    self.nextAvailableID = 1
    
    -- Assign ourselves an ID as host
    self.playerID = self:AssignPlayerID(self.playerFullName)
    
    -- Update UI immediately to reflect state change
    self:UpdateUI(true)

    -- Broadcast start message - send item link in a separate message to ensure it's intact
    PL:SendCommMessage(self.COMM_PREFIX_HOST, self.COMM_START, self:GetDistributionChannel())
    
    -- Send item link as a separate message if available
    if self.currentLootItemLink then
        -- Share item again just to be sure
        PL:SendCommMessage(self.COMM_PREFIX_HOST, self.COMM_ITEM .. ":" .. self.currentLootItemLink, self:GetDistributionChannel())
        
        -- Show raid warning with item
        local message = "Roll started for " .. self.currentLootItemLink
        if IsInRaid() then
            SendChatMessage(message, "RAID_WARNING")
        else
            SendChatMessage(message, "PARTY")
        end
    else
        local message = "Roll started"
        if IsInRaid() then
            SendChatMessage(message, "RAID_WARNING")
        else
            SendChatMessage(message, "PARTY")
        end
    end
    
    print("|cff00ff00You started a roll session.|r")
    
    -- Start timer if enabled
    if self.timerCheckbox and self.timerCheckbox:GetChecked() then
        -- Get duration from edit box
        local inputDuration = tonumber(self.timerEditBox:GetText()) or self.timerDuration
        
        -- Ensure it's within reasonable bounds
        if inputDuration < 5 then inputDuration = 5 end
        if inputDuration > 60 then inputDuration = 60 end
        
        self.timerDuration = inputDuration
        self:StartTimer(inputDuration)
        print("|cff00ff00Auto-stop timer set for " .. inputDuration .. " seconds.|r")
    end
    
    -- Final UI update
    self:UpdateUI(true)
end

-- Stop the current roll session
function PL:StopRollSession()
    if not self.isHost or not self.sessionActive then
        print("|cffff0000You're not the host or no session is active.|r")
        return
    end
    
    -- Update the state variables
    self.sessionActive = false
    
    -- Stop the timer if active
    if self.timerActive then
        self:StopTimer()
    end
    
    -- Update UI immediately to reflect state change
    self:UpdateUI(true)
    
    -- Broadcast stop message with participant IDs and priorities (compact format)
    local message = self.COMM_STOP
    for i, data in ipairs(self.participants) do
        if data.id then -- Only include participants with valid IDs
            message = message .. ":" .. data.id .. "," .. data.priority
        end
    end
    
    PL:SendCommMessage(self.COMM_PREFIX_HOST, message, self:GetDistributionChannel())
    
    print("|cffff9900Roll session ended. Results are displayed.|r")
    
    -- Sort participants by priority (lower is better)
    table.sort(self.participants, function(a, b)
        return a.priority < b.priority
    end)
    
    -- Display raid warning with results
    if #self.participants > 0 then
        local resultMessage = ""
        if self.currentLootItemLink then
            resultMessage = "Roll results for " .. self.currentLootItemLink .. ": "
        else
            resultMessage = "Roll results: "
        end
        
        -- Find all players with the same highest priority
        local highestPriority = self.participants[1].priority
        local winners = {}
        
        for i, data in ipairs(self.participants) do
            if data.priority == highestPriority then
                table.insert(winners, self:GetDisplayName(data.name) .. " (" .. data.priority .. ")")
            else
                -- Stop once we reach a different priority
                break
            end
        end
        
        -- Add all winners to the message
        resultMessage = resultMessage .. table.concat(winners, ", ")
        
        -- Use consistent channel for announcements
        local chatChannel = IsInRaid() and "RAID_WARNING" or "PARTY"
        SendChatMessage(resultMessage, chatChannel)
    end

    -- Final UI update
    self:UpdateUI(true)
end

-- Join a roll with selected priority
function PL:JoinRoll(priority)
    if not self.sessionActive then return end
    
    -- Ensure we have an ID or request one
    if not self.playerID then
        self:RequestPlayerID()
    end
    
    -- Update player's priority (whether joining fresh or changing)
    self:UpdatePlayerPriority(priority)
    
    -- Highlight the selected button
    for i = 1, 19 do
        if i == priority then
            self.priorityButtons[i]:SetNormalFontObject("GameFontHighlight")
            self.priorityButtons[i]:LockHighlight()
        else
            self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
            self.priorityButtons[i]:UnlockHighlight()
        end
    end
    
    -- Print message based on whether this is a change or initial join
    if self:HasPlayerJoined(self.playerFullName) then
        print("|cff00ff00You changed your priority to " .. priority .. ".|r")
    else
        print("|cff00ff00You joined the roll with priority " .. priority .. ".|r")
    end
end

-- Check if player has already joined
function PL:HasPlayerJoined(name)
    for _, data in ipairs(self.participants) do
        -- Normalize both names to ensure consistent comparison
        if self:NormalizeName(data.name) == self:NormalizeName(name) then
            return true
        end
    end
    return false
end

-- Handle addon communication
function PL:OnCommReceived(prefix, message, distribution, sender)
    if not string.match(prefix, "PL.*") then return end

    -- Normalize the sender name for consistent comparison
    local normalizedSender = self:NormalizeName(sender)
    local normalizedPlayer = self:NormalizeName(self.playerFullName)
    
    if normalizedPlayer ~= normalizedSender then
        if message:find(self.COMM_START) == 1 then
            -- Someone started a roll session
            self.sessionActive = true

            -- Show the window for all players when a session starts
            self.PriorityLootFrame:Show()

            self.isHost = false
            self.sessionHost = sender
            self.participants = {}
            self.playerPriority = nil -- Reset player's priority
            
            -- Reset ID maps for new session
            self.playerIDMap = {}
            self.idToPlayerMap = {}
            self.playerID = nil
            
            -- Request an ID from the host
            self:RequestPlayerID()
            
            -- Don't try to parse item from START message
            -- Item will come in a separate ITEM message
            print("|cff00ff00" .. self:GetDisplayName(sender) .. " started a roll session.|r")
            
            self:UpdateUI()

        elseif message:find(self.COMM_ITEM) == 1 then
            -- Show the window for all players when an item is selected
            self.PriorityLootFrame:Show()

            -- Item info from host
            -- Extract the item link portion after the COMM_ITEM: prefix
            local itemLink = message:sub(#(self.COMM_ITEM .. ":") + 1)
            
            if itemLink and itemLink ~= "" then
                self:SetCurrentItem(itemLink)
                
                print("|cff00ff00" .. self:GetDisplayName(sender) .. " shared item: " .. itemLink .. ".|r")
            end
        
        elseif message == self.COMM_CLEAR then
            -- Host has cleared the item, clear it for everyone
            print("|cffff9900Item cleared by " .. self:GetDisplayName(sender) .. ".|r")
            
            -- Clear local item data but don't re-broadcast
            self.currentLootItemLink = nil
            self.currentLootItemTexture = nil
            
            -- Update UI
            self:UpdateUI()
            
        elseif message:find(self.COMM_JOIN) == 1 then
            -- Someone joined the roll or changed their priority
            local parts = {strsplit(":", message)}
            if parts[2] then
                local joinData = {strsplit(",", parts[2])}
                if joinData[1] and joinData[2] then
                    local name = joinData[1]
                    local priority = tonumber(joinData[2])
                    local id = tonumber(joinData[3]) -- ID might be present
                    
                    -- If ID is present, update our mapping
                    if id then
                        self.playerIDMap[self:NormalizeName(name)] = id
                        self.idToPlayerMap[id] = self:NormalizeName(name)
                    end
                    
                    -- Check if this is the current player
                    if self:NormalizeName(name) == normalizedPlayer then
                        self.playerPriority = priority
                        if id then self.playerID = id end
                    end
                    
                    -- Add or update participant in the list
                    local existingEntry = nil
                    for i, data in ipairs(self.participants) do
                        if self:NormalizeName(data.name) == self:NormalizeName(name) then
                            data.priority = priority
                            if id then data.id = id end
                            existingEntry = data
                            break
                        end
                    end
                    
                    if not existingEntry then
                        -- New participant
                        table.insert(self.participants, {
                            name = name, 
                            priority = priority,
                            id = id
                        })
                        print("|cff00ff00" .. self:GetDisplayName(name) .. " joined the roll.|r")
                    else
                        -- Existing participant changed priority
                        print("|cff00ff00" .. self:GetDisplayName(name) .. " changed priority.|r")
                    end
                    
                    self:UpdateUI()
                end
            end
            
        elseif message:find(self.COMM_LEAVE) == 1 then
            -- Someone left the roll
            local parts = {strsplit(":", message)}
            if parts[2] then
                local leavingData = parts[2]
                local id = tonumber(leavingData)
                
                if id then
                    -- Handle leaving by ID
                    local leavingPlayer = self:GetPlayerNameFromID(id)
                    if leavingPlayer then
                        -- Remove player from participants list by ID
                        for i, data in ipairs(self.participants) do
                            if data.id == id then
                                table.remove(self.participants, i)
                                print("|cffff9900" .. self:GetDisplayName(leavingPlayer) .. " left the roll.|r")
                                break
                            end
                        end
                    end
                else
                    -- Handle leaving by name (legacy support)
                    local leavingPlayer = leavingData
                    -- Remove player from participants list
                    for i, data in ipairs(self.participants) do
                        if self:NormalizeName(data.name) == self:NormalizeName(leavingPlayer) then
                            table.remove(self.participants, i)
                            print("|cffff9900" .. self:GetDisplayName(leavingPlayer) .. " left the roll.|r")
                            break
                        end
                    end
                end
                
                self:UpdateUI()
            end
            
        elseif message:find(self.COMM_TIMER) == 1 then
            -- Timer sync from host
            local parts = {strsplit(":", message)}
            if parts[2] and not self.isHost then
                local remainingTime = tonumber(parts[2])
                if remainingTime and remainingTime > 0 then
                    -- Start Timer
                    self:StartTimer(remainingTime)
                end
            end
            
        elseif message:find(self.COMM_ID_ASSIGN) == 1 then
            -- ID assignment from host
            local parts = {strsplit(":", message)}
            if parts[2] then
                local idData = {strsplit(",", parts[2])}
                if idData[1] and idData[2] then
                    local playerName = idData[1]
                    local id = tonumber(idData[2])
                    
                    -- Store mapping
                    self.playerIDMap[self:NormalizeName(playerName)] = id
                    self.idToPlayerMap[id] = self:NormalizeName(playerName)
                    
                    -- If this is for current player, store ID
                    if self:NormalizeName(playerName) == normalizedPlayer then
                        self.playerID = id
                        
                        -- If we've already set a priority, re-broadcast with our ID
                        if self.playerPriority then
                            self:UpdatePlayerPriority(self.playerPriority)
                        end
                    end
                    
                    -- Update any existing participant entries
                    for i, data in ipairs(self.participants) do
                        if self:NormalizeName(data.name) == self:NormalizeName(playerName) then
                            data.id = id
                            break
                        end
                    end
                    
                    self:UpdateUI()
                end
            end
            
        elseif message:find(self.COMM_ID_REQUEST) == 1 then
            -- ID request from a player
            if not self.isHost then return end
            
            local parts = {strsplit(":", message)}
            if parts[2] then
                local requestingPlayer = parts[2]
                
                -- Assign an ID to the requesting player
                self:AssignPlayerID(requestingPlayer)
            end
            
        elseif message:find(self.COMM_STOP) == 1 then
            -- Session ended with results
            self.sessionActive = false

            -- Stop the timer if active
            if self.timerActive then
                self:StopTimer()
            end
            
            -- Parse participant list with IDs and priorities
            -- Keep existing participant list but update priorities based on IDs
            local rollResults = {}
            local parts = {strsplit(":", message)}
            for i = 2, #parts do
                local idPriority = {strsplit(",", parts[i])}
                if idPriority[1] and idPriority[2] then
                    local id = tonumber(idPriority[1])
                    local priority = tonumber(idPriority[2])
                    
                    -- Look up player name by ID
                    local playerName = self:GetPlayerNameFromID(id)
                    
                    if playerName then
                        rollResults[id] = {
                            name = playerName,
                            priority = priority,
                            id = id
                        }
                    end
                end
            end
            
            -- Update participant list with new results
            for i, data in ipairs(self.participants) do
                if data.id and rollResults[data.id] then
                    data.priority = rollResults[data.id].priority
                end
            end
            
            -- Sort participants by priority (lower is better)
            table.sort(self.participants, function(a, b)
                return a.priority < b.priority
            end)
            
            print("|cffff9900Roll session ended by " .. self:GetDisplayName(sender) .. ". Results are displayed.|r")
            
            -- Important: We no longer clear the item on roll end
            -- The item remains displayed until cleared manually or a new roll starts
            
            self:UpdateUI()
        end
    end
end

-- Define slash command handler
function PL:SlashCommandHandler(msg)
    if not self.initialized then
        print("|cffff0000PriorityLoot is still initializing. Please try again in a moment.|r")
        return
    end
    
    -- Only allow opening if in a raid
    if not IsInRaid() then
        print("|cffff0000PriorityLoot can only be used while in a raid.|r")
        return
    end
    
    if self.PriorityLootFrame:IsVisible() then
        self.PriorityLootFrame:Hide()
    else
        self.PriorityLootFrame:Show()
    end
end

-- Initialize the addon
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" and ... == addonName then
        -- Register comm prefix
        PL:RegisterComm(PL.COMM_PREFIX_HOST, function(prefix, message, distribution, sender)
        PL:OnCommReceived(prefix, message, distribution, sender)
        end)

        -- register channels for all members
        for i = 1, PL.commPrefixChannels do
		    PL:RegisterComm(PL.commPrefixPlayerConst .. tostring(i), function(prefix, message, distribution, sender)
                PL:OnCommReceived(prefix, message, distribution, sender)
            end)
            if i == PL.commPrefixChannels then
                break
            end
        end

        if IsInRaid() then
            PL.commPlayerChannel = mod(UnitInRaid("player"),PL.commPrefixChannels)
            PL.COMM_PREFIX_PLAYER = PL.commPrefixPlayerConst .. tostring(PL.commPlayerChannel)
        end

        -- Get player's full name (with server)
        PL.playerFullName = PL:GetPlayerFullName()
        
        -- Load UI module
        PL:InitUI()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Get player's full name (with server) when entering world
        PL.playerFullName = PL:GetPlayerFullName()
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PARTY_LOOT_METHOD_CHANGED" then
        if PL.initialized then
            PL.commPlayerChannel = mod(UnitInRaid("player"),PL.commPrefixChannels)
            PL.COMM_PREFIX_PLAYER = PL.commPrefixPlayerConst .. tostring(PL.commPlayerChannel)
            PL:UpdateUI()
        end
    end
end

-- Register slash commands
SLASH_PRIORITYLOOT1 = "/priorityloot"
SLASH_PRIORITYLOOT2 = "/pl"
SlashCmdList["PRIORITYLOOT"] = function(msg) PL:SlashCommandHandler(msg) end

-- Create and register events frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
eventFrame:SetScript("OnEvent", OnEvent)