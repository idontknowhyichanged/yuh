local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui", 8)

local FIREBASE_URL = "https://cacc-c57bf-default-rtdb.firebaseio.com"
local API_KEY = "AIzaSyBquxKffIm2lBtpi90GLLDdrQG_0yvlo4Y"

local POLL_INTERVAL = 0.28
local AUTH_REFRESH_MARGIN = 300
local MAX_LOG_LINES = 140
local CLAIM_TIMEOUT = 75     -- a bit more generous
local BETWEEN_OUTFITS_WAIT = 1.1   -- ← most important change
local RESET_WAIT = 1.4

local CommunityRemote = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote", 8)
local CatalogGuiRemote   = ReplicatedStorage:WaitForChild("CatalogGuiRemote", 8)
local UpdateStatusRemote = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UpdatePlayerStatus", 5)

local active = true
local isProcessing = false
local currentIdToken = nil
local tokenExpiresAt = 0

local MY_USER_ID = tostring(Player.UserId)
local usernameCache = {}

-- ────────────────────────────────────────
--   Graphics / Performance
-- ────────────────────────────────────────
local function optimizeGraphics()
    settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    
    Lighting.GlobalShadows = false
    Lighting.Brightness = 1
    Lighting.Ambient = Color3.new(1,1,1)
    Lighting.OutdoorAmbient = Color3.new(1,1,1)
    Lighting.EnvironmentDiffuseScale = 0
    Lighting.EnvironmentSpecularScale = 0
    Lighting.Technology = Enum.Technology.Compatibility

    for _, effect in Lighting:GetChildren() do
        if effect:IsA("PostEffect") then
            effect.Enabled = false
        end
    end

    pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.All, false)
    pcall(StarterGui.SetCore, StarterGui, "ChatActive", false)

    UserInputService.MouseEnabled = false
    UserInputService.MouseIconEnabled = false

    task.wait(0.8)
    log("Graphics optimized (streaming-safe)")
end

-- ────────────────────────────────────────
--   Clean on-screen logger
-- ────────────────────────────────────────
local function createCleanLogger()
    local gui = Instance.new("ScreenGui")
    gui.Name = "CACLogger"
    gui.ResetOnSpawn = false
    gui.Parent = PlayerGui

    local frame = Instance.new("Frame", gui)
    frame.Size = UDim2.fromOffset(560, 340)
    frame.Position = UDim2.fromOffset(16, 16)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    frame.BorderSizePixel = 0

    local logBox = Instance.new("TextLabel", frame)
    logBox.Size = UDim2.fromScale(1,1)
    logBox.BackgroundTransparency = 1
    logBox.TextColor3 = Color3.new(0.95,0.95,0.98)
    logBox.Font = Enum.Font.Code
    logBox.TextSize = 13.5
    logBox.TextXAlignment = Enum.TextXAlignment.Left
    logBox.TextYAlignment = Enum.TextYAlignment.Top
    logBox.TextWrapped = true
    logBox.RichText = true
    logBox.Text = `<font color="#aaa">[CAC] Logger • {os.date("%H:%M:%S")} • Worker {MY_USER_ID}</font>`

    local function addLine(msg)
        print("[CAC] " .. msg)
        if not logBox.Parent then return end
        
        local time = os.date("%H:%M:%S")
        logBox.Text ..= `\n<font color="#ccc">[{time}]</font> {msg}`
        
        local lines = logBox.Text:split("\n")
        if #lines > MAX_LOG_LINES then
            logBox.Text = table.concat(lines, "\n", #lines - MAX_LOG_LINES + 1)
        end
    end

    local btn = Instance.new("TextButton", frame)
    btn.Size = UDim2.fromOffset(90, 28)
    btn.Position = UDim2.new(1,-98,0,8)
    btn.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
    btn.TextColor3 = Color3.new(1,1,1)
    btn.Font = Enum.Font.Code
    btn.TextSize = 14
    btn.Text = "STOP"
    btn.MouseButton1Click:Connect(function()
        active = false
        gui:Destroy()
        warn("[CAC] Manually stopped")
    end)

    return addLine
end

local log = createCleanLogger()

-- ────────────────────────────────────────
--   HTTP Helpers
-- ────────────────────────────────────────
local request_impl = (syn and syn.request) or (http and http.request) or (request or HttpService.HttpRequestAsync)

local function http_req(method, url, body)
    if not request_impl then return nil end
    local success, resp = pcall(request_impl, {
        Url = url,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "Roblox/WinInet"
        },
        Body = body and HttpService:JSONEncode(body) or nil
    })
    if not success or not resp or resp.StatusCode < 200 or resp.StatusCode > 299 then
        return nil
    end
    local ok, json = pcall(HttpService.JSONDecode, HttpService, resp.Body)
    return ok and json or nil
end

local function refreshAuthToken()
    log("Refreshing auth token...")
    local data = http_req("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key="..API_KEY, {
        returnSecureToken = true
    })
    if not data or not data.idToken then
        log("<font color=\"#f55\">Firebase auth failed</font>")
        return false
    end
    currentIdToken = data.idToken
    tokenExpiresAt = tick() + (data.expiresIn or 3600) - AUTH_REFRESH_MARGIN
    log("Token refreshed")
    return true
end

local function getRequests()
    if tick() > tokenExpiresAt then
        if not refreshAuthToken() then return {} end
    end
    return http_req("GET", FIREBASE_URL.."/requests.json?auth="..currentIdToken) or {}
end

local function patch(requestId, data)
    local url = FIREBASE_URL .. ("/requests/%s.json?auth=%s"):format(requestId, currentIdToken)
    local success, resp = pcall(request_impl, {
        Url = url,
        Method = "PATCH",
        Headers = {["Content-Type"] = "application/json"},
        Body = HttpService:JSONEncode(data)
    })
    return success and resp and resp.StatusCode >= 200 and resp.StatusCode < 300
end

local function tryClaim(requestId)
    local url = FIREBASE_URL .. ("/requests/%s.json?auth=%s"):format(requestId, currentIdToken)
    
    local current = http_req("GET", url)
    if not current then return false end
    if current.result then return false end
    
    local timedOut = current.claimedBy and current.claimedAt and (os.time() - current.claimedAt > CLAIM_TIMEOUT)
    if not timedOut and (current.claimedBy or current.processing) then
        return false
    end

    local claimData = {
        claimedBy = MY_USER_ID,
        claimedAt = os.time(),
        processing = true
    }

    if not patch(requestId, claimData) then return false end

    task.wait(0.06 + math.random() * 0.08)
    
    local after = http_req("GET", url)
    if not after or after.claimedBy ~= MY_USER_ID then
        log("Claim collision → " .. requestId)
        return false
    end

    log(timedOut and ("Reclaimed timeout → " .. requestId) or ("Claimed → " .. requestId))
    return true
end

local function sendResult(id, payload)
    if patch(id, {result = payload}) then
        log("Result sent → " .. id)
    else
        log("<font color=\"#fa5\">Failed to send result → " .. id .. "</font>")
    end
end

-- ────────────────────────────────────────
--   Character Reset (more aggressive)
-- ────────────────────────────────────────
local function hardResetCharacter()
    pcall(function()
        -- Force default avatar
        CatalogGuiRemote:InvokeServer({Action = "MorphIntoPlayer", UserId = Player.UserId, RigType = Enum.HumanoidRigType.R15})
        UpdateStatusRemote:FireServer("None")
    end)
    
    -- Remove character entirely if possible
    if Player.Character then
        pcall(function() Player.Character:Destroy() end)
    end
    
    -- Wait for new character
    local newChar = Player.CharacterAdded:Wait()
    local hum = newChar:WaitForChild("Humanoid", 4)
    if hum then
        hum:WaitForChild("HumanoidDescription", 4.5)
    end
    
    task.wait(0.3)
    log("Hard character reset completed")
end

local function getUsername(userIdStr)
    if usernameCache[userIdStr] then return usernameCache[userIdStr] end
    
    local success, name = pcall(Players.GetNameFromUserIdAsync, Players, tonumber(userIdStr))
    local result = success and name or userIdStr
    usernameCache[userIdStr] = result
    return result
end

-- ────────────────────────────────────────
--   Core outfit processor
-- ────────────────────────────────────────
local function processSingleOutfit(hexCode, requesterName)
    local code = tonumber(hexCode, 16)
    if not code then
        return {error = "Invalid outfit code: " .. tostring(hexCode)}
    end

    log(("Processing • %s • code %d"):format(requesterName, code))

    local success, outfit = pcall(CommunityRemote.InvokeServer, CommunityRemote, {
        Action = "GetFromOutfitCode",
        OutfitCode = code
    })

    if not success or not outfit or type(outfit) ~= "table" then
        return {error = "Failed to fetch outfit (code " .. code .. ")"}
    end

    -- Try wear (with retry)
    local wearOk = false
    for attempt = 1, 2 do
        wearOk = pcall(CommunityRemote.InvokeServer, CommunityRemote, {
            Action = "WearCommunityOutfit",
            OutfitInfo = outfit
        })
        if wearOk then break end
        task.wait(0.4)
    end

    if not wearOk then
        return {error = "WearCommunityOutfit failed after retry"}
    end

    local char = Player.Character or Player.CharacterAdded:Wait()
    local humanoid = char:WaitForChild("Humanoid", 4)
    if not humanoid then return {error = "Humanoid not found"} end

    task.wait(0.6) -- give network time to replicate accessories

    local desc = humanoid:FindFirstChild("HumanoidDescription")
    if not desc then
        log("No HumanoidDescription after wear → forcing reset")
        hardResetCharacter()
        return {error = "HumanoidDescription missing after apply"}
    end

    -- Build result
    local otherAcc = {}
    for _, acc in desc:GetAccessories(true) do
        local entry = {
            assetId = acc.AssetId,
            isLayered = acc.IsLayered,
            type = acc.AccessoryType.Name,
        }
        if acc.Order then entry.order = acc.Order end
        table.insert(otherAcc, entry)
    end

    local result = {
        RigType = humanoid.RigType.Name,
        Colors = {
            Head       = desc.HeadColor:ToHex(),
            Torso      = desc.TorsoColor:ToHex(),
            LeftArm    = desc.LeftArmColor:ToHex(),
            RightArm   = desc.RightArmColor:ToHex(),
            LeftLeg    = desc.LeftLegColor:ToHex(),
            RightLeg   = desc.RightLegColor:ToHex(),
        },
        Clothing = {
            Shirt = desc.Shirt,
            Pants = desc.Pants,
        },
        Accessories = { Other = otherAcc },
        Scales = {
            Height    = desc.HeightScale,
            Width     = desc.WidthScale,
            Head      = desc.HeadScale,
            Depth     = desc.DepthScale,
            Proportion = desc.ProportionScale,
            BodyType  = desc.BodyTypeScale,
        },
        Body = {
            Head      = desc.Head,
            Torso     = desc.Torso,
            LeftArm   = desc.LeftArm,
            RightArm  = desc.RightArm,
            LeftLeg   = desc.LeftLeg,
            RightLeg  = desc.RightLeg,
            Face      = desc.Face,
        },
        Animations = {
            walk = desc.WalkAnimation or 0,
            run  = desc.RunAnimation or 0,
            jump = desc.JumpAnimation or 0,
            idle = desc.IdleAnimation or 0,
            fall = desc.FallAnimation or 0,
            swim = desc.SwimAnimation or 0,
            climb = desc.ClimbAnimation or 0,
        }
    }

    log(("%d accessories captured"):format(#otherAcc))
    return result
end

local function processRequest(requestId, data)
    isProcessing = true
    local requesterName = data.username or getUsername(data.userId or "unknown")

    log(("Starting batch • %s • %s"):format(requesterName, requestId))

    local success, errMsg = pcall(function()
        local result = {}
        local codes = data.codes or (data.code and {data.code}) or {}

        for i, hex in ipairs(codes) do
            -- Reset BEFORE each outfit (critical fix)
            if i > 1 then
                hardResetCharacter()
                task.wait(BETWEEN_OUTFITS_WAIT + math.random() * 0.3)
            end

            local outfitData = processSingleOutfit(hex, requesterName)
            result["outfit" .. i] = outfitData

            task.wait(0.5 + math.random() * 0.4)
        end

        -- Final reset (clean exit)
        hardResetCharacter()
        task.wait(0.4)

        sendResult(requestId, result)
    end)

    if not success then
        log(("<font color=\"#f66\">Processing error: %s</font>"):format(tostring(errMsg)))
        sendResult(requestId, {error = tostring(errMsg)})
    end

    isProcessing = false
end

-- ────────────────────────────────────────
--   Startup
-- ────────────────────────────────────────
task.spawn(optimizeGraphics)

task.spawn(function()
    if not refreshAuthToken() then
        log("<font color=\"#f55\">Initial auth failed → stopping</font>")
        return
    end

    log(("Listener active • poll %.2fs • multi-safe • better reset"):format(POLL_INTERVAL))

    while active do
        if isProcessing then
            RunService.Heartbeat:Wait()
            continue
        end

        local t = tick()
        local requests = getRequests() or {}

        for id, data in pairs(requests) do
            local codes = data.codes or (data.code and {data.code}) or {}
            if #codes > 0 and not data.result then
                if tryClaim(id) then
                    task.spawn(processRequest, id, data)
                    break   -- process one at a time
                end
            end
        end

        local elapsed = tick() - t
        if elapsed < POLL_INTERVAL then
            task.wait(POLL_INTERVAL - elapsed)
        end
    end
end)

-- Anti-AFK
task.spawn(function()
    while active do
        Player.Idled:Wait()
        if not active then break end
        log("Anti-AFK")
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        task.wait(280 + math.random(0, 40))
    end
end)

log("<font color=\"#8f8\">CAC ready • improved reset • batch-safe • 2026</font>")
