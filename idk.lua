local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui", 8)

local FIREBASE_URL = "https://cacc-c57bf-default-rtdb.firebaseio.com"
local API_KEY = "AIzaSyBquxKffIm2lBtpi90GLLDdrQG_0yvlo4Y"

local POLL_INTERVAL = 0.4
local AUTH_REFRESH_MARGIN = 300
local MAX_LOG_LINES = 120

local CommunityRemote = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote", 8)
local CatalogGuiRemote = ReplicatedStorage:WaitForChild("CatalogGuiRemote", 8)
local UpdateStatusRemote = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UpdatePlayerStatus", 5)

local active = true
local isProcessing = false
local currentIdToken = nil
local tokenExpiresAt = 0

-- ────────────────────────────────────────────────
--   NEW: Used for claiming requests
-- ────────────────────────────────────────────────
local MY_USER_ID = tostring(Player.UserId)   -- string because Firebase likes strings for IDs

local function createCleanLogger()
    local gui = Instance.new("ScreenGui")
    gui.Name = "CACLogger"
    gui.ResetOnSpawn = false
    gui.Parent = PlayerGui

    local frame = Instance.new("Frame", gui)
    frame.Size = UDim2.fromOffset(540, 320)
    frame.Position = UDim2.fromOffset(16, 16)
    frame.BackgroundColor3 = Color3.fromRGB(17, 17, 23)
    frame.BorderSizePixel = 0

    local logBox = Instance.new("TextLabel", frame)
    logBox.Size = UDim2.fromScale(1,1)
    logBox.BackgroundTransparency = 1
    logBox.TextColor3 = Color3.fromRGB(185, 210, 255)
    logBox.Font = Enum.Font.Code
    logBox.TextSize = 13.5
    logBox.TextXAlignment = Enum.TextXAlignment.Left
    logBox.TextYAlignment = Enum.TextYAlignment.Top
    logBox.TextWrapped = true
    logBox.Text = "[CAC] Logger started • "..os.date("%H:%M:%S") .. " • Worker: " .. MY_USER_ID

    local function addLine(msg)
        print("[CAC]", msg)
        if not logBox.Parent then return end
        logBox.Text ..= "\n" .. msg
        local lines = logBox.Text:split("\n")
        if #lines > MAX_LOG_LINES then
            logBox.Text = table.concat(lines, "\n", #lines - MAX_LOG_LINES + 1)
        end
    end

    local kill = Instance.new("TextButton", frame)
    kill.Size = UDim2.fromOffset(86, 26)
    kill.Position = UDim2.new(1,-94,0,6)
    kill.BackgroundColor3 = Color3.fromRGB(210, 60, 60)
    kill.TextColor3 = Color3.new(1,1,1)
    kill.Font = Enum.Font.Code
    kill.TextSize = 13
    kill.Text = "STOP"
    kill.MouseButton1Click:Connect(function()
        active = false
        gui:Destroy()
        warn("[CAC] Listener manually terminated")
    end)

    return addLine
end

local log = createCleanLogger()

local request_impl = (syn and syn.request) or (http and http.request) or (request or game.HttpService.HttpRequestAsync)

local function http_req(method, url, body)
    if not request_impl then return nil end
    local success, response = pcall(request_impl, {
        Url = url,
        Method = method,
        Headers = {["Content-Type"] = "application/json", ["User-Agent"] = "Roblox/WinInet"},
        Body = body and HttpService:JSONEncode(body) or nil
    })
    if not success or not response or response.StatusCode < 200 or response.StatusCode > 299 then 
        if response then
            log("HTTP error: " .. response.StatusCode .. " - " .. (response.Body or "no body"))
        end
        return nil 
    end
    local ok, json = pcall(HttpService.JSONDecode, HttpService, response.Body)
    return ok and json or nil
end

local function refreshAuthToken()
    log("Refreshing Firebase token...")
    local data = http_req("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key="..API_KEY, {returnSecureToken = true})
    if not data or not data.idToken then 
        log("Firebase auth failed") 
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
    local url = FIREBASE_URL..("/requests/%s.json?auth=%s"):format(requestId, currentIdToken)
    local success, response = pcall(request_impl, {
        Url = url,
        Method = "PATCH",
        Headers = {["Content-Type"] = "application/json"},
        Body = HttpService:JSONEncode(data)
    })
    if not success or not response then 
        log("Patch failed (pcall/response)") 
        return false 
    end
    if response.StatusCode < 200 or response.StatusCode > 299 then
        log("Patch error - code: "..response.StatusCode.." body: "..(response.Body or "nil"))
        return false
    end
    return true
end

-- ────────────────────────────────────────────────
--   NEW: Try to claim this request (optimistic lock)
-- ────────────────────────────────────────────────
local function tryClaim(requestId)
    local url = FIREBASE_URL .. ("/requests/%s.json?auth=%s"):format(requestId, currentIdToken)
    
    -- Quick read → check if still free
    local current = http_req("GET", url)
    if not current then return false end
    if current.claimedBy or current.processing or current.result then 
        return false 
    end
    
    -- Attempt to claim
    local claimData = {
        claimedBy = MY_USER_ID,
        claimedAt = os.time(),
        processing = true
    }
    
    local patchSuccess = patch(requestId, claimData)
    if not patchSuccess then return false end
    
    -- Verify we actually got it (race protection)
    task.wait(0.08 + math.random(0, 120)/1000)  -- tiny random delay
    local after = http_req("GET", url)
    if not after or after.claimedBy ~= MY_USER_ID then
        log("Claim lost race on " .. requestId)
        return false
    end
    
    log("Claimed request " .. requestId)
    return true
end

local function sendResult(id, payload) 
    patch(id, {result = payload}) 
end

local function forceResetCharacter()
    pcall(function()
        CatalogGuiRemote:InvokeServer({Action = "MorphIntoPlayer", UserId = Player.UserId, RigType = Enum.HumanoidRigType.R15})
        UpdateStatusRemote:FireServer("None")
    end)
    log("Final character reset")
end

local function processSingleOutfit(hexCode, requesterUserId)
    local code = tonumber(hexCode, 16)
    if not code then return {error = "Invalid outfit code"} end
    local requester = requesterUserId or "?"
    log(("Processing • user: %s • code: %d"):format(requester, code))
    
    local success, outfit = pcall(CommunityRemote.InvokeServer, CommunityRemote, {Action = "GetFromOutfitCode", OutfitCode = code})
    if not success or not outfit then return {error = "Failed to fetch outfit data"} end
    
    local ok = pcall(CommunityRemote.InvokeServer, CommunityRemote, {Action = "WearCommunityOutfit", OutfitInfo = outfit})
    if not ok then return {error = "Failed to wear outfit"} end
    
    local char = Player.Character or Player.CharacterAdded:Wait()
    local humanoid = char:WaitForChild("Humanoid", 4)
    if not humanoid then return {error = "Humanoid not found"} end
    
    local desc = humanoid:WaitForChild("HumanoidDescription", 3.5)
    if not desc then return {error = "No HumanoidDescription"} end
    
    local otherAcc = {}
    for _, acc in desc:GetAccessories(true) do
        local entry = {
            assetId = acc.AssetId,
            isLayered = acc.IsLayered,
            type = acc.AccessoryType.Name
        }
        if acc.Order then entry.order = acc.Order end
        table.insert(otherAcc, entry)
    end
    
    local animations = {
        walk = desc.WalkAnimation or 0,
        run = desc.RunAnimation or 0,
        jump = desc.JumpAnimation or 0,
        idle = desc.IdleAnimation or 0,
        fall = desc.FallAnimation or 0,
        swim = desc.SwimAnimation or 0,
        climb = desc.ClimbAnimation or 0,
    }
    
    local result = {
        RigType = humanoid.RigType.Name,
        Colors = {
            Head = desc.HeadColor:ToHex(),
            Torso = desc.TorsoColor:ToHex(),
            LeftArm = desc.LeftArmColor:ToHex(),
            RightArm = desc.RightArmColor:ToHex(),
            LeftLeg = desc.LeftLegColor:ToHex(),
            RightLeg = desc.RightLegColor:ToHex(),
        },
        Clothing = {Shirt = desc.Shirt, Pants = desc.Pants},
        Accessories = {Other = otherAcc},
        Scales = {
            Height = desc.HeightScale,
            Width = desc.WidthScale,
            Head = desc.HeadScale,
            Depth = desc.DepthScale,
            Proportion = desc.ProportionScale,
            BodyType = desc.BodyTypeScale,
        },
        Body = {
            Head = desc.Head,
            Torso = desc.Torso,
            LeftArm = desc.LeftArm,
            RightArm = desc.RightArm,
            LeftLeg = desc.LeftLeg,
            RightLeg = desc.RightLeg,
            Face = desc.Face,
        },
        Animations = animations
    }
    
    log(("Done • %d acc"):format(#otherAcc))
    return result
end

local function processRequest(requestId, data, requesterUserId)
    isProcessing = true
    
    local result
    if data.code then
        result = processSingleOutfit(data.code, requesterUserId)
        task.wait(0.8)
        forceResetCharacter()
    elseif data.codes and typeof(data.codes) == "table" and #data.codes > 0 then
        result = {}
        for i, hexCode in ipairs(data.codes) do
            local single = processSingleOutfit(hexCode, requesterUserId)
            result["outfit"..i] = single
            task.wait(1.2)  -- delay between outfits
        end
        task.wait(0.6)
        forceResetCharacter()  -- only reset once at end
    else
        result = {error = "Invalid request format"}
    end
    
    sendResult(requestId, result)
    task.wait(0.4)
    isProcessing = false
end

-- ────────────────────────────────────────────────
--   MAIN WORKER LOOP (updated with claiming)
-- ────────────────────────────────────────────────
task.spawn(function()
    if not refreshAuthToken() then
        log("Initial authentication failed → stopping")
        return
    end
    
    log("Listener active • poll: "..POLL_INTERVAL.."s • multi-worker mode • claimedBy locking")
    
    while active do
        if isProcessing then
            RunService.Heartbeat:Wait()
            continue
        end
        
        local t = tick()
        local requests = getRequests() or {}
        
        for id, data in pairs(requests) do
            if (data.code or (data.codes and #data.codes > 0))
               and not data.result
               and not data.processing
               and not data.claimedBy then   -- only consider unclaimed
                
                if tryClaim(id) then
                    task.spawn(processRequest, id, data, data.userId)
                    break  -- one request per loop per worker
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
        log("Anti-AFK kick")
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        task.wait(285 + math.random(0, 30))
    end
end)

log("CAC ready • multi-worker • 2026")

