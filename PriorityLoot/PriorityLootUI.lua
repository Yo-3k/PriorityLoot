-- PriorityLootUI.lua
-- UI components for PriorityLoot addon

local addonName, PL = ...

-- UI elements
PL.PriorityLootFrame = nil
PL.rollListFrame = nil
PL.startButton = nil
PL.stopButton = nil
PL.priorityButtons = {}
PL.playerListScrollFrame = nil
PL.playerListContent = nil
PL.timerCheckbox = nil
PL.timerEditBox = nil
PL.timerDisplay = nil
PL.clearButton = nil -- Clear button

-- Item display elements
PL.itemDropFrame = nil
PL.itemDisplayFrame = nil
PL.itemIcon = nil
PL.itemText = nil

-- Button press relief time
PL.lastPressTime = 0

-- UI update throttling variables
PL.lastUIUpdateTime = 0
PL.uiUpdateQueued = false
PL.UI_UPDATE_THROTTLE = 0.1 -- 100ms minimum between updates

-- Returns true if button can be pressed again (kept for optional use)
function PL:ButtonRelief()
    now = GetTime()

    -- Make sure Button can only be pressed every 0.5s
    if ((GetTime() - self.lastPressTime) > 0.5) then
        self.lastPressTime = GetTime()
        return true
    else
        return false
    end
end

-- Update the timer display
function PL:UpdateTimerDisplay(remainingTime)
    if not self.timerDisplay then return end
    
    -- Format remaining time
    local formattedTime = self:FormatTime(math.ceil(remainingTime))
    self.timerDisplay:SetText("Time remaining: " .. formattedTime)
    
    -- Change color based on remaining time
    if remainingTime <= 5 then
        self.timerDisplay:SetTextColor(1, 0, 0) -- Red for last 5 seconds
    elseif remainingTime <= 10 then
        self.timerDisplay:SetTextColor(1, 0.5, 0) -- Orange for 6-10 seconds
    else
        self.timerDisplay:SetTextColor(1, 1, 1) -- White otherwise
    end
end

-- Update the list of participants
function PL:UpdateParticipantsList()
    if not self.playerListContent then return end
    
    -- Clear existing entries
    for _, child in ipairs({self.playerListContent:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    
    -- Create entries for each participant
    local yOffset = 0
    for i, data in ipairs(self.participants) do
        local entry = CreateFrame("Frame", nil, self.playerListContent)
        entry:SetSize(200, 20)
        entry:SetPoint("TOPLEFT", 0, -yOffset)
        
        -- Get class color for the player
        local classColor = self:GetClassColor(data.name)
        
        -- Create name text with class color (display name without server)
        local nameText = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameText:SetPoint("LEFT", 5, 0)
        nameText:SetText("|cff" .. classColor .. self:GetDisplayName(data.name) .. "|r")
        
        -- Show priority based on session state and ownership
        local priorityText = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        priorityText:SetPoint("RIGHT", -5, 0)
        
        if not self.sessionActive then
            -- Always show priority when session is stopped
            priorityText:SetText("Priority: " .. data.priority)
        else
            -- During active session:
            -- Show actual priority only for your character
            -- Show "?" for other players
            if self:NormalizeName(data.name) == self:NormalizeName(self.playerFullName) then
                priorityText:SetText("Priority: " .. data.priority)
            else
                priorityText:SetText("Priority: ?")
            end
        end
        
        yOffset = yOffset + 20
    end
    
    -- Adjust content height
    self.playerListContent:SetHeight(math.max(140, yOffset))
end

-- Update UI based on session state - Improved with throttling and state consistency
function PL:UpdateUI(force)
    -- Skip if frame not initialized yet
    if not self.PriorityLootFrame then return end
    
    local now = GetTime()
    
    -- If we've updated very recently and this isn't a forced update, queue one for later
    if not force and now - self.lastUIUpdateTime < self.UI_UPDATE_THROTTLE then
        -- Don't schedule more than one update
        if not self.uiUpdateQueued then
            self.uiUpdateQueued = true
            C_Timer.After(self.UI_UPDATE_THROTTLE, function()
                self.uiUpdateQueued = false
                self:UpdateUI(true) -- Force the update when it runs
            end)
        end
        return
    end
    
    -- Record this update time
    self.lastUIUpdateTime = now
    
    -- Take a snapshot of the current state to ensure consistency
    local stateSnapshot = {
        sessionActive = self.sessionActive,
        isHost = self.isHost,
        timerActive = self.timerActive,
        playerPriority = self.playerPriority,
        sessionHost = self.sessionHost
    }
    
    -- Basic button state
    local canStartRoll = IsInRaid() and self:IsMasterLooter()
    
    -- Lock UI during state transitions to avoid inconsistency
    local isStateTransitioning = self.isProcessingRollAction
    
    -- Detect and fix inconsistent states early
    if not stateSnapshot.sessionActive and stateSnapshot.timerActive then
        -- Inconsistent state detected - force stop timer
        print("|cffff0000Inconsistent timer state detected and fixed.|r")
        self.timerActive = false
        if self.timerFrame then
            self.timerFrame:SetScript("OnUpdate", nil)
        end
        if self.timerDisplay then
            self.timerDisplay:SetText("")
        end
        
        -- Update snapshot after fixing
        stateSnapshot.timerActive = false
    end
    
    -- Session state logic - use the snapshot for consistency
    if stateSnapshot.sessionActive then
        self.startButton:SetEnabled(false)
        self.timerCheckbox:SetEnabled(false)
        self.timerEditBox:SetEnabled(false)
        
        -- Enable stop button for host only
        self.stopButton:SetEnabled(stateSnapshot.isHost and not isStateTransitioning)
        
        -- Enable priority buttons
        for i = 1, 19 do
            self.priorityButtons[i]:SetEnabled(not isStateTransitioning)
            
            -- Highlight current selection
            if stateSnapshot.playerPriority and stateSnapshot.playerPriority == i then
                self.priorityButtons[i]:SetNormalFontObject("GameFontHighlight")
                self.priorityButtons[i]:LockHighlight()
            else
                self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
                self.priorityButtons[i]:UnlockHighlight()
            end
        end
        
        -- Enable clear button
        self.clearButton:SetEnabled(not isStateTransitioning)
        
        -- Update priority text
        if self.yourPriorityText then
            if stateSnapshot.playerPriority then
                self.yourPriorityText:SetText("Your priority: " .. stateSnapshot.playerPriority)
            else
                self.yourPriorityText:SetText("Your priority: None")
            end
        end
    else
        -- Not in session
        self.startButton:SetEnabled(canStartRoll and not isStateTransitioning)
        self.stopButton:SetEnabled(false)
        self.timerCheckbox:SetEnabled(canStartRoll and not isStateTransitioning)
        self.timerEditBox:SetEnabled(canStartRoll and self.timerCheckbox:GetChecked() and not isStateTransitioning)
        
        -- Disable priority buttons
        for i = 1, 19 do
            self.priorityButtons[i]:SetEnabled(false)
            self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
            self.priorityButtons[i]:UnlockHighlight()
        end
        
        -- Disable clear button
        self.clearButton:SetEnabled(false)
        
        -- Don't reset player's priority here, that should be handled elsewhere
        -- when the session actually ends
        if self.yourPriorityText then
            if stateSnapshot.playerPriority then
                self.yourPriorityText:SetText("Your priority: " .. stateSnapshot.playerPriority)
            else
                self.yourPriorityText:SetText("Your priority: None")
            end
        end
    end
    
    -- Session info text
    if self.sessionInfoText then
        if stateSnapshot.sessionActive then
            if stateSnapshot.isHost then
                self.sessionInfoText:SetText("You started a roll session")
            else
                local hostName = self:GetDisplayName(stateSnapshot.sessionHost or "Unknown")
                self.sessionInfoText:SetText("Roll session started by " .. hostName)
            end
        else
            self.sessionInfoText:SetText("No active roll session")
        end
    end
    
    -- Item display handling
    self:UpdateItemDisplay()
    
    -- Update participants list
    self:UpdateParticipantsList()
    
    -- DEFENSIVE CHECK: Make sure buttons are disabled if session is inactive
    if not self.sessionActive then
        for i = 1, 19 do
            if self.priorityButtons[i] and self.priorityButtons[i]:IsEnabled() then
                -- Force disable any buttons that should be disabled
                self.priorityButtons[i]:SetEnabled(false)
                self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
                self.priorityButtons[i]:UnlockHighlight()
                print("|cffff0000Fixed inconsistent button state.|r")
            end
        end
    end
end

-- Check if player is host or is allowed to manage items
function PL:CanManageItems()
    -- Only the host (master looter) can manage items
    return not self.sessionActive and self:IsMasterLooter()
end

-- Handle item display updates separately
function PL:UpdateItemDisplay()
    -- Item drop frame visibility - only show to host if no item and not in session
    if self.itemDropFrame then
        if self.sessionActive or not self:CanManageItems() or self.currentLootItemLink then
            self.itemDropFrame:Hide()
        else
            self.itemDropFrame:Show()
        end
    end
    
    -- Item display frame visibility
    if self.itemDisplayFrame then
        if self.currentLootItemLink then
            self.itemDisplayFrame:Show()
            if self.itemIcon then
                self.itemIcon:SetTexture(self.currentLootItemTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
            end
            if self.itemText then
                self.itemText:SetText(self.currentLootItemLink)
            end
            
            -- Only show the clear button for host and not during active session
            if self.clearItemButton then
                if self.sessionActive or not self:CanManageItems() then
                    self.clearItemButton:Hide()
                else
                    self.clearItemButton:Show()
                end
            end
        else
            self.itemDisplayFrame:Hide()
        end
    end
end

-- Setup the item drop frame with Classic SoD compatibility
function PL:CreateItemDropFrame()
    if self.itemDropFrame then return self.itemDropFrame end
    
    -- First check if sessionInfoText exists
    if not self.sessionInfoText then
        print("|cffff0000Error: Cannot create item frame before session info is initialized|r")
        return nil
    end
    
    -- Create a container frame for item drop functionality
    local dropFrame = CreateFrame("Button", "PriorityLootItemDropFrame", self.PriorityLootFrame, "BackdropTemplate")
    dropFrame:SetSize(220, 40)
    dropFrame:SetPoint("TOP", self.sessionInfoText, "BOTTOM", 0, -30)
    
    -- Appearance - specify backdrop explicitly for Classic compatibility
    local backdrop = {
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    }
    dropFrame:SetBackdrop(backdrop)
    dropFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    
    -- Add text for instructions
    local dropText = dropFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dropText:SetPoint("CENTER")
    dropText:SetText("Drag item here")
    
    -- Make it receive item drag & drop
    dropFrame:RegisterForDrag("LeftButton")
    dropFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    -- Item display frame (shown when an item is selected)
    self.itemDisplayFrame = CreateFrame("Frame", "PriorityLootItemDisplay", self.PriorityLootFrame, "BackdropTemplate")
    self.itemDisplayFrame:SetSize(220, 40)
    self.itemDisplayFrame:SetPoint("TOP", self.sessionInfoText, "BOTTOM", 0, -30)
    self.itemDisplayFrame:SetBackdrop(backdrop)
    self.itemDisplayFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    
    -- Item icon
    self.itemIcon = self.itemDisplayFrame:CreateTexture("PriorityLootItemIcon", "ARTWORK")
    self.itemIcon:SetSize(32, 32)
    self.itemIcon:SetPoint("LEFT", 8, 0)
    
    -- Item text
    self.itemText = self.itemDisplayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.itemText:SetPoint("LEFT", self.itemIcon, "RIGHT", 8, 0)
    self.itemText:SetPoint("RIGHT", -8, 0)
    self.itemText:SetJustifyH("LEFT")
    self.itemText:SetWordWrap(false)
    
    -- Set up item display frame
    self.itemDisplayFrame:EnableMouse(true)
    
    -- Set up tooltip to right of frame
    self.itemDisplayFrame:SetScript("OnEnter", function()
        if self.currentLootItemLink then
            GameTooltip:SetOwner(self.itemDisplayFrame, "ANCHOR_NONE")
            GameTooltip:SetPoint("LEFT", self.PriorityLootFrame, "RIGHT", 5, 0)
            GameTooltip:SetHyperlink(self.currentLootItemLink)
            GameTooltip:Show()
        end
    end)
    
    self.itemDisplayFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Setup drag and drop functionality
    self.itemDisplayFrame:SetScript("OnReceiveDrag", function()
        -- Only host can drag items
        if not self:CanManageItems() or self.sessionActive then return end
        
        local infoType, itemID, itemLink = GetCursorInfo()
        if infoType == "item" and itemLink then
            self:SetCurrentItem(itemLink)
            ClearCursor()
        end
    end)
    
    self.itemDisplayFrame:SetScript("OnMouseDown", function(frame, button)
        -- Only host can change items
        if not self:CanManageItems() or self.sessionActive then return end
        
        if button == "LeftButton" then
            local infoType, itemID, itemLink = GetCursorInfo()
            if infoType == "item" and itemLink then
                self:SetCurrentItem(itemLink)
                ClearCursor()
            end
        end
    end)
    
    -- Clear button for the item
    local clearItemButton = CreateFrame("Button", nil, self.itemDisplayFrame, "UIPanelCloseButton")
    clearItemButton:SetSize(20, 20)
    clearItemButton:SetPoint("TOPRIGHT", -2, -2)
    clearItemButton:SetScript("OnClick", function()
        -- Only host can clear items and not during active session
        if not self:CanManageItems() or self.sessionActive then return end
        
        if self.ClearCurrentItem then
            self:ClearCurrentItem()
        end
    end)
    self.clearItemButton = clearItemButton
    
    -- Hide item display by default
    self.itemDisplayFrame:Hide()
    
    -- Setup script handlers for the drop frame
    dropFrame:SetScript("OnReceiveDrag", function()
        -- Only host can add items
        if not self:CanManageItems() then return end
        
        local infoType, itemID, itemLink = GetCursorInfo()
        if infoType == "item" and itemLink then
            self:SetCurrentItem(itemLink)
            dropFrame:Hide()
            ClearCursor()
        end
    end)
    
    dropFrame:SetScript("OnMouseDown", function(frame, button)
        -- Only host can add items
        if not self:CanManageItems() then return end
        
        if button == "LeftButton" then
            local infoType, itemID, itemLink = GetCursorInfo()
            if infoType == "item" and itemLink then
                self:SetCurrentItem(itemLink)
                dropFrame:Hide()
                ClearCursor()
            end
        end
    end)
    
    -- Store reference to the drop frame
    self.itemDropFrame = dropFrame
    
    return dropFrame
end

-- Create the UI
function PL:InitUI()
    -- Main frame
    self.PriorityLootFrame = CreateFrame("Frame", "PriorityLootFrame", UIParent, "BackdropTemplate")
    self.PriorityLootFrame:SetSize(260, 500)
    self.PriorityLootFrame:SetPoint("CENTER")
    self.PriorityLootFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    self.PriorityLootFrame:SetBackdropColor(0, 0, 0, 0.8)
    self.PriorityLootFrame:SetMovable(true)
    self.PriorityLootFrame:EnableMouse(true)
    self.PriorityLootFrame:RegisterForDrag("LeftButton")
    self.PriorityLootFrame:SetScript("OnDragStart", self.PriorityLootFrame.StartMoving)
    self.PriorityLootFrame:SetScript("OnDragStop", self.PriorityLootFrame.StopMovingOrSizing)
    
    -- Title
    local title = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Priority Loot")
    
    -- Timer checkbox
    self.timerCheckbox = CreateFrame("CheckButton", "PriorityLootTimerCheckbox", self.PriorityLootFrame, "UICheckButtonTemplate")
    self.timerCheckbox:SetPoint("TOPLEFT", 20, -42)
    self.timerCheckbox:SetSize(24, 24)
    _G[self.timerCheckbox:GetName() .. "Text"]:SetText("Auto-stop")
    self.timerCheckbox:SetChecked(true) -- Default to checked
    self.timerCheckbox:SetScript("OnClick", function(checkBox)
        local isChecked = checkBox:GetChecked()
        self.timerEditBox:SetEnabled(isChecked)
        if isChecked then
            self.timerEditBox:SetTextColor(1, 1, 1)
        else
            self.timerEditBox:SetTextColor(0.5, 0.5, 0.5)
        end
    end)
    
    -- Timer text input
    local timerLabel = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timerLabel:SetPoint("LEFT", self.timerCheckbox, "RIGHT", 80, 0)
    timerLabel:SetText("Seconds:")
    
    self.timerEditBox = CreateFrame("EditBox", "PriorityLootTimerEditBox", self.PriorityLootFrame, "InputBoxTemplate")
    self.timerEditBox:SetPoint("LEFT", timerLabel, "RIGHT", 5, 0)
    self.timerEditBox:SetSize(40, 16)
    self.timerEditBox:SetAutoFocus(false)
    self.timerEditBox:SetNumeric(true)
    self.timerEditBox:SetMaxLetters(3)
    self.timerEditBox:SetText(tostring(self.timerDuration))
    self.timerEditBox:SetEnabled(true) -- Since checkbox is checked by default
    self.timerEditBox:SetTextColor(1, 1, 1)
    
    self.timerEditBox:SetScript("OnEnterPressed", function(editBox)
        local value = tonumber(editBox:GetText())
        if value then
            -- Limit to reasonable values
            if value < 5 then value = 5 end
            if value > 60 then value = 60 end
            
            self.timerDuration = value
            editBox:SetText(tostring(value))
        else
            -- Reset to default if invalid
            editBox:SetText(tostring(self.timerDuration))
        end
        editBox:ClearFocus()
    end)
    
    self.timerEditBox:SetScript("OnEscapePressed", function(editBox)
        editBox:SetText(tostring(self.timerDuration))
        editBox:ClearFocus()
    end)
    
    -- Host controls with button spam protection (removed ButtonRelief as requested)
    self.startButton = CreateFrame("Button", "PriorityLootStartButton", self.PriorityLootFrame, "UIPanelButtonTemplate")
    self.startButton:SetSize(100, 24)
    self.startButton:SetPoint("TOPLEFT", 20, -70)
    self.startButton:SetText("Start Roll")
    self.startButton:SetScript("OnClick", function() 
        self:StartRollSession() 
    end)
    
    self.stopButton = CreateFrame("Button", "PriorityLootStopButton", self.PriorityLootFrame, "UIPanelButtonTemplate")
    self.stopButton:SetSize(100, 24)
    self.stopButton:SetPoint("TOPRIGHT", -20, -70)
    self.stopButton:SetText("Stop Roll")
    self.stopButton:SetEnabled(false)
    self.stopButton:SetScript("OnClick", function() 
        self:StopRollSession() 
    end)
    
    -- Current session info
    local sessionInfoText = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sessionInfoText:SetPoint("TOP", 0, -100)
    sessionInfoText:SetText("No active roll session")
    self.sessionInfoText = sessionInfoText
    
    -- Timer display
    self.timerDisplay = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.timerDisplay:SetPoint("TOP", sessionInfoText, "BOTTOM", 0, -5)
    self.timerDisplay:SetText("")
    
    -- Now create the item drop frame after sessionInfoText is initialized
    self:CreateItemDropFrame()
    
    -- Calculate button grid dimensions
    local buttonWidth = 30
    local buttonHeight = 24
    local buttonSpacing = 5
    local buttonsPerRow = 5
    local numRows = 4
    
    -- Calculate total width of button grid
    local totalWidth = (buttonWidth * buttonsPerRow) + (buttonSpacing * (buttonsPerRow - 1))
    
    -- Calculate total height of button grid
    local totalHeight = (buttonHeight * numRows) + (buttonSpacing * (numRows - 1))
    
    -- Priority buttons frame with increased spacing
    local priorityFrame = CreateFrame("Frame", nil, self.PriorityLootFrame)
    priorityFrame:SetSize(totalWidth, totalHeight)
    -- Center it horizontally and position it below the item display with more space
    priorityFrame:SetPoint("TOP", self.PriorityLootFrame, "TOP", 0, -200)
    
    -- Priority buttons (1-19, arranged in rows of 5)
    for i = 1, 19 do
        local row = math.ceil(i / 5)
        local col = ((i - 1) % 5) + 1
        
        local button = CreateFrame("Button", nil, priorityFrame, "UIPanelButtonTemplate")
        button:SetSize(buttonWidth, buttonHeight)
        local xPos = (col - 1) * (buttonWidth + buttonSpacing)
        local yPos = (row - 1) * (buttonHeight + buttonSpacing)
        button:SetPoint("TOPLEFT", xPos, -yPos)
        button:SetText(i)
        button:SetEnabled(false)
        button:SetScript("OnClick", function() self:JoinRoll(i) end)
        
        self.priorityButtons[i] = button
    end
    
    -- Add Reset button (RS) as the same size as priority buttons
    -- Position it in row 4, column 5 (5th position of 4th row)
    self.clearButton = CreateFrame("Button", "PriorityLootClearButton", priorityFrame, "UIPanelButtonTemplate")
    self.clearButton:SetSize(buttonWidth, buttonHeight)
    local xPos = 4 * (buttonWidth + buttonSpacing) -- 5th position (index 4)
    local yPos = 3 * (buttonHeight + buttonSpacing) -- 4th row (index 3)
    self.clearButton:SetPoint("TOPLEFT", xPos, -yPos)
    self.clearButton:SetText("RS")
    self.clearButton:SetEnabled(false)
    self.clearButton:SetScript("OnClick", function() self:ClearPlayerRoll() end)
    
    -- Player's current priority
    local yourPriorityText = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    yourPriorityText:SetPoint("TOP", priorityFrame, "BOTTOM", 0, -5)
    yourPriorityText:SetText("Your priority: None")
    self.yourPriorityText = yourPriorityText
    
    -- Player list frame - moved down to ensure it's below the priority buttons
    local listTitleText = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listTitleText:SetPoint("TOP", yourPriorityText, "BOTTOM", 0, -5) -- Position relative to priority frame
    listTitleText:SetText("Participants")
    
    -- Create a parent frame for the scroll frame to fix the slider position
    local scrollContainer = CreateFrame("Frame", nil, self.PriorityLootFrame)
    scrollContainer:SetPoint("TOP", listTitleText, "BOTTOM", 0, -5) -- Position relative to title
    scrollContainer:SetPoint("BOTTOM", self.PriorityLootFrame, "BOTTOM", 0, 10) -- Extend to bottom of window
    scrollContainer:SetWidth(220)
    
    -- Scrolling list for participants
    self.playerListScrollFrame = CreateFrame("ScrollFrame", "PriorityLootScrollFrame", scrollContainer, "UIPanelScrollFrameTemplate")
    self.playerListScrollFrame:SetPoint("TOPLEFT", 0, 0)
    self.playerListScrollFrame:SetPoint("BOTTOMRIGHT", -22, 0) -- Make room for the scroll bar
    
    -- Position the scrollbar properly
    local scrollbar = _G["PriorityLootScrollFrameScrollBar"]
    scrollbar:ClearAllPoints()
    scrollbar:SetPoint("TOPRIGHT", scrollContainer, "TOPRIGHT", 0, -16)
    scrollbar:SetPoint("BOTTOMRIGHT", scrollContainer, "BOTTOMRIGHT", 0, 16)
    
    self.playerListContent = CreateFrame("Frame", "PriorityLootScrollFrameContent", self.playerListScrollFrame)
    self.playerListContent:SetSize(200, 140)
    self.playerListScrollFrame:SetScrollChild(self.playerListContent)
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, self.PriorityLootFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", 0, 0)
    
    -- Hide by default
    self.PriorityLootFrame:Hide()
    
    -- Initialize UI state
    self:UpdateUI(true)
    
    -- Create a consistency check frame
    self.consistencyCheckFrame = CreateFrame("Frame")
    self.lastConsistencyCheck = 0
    self.CONSISTENCY_CHECK_INTERVAL = 0.5 -- Check every 0.5 seconds
    
    self.consistencyCheckFrame:SetScript("OnUpdate", function(_, elapsed)
        self.lastConsistencyCheck = self.lastConsistencyCheck + elapsed
        if self.lastConsistencyCheck < self.CONSISTENCY_CHECK_INTERVAL then
            return
        end
        self.lastConsistencyCheck = 0
        
        -- Check for inconsistent states
        if not self.sessionActive then
            -- Ensure all buttons are disabled when session is inactive
            local needsUpdate = false
            for i = 1, 19 do
                if self.priorityButtons[i] and self.priorityButtons[i]:IsEnabled() then
                    self.priorityButtons[i]:SetEnabled(false)
                    self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
                    self.priorityButtons[i]:UnlockHighlight()
                    needsUpdate = true
                end
            end
            
            if needsUpdate then
                print("|cffff0000Fixed UI inconsistency in periodic check.|r")
            end
        end
    end)
    
    self.initialized = true
    print("|cff00ff00PriorityLoot v" .. self.version .. " loaded. Type /pl or /priorityloot to open.|r")
end