-- ══════════════════════════════════════════════════════════════════════════════
--   CAC Firebase Outfit Fetcher – 2026 Speed & Clean Edition
-- ══════════════════════════════════════════════════════════════════════════════

-- Services
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local HttpService         = game:GetService("HttpService")
local VirtualUser         = game:GetService("VirtualUser")
local RunService          = game:GetService("RunService")

local Player              = Players.LocalPlayer
local PlayerGui           = Player:WaitForChild("PlayerGui", 8)

-- Config ──────────────────────────────────────────────────────────────
local FIREBASE_URL        = "https://cacc-c57bf-default-rtdb.firebaseio.com"
local API_KEY             = "AIzaSyBquxKffIm2lBtpi90GLLDdrQG_0yvlo4Y"

local POLL_INTERVAL       = 0.45      -- was 0.8
local AUTH_REFRESH_MARGIN = 300       -- refresh 5 min before expiry
local MAX_LOG_LINES       = 120

-- Remotes
local CommunityRemote     = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote", 8)
local CatalogGuiRemote    = ReplicatedStorage:WaitForChild("CatalogGuiRemote", 8)
local UpdateStatusRemote  = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UpdatePlayerStatus", 5)

-- Globals
local active              = true
local isProcessing        = false
local currentIdToken      = nil
local tokenExpiresAt      = 0

-- ─────────────────────────────────────────────────────────────────────────────

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
    logBox.Text = "[CAC] Logger started • "..os.date("%H:%M:%S")

    local function addLine(msg)
        print("[CAC]", msg)
        if not logBox.Parent then return end

        logBox.Text ..= "\n" .. msg
        local lines = logBox.Text:split("\n")
        if #lines > MAX_LOG_LINES then
            logBox.Text = table.concat(lines, "\n", #lines - MAX_LOG_LINES + 1)
        end
    end

    -- Minimalistic kill button
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

-- ─────────────────────────────────────────────────────────────────────────────
--                               HTTP + Auth
-- ─────────────────────────────────────────────────────────────────────────────

local request_impl = (syn and syn.request)
                   or (http and http.request)
                   or (request or game.HttpService.HttpRequestAsync)

local function http_req(method, url, body)
    if not request_impl then return nil end

    local success, response = pcall(request_impl, {
        Url = url,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "Roblox/WinInet"
        },
        Body = body and HttpService:JSONEncode(body) or nil
    })

    if not success or not response then return nil end
    if response.StatusCode < 200 or response.StatusCode > 299 then
        return nil
    end

    local ok, json = pcall(HttpService.JSONDecode, HttpService, response.Body)
    return ok and json or nil
end

local function refreshAuthToken()
    log("Refreshing Firebase token...")

    local data = http_req("POST",
        "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key="..API_KEY,
        { returnSecureToken = true }
    )

    if not data or not data.idToken then
        log("Firebase auth failed")
        return false
    end

    currentIdToken = data.idToken
    tokenExpiresAt = tick() + (data.expiresIn or 3600) - AUTH_REFRESH_MARGIN
    log("Token refreshed")
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────

local function getRequests()
    if tick() > tokenExpiresAt then
        if not refreshAuthToken() then return {} end
    end

    return http_req("GET", FIREBASE_URL.."/requests.json?auth="..currentIdToken) or {}
end

local function patch(requestId, data)
    local url = FIREBASE_URL..("/requests/%s.json?auth=%s"):format(requestId, currentIdToken)

    if not http_req("PATCH", url, data) then
        -- one retry with fresh token
        if refreshAuthToken() then
            http_req("PATCH", url, data)
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────

local function sendResult(id, payload)      patch(id, {result = payload}) end
local function markProcessing(id, v)        patch(id, {processing = v}) end

local function forceResetCharacter()
    pcall(function()
        CatalogGuiRemote:InvokeServer({
            Action = "MorphIntoPlayer",
            UserId = Player.UserId,
            RigType = Enum.HumanoidRigType.R15
        })
        UpdateStatusRemote:FireServer("None")
    end)
    log("Character reset")
end

-- ─────────────────────────────────────────────────────────────────────────────
--                             Core Request Handler
-- ─────────────────────────────────────────────────────────────────────────────

local function processRequest(requestId, hexCode)
    isProcessing = true
    markProcessing(requestId, true)

    local code = tonumber(hexCode, 16)
    if not code then
        sendResult(requestId, {error = "Invalid outfit code"})
        isProcessing = false
        return
    end

    local reqData = http_req("GET", ("%s/requests/%s.json?auth=%s"):format(FIREBASE_URL, requestId, currentIdToken))
    local requester = reqData and reqData.userId or "?"

    log(("Handling %s • user: %s • code: %d"):format(requestId, requester, code))

    local success, outfit = pcall(CommunityRemote.InvokeServer, CommunityRemote, {
        Action = "GetFromOutfitCode",
        OutfitCode = code
    })

    if not success or not outfit then
        sendResult(requestId, {error = "Failed to fetch outfit data"})
        isProcessing = false
        return
    end

    local ok = pcall(CommunityRemote.InvokeServer, CommunityRemote, {
        Action = "WearCommunityOutfit",
        OutfitInfo = outfit
    })

    if not ok then
        sendResult(requestId, {error = "Failed to wear outfit"})
        isProcessing = false
        return
    end

    -- Wait for humanoid & description (more reliable way)
    local char = Player.Character or Player.CharacterAdded:Wait()
    local humanoid = char:WaitForChild("Humanoid", 4)
    if not humanoid then
        sendResult(requestId, {error = "Humanoid not found"})
        isProcessing = false
        return
    end

    local desc = humanoid:WaitForChild("HumanoidDescription", 3.5)
    if not desc then
        sendResult(requestId, {error = "No HumanoidDescription"})
        isProcessing = false
        return
    end

    -- ── Build result (same structure as before) ──────────────────────────────

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
            Head      = desc.HeadColor:ToHex(),
            Torso     = desc.TorsoColor:ToHex(),
            LeftArm   = desc.LeftArmColor:ToHex(),
            RightArm  = desc.RightArmColor:ToHex(),
            LeftLeg   = desc.LeftLegColor:ToHex(),
            RightLeg  = desc.RightLegColor:ToHex(),
        },
        Clothing = {
            Shirt = desc.Shirt,
            Pants = desc.Pants,
        },
        Accessories = { Other = otherAcc },
        Scales = {
            Height     = desc.HeightScale,
            Width      = desc.WidthScale,
            Head       = desc.HeadScale,
            Depth      = desc.DepthScale,
            Proportion = desc.ProportionScale,
            BodyType   = desc.BodyTypeScale,
        },
        Body = {
            Head      = desc.Head,
            Torso     = desc.Torso,
            LeftArm   = desc.LeftArm,
            RightArm  = desc.RightArm,
            LeftLeg   = desc.LeftLeg,
            RightLeg  = desc.RightLeg,
            Face      = desc.Face,
        }
    }

    sendResult(requestId, result)
    log(("Completed • %d accessories"):format(#otherAcc))

    task.delay(1.4, function()
        forceResetCharacter()
        isProcessing = false
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
--                                 Main Loop
-- ─────────────────────────────────────────────────────────────────────────────

task.spawn(function()
    if not refreshAuthToken() then
        log("Initial authentication failed → stopping")
        return
    end

    log("Listener active • poll: "..POLL_INTERVAL.."s")

    while active do
        if isProcessing then
            RunService.Heartbeat:Wait()
            continue
        end

        local t = tick()
        local requests = getRequests()

        for id, data in pairs(requests) do
            if data.code and not data.result and not data.processing then
                task.spawn(processRequest, id, data.code)
                break   -- process one request per cycle
            end
        end

        local elapsed = tick() - t
        if elapsed < POLL_INTERVAL then
            task.wait(POLL_INTERVAL - elapsed)
        end
    end
end)

-- Anti-AFK (slightly less aggressive)
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

log("CAC ready • v2026.01 clean+fast")

