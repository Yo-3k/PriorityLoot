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

-- Update UI based on session state
function PL:UpdateUI()
    if not self.PriorityLootFrame then return end
    
    -- Update buttons based on role and session state
    if self.sessionActive then
        -- Disable start button during active sessions
        self.startButton:SetEnabled(false)
        
        -- Disable timer controls during active session
        self.timerCheckbox:SetEnabled(false)
        self.timerEditBox:SetEnabled(false)
        
        -- Enable stop button ONLY for the host
        if self.isHost then
            self.stopButton:SetEnabled(true)
        else
            self.stopButton:SetEnabled(false)
        end
        
        -- Enable priority buttons for selection/changes during active session
        for i = 1, 19 do
            self.priorityButtons[i]:SetEnabled(true)
            
            -- Highlight current selection (if any)
            if self.playerPriority and self.playerPriority == i then
                self.priorityButtons[i]:SetNormalFontObject("GameFontHighlight")
                self.priorityButtons[i]:LockHighlight()
            else
                self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
                self.priorityButtons[i]:UnlockHighlight()
            end
        end
        
        -- Enable the clear button during active session
        self.clearButton:SetEnabled(true)
        
        -- Update player's priority text
        if self.playerPriority then
            self.yourPriorityText:SetText("Your priority: " .. self.playerPriority)
        else
            self.yourPriorityText:SetText("Your priority: None")
        end
    else
        -- Only enable Start button for Master Looter in raid
        local canStartRoll = IsInRaid() and self:IsMasterLooter()
        self.startButton:SetEnabled(canStartRoll)
        self.stopButton:SetEnabled(false)
        
        -- Enable timer controls only when no session is active and player is master looter
        self.timerCheckbox:SetEnabled(canStartRoll)
        self.timerEditBox:SetEnabled(canStartRoll and self.timerCheckbox:GetChecked())
        
        -- Disable and reset priority buttons
        for i = 1, 19 do
            self.priorityButtons[i]:SetEnabled(false)
            self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
            self.priorityButtons[i]:UnlockHighlight()
        end
        
        -- Disable the clear button when no session is active
        self.clearButton:SetEnabled(false)
        
        -- Reset player's priority display
        self.playerPriority = nil
        self.yourPriorityText:SetText("Your priority: None")
    end
    
    -- Update session info text
    if self.sessionActive then
        if self.isHost then
            self.sessionInfoText:SetText("You started a roll session")
        else
            self.sessionInfoText:SetText("Roll session started by " .. self:GetDisplayName(self.sessionHost))
        end
    else
        self.sessionInfoText:SetText("No active roll session")
    end
    
    -- Update participants list
    self:UpdateParticipantsList()
end

-- Create the UI
function PL:InitUI()
    -- Main frame
    self.PriorityLootFrame = CreateFrame("Frame", "PriorityLootFrame", UIParent, "BackdropTemplate")
    self.PriorityLootFrame:SetSize(260, 460) -- More compact width, slightly taller to accommodate everything
    self.PriorityLootFrame:SetPoint("CENTER")
    self.PriorityLootFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
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
    
    -- Host controls
    self.startButton = CreateFrame("Button", "PriorityLootStartButton", self.PriorityLootFrame, "UIPanelButtonTemplate")
    self.startButton:SetSize(100, 24)
    self.startButton:SetPoint("TOPLEFT", 20, -70)
    self.startButton:SetText("Start Roll")
    self.startButton:SetScript("OnClick", function() self:StartRollSession() end)
    
    self.stopButton = CreateFrame("Button", "PriorityLootStopButton", self.PriorityLootFrame, "UIPanelButtonTemplate")
    self.stopButton:SetSize(100, 24)
    self.stopButton:SetPoint("TOPRIGHT", -20, -70)
    self.stopButton:SetText("Stop Roll")
    self.stopButton:SetEnabled(false)
    self.stopButton:SetScript("OnClick", function() self:StopRollSession() end)
    
    -- Current session info
    local sessionInfoText = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sessionInfoText:SetPoint("TOP", 0, -100)
    sessionInfoText:SetText("No active roll session")
    self.sessionInfoText = sessionInfoText
    
    -- Timer display
    self.timerDisplay = self.PriorityLootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.timerDisplay:SetPoint("TOP", sessionInfoText, "BOTTOM", 0, -5)
    self.timerDisplay:SetText("")
    
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
    
    -- Priority buttons frame (centered horizontally)
    local priorityFrame = CreateFrame("Frame", nil, self.PriorityLootFrame)
    priorityFrame:SetSize(totalWidth, totalHeight)
    -- Center it horizontally by anchoring to the center of the window
    priorityFrame:SetPoint("TOP", self.PriorityLootFrame, "TOP", 0, -140)
    
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
    
    self:UpdateUI()
    
    self.initialized = true
    print("|cff00ff00PriorityLoot v" .. self.version .. " loaded. Type /pl or /priorityloot to open.|r")
end