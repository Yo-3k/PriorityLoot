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
PL.collectingResults = false -- Flag for when we're collecting results
PL.prioritiesReceived = {} -- Track which players have submitted priorities

-- Item tracking variables
PL.currentLootItemLink = nil
PL.currentLootItemTexture = nil

-- Communication
PL.COMM_PREFIX = "PriorityLoot"
PL.COMM_JOIN = "JOIN"
PL.COMM_START = "START"
PL.COMM_STOP = "STOP"
PL.COMM_TIMER = "TIMER" -- For timer sync
PL.COMM_LEAVE = "LEAVE" -- For removing player from roll
PL.COMM_ITEM = "ITEM"   -- For sharing item data
PL.COMM_CLEAR = "CLEAR" -- For clearing item data
PL.COMM_PRIORITY = "PRIO" -- For sending priority at the end of the roll

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
    
    PL:SendCommMessage(self.COMM_PREFIX, self.COMM_TIMER .. ":" .. remainingTime, self:GetDistributionChannel())
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

-- Broadcast player's priority only at the end of roll
function PL:BroadcastFinalPriority()
    if not self.playerPriority then return end
    
    PL:SendCommMessage(self.COMM_PREFIX, self.COMM_PRIORITY .. ":" .. self.playerFullName .. "," .. self.playerPriority, self:GetDistributionChannel())
end

-- Add player to participants list without priority value
function PL:JoinRollWithoutPriority()
    -- Only send join status, not priority
    PL:SendCommMessage(self.COMM_PREFIX, self.COMM_JOIN .. ":" .. self.playerFullName, self:GetDistributionChannel())
    
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
    
    -- Broadcast removal to all raid members
    PL:SendCommMessage(self.COMM_PREFIX, self.COMM_LEAVE .. ":" .. self.playerFullName, self:GetDistributionChannel())
    
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
        PL:SendCommMessage(self.COMM_PREFIX, self.COMM_ITEM .. ":" .. itemLink, self:GetDistributionChannel())
    end
    
    -- Update UI
    self:UpdateUI()
end

-- Clear the current item and broadcast to all players if host
function PL:ClearCurrentItem()
    -- Only broadcast if we're the host and there's an item to clear
    if self:IsMasterLooter() and self.currentLootItemLink then
        -- Broadcast clear item command
        PL:SendCommMessage(self.COMM_PREFIX, self.COMM_CLEAR, self:GetDistributionChannel())
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
    self.prioritiesReceived = {} -- Reset priority tracking
    
    -- Update UI immediately to reflect state change
    self:UpdateUI(true)
    
    -- Broadcast start message - send item link in a separate message to ensure it's intact
    PL:SendCommMessage(self.COMM_PREFIX, self.COMM_START, self:GetDistributionChannel())
    
    -- Send item link as a separate message if available
    if self.currentLootItemLink then
        -- Share item again just to be sure
        PL:SendCommMessage(self.COMM_PREFIX, self.COMM_ITEM .. ":" .. self.currentLootItemLink, self:GetDistributionChannel())
        
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
    self.collectingResults = true -- Start collecting results
    
    -- Reset priorities received tracking
    self.prioritiesReceived = {}
    
    -- Stop the timer if active
    if self.timerActive then
        self:StopTimer()
    end
    
    -- Update UI immediately to reflect state change
    self:UpdateUI(true)
    
    -- Broadcast stop message to trigger all players to send priorities
    PL:SendCommMessage(self.COMM_PREFIX, self.COMM_STOP, self:GetDistributionChannel())
    
    print("|cffff9900Roll session ended. Collecting priorities...|r")
    
    -- Send our own priority immediately
    self:BroadcastFinalPriority()
    
    -- Mark our own priority as received
    if self.playerPriority then
        self.prioritiesReceived[self:NormalizeName(self.playerFullName)] = true
    end
    
    -- Check if we're the only participant
    self:CheckAllPrioritiesReceived()
end

-- Check if all priorities have been received
function PL:CheckAllPrioritiesReceived()
    if not self.collectingResults then return end
    
    local allReceived = true
    local missingCount = 0
    
    -- Count how many participants are missing priorities
    for _, participant in ipairs(self.participants) do
        local normalizedName = self:NormalizeName(participant.name)
        if not self.prioritiesReceived[normalizedName] then
            allReceived = false
            missingCount = missingCount + 1
        end
    end
    
    if allReceived then
        -- All priorities received, finalize results
        self.collectingResults = false
        
        -- Sort participants by priority (lower is better)
        table.sort(self.participants, function(a, b)
            -- If either one has no priority, sort them to the end
            if not a.priority then return false end
            if not b.priority then return true end
            return a.priority < b.priority
        end)
        
        -- Display raid warning with results
        self:AnnounceResults()
        
        -- Final UI update
        self:UpdateUI(true)
        
        print("|cff00ff00All priorities received. Results finalized.|r")
    else
        -- Still waiting for some priorities
        if missingCount == 1 then
            print("|cffff9900Waiting for 1 player to submit their priority...|r")
        else
            print("|cffff9900Waiting for " .. missingCount .. " players to submit their priorities...|r")
        end
    end
end

-- Announce roll results to raid
function PL:AnnounceResults()
    if #self.participants == 0 then return end
    
    -- Count how many players have priorities
    local playersWithPriority = 0
    for _, data in ipairs(self.participants) do
        if data.priority then
            playersWithPriority = playersWithPriority + 1
        end
    end
    
    -- If no one submitted priorities, exit
    if playersWithPriority == 0 then
        local noResultsMsg = "No priorities were submitted for the roll."
        print("|cffff9900" .. noResultsMsg .. "|r")
        
        if self.isHost then
            local chatChannel = IsInRaid() and "RAID_WARNING" or "PARTY"
            SendChatMessage(noResultsMsg, chatChannel)
        end
        return
    end
    
    local resultMessage = ""
    if self.currentLootItemLink then
        resultMessage = "Roll results for " .. self.currentLootItemLink .. ": "
    else
        resultMessage = "Roll results: "
    end
    
    -- Find all players with valid priorities and the same highest priority
    local highestPriority = nil
    
    -- Find the highest (lowest number) valid priority
    for _, data in ipairs(self.participants) do
        if data.priority then
            if highestPriority == nil or data.priority < highestPriority then
                highestPriority = data.priority
            end
        end
    end
    
    if highestPriority then
        local winners = {}
        
        for _, data in ipairs(self.participants) do
            if data.priority == highestPriority then
                table.insert(winners, self:GetDisplayName(data.name) .. " (" .. data.priority .. ")")
            end
        end
        
        -- Add all winners to the message
        resultMessage = resultMessage .. table.concat(winners, ", ")
        
        -- Use consistent channel for announcements
        if self.isHost then
            local chatChannel = IsInRaid() and "RAID_WARNING" or "PARTY"
            SendChatMessage(resultMessage, chatChannel)
        end
    end
end

-- Join a roll with selected priority
function PL:JoinRoll(priority)
    if not self.sessionActive then return end
    
    -- Store priority locally (don't broadcast priority)
    self.playerPriority = priority
    
    -- Check if already joined
    local alreadyJoined = false
    for _, data in ipairs(self.participants) do
        if self:NormalizeName(data.name) == self:NormalizeName(self.playerFullName) then
            alreadyJoined = true
            break
        end
    end
    
    -- Add to participants list or update existing entry
    local playerEntry = nil
    for i, data in ipairs(self.participants) do
        if self:NormalizeName(data.name) == self:NormalizeName(self.playerFullName) then
            playerEntry = data
            break
        end
    end
    
    -- If not found, add player to list and broadcast join
    if not playerEntry then
        table.insert(self.participants, {
            name = self.playerFullName, 
            priority = priority -- For our own display only
        })
        
        -- Broadcast that we joined, but not our priority
        self:JoinRollWithoutPriority()
    end
    
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
    if alreadyJoined then
        print("|cff00ff00You changed your priority to " .. priority .. ".|r")
    else
        print("|cff00ff00You joined the roll with priority " .. priority .. ".|r")
    end
    
    -- Update UI
    self:UpdateUI()
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

-- Get priority display value based on whether it's the current player or roll is finished
function PL:GetPriorityDisplay(participant)
    -- If it's current player, always show the priority
    if self:NormalizeName(participant.name) == self:NormalizeName(self.playerFullName) then
        return tostring(participant.priority or "?")
    end
    
    -- If we're in results collection or session is over, show priority if we have it
    if not self.sessionActive or self.collectingResults then
        return tostring(participant.priority or "?")
    end
    
    -- Otherwise during active session, show ? for other players
    return "?"
end

-- Handle addon communication
function PL:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= self.COMM_PREFIX then return end
    
    -- Normalize the sender name for consistent comparison
    local normalizedSender = self:NormalizeName(sender)
    local normalizedPlayer = self:NormalizeName(self.playerFullName)
    
    if normalizedPlayer ~= normalizedSender then
        if message:find(self.COMM_START) == 1 then
            -- Someone started a roll session
            self.sessionActive = true
            self.collectingResults = false
            self.prioritiesReceived = {}
            
            -- Show the window for all players when a session starts
            self.PriorityLootFrame:Show()

            self.isHost = false
            self.sessionHost = sender
            self.participants = {}
            self.playerPriority = nil -- Reset player's priority
            
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
            -- Someone joined the roll (without priority)
            local parts = {strsplit(":", message)}
            if parts[2] then
                local joiningPlayer = parts[2]
                
                -- Only add if not already in list
                local existingEntry = nil
                for i, data in ipairs(self.participants) do
                    if self:NormalizeName(data.name) == self:NormalizeName(joiningPlayer) then
                        existingEntry = data
                        break
                    end
                end
                
                if not existingEntry then
                    -- New participant (no priority yet)
                    table.insert(self.participants, {name = joiningPlayer})
                    print("|cff00ff00" .. self:GetDisplayName(joiningPlayer) .. " joined the roll.|r")
                    
                    self:UpdateUI()
                end
            end
            
        elseif message:find(self.COMM_LEAVE) == 1 then
            -- Someone left the roll
            local parts = {strsplit(":", message)}
            if parts[2] then
                local leavingPlayer = parts[2]
                
                -- Remove player from participants list
                for i, data in ipairs(self.participants) do
                    if self:NormalizeName(data.name) == self:NormalizeName(leavingPlayer) then
                        table.remove(self.participants, i)
                        print("|cffff9900" .. self:GetDisplayName(leavingPlayer) .. " left the roll.|r")
                        break
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
            
        elseif message:find(self.COMM_PRIORITY) == 1 then
            -- Priority submitted from a player
            local parts = {strsplit(":", message)}
            if parts[2] then
                local priorityData = {strsplit(",", parts[2])}
                if priorityData[1] and priorityData[2] then
                    local playerName = priorityData[1]
                    local priority = tonumber(priorityData[2])
                    
                    -- Track that we've received this player's priority
                    self.prioritiesReceived[self:NormalizeName(playerName)] = true
                    
                    -- Update participant priority
                    for i, data in ipairs(self.participants) do
                        if self:NormalizeName(data.name) == self:NormalizeName(playerName) then
                            data.priority = priority
                            break
                        end
                    end
                    
                    -- Sort participants by priority (lower is better)
                    table.sort(self.participants, function(a, b)
                        -- If either one has no priority, sort them to the end
                        if not a.priority then return false end
                        if not b.priority then return true end
                        return a.priority < b.priority
                    end)

                    self:UpdateUI()
                end
            end
            
        elseif message == self.COMM_STOP then
            -- Host is stopping the session, broadcast our priority
            self.sessionActive = false
            self.collectingResults = true
            self.prioritiesReceived = {} -- Reset tracking
            
            -- Stop the timer if active
            if self.timerActive then
                self:StopTimer()
            end
            
            print("|cffff9900Roll session ended by " .. self:GetDisplayName(sender) .. ". Sending priority...|r")
            
            -- Broadcast our final priority
            self:BroadcastFinalPriority()
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
        -- Register comm prefix with proper method
        PL:RegisterComm(PL.COMM_PREFIX, function(prefix, message, distribution, sender)
            PL:OnCommReceived(prefix, message, distribution, sender)
        end)
        
        -- Get player's full name (with server)
        PL.playerFullName = PL:GetPlayerFullName()
        
        -- Load UI module
        PL:InitUI()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Get player's full name (with server) when entering world
        PL.playerFullName = PL:GetPlayerFullName()
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PARTY_LOOT_METHOD_CHANGED" then
        if PL.initialized then
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