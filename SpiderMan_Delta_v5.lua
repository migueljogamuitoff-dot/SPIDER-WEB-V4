--[[
SPIDER//WEB v5 - HUD de jogo, teia com balanço e montagem de traje
- HUD em portugues, arrastavel e adaptado para celular
- Teia visual, puxao, escalada local, arrancada, sentido-aranha
- Animacao procedural local (R6 e R15), sem depender de ID de animacao
- Tudo aqui e local. Nao prende jogadores nem concede autoridade no servidor.
Cole o arquivo completo no executor e execute. Se falhar, abra o console do executor e veja a mensagem [SPIDER//WEB].
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer
if not player then
    warn("[SPIDER//WEB] Players.LocalPlayer indisponivel neste ambiente.")
    return
end

-- Encerra uma versao anterior se voce executar o script de novo.
if type(_G.SpiderWebDeltaStop) == "function" then
    pcall(_G.SpiderWebDeltaStop)
end

local CONFIG = {
    MaxWebDistance = 180,
    MaxPullDistance = 210,
    WebCooldown = 0.35,
    PullCooldown = 0.8,
    DashCooldown = 1.0,
    ClimbSpeed = 15,
    ClimbWallDistance = 3.5,
    DashSpeed = 72,
    SoundEnabled = true,
    -- Se um som nao estiver disponivel na sua experiencia, ele e ignorado sem interromper o script.
    Sounds = {
        web = "rbxassetid://12222200",
        pull = "rbxassetid://9084017080",
        sense = "rbxassetid://9113420776",
    },
}

local C = {
    bg = Color3.fromRGB(8, 12, 24),
    panel = Color3.fromRGB(16, 24, 43),
    panel2 = Color3.fromRGB(24, 36, 59),
    red = Color3.fromRGB(255, 48, 72),
    redDark = Color3.fromRGB(137, 24, 46),
    blue = Color3.fromRGB(38, 174, 255),
    cyan = Color3.fromRGB(100, 238, 255),
    white = Color3.fromRGB(245, 250, 255),
    muted = Color3.fromRGB(153, 171, 197),
    green = Color3.fromRGB(66, 231, 163),
    yellow = Color3.fromRGB(255, 211, 83),
}

local alive = true
local climbing = false
local spiderMode = true
local spiderSense = false
local busy = {web = false, pull = false, dash = false}
local connections = {}
local tracked = {}
local currentGui, panel, effectsFolder
local currentHighlight, currentLight
local toastToken = 0
local actionName = "none"
local actionUntil = 0
local actionStarted = 0
local actionDuration = 0
local jointCache = {}
local currentCharacter
local activeSwing = nil
local suitEquipped = false
local suitBusy = false
local suitParts = {}
local suitOriginals = {}
local suitClothing = {}
local activeSuitCase = nil
local gameHudState, gameHudHealth, gameHudMomentum, gameHudSpeed

local function connect(signal, callback)
    local ok, conn = pcall(function() return signal:Connect(callback) end)
    if ok and conn then table.insert(connections, conn) end
    return conn
end

local function forget(object)
    if object then pcall(function() object:Destroy() end) end
end

local function track(object, lifetime)
    table.insert(tracked, object)
    if lifetime then pcall(function() Debris:AddItem(object, lifetime) end) end
    return object
end

local function tween(object, duration, goal, style, direction)
    if not object or not object.Parent then return end
    local ok, tw = pcall(function()
        local t = TweenService:Create(object, TweenInfo.new(duration or 0.2, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out), goal)
        t:Play()
        return t
    end)
    return ok and tw or nil
end

local function notify(message, accent)
    if not alive or not currentGui then return end
    local toast = currentGui:FindFirstChild("Toast")
    if not toast then return end
    local label = toast:FindFirstChild("Message")
    local stroke = toast:FindFirstChildOfClass("UIStroke")
    if not label then return end
    toastToken += 1
    local myToken = toastToken
    label.Text = tostring(message)
    label.TextColor3 = accent or C.white
    if stroke then stroke.Color = accent or C.blue end
    toast.Visible = true
    toast.Size = UDim2.fromOffset(276, 0)
    tween(toast, 0.22, {Size = UDim2.fromOffset(276, 38)}, Enum.EasingStyle.Back)
    task.delay(1.8, function()
        if alive and toast.Parent and myToken == toastToken then
            tween(toast, 0.15, {Size = UDim2.fromOffset(276, 0)}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        end
    end)
end

local function characterParts()
    local ch = player.Character
    if not ch then return nil, nil, nil end
    return ch, ch:FindFirstChildOfClass("Humanoid"), ch:FindFirstChild("HumanoidRootPart")
end

local function handPart(ch, right)
    if not ch then return nil end
    if right then
        return ch:FindFirstChild("RightHand") or ch:FindFirstChild("RightLowerArm") or ch:FindFirstChild("Right Arm") or ch:FindFirstChild("HumanoidRootPart")
    end
    return ch:FindFirstChild("LeftHand") or ch:FindFirstChild("LeftLowerArm") or ch:FindFirstChild("Left Arm") or ch:FindFirstChild("HumanoidRootPart")
end

local function getEffectsFolder()
    if effectsFolder and effectsFolder.Parent then return effectsFolder end
    effectsFolder = Instance.new("Folder")
    effectsFolder.Name = "SpiderWeb_LocalEffects"
    effectsFolder.Parent = Workspace
    return effectsFolder
end

local function playSound(kind, volume, playback)
    if not CONFIG.SoundEnabled then return end
    local id = CONFIG.Sounds[kind]
    if type(id) ~= "string" or id == "" then return end
    local sound
    local ok = pcall(function()
        sound = Instance.new("Sound")
        sound.Name = "SpiderWebSFX"
        sound.SoundId = id
        sound.Volume = volume or 0.35
        sound.PlaybackSpeed = playback or 1
        sound.Parent = SoundService
        sound:Play()
    end)
    if ok and sound then Debris:AddItem(sound, 5) else forget(sound) end
end

local function raycastCamera(distance)
    local camera = Workspace.CurrentCamera
    if not camera then return nil end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ch = player.Character
    params.FilterDescendantsInstances = ch and {ch} or {}
    params.IgnoreWater = true
    return Workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * (distance or CONFIG.MaxWebDistance), params)
end

local function targetIsCharacter(part)
    if not part then return false end
    local model = part:FindFirstAncestorOfClass("Model")
    return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function burst(position, color, amount)
    local part = Instance.new("Part")
    part.Name = "SpiderWeb_FXPoint"
    part.Size = Vector3.new(0.12, 0.12, 0.12)
    part.Transparency = 1
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CFrame = CFrame.new(position)
    part.Parent = getEffectsFolder()
    track(part, 1.4)
    local att = Instance.new("Attachment")
    att.Parent = part
    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "SpiderWeb_Sparks"
    emitter.Texture = "rbxassetid://243660364"
    emitter.Color = ColorSequence.new(color or C.cyan, C.white)
    emitter.LightEmission = 0.85
    emitter.Lifetime = NumberRange.new(0.18, 0.42)
    emitter.Speed = NumberRange.new(5, 12)
    emitter.SpreadAngle = Vector2.new(180, 180)
    emitter.Rotation = NumberRange.new(0, 360)
    emitter.RotSpeed = NumberRange.new(-120, 120)
    emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.16), NumberSequenceKeypoint.new(1, 0)})
    emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1)})
    emitter.Parent = att
    pcall(function() emitter:Emit(amount or 16) end)
    track(emitter, 1)
    local orb = Instance.new("Part")
    orb.Name = "SpiderWeb_Impact"
    orb.Shape = Enum.PartType.Ball
    orb.Material = Enum.Material.Neon
    orb.Color = color or C.cyan
    orb.Size = Vector3.new(0.25, 0.25, 0.25)
    orb.Transparency = 0.06
    orb.Anchored = true
    orb.CanCollide = false
    orb.CanTouch = false
    orb.CanQuery = false
    orb.CFrame = CFrame.new(position)
    orb.Parent = getEffectsFolder()
    track(orb, 0.5)
    tween(orb, 0.28, {Size = Vector3.new(2.8, 2.8, 2.8), Transparency = 1}, Enum.EasingStyle.Quad)
end

local function webLine(destination, lifetime, curve)
    local ch = player.Character
    local hand = handPart(ch, true)
    if not hand or not hand:IsA("BasePart") then return false end
    local life = lifetime or 1.6
    local endPart = Instance.new("Part")
    endPart.Name = "SpiderWeb_LineEnd"
    endPart.Size = Vector3.new(0.08, 0.08, 0.08)
    endPart.Transparency = 1
    endPart.Anchored = true
    endPart.CanCollide = false
    endPart.CanTouch = false
    endPart.CanQuery = false
    endPart.CFrame = CFrame.new(hand.Position)
    endPart.Parent = getEffectsFolder()
    track(endPart, life)

    local a0 = Instance.new("Attachment")
    a0.Name = "SpiderWeb_Wrist"
    a0.Position = Vector3.new(0, -0.1, -0.22)
    a0.Parent = hand
    track(a0, life)
    local a1 = Instance.new("Attachment")
    a1.Name = "SpiderWeb_Tip"
    a1.Parent = endPart
    track(a1, life)

    local bend = math.clamp(curve or (destination - hand.Position).Magnitude * 0.08, 2, 10)
    local glow = Instance.new("Beam")
    glow.Name = "SpiderWeb_Glow"
    glow.Attachment0 = a0
    glow.Attachment1 = a1
    glow.FaceCamera = true
    glow.Width0 = 0.22
    glow.Width1 = 0.09
    glow.LightEmission = 1
    glow.LightInfluence = 0
    glow.Segments = 28
    glow.CurveSize0 = bend
    glow.CurveSize1 = -bend
    glow.Color = ColorSequence.new(C.blue, C.cyan)
    glow.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.56), NumberSequenceKeypoint.new(1, 0.84)})
    glow.Parent = getEffectsFolder()
    track(glow, life)

    local beam = Instance.new("Beam")
    beam.Name = "SpiderWeb_BraidedFilament"
    beam.Attachment0 = a0
    beam.Attachment1 = a1
    beam.FaceCamera = true
    beam.Width0 = 0.085
    beam.Width1 = 0.027
    beam.LightEmission = 1
    beam.LightInfluence = 0
    beam.Segments = 28
    beam.CurveSize0 = bend
    beam.CurveSize1 = -bend
    beam.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, C.white), ColorSequenceKeypoint.new(0.55, Color3.fromRGB(223, 250, 255)), ColorSequenceKeypoint.new(1, C.cyan)})
    beam.Transparency = NumberSequence.new(0.04)
    beam.Parent = getEffectsFolder()
    track(beam, life)

    tween(endPart, 0.16, {CFrame = CFrame.new(destination)}, Enum.EasingStyle.Quint)
    task.delay(0.16, function()
        if alive and endPart.Parent then burst(destination, C.cyan, 18) end
    end)
    return true
end

-- Animacao procedural: nao precisa de IDs publicados. E um estilo local aproximado, nao um pacote oficial do catalogo.
local function refreshJoints(ch)
    jointCache = {}
    if not ch then return end
    for _, obj in ipairs(ch:GetDescendants()) do
        if obj:IsA("Motor6D") then
            local key = string.lower(obj.Name):gsub("%s+", "")
            jointCache[key] = obj
        end
    end
    currentCharacter = ch
end

local function motor(keys)
    for _, key in ipairs(keys) do
        if jointCache[key] then return jointCache[key] end
    end
    return nil
end

local function pose(name, cf)
    local m = motor({name})
    if m then pcall(function() m.Transform = cf end) end
end

local function setSpiderAction(name, duration)
    actionName = name
    actionStarted = os.clock()
    actionDuration = duration or 0.45
    actionUntil = actionStarted + actionDuration
end

local function animateSpider(dt)
    if not alive or not spiderMode then return end
    local ch, humanoid, root = characterParts()
    if not ch or not humanoid or not root or humanoid.Health <= 0 then return end
    if ch ~= currentCharacter then refreshJoints(ch) end

    -- O Animate nativo do avatar continua controlando andar, correr, pular e cair.
    -- Aqui só adicionamos poses curtas por cima de ações, sem zerar as juntas todo frame.
    local t = os.clock()
    if actionName == "none" or t >= actionUntil then
        actionName = "none"
        return
    end

    if actionName == "web" then
        local shoulder = motor({"rightshoulder"})
        local elbow = motor({"rightelbow"})
        local waist = motor({"waist"})
        if shoulder then shoulder.Transform = shoulder.Transform * CFrame.Angles(math.rad(-62), math.rad(5), math.rad(18)) end
        if elbow then elbow.Transform = elbow.Transform * CFrame.Angles(math.rad(-30), 0, 0) end
        if waist then waist.Transform = waist.Transform * CFrame.Angles(math.rad(-5), math.rad(7), 0) end
    elseif actionName == "dash" then
        local rootJoint = motor({"rootjoint", "root"})
        local right = motor({"rightshoulder"})
        local left = motor({"leftshoulder"})
        if rootJoint then rootJoint.Transform = rootJoint.Transform * CFrame.Angles(math.rad(-18), 0, 0) end
        if right then right.Transform = right.Transform * CFrame.Angles(math.rad(-38), 0, math.rad(22)) end
        if left then left.Transform = left.Transform * CFrame.Angles(math.rad(-38), 0, math.rad(-22)) end
    elseif actionName == "flip" then
        local rootJoint = motor({"rootjoint", "root"})
        local progress = math.clamp((t - actionStarted) / math.max(actionDuration, 0.01), 0, 1)
        if rootJoint then rootJoint.Transform = rootJoint.Transform * CFrame.Angles(math.rad(360 * progress), 0, 0) end
        local right = motor({"rightshoulder"})
        local left = motor({"leftshoulder"})
        if right then right.Transform = right.Transform * CFrame.Angles(math.rad(-92), 0, math.rad(18)) end
        if left then left.Transform = left.Transform * CFrame.Angles(math.rad(-92), 0, math.rad(-18)) end
    elseif actionName == "suit" then
        local right = motor({"rightshoulder"})
        local left = motor({"leftshoulder"})
        if right then right.Transform = right.Transform * CFrame.Angles(math.rad(-40), 0, math.rad(18)) end
        if left then left.Transform = left.Transform * CFrame.Angles(math.rad(-40), 0, math.rad(-18)) end
    end
end

-- HUD ---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "SpiderWebDeltaV3"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 99999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local guiParented = false
-- Diferentes executores oferecem diferentes pais para a interface. Testa sem travar o script.
if type(gethui) == "function" then
    local ok, hidden = pcall(gethui)
    if ok and hidden then guiParented = pcall(function() gui.Parent = hidden end) and gui.Parent ~= nil end
end
if not guiParented then guiParented = pcall(function() gui.Parent = CoreGui end) and gui.Parent ~= nil end
if not guiParented then
    local ok, pg = pcall(function() return player:WaitForChild("PlayerGui", 8) end)
    if ok and pg then guiParented = pcall(function() gui.Parent = pg end) and gui.Parent ~= nil end
end
if not guiParented then
    warn("[SPIDER//WEB] Nao consegui criar a interface. Seu executor pode bloquear ScreenGui; tente executar novamente dentro de uma partida.")
    return
end
currentGui = gui

local function create(className, props, parent)
    local obj = Instance.new(className)
    for prop, value in pairs(props or {}) do pcall(function() obj[prop] = value end) end
    obj.Parent = parent
    return obj
end

-- HUD de jogo sempre visivel: estado, vida e impulso.
local gameHud = create("Frame", {Name = "SpiderGameHUD", Position = UDim2.new(0.5, -119, 0, 8), Size = UDim2.fromOffset(238, 82), BackgroundColor3 = C.bg, BackgroundTransparency = 0.08, BorderSizePixel = 0}, gui)
create("UICorner", {CornerRadius = UDim.new(0, 13)}, gameHud)
create("UIStroke", {Color = C.blue, Thickness = 1.2, Transparency = 0.18}, gameHud)
create("UIGradient", {Color = ColorSequence.new(Color3.fromRGB(26, 37, 61), Color3.fromRGB(10, 14, 27)), Rotation = 20}, gameHud)
local hudLogo = create("Frame", {Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(31, 31), BackgroundColor3 = C.red, BorderSizePixel = 0}, gameHud)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, hudLogo)
create("UIGradient", {Color = ColorSequence.new(C.red, C.blue), Rotation = 35}, hudLogo)
create("TextLabel", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "S", Font = Enum.Font.GothamBlack, TextSize = 20, TextColor3 = C.white}, hudLogo)
create("TextLabel", {Position = UDim2.fromOffset(49, 8), Size = UDim2.new(1, -60, 0, 19), BackgroundTransparency = 1, Text = "SPIDER//WEB", Font = Enum.Font.GothamBlack, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.white}, gameHud)
gameHudState = create("TextLabel", {Position = UDim2.fromOffset(49, 27), Size = UDim2.new(1, -60, 0, 14), BackgroundTransparency = 1, Text = "SISTEMA ARACNÍDEO ONLINE", Font = Enum.Font.GothamMedium, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.green}, gameHud)
local hpBack = create("Frame", {Position = UDim2.fromOffset(11, 49), Size = UDim2.new(1, -22, 0, 7), BackgroundColor3 = Color3.fromRGB(43, 52, 69), BorderSizePixel = 0}, gameHud)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, hpBack)
gameHudHealth = create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.green, BorderSizePixel = 0}, hpBack)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, gameHudHealth)
local momentumBack = create("Frame", {Position = UDim2.fromOffset(11, 65), Size = UDim2.new(1, -56, 0, 5), BackgroundColor3 = Color3.fromRGB(43, 52, 69), BorderSizePixel = 0}, gameHud)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, momentumBack)
gameHudMomentum = create("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.cyan, BorderSizePixel = 0}, momentumBack)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, gameHudMomentum)
gameHudSpeed = create("TextLabel", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0, 67), Size = UDim2.fromOffset(39, 14), BackgroundTransparency = 1, Text = "000", Font = Enum.Font.GothamBlack, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.cyan}, gameHud)

panel = create("Frame", {
    Name = "HUD", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -92),
    Size = UDim2.fromOffset(292, 488), BackgroundColor3 = C.bg, BackgroundTransparency = 0.035,
    BorderSizePixel = 0, ClipsDescendants = true,
}, gui)
local pc = create("UICorner", {CornerRadius = UDim.new(0, 17)}, panel)
local ps = create("UIStroke", {Color = C.blue, Thickness = 1.4, Transparency = 0.12}, panel)
create("UIGradient", {Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(21, 32, 57)), ColorSequenceKeypoint.new(0.62, C.bg), ColorSequenceKeypoint.new(1, Color3.fromRGB(36, 13, 32))}), Rotation = 25}, panel)
local uiScale = create("UIScale", {Scale = 0.94}, panel)
tween(uiScale, 0.35, {Scale = 1}, Enum.EasingStyle.Back)

local header = create("Frame", {Name = "Header", Size = UDim2.new(1, 0, 0, 61), BackgroundColor3 = C.panel2, BorderSizePixel = 0}, panel)
create("UICorner", {CornerRadius = UDim.new(0, 17)}, header)
create("UIGradient", {Color = ColorSequence.new(C.redDark, Color3.fromRGB(16, 69, 111)), Rotation = 4}, header)
local logo = create("Frame", {Size = UDim2.fromOffset(37, 37), Position = UDim2.fromOffset(11, 12), BackgroundColor3 = C.red, BorderSizePixel = 0}, header)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, logo)
create("UIGradient", {Color = ColorSequence.new(C.red, C.blue), Rotation = 45}, logo)
create("TextLabel", {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "S", Font = Enum.Font.GothamBlack, TextSize = 24, TextColor3 = C.white}, logo)
create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(57, 8), Size = UDim2.new(1, -97, 0, 24), Text = "SPIDER//WEB", Font = Enum.Font.GothamBlack, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.white}, header)
create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(58, 32), Size = UDim2.new(1, -98, 0, 15), Text = "MODO ARANHA  •  V5.0", Font = Enum.Font.GothamMedium, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(208, 225, 245)}, header)
local minimize = create("TextButton", {Name = "Recolher", Position = UDim2.new(1, -37, 0, 17), Size = UDim2.fromOffset(27, 27), Text = "—", Font = Enum.Font.GothamBlack, TextSize = 15, TextColor3 = C.white, BackgroundColor3 = C.white, BackgroundTransparency = 0.85, BorderSizePixel = 0, AutoButtonColor = false}, header)
create("UICorner", {CornerRadius = UDim.new(0, 8)}, minimize)

local statusDot = create("Frame", {Position = UDim2.fromOffset(13, 70), Size = UDim2.fromOffset(7, 7), BackgroundColor3 = C.green, BorderSizePixel = 0}, panel)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, statusDot)
local status = create("TextLabel", {Name = "Status", BackgroundTransparency = 1, Position = UDim2.fromOffset(25, 65), Size = UDim2.new(1, -35, 0, 17), Text = "ATIVO  •  EFEITOS LOCAIS", Font = Enum.Font.GothamBold, TextSize = 9, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.green}, panel)
create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 85), Size = UDim2.new(1, -24, 0, 14), Text = "HABILIDADES ARACNÍDEAS", Font = Enum.Font.GothamBold, TextSize = 9, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.muted}, panel)

local scroll = create("ScrollingFrame", {Name = "Habilidades", Position = UDim2.fromOffset(9, 103), Size = UDim2.new(1, -18, 0, 327), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = C.blue, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y}, panel)
create("UIListLayout", {Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder}, scroll)
create("UIPadding", {PaddingBottom = UDim.new(0, 5), PaddingLeft = UDim.new(0, 1), PaddingRight = UDim.new(0, 3)}, scroll)
local footer = create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.new(0, 11, 1, -35), Size = UDim2.new(1, -55, 0, 20), Text = "ANIMAÇÕES NATIVAS + EFEITOS LOCAIS", Font = Enum.Font.GothamMedium, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.muted}, panel)
local close = create("TextButton", {Name = "Fechar", Position = UDim2.new(1, -40, 1, -39), Size = UDim2.fromOffset(29, 29), Text = "×", Font = Enum.Font.GothamBlack, TextSize = 20, TextColor3 = C.white, BackgroundColor3 = C.redDark, BorderSizePixel = 0, AutoButtonColor = false}, panel)
create("UICorner", {CornerRadius = UDim.new(0, 8)}, close)

local toast = create("Frame", {Name = "Toast", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 100), Size = UDim2.fromOffset(276, 0), BackgroundColor3 = C.panel, BackgroundTransparency = 0.03, BorderSizePixel = 0, ClipsDescendants = true, Visible = true}, gui)
create("UICorner", {CornerRadius = UDim.new(0, 11)}, toast)
create("UIStroke", {Color = C.blue, Thickness = 1.2, Transparency = 0.12}, toast)
create("TextLabel", {Name = "Message", BackgroundTransparency = 1, Position = UDim2.fromOffset(9, 0), Size = UDim2.new(1, -18, 1, 0), Text = "SISTEMA ARACNÍDEO PRONTO", Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.white}, toast)

local buttons = {}
local function makeButton(key, icon, titleText, detail, accent, order)
    local b = create("TextButton", {Name = key, LayoutOrder = order, Size = UDim2.new(1, -2, 0, 44), BackgroundColor3 = C.panel2, BackgroundTransparency = 0.08, BorderSizePixel = 0, Text = "", AutoButtonColor = false, ClipsDescendants = true}, scroll)
    create("UICorner", {CornerRadius = UDim.new(0, 10)}, b)
    local stroke = create("UIStroke", {Color = accent, Thickness = 1, Transparency = 0.64}, b)
    local stripe = create("Frame", {Position = UDim2.fromOffset(0, 6), Size = UDim2.new(0, 3, 1, -12), BackgroundColor3 = accent, BorderSizePixel = 0}, b)
    create("UICorner", {CornerRadius = UDim.new(1, 0)}, stripe)
    create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 1), Size = UDim2.fromOffset(28, 42), Text = icon, Font = Enum.Font.GothamBlack, TextSize = 19, TextColor3 = accent}, b)
    local title = create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(40, 5), Size = UDim2.new(1, -79, 0, 17), Text = titleText, Font = Enum.Font.GothamBold, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.white}, b)
    local desc = create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(40, 22), Size = UDim2.new(1, -79, 0, 14), Text = detail, Font = Enum.Font.GothamMedium, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.muted}, b)
    local badge = create("TextLabel", {AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -7, 0.5, 0), Size = UDim2.fromOffset(25, 21), BackgroundColor3 = accent, BackgroundTransparency = 0.82, BorderSizePixel = 0, Text = "›", Font = Enum.Font.GothamBlack, TextSize = 10, TextColor3 = C.white}, b)
    create("UICorner", {CornerRadius = UDim.new(0, 6)}, badge)
    connect(b.Activated, function()
        if not alive then return end
        tween(b, 0.07, {BackgroundColor3 = accent, BackgroundTransparency = 0.01})
        task.delay(0.09, function() if b.Parent then tween(b, 0.15, {BackgroundColor3 = C.panel2, BackgroundTransparency = 0.08}) end end)
    end)
    buttons[key] = {button = b, title = title, detail = desc, badge = badge, stroke = stroke, accent = accent}
    return b
end

local bWeb = makeButton("Web", "🕸", "BALANÇO DE TEIA", "Mire numa superfície e se lance", C.blue, 1)
local bPull = makeButton("Pull", "⚡", "PUXÃO DE TEIA", "Impulso em direcao a superficie", C.red, 2)
local bClimb = makeButton("Climb", "↟", "ESCALAR PAREDE", "Ligue e ande contra a parede", C.cyan, 3)
local bMode = makeButton("Mode", "✦", "POSES DE AÇÃO: ON", "Mantém andar/pular do Roblox", C.red, 4)
local bSense = makeButton("Sense", "◉", "SENTIDO-ARANHA", "Aura e pulso de energia", C.yellow, 5)
local bDash = makeButton("Dash", "➤", "ARRANCADA ARANHA", "Avanco rapido com rastro", C.red, 6)
local bClear = makeButton("Clear", "✧", "LIMPAR EFEITOS", "Desliga aura e escalada", C.muted, 7)
local bSuit = makeButton("Suit", "⬡", "EQUIPAR TRAJE", "Mala + montagem peça por peça", C.red, 8)

-- Arrastar o painel pela barra superior: toque ou mouse.
do
    local dragging, dragStart, panelStart = false, nil, nil
    connect(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            panelStart = panel.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if not alive or not dragging or not dragStart or not panelStart then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            panel.Position = UDim2.new(panelStart.X.Scale, panelStart.X.Offset + delta.X, panelStart.Y.Scale, panelStart.Y.Offset + delta.Y)
        end
    end)
end

local expanded = true
connect(minimize.Activated, function()
    expanded = not expanded
    minimize.Text = expanded and "—" or "+"
    scroll.Visible = expanded
    statusDot.Visible = expanded
    status.Visible = expanded
    footer.Visible = expanded
    close.Visible = expanded
    tween(panel, 0.23, {Size = expanded and UDim2.fromOffset(292, 488) or UDim2.fromOffset(292, 62)})
end)

local function stopSwing()
    local swing = activeSwing
    if not swing then return end
    activeSwing = nil
    forget(swing.constraint)
    forget(swing.rootAttachment)
    forget(swing.anchorAttachment)
    forget(swing.anchor)
end

local function shootWeb()
    if not alive then return end
    if activeSwing then
        stopSwing()
        notify("TEIA SOLTA", C.muted)
        return
    end
    if busy.web then return end
    busy.web = true
    task.delay(CONFIG.WebCooldown, function() busy.web = false end)
    local ch, hum, root = characterParts()
    local cam = Workspace.CurrentCamera
    if not ch or not hum or not root or hum.Health <= 0 or not cam then notify("PERSONAGEM NAO DISPONIVEL", C.red); return end
    if hum.FloorMaterial ~= Enum.Material.Air and hum.MoveDirection.Magnitude < 0.05 then
        notify("PULE OU CORRA ANTES DE BALANÇAR", C.yellow)
    end
    local hit = raycastCamera(CONFIG.MaxWebDistance)
    if not hit or targetIsCharacter(hit.Instance) then
        notify("MIRE NUM TELHADO OU NUMA PAREDE", C.yellow)
        playSound("web", 0.22, 1.25)
        return
    end
    local distance = (hit.Position - root.Position).Magnitude
    if not webLine(hit.Position, 1.75, math.clamp(distance * 0.075, 2, 10)) then
        notify("NAO ENCONTREI A MAO DO PERSONAGEM", C.red)
        return
    end
    local anchor = Instance.new("Part")
    anchor.Name = "SpiderSwing_Anchor"
    anchor.Size = Vector3.new(0.12, 0.12, 0.12)
    anchor.Transparency = 1
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanTouch = false
    anchor.CanQuery = false
    anchor.CFrame = CFrame.new(hit.Position)
    anchor.Parent = getEffectsFolder()
    local anchorAttachment = Instance.new("Attachment")
    anchorAttachment.Name = "SpiderSwing_AnchorAttachment"
    anchorAttachment.Parent = anchor
    local rootAttachment = Instance.new("Attachment")
    rootAttachment.Name = "SpiderSwing_RootAttachment"
    rootAttachment.Position = Vector3.new(0, 0.7, 0)
    rootAttachment.Parent = root
    local rope = Instance.new("RopeConstraint")
    rope.Name = "SpiderSwing_RopePhysics"
    rope.Attachment0 = rootAttachment
    rope.Attachment1 = anchorAttachment
    rope.Length = math.max(5, distance - math.clamp(distance * 0.2, 2, 8))
    rope.Visible = false
    rope.Thickness = 0.05
    rope.Restitution = 0.08
    rope.Parent = root
    activeSwing = {anchor = anchor, anchorAttachment = anchorAttachment, rootAttachment = rootAttachment, constraint = rope}
    local currentSwing = activeSwing
    root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + cam.CFrame.LookVector * 27 + Vector3.new(0, 13, 0)
    setSpiderAction("web", 0.52)
    burst(hit.Position, C.cyan, 22)
    playSound("web", 0.42, 0.92)
    notify("BALANÇO ATIVO • TOQUE DE NOVO PARA SOLTAR", C.blue)
    task.delay(1.65, function()
        if activeSwing == currentSwing then stopSwing() end
    end)
end

local function pullWeb()
    if not alive or busy.pull then return end
    busy.pull = true
    task.delay(CONFIG.PullCooldown, function() busy.pull = false end)
    local ch, hum, root = characterParts()
    if not ch or not hum or not root or hum.Health <= 0 then notify("PERSONAGEM NAO DISPONIVEL", C.red); return end
    local hit = raycastCamera(CONFIG.MaxPullDistance)
    if not hit then notify("MIRE EM UMA SUPERFICIE SOLIDA", C.yellow); return end
    if targetIsCharacter(hit.Instance) then notify("MIRE EM UMA PAREDE, NAO EM UM JOGADOR", C.yellow); return end
    webLine(hit.Position, 1.35, 3)
    setSpiderAction("web", 0.48)
    playSound("pull", 0.4, 1.05)
    local offset = hit.Position - root.Position
    if offset.Magnitude > 4 then
        local speed = math.clamp(offset.Magnitude * 0.68, 38, 88)
        root.AssemblyLinearVelocity = offset.Unit * speed + Vector3.new(0, math.clamp(offset.Y * 0.12 + 10, 7, 22), 0)
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
    notify("PUXÃO DE TEIA!", C.red)
end

local function toggleClimb()
    climbing = not climbing
    local d = buttons.Climb
    d.title.Text = climbing and "ESCALADA: ATIVA" or "ESCALAR PAREDE"
    d.detail.Text = climbing and "Joystick + câmera para subir" or "Chegue perto e ligue a escalada"
    d.badge.Text = climbing and "ON" or "›"
    tween(d.stroke, 0.15, {Color = climbing and C.green or C.cyan, Transparency = climbing and 0.14 or 0.64})
    notify(climbing and "ESCALADA ATIVADA" or "ESCALADA DESATIVADA", climbing and C.green or C.muted)
end

local function toggleMode()
    spiderMode = not spiderMode
    -- Não zeramos Motor6D.Transform: o Animate oficial do Roblox continua dono das poses normais.
    local d = buttons.Mode
    d.title.Text = spiderMode and "ANIMAÇÃO ARANHA: ON" or "ANIMAÇÃO ARANHA: OFF"
    d.detail.Text = spiderMode and "Poses extras sem trocar o Animate" or "Animações padrão do jogo"
    d.badge.Text = spiderMode and "ON" or "OFF"
    tween(d.stroke, 0.15, {Color = spiderMode and C.red or C.muted, Transparency = spiderMode and 0.15 or 0.64})
    notify(spiderMode and "ESTILO DE MOVIMENTO ARANHA ATIVADO" or "ANIMACOES PADRAO RESTAURADAS", spiderMode and C.red or C.muted)
end

local function toggleSense()
    spiderSense = not spiderSense
    local ch, _, root = characterParts()
    if spiderSense and ch then
        forget(currentHighlight)
        currentHighlight = Instance.new("Highlight")
        currentHighlight.Name = "SpiderSense_Local"
        currentHighlight.Adornee = ch
        currentHighlight.FillColor = C.cyan
        currentHighlight.OutlineColor = C.yellow
        currentHighlight.FillTransparency = 0.78
        currentHighlight.OutlineTransparency = 0.05
        pcall(function() currentHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop end)
        currentHighlight.Parent = ch
        if root then
            forget(currentLight)
            currentLight = Instance.new("PointLight")
            currentLight.Name = "SpiderSense_Light"
            currentLight.Color = C.cyan
            currentLight.Range = 12
            currentLight.Brightness = 0.8
            currentLight.Parent = root
        end
        playSound("sense", 0.25, 1.15)
        notify("SENTIDO-ARANHA ATIVADO", C.yellow)
    else
        forget(currentHighlight); forget(currentLight)
        currentHighlight, currentLight = nil, nil
        notify("SENTIDO-ARANHA DESATIVADO", C.muted)
    end
    local d = buttons.Sense
    d.title.Text = spiderSense and "SENTIDO-ARANHA: ON" or "SENTIDO-ARANHA"
    d.detail.Text = spiderSense and "Aura ativa no seu personagem" or "Aura e pulso de energia"
    d.badge.Text = spiderSense and "ON" or "›"
    tween(d.stroke, 0.15, {Color = C.yellow, Transparency = spiderSense and 0.13 or 0.64})
end

local function dash()
    if not alive or busy.dash then return end
    busy.dash = true
    task.delay(CONFIG.DashCooldown, function() busy.dash = false end)
    local ch, hum, root = characterParts()
    local cam = Workspace.CurrentCamera
    if not ch or not hum or not root or hum.Health <= 0 or not cam then return end
    local look = cam.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude < 0.05 then flat = root.CFrame.LookVector end
    flat = flat.Unit
    root.AssemblyLinearVelocity = flat * CONFIG.DashSpeed + Vector3.new(0, math.max(root.AssemblyLinearVelocity.Y, 8), 0)
    setSpiderAction("dash", 0.42)
    local a0 = Instance.new("Attachment"); a0.Position = Vector3.new(-0.72, 0, 0.3); a0.Parent = root; track(a0, 0.55)
    local a1 = Instance.new("Attachment"); a1.Position = Vector3.new(0.72, 0, 0.3); a1.Parent = root; track(a1, 0.55)
    local trail = Instance.new("Trail")
    trail.Name = "SpiderDash_Trail"
    trail.Attachment0 = a0; trail.Attachment1 = a1
    trail.Color = ColorSequence.new(C.cyan, C.red)
    trail.LightEmission = 0.9
    trail.Lifetime = 0.28
    trail.MinLength = 0.05
    trail.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1)})
    trail.Parent = getEffectsFolder(); track(trail, 0.6)
    burst(root.Position - flat * 2, C.red, 10)
    playSound("web", 0.35, 1.4)
    notify("ARRANCADA ARANHA!", C.red)
end

local function clearEffects()
    climbing = false
    stopSwing()
    if spiderSense then
        spiderSense = false
        forget(currentHighlight); forget(currentLight)
        currentHighlight, currentLight = nil, nil
    end
    for _, object in ipairs(tracked) do forget(object) end
    table.clear(tracked)
    forget(effectsFolder); effectsFolder = nil
    local c = buttons.Climb
    c.title.Text = "ESCALAR PAREDE"; c.detail.Text = "Ligue e ande contra a parede"; c.badge.Text = "›"
    tween(c.stroke, 0.12, {Color = C.cyan, Transparency = 0.64})
    local s = buttons.Sense
    s.title.Text = "SENTIDO-ARANHA"; s.detail.Text = "Aura e pulso de energia"; s.badge.Text = "›"
    tween(s.stroke, 0.12, {Color = C.yellow, Transparency = 0.64})
    notify("EFEITOS LIMPOS", C.green)
end

local BODY_PART_NAMES = {
    head = true, torso = true, uppertorso = true, lowertorso = true,
    leftarm = true, rightarm = true, leftleg = true, rightleg = true,
    leftupperarm = true, rightupperarm = true, leftlowerarm = true, rightlowerarm = true,
    lefthand = true, righthand = true, leftupperleg = true, rightupperleg = true,
    leftlowerleg = true, rightlowerleg = true, leftfoot = true, rightfoot = true,
}

local function isSpiderBodyPart(obj)
    return obj and obj:IsA("BasePart") and BODY_PART_NAMES[string.lower(obj.Name):gsub("%s+", "")] == true
end

local function suitColorFor(partName)
    local n = string.lower(partName)
    if n:find("leg") or n:find("foot") or n == "lowertorso" then
        return Color3.fromRGB(22, 66, 166)
    end
    return Color3.fromRGB(191, 20, 40)
end

local function setSuitButton()
    local b = buttons.Suit
    if not b then return end
    b.title.Text = suitEquipped and "REMOVER TRAJE" or "EQUIPAR TRAJE"
    b.detail.Text = suitEquipped and "Voltar ao visual original" or "Mala + montagem peça por peça"
    b.badge.Text = suitEquipped and "ON" or "›"
    tween(b.stroke, 0.16, {Color = suitEquipped and C.green or C.red, Transparency = suitEquipped and 0.12 or 0.64})
end

local function makeWeldedDecalPart(parentCharacter, target, name, size, localOffset, color, localRotation)
    if not target or not target.Parent then return nil end
    local detail = Instance.new("Part")
    detail.Name = name
    detail.Size = size
    detail.Material = Enum.Material.SmoothPlastic
    detail.Color = color
    detail.Anchored = false
    detail.Massless = true
    detail.CanCollide = false
    detail.CanTouch = false
    detail.CanQuery = false
    detail.CFrame = target.CFrame * CFrame.new(localOffset) * (localRotation or CFrame.identity)
    detail.Parent = parentCharacter
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = detail
    weld.Part1 = target
    weld.Parent = detail
    table.insert(suitParts, detail)
    return detail
end

local function addSpiderEmblem(ch)
    local chest = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso") or ch:FindFirstChild("LowerTorso")
    if not chest or not chest:IsA("BasePart") then return end
    local z = -(chest.Size.Z / 2 + 0.035)
    local black = Color3.fromRGB(12, 14, 22)
    makeWeldedDecalPart(ch, chest, "SpiderSuit_EmblemBody", Vector3.new(0.11, 0.42, 0.045), Vector3.new(0, 0, z), black)
    for side = -1, 1, 2 do
        for i = 1, 2 do
            local y = 0.08 - (i - 1) * 0.16
            local x = side * (0.105 + (i - 1) * 0.055)
            local rot = CFrame.Angles(0, 0, math.rad(side * (28 + (i - 1) * 15)))
            makeWeldedDecalPart(ch, chest, "SpiderSuit_EmblemLeg", Vector3.new(0.065, 0.27, 0.04), Vector3.new(x, y, z - 0.005), black, rot)
        end
    end
end

local function addMaskEyes(ch)
    local head = ch:FindFirstChild("Head")
    if not head or not head:IsA("BasePart") then return end
    local z = -(head.Size.Z / 2 + 0.035)
    for side = -1, 1, 2 do
        local eye = makeWeldedDecalPart(ch, head, "SpiderSuit_MaskEye", Vector3.new(0.22, 0.105, 0.055), Vector3.new(side * 0.17, 0.06, z), Color3.fromRGB(241, 250, 255), CFrame.Angles(0, 0, math.rad(side * -16)))
        if eye then eye.Material = Enum.Material.Neon end
    end
end

local function restoreSuit(force)
    if not force and suitBusy then return end
    suitBusy = false
    for _, obj in ipairs(suitParts) do forget(obj) end
    suitParts = {}
    for part, saved in pairs(suitOriginals) do
        if part and part.Parent then
            pcall(function() part.Color = saved.Color; part.Material = saved.Material; part.Transparency = saved.Transparency end)
        end
    end
    suitOriginals = {}
    for _, saved in ipairs(suitClothing) do
        if saved.object and saved.object.Parent then pcall(function() saved.object[saved.property] = saved.value end) end
    end
    suitClothing = {}
    forget(activeSuitCase)
    activeSuitCase = nil
    suitEquipped = false
    setSuitButton()
end

local function createSuitCase(ch, hand)
    local caseModel = Instance.new("Model")
    caseModel.Name = "SpiderSuit_ThrowCase"
    caseModel.Parent = Workspace
    local body = Instance.new("Part")
    body.Name = "CaseBody"
    body.Size = Vector3.new(1.05, 0.72, 0.22)
    body.Color = Color3.fromRGB(20, 25, 36)
    body.Material = Enum.Material.Metal
    body.Anchored = true
    body.CanCollide = false; body.CanTouch = false; body.CanQuery = false
    body.Parent = caseModel
    caseModel.PrimaryPart = body
    local handle = Instance.new("Part")
    handle.Name = "Handle"
    handle.Size = Vector3.new(0.38, 0.075, 0.075)
    handle.Color = Color3.fromRGB(170, 182, 198)
    handle.Material = Enum.Material.Metal
    handle.Anchored = true
    handle.CanCollide = false; handle.CanTouch = false; handle.CanQuery = false
    handle.Parent = caseModel
    local stripe = Instance.new("Part")
    stripe.Name = "SpiderStripe"
    stripe.Size = Vector3.new(0.08, 0.68, 0.035)
    stripe.Color = C.red
    stripe.Material = Enum.Material.Neon
    stripe.Anchored = true
    stripe.CanCollide = false; stripe.CanTouch = false; stripe.CanQuery = false
    stripe.Parent = caseModel
    caseModel:PivotTo(hand.CFrame * CFrame.new(0, -0.18, -0.58) * CFrame.Angles(0, 0, math.rad(90)))
    local function syncDetails()
        local cf = body.CFrame
        handle.CFrame = cf * CFrame.new(0, 0.39, 0)
        stripe.CFrame = cf * CFrame.new(0, 0, -0.125)
    end
    syncDetails()
    return caseModel, body, syncDetails
end

local function equipSuitSequence()
    if suitBusy or suitEquipped then return end
    local ch, hum, root = characterParts()
    if not ch or not hum or not root or hum.Health <= 0 then notify("PERSONAGEM NAO DISPONIVEL", C.red); return end
    local hand = handPart(ch, true) or root
    suitBusy = true
    notify("TRAJE PREPARADO • ABRINDO MALETA", C.red)
    playSound("web", 0.35, 0.78)
    local caseModel, caseBody, syncDetails = createSuitCase(ch, hand)
    activeSuitCase = caseModel
    local following = true
    local followConn = RunService.RenderStepped:Connect(function()
        if following and caseModel.Parent and hand.Parent then
            caseModel:PivotTo(hand.CFrame * CFrame.new(0, -0.18, -0.58) * CFrame.Angles(0, 0, math.rad(90)))
            syncDetails()
        end
    end)
    task.wait(0.62)
    if not suitBusy or not ch.Parent or not root.Parent then
        pcall(function() followConn:Disconnect() end)
        forget(caseModel)
        if activeSuitCase == caseModel then activeSuitCase = nil end
        return
    end
    following = false
    pcall(function() followConn:Disconnect() end)
    local startPivot = caseModel:GetPivot()
    local tossTarget = root.Position + root.CFrame.LookVector * 5 + Vector3.new(0, 17, 0)
    local throwStart = os.clock()
    local throwDuration = 0.52
    while os.clock() - throwStart < throwDuration and suitBusy and caseModel.Parent do
        local alpha = math.clamp((os.clock() - throwStart) / throwDuration, 0, 1)
        local eased = 1 - (1 - alpha) ^ 3
        local position = startPivot.Position:Lerp(tossTarget, eased)
        caseModel:PivotTo(CFrame.new(position) * CFrame.Angles(math.rad(alpha * 180), math.rad(alpha * 520), math.rad(alpha * 85)))
        task.wait()
    end
    if not suitBusy or not ch.Parent then forget(caseModel); return end
    setSpiderAction("flip", 0.82)
    local oldAutoRotate = hum.AutoRotate
    hum.AutoRotate = false
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    root.AssemblyLinearVelocity = -root.CFrame.LookVector * 23 + Vector3.new(0, 35, 0)
    root.AssemblyAngularVelocity = root.CFrame.RightVector * 7.5
    task.delay(0.78, function()
        if root and root.Parent then root.AssemblyAngularVelocity = Vector3.zero end
        if hum and hum.Parent then hum.AutoRotate = oldAutoRotate end
    end)
    playSound("web", 0.42, 1.35)
    burst(root.Position, C.red, 26)
    notify("SALTO • MONTAGEM DO TRAJE", C.cyan)
    task.wait(0.28)
    local targets = {}
    for _, obj in ipairs(ch:GetChildren()) do
        if isSpiderBodyPart(obj) then table.insert(targets, obj) end
    end
    table.sort(targets, function(a, b)
        local function rank(p)
            local n = string.lower(p.Name)
            if n == "head" then return 1 end
            if n:find("torso") or n == "torso" then return 2 end
            if n:find("arm") or n:find("hand") then return 3 end
            return 4
        end
        return rank(a) < rank(b)
    end)
    local originals = {}
    for _, part in ipairs(targets) do
        if part and part.Parent then
            suitOriginals[part] = {Color = part.Color, Material = part.Material, Transparency = part.Transparency}
            table.insert(originals, part)
        end
    end
    for _, obj in ipairs(ch:GetChildren()) do
        if obj:IsA("Shirt") then
            table.insert(suitClothing, {object = obj, property = "ShirtTemplate", value = obj.ShirtTemplate})
            pcall(function() obj.ShirtTemplate = "" end)
        elseif obj:IsA("Pants") then
            table.insert(suitClothing, {object = obj, property = "PantsTemplate", value = obj.PantsTemplate})
            pcall(function() obj.PantsTemplate = "" end)
        elseif obj:IsA("ShirtGraphic") then
            table.insert(suitClothing, {object = obj, property = "Graphic", value = obj.Graphic})
            pcall(function() obj.Graphic = "" end)
        end
    end
    local function installPlate(part, index)
        task.spawn(function()
            task.wait((index - 1) * 0.085)
            if not suitBusy or not part.Parent or not ch.Parent then return end
            local plate = Instance.new("Part")
            plate.Name = "SpiderSuit_ArmorPlate"
            plate.Size = part.Size + Vector3.new(0.045, 0.045, 0.045)
            plate.Color = suitColorFor(part.Name)
            plate.Material = Enum.Material.SmoothPlastic
            plate.Transparency = 0.06
            plate.Anchored = true
            plate.Massless = true
            plate.CanCollide = false; plate.CanTouch = false; plate.CanQuery = false
            local targetCF = part.CFrame
            plate.CFrame = targetCF + Vector3.new(math.random(-4, 4), 15 + math.random(0, 4), math.random(-4, 4))
            plate.Parent = Workspace
            local flight = TweenService:Create(plate, TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {CFrame = targetCF})
            flight:Play()
            flight.Completed:Wait()
            if not suitBusy or not part.Parent or not ch.Parent then forget(plate); return end
            plate.CFrame = part.CFrame
            plate.Parent = ch
            plate.Anchored = false
            local weld = Instance.new("WeldConstraint")
            weld.Part0 = plate
            weld.Part1 = part
            weld.Parent = plate
            part.Color = suitColorFor(part.Name)
            part.Material = Enum.Material.SmoothPlastic
            table.insert(suitParts, plate)
            burst(part.Position, suitColorFor(part.Name), 5)
        end)
    end
    for i, part in ipairs(originals) do installPlate(part, i) end
    task.wait(math.max(0.8, (#originals - 1) * 0.085 + 0.48))
    if not suitBusy or not ch.Parent then
        hum.AutoRotate = oldAutoRotate
        return
    end
    addSpiderEmblem(ch)
    addMaskEyes(ch)
    suitEquipped = true
    suitBusy = false
    setSuitButton()
    task.delay(0.75, function()
        if activeSuitCase == caseModel then activeSuitCase = nil end
        forget(caseModel)
    end)
    burst(root.Position, C.cyan, 32)
    notify("TRAJE ARACNÍDEO EQUIPADO", C.green)
end

local function toggleSuit()
    if suitBusy then notify("MONTAGEM EM ANDAMENTO", C.yellow); return end
    if suitEquipped then
        restoreSuit(false)
        notify("TRAJE REMOVIDO", C.muted)
    else
        task.spawn(equipSuitSequence)
    end
end

connect(bWeb.Activated, shootWeb)
connect(bPull.Activated, pullWeb)
connect(bClimb.Activated, toggleClimb)
connect(bMode.Activated, toggleMode)
connect(bSense.Activated, toggleSense)
connect(bDash.Activated, dash)
connect(bClear.Activated, clearEffects)
connect(bSuit.Activated, toggleSuit)

connect(UserInputService.InputBegan, function(input, processed)
    if not alive or processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local k = input.KeyCode
    if k == Enum.KeyCode.Q then shootWeb()
    elseif k == Enum.KeyCode.E then pullWeb()
    elseif k == Enum.KeyCode.R then toggleClimb()
    elseif k == Enum.KeyCode.T then toggleSense()
    elseif k == Enum.KeyCode.F then dash()
    elseif k == Enum.KeyCode.G then toggleMode()
    elseif k == Enum.KeyCode.C then clearEffects()
    elseif k == Enum.KeyCode.V then toggleSuit() end
end)

connect(RunService.PreSimulation, function(dt)
    if not alive then return end
    animateSpider(dt)
    local ch, hum, root = characterParts()
    if hum and root and hum.Health > 0 then
        local speed = root.AssemblyLinearVelocity.Magnitude
        if gameHudHealth then
            gameHudHealth.Size = UDim2.new(math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1), 0, 1, 0)
            gameHudHealth.BackgroundColor3 = hum.Health / math.max(hum.MaxHealth, 1) < 0.3 and C.red or C.green
        end
        if gameHudMomentum then gameHudMomentum.Size = UDim2.new(math.clamp(speed / 70, 0, 1), 0, 1, 0) end
        if gameHudSpeed then gameHudSpeed.Text = string.format("%03d", math.floor(speed)) end
        if gameHudState then
            local stateText = climbing and "ESCALADA ATIVA" or (hum.FloorMaterial == Enum.Material.Air and "NO AR • MOBILIDADE" or "SISTEMA ONLINE")
            gameHudState.Text = stateText
            gameHudState.TextColor3 = climbing and C.cyan or (hum.FloorMaterial == Enum.Material.Air and C.yellow or C.green)
        end
    end
    if spiderSense and currentLight and currentLight.Parent then
        currentLight.Brightness = 0.48 + (math.sin(os.clock() * 5) + 1) * 0.3
    end
    if not climbing then return end
    if not ch or not hum or not root or hum.Health <= 0 then climbing = false; return end
    local cam = Workspace.CurrentCamera
    local direction = root.CFrame.LookVector
    if cam then direction = cam.CFrame.LookVector end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {ch}
    params.IgnoreWater = true
    local wall = Workspace:Raycast(root.Position + Vector3.new(0, 0.35, 0), root.CFrame.LookVector * CONFIG.ClimbWallDistance, params)
    if not wall and direction.Magnitude > 0 then
        wall = Workspace:Raycast(root.Position + Vector3.new(0, 0.35, 0), direction * CONFIG.ClimbWallDistance, params)
    end
    if not wall or math.abs(wall.Normal.Y) >= 0.35 then
        climbing = false
        local b = buttons.Climb
        if b then
            b.title.Text = "ESCALAR PAREDE"; b.detail.Text = "Chegue perto e ligue a escalada"; b.badge.Text = "›"
            tween(b.stroke, 0.15, {Color = C.cyan, Transparency = 0.64})
        end
        if gameHudState then gameHudState.Text = "PAREDE PERDIDA"; gameHudState.TextColor3 = C.yellow end
        return
    end
    local climbInput = 0
    if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
        climbInput = 1
    elseif UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
        climbInput = -1
    else
        local move = hum.MoveDirection
        local forwardAmount = move:Dot(root.CFrame.LookVector)
        if forwardAmount > 0.15 then climbInput = 1 elseif forwardAmount < -0.15 then climbInput = -1 end
        if cam and move.Magnitude > 0.05 and math.abs(cam.CFrame.LookVector.Y) > 0.38 then
            climbInput = cam.CFrame.LookVector.Y > 0 and 1 or -1
        end
    end
    local facing = Vector3.new(-wall.Normal.X, 0, -wall.Normal.Z)
    if facing.Magnitude > 0.05 then
        root.CFrame = CFrame.lookAt(root.Position, root.Position + facing.Unit)
    end
    root.AssemblyLinearVelocity = (-wall.Normal * 2) + Vector3.new(0, climbInput * CONFIG.ClimbSpeed, 0)
    if hum:GetState() ~= Enum.HumanoidStateType.Climbing then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Climbing) end)
    end
end)

connect(player.CharacterAdded, function(ch)
    stopSwing()
    suitBusy = false
    suitEquipped = false
    forget(activeSuitCase)
    activeSuitCase = nil
    for _, obj in ipairs(suitParts) do forget(obj) end
    suitParts = {}
    suitOriginals = {}
    suitClothing = {}
    currentCharacter = nil
    jointCache = {}
    task.delay(0.5, function()
        if not alive or not ch.Parent then return end
        refreshJoints(ch)
        if spiderSense then
            local root = ch:FindFirstChild("HumanoidRootPart")
            if root then
                forget(currentLight)
                currentLight = Instance.new("PointLight")
                currentLight.Color = C.cyan; currentLight.Range = 12; currentLight.Brightness = 0.8
                currentLight.Parent = root
            end
            forget(currentHighlight)
            currentHighlight = Instance.new("Highlight")
            currentHighlight.Adornee = ch; currentHighlight.FillColor = C.cyan; currentHighlight.OutlineColor = C.yellow
            currentHighlight.FillTransparency = 0.78; currentHighlight.OutlineTransparency = 0.05
            pcall(function() currentHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop end)
            currentHighlight.Parent = ch
        end
        if buttons.Suit then
            buttons.Suit.title.Text = "EQUIPAR TRAJE"
            buttons.Suit.detail.Text = "Mala + montagem peça por peça"
            buttons.Suit.badge.Text = "›"
        end
    end)
end)

local function stopAll()
    if not alive then return end
    stopSwing()
    restoreSuit(true)
    alive = false
    for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
    connections = {}
    for _, object in ipairs(tracked) do forget(object) end
    tracked = {}
    forget(currentHighlight); forget(currentLight); forget(effectsFolder); forget(currentGui)
    currentHighlight, currentLight, effectsFolder, currentGui = nil, nil, nil, nil
    _G.SpiderWebDeltaStop = nil
end

connect(close.Activated, function()
    notify("SISTEMA ENCERRADO", C.red)
    task.delay(0.12, stopAll)
end)
_G.SpiderWebDeltaStop = stopAll

if player.Character then refreshJoints(player.Character) end
playSound("sense", 0.14, 1.25)
notify("SPIDER//WEB V5 PRONTO", C.green)
print("[SPIDER//WEB V5] HUD de jogo iniciado. Balanço=botão/Q, Puxão=botão/E, Escalada=botão/R, Sentido=botão/T, Arrancada=botão/F, Poses=botão/G, Traje=botão/V, Limpar=botão/C.")
