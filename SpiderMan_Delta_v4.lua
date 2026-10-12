--[[
SPIDER//WEB v4 - script unico completo para Delta (Android/PC)
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
    ClimbSpeed = 13,
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
local jointCache = {}
local currentCharacter

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
    local endPart = Instance.new("Part")
    endPart.Name = "SpiderWeb_LineEnd"
    endPart.Size = Vector3.new(0.08, 0.08, 0.08)
    endPart.Transparency = 1
    endPart.Anchored = true
    endPart.CanCollide = false
    endPart.CanTouch = false
    endPart.CanQuery = false
    endPart.CFrame = CFrame.new(destination)
    endPart.Parent = getEffectsFolder()
    track(endPart, lifetime or 1.6)

    local a0 = Instance.new("Attachment")
    a0.Name = "SpiderWeb_Wrist"
    a0.Position = Vector3.new(0, -0.1, -0.22)
    a0.Parent = hand
    track(a0, lifetime or 1.6)
    local a1 = Instance.new("Attachment")
    a1.Name = "SpiderWeb_Tip"
    a1.Parent = endPart
    track(a1, lifetime or 1.6)

    local beam = Instance.new("Beam")
    beam.Name = "SpiderWeb_Beam"
    beam.Attachment0 = a0
    beam.Attachment1 = a1
    beam.FaceCamera = true
    beam.Width0 = 0.13
    beam.Width1 = 0.04
    beam.LightEmission = 0.9
    beam.LightInfluence = 0
    beam.Segments = 16
    beam.CurveSize0 = curve or 1.4
    beam.CurveSize1 = -(curve or 1.4)
    beam.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, C.white), ColorSequenceKeypoint.new(0.6, Color3.fromRGB(210, 245, 255)), ColorSequenceKeypoint.new(1, C.cyan)})
    beam.Transparency = NumberSequence.new(0.06)
    beam.Parent = getEffectsFolder()
    track(beam, lifetime or 1.6)
    burst(destination, C.white, 14)
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
    actionUntil = os.clock() + (duration or 0.45)
end

local function animateSpider(dt)
    if not alive or not spiderMode then return end
    local ch, humanoid, root = characterParts()
    if not ch or not humanoid or not root or humanoid.Health <= 0 then return end
    if ch ~= currentCharacter then refreshJoints(ch) end

    -- Limpa Transform para o estilo procedural assumir as juntas enquanto o modo esta ligado.
    for _, m in pairs(jointCache) do pcall(function() m.Transform = CFrame.identity end) end
    local t = os.clock()
    local speed = root.AssemblyLinearVelocity.Magnitude
    local moving = humanoid.MoveDirection.Magnitude > 0.08
    local phase = t * (speed > 18 and 12 or 7)
    local leftSwing = math.sin(phase)
    local rightSwing = -leftSwing
    local climbingNow = climbing
    local airborne = humanoid.FloorMaterial == Enum.Material.Air and not climbingNow

    if actionName ~= "none" and t < actionUntil then
        if actionName == "web" then
            pose("rightshoulder", CFrame.Angles(math.rad(-72), math.rad(6), math.rad(22)))
            pose("leftshoulder", CFrame.Angles(math.rad(14), 0, math.rad(-12)))
            pose("rightelbow", CFrame.Angles(math.rad(-38), 0, 0))
            pose("waist", CFrame.Angles(math.rad(-8), math.rad(12), 0))
            pose("neck", CFrame.Angles(math.rad(4), math.rad(-8), 0))
        elseif actionName == "jump" then
            pose("rootjoint", CFrame.Angles(math.rad(-12), 0, 0))
            pose("waist", CFrame.Angles(math.rad(-18), 0, 0))
            pose("rightshoulder", CFrame.Angles(math.rad(-115), 0, math.rad(18)))
            pose("leftshoulder", CFrame.Angles(math.rad(-105), 0, math.rad(-18)))
            pose("righthip", CFrame.Angles(math.rad(30), 0, 0))
            pose("lefthip", CFrame.Angles(math.rad(30), 0, 0))
            pose("rightknee", CFrame.Angles(math.rad(-35), 0, 0))
            pose("leftknee", CFrame.Angles(math.rad(-35), 0, 0))
        elseif actionName == "dash" then
            pose("rootjoint", CFrame.Angles(math.rad(-30), 0, 0))
            pose("waist", CFrame.Angles(math.rad(14), 0, 0))
            pose("rightshoulder", CFrame.Angles(math.rad(-35), 0, math.rad(30)))
            pose("leftshoulder", CFrame.Angles(math.rad(-35), 0, math.rad(-30)))
            pose("righthip", CFrame.Angles(math.rad(-25), 0, 0))
            pose("lefthip", CFrame.Angles(math.rad(25), 0, 0))
        end
        return
    else
        actionName = "none"
    end

    if climbingNow then
        pose("rootjoint", CFrame.Angles(math.rad(-10), 0, 0))
        pose("waist", CFrame.Angles(math.rad(-9), 0, 0))
        pose("rightshoulder", CFrame.Angles(math.rad(-65 + leftSwing * 18), 0, math.rad(15)))
        pose("leftshoulder", CFrame.Angles(math.rad(-65 + rightSwing * 18), 0, math.rad(-15)))
        pose("rightelbow", CFrame.Angles(math.rad(-55), 0, 0))
        pose("leftelbow", CFrame.Angles(math.rad(-55), 0, 0))
        pose("righthip", CFrame.Angles(math.rad(18 + rightSwing * 16), 0, 0))
        pose("lefthip", CFrame.Angles(math.rad(18 + leftSwing * 16), 0, 0))
        pose("rightknee", CFrame.Angles(math.rad(-25), 0, 0))
        pose("leftknee", CFrame.Angles(math.rad(-25), 0, 0))
    elseif airborne then
        local falling = root.AssemblyLinearVelocity.Y < -2
        pose("rootjoint", CFrame.Angles(math.rad(falling and 15 or -13), 0, 0))
        pose("waist", CFrame.Angles(math.rad(falling and -8 or -15), 0, 0))
        pose("rightshoulder", CFrame.Angles(math.rad(falling and -8 or -100), 0, math.rad(22)))
        pose("leftshoulder", CFrame.Angles(math.rad(falling and -8 or -100), 0, math.rad(-22)))
        pose("righthip", CFrame.Angles(math.rad(falling and -5 or 28), 0, 0))
        pose("lefthip", CFrame.Angles(math.rad(falling and -5 or 28), 0, 0))
        pose("rightknee", CFrame.Angles(math.rad(falling and 12 or -30), 0, 0))
        pose("leftknee", CFrame.Angles(math.rad(falling and 12 or -30), 0, 0))
    elseif moving then
        local sprinting = speed > 17
        pose("rootjoint", CFrame.Angles(math.rad(sprinting and -18 or -7), 0, math.rad(leftSwing * 3)))
        pose("waist", CFrame.Angles(math.rad(-4), 0, math.rad(leftSwing * 4)))
        pose("neck", CFrame.Angles(math.rad(4), 0, 0))
        pose("rightshoulder", CFrame.Angles(math.rad(leftSwing * (sprinting and 38 or 25) - 14), 0, math.rad(12)))
        pose("leftshoulder", CFrame.Angles(math.rad(rightSwing * (sprinting and 38 or 25) - 14), 0, math.rad(-12)))
        pose("rightelbow", CFrame.Angles(math.rad(-35), 0, 0))
        pose("leftelbow", CFrame.Angles(math.rad(-35), 0, 0))
        pose("righthip", CFrame.Angles(math.rad(rightSwing * (sprinting and 35 or 23)), 0, 0))
        pose("lefthip", CFrame.Angles(math.rad(leftSwing * (sprinting and 35 or 23)), 0, 0))
        pose("rightknee", CFrame.Angles(math.rad(math.max(0, leftSwing) * (sprinting and 32 or 18)), 0, 0))
        pose("leftknee", CFrame.Angles(math.rad(math.max(0, rightSwing) * (sprinting and 32 or 18)), 0, 0))
    else
        local breathe = math.sin(t * 2.2)
        pose("rootjoint", CFrame.Angles(math.rad(-3 + breathe * 1.2), 0, 0))
        pose("waist", CFrame.Angles(math.rad(2 + breathe * 1.5), 0, 0))
        pose("rightshoulder", CFrame.Angles(math.rad(-7 + breathe * 2), 0, math.rad(9)))
        pose("leftshoulder", CFrame.Angles(math.rad(-7 + breathe * 2), 0, math.rad(-9)))
        pose("rightelbow", CFrame.Angles(math.rad(-13), 0, 0))
        pose("leftelbow", CFrame.Angles(math.rad(-13), 0, 0))
        pose("neck", CFrame.Angles(math.rad(breathe), 0, 0))
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

panel = create("Frame", {
    Name = "HUD", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -96),
    Size = UDim2.fromOffset(264, 398), BackgroundColor3 = C.bg, BackgroundTransparency = 0.035,
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
create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(58, 32), Size = UDim2.new(1, -98, 0, 15), Text = "MODO ARANHA  •  V4.0", Font = Enum.Font.GothamMedium, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(208, 225, 245)}, header)
local minimize = create("TextButton", {Name = "Recolher", Position = UDim2.new(1, -37, 0, 17), Size = UDim2.fromOffset(27, 27), Text = "—", Font = Enum.Font.GothamBlack, TextSize = 15, TextColor3 = C.white, BackgroundColor3 = C.white, BackgroundTransparency = 0.85, BorderSizePixel = 0, AutoButtonColor = false}, header)
create("UICorner", {CornerRadius = UDim.new(0, 8)}, minimize)

local statusDot = create("Frame", {Position = UDim2.fromOffset(13, 70), Size = UDim2.fromOffset(7, 7), BackgroundColor3 = C.green, BorderSizePixel = 0}, panel)
create("UICorner", {CornerRadius = UDim.new(1, 0)}, statusDot)
local status = create("TextLabel", {Name = "Status", BackgroundTransparency = 1, Position = UDim2.fromOffset(25, 65), Size = UDim2.new(1, -35, 0, 17), Text = "ATIVO  •  EFEITOS LOCAIS", Font = Enum.Font.GothamBold, TextSize = 9, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.green}, panel)
create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 85), Size = UDim2.new(1, -24, 0, 14), Text = "HABILIDADES ARACNÍDEAS", Font = Enum.Font.GothamBold, TextSize = 9, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.muted}, panel)

local scroll = create("ScrollingFrame", {Name = "Habilidades", Position = UDim2.fromOffset(9, 103), Size = UDim2.new(1, -18, 0, 247), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = C.blue, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y}, panel)
create("UIListLayout", {Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder}, scroll)
create("UIPadding", {PaddingBottom = UDim.new(0, 5), PaddingLeft = UDim.new(0, 1), PaddingRight = UDim.new(0, 3)}, scroll)
local footer = create("TextLabel", {BackgroundTransparency = 1, Position = UDim2.new(0, 11, 1, -35), Size = UDim2.new(1, -55, 0, 20), Text = "ANIMAÇÃO PROCEDURAL  •  LOCAL", Font = Enum.Font.GothamMedium, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.muted}, panel)
local close = create("TextButton", {Name = "Fechar", Position = UDim2.new(1, -40, 1, -39), Size = UDim2.fromOffset(29, 29), Text = "×", Font = Enum.Font.GothamBlack, TextSize = 20, TextColor3 = C.white, BackgroundColor3 = C.redDark, BorderSizePixel = 0, AutoButtonColor = false}, panel)
create("UICorner", {CornerRadius = UDim.new(0, 8)}, close)

local toast = create("Frame", {Name = "Toast", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 42), Size = UDim2.fromOffset(276, 0), BackgroundColor3 = C.panel, BackgroundTransparency = 0.03, BorderSizePixel = 0, ClipsDescendants = true, Visible = true}, gui)
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

local bWeb = makeButton("Web", "🕸", "DISPARAR TEIA", "Teia visual ate onde voce mira", C.blue, 1)
local bPull = makeButton("Pull", "⚡", "PUXÃO DE TEIA", "Impulso em direcao a superficie", C.red, 2)
local bClimb = makeButton("Climb", "↟", "ESCALAR PAREDE", "Ligue e ande contra a parede", C.cyan, 3)
local bMode = makeButton("Mode", "✦", "ANIMAÇÃO ARANHA: ON", "Movimento procedural local", C.red, 4)
local bSense = makeButton("Sense", "◉", "SENTIDO-ARANHA", "Aura e pulso de energia", C.yellow, 5)
local bDash = makeButton("Dash", "➤", "ARRANCADA ARANHA", "Avanco rapido com rastro", C.red, 6)
local bClear = makeButton("Clear", "✧", "LIMPAR EFEITOS", "Desliga aura e escalada", C.muted, 7)

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
    tween(panel, 0.23, {Size = expanded and UDim2.fromOffset(264, 398) or UDim2.fromOffset(264, 62)})
end)

local function shootWeb()
    if not alive or busy.web then return end
    busy.web = true
    task.delay(CONFIG.WebCooldown, function() busy.web = false end)
    local ch, hum = characterParts()
    if not ch or not hum or hum.Health <= 0 then notify("PERSONAGEM NAO DISPONIVEL", C.red); return end
    local cam = Workspace.CurrentCamera
    if not cam then notify("CAMERA NAO DISPONIVEL", C.red); return end
    local hit = raycastCamera(CONFIG.MaxWebDistance)
    local point = hit and hit.Position or (cam.CFrame.Position + cam.CFrame.LookVector * 85)
    if webLine(point, 1.6, 1.5) then
        setSpiderAction("web", 0.38)
        burst(point, C.cyan, 12)
        playSound("web", 0.36, 1.1)
        notify(hit and "TEIA DISPARADA!" or "TEIA LANCADA AO LONGE", C.blue)
    else
        notify("NAO ENCONTREI A MAO DO PERSONAGEM", C.red)
    end
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
    webLine(hit.Position, 1.2, 2)
    setSpiderAction("web", 0.32)
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
    d.detail.Text = climbing and "Ande de frente contra a parede" or "Ligue e ande contra a parede"
    d.badge.Text = climbing and "ON" or "›"
    tween(d.stroke, 0.15, {Color = climbing and C.green or C.cyan, Transparency = climbing and 0.14 or 0.64})
    notify(climbing and "ESCALADA ATIVADA" or "ESCALADA DESATIVADA", climbing and C.green or C.muted)
end

local function toggleMode()
    spiderMode = not spiderMode
    if not spiderMode then
        for _, m in pairs(jointCache) do pcall(function() m.Transform = CFrame.identity end) end
    end
    local d = buttons.Mode
    d.title.Text = spiderMode and "ANIMAÇÃO ARANHA: ON" or "ANIMAÇÃO ARANHA: OFF"
    d.detail.Text = spiderMode and "Idle, corrida, salto e escalada" or "Usar animacoes normais do jogo"
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

connect(bWeb.Activated, shootWeb)
connect(bPull.Activated, pullWeb)
connect(bClimb.Activated, toggleClimb)
connect(bMode.Activated, toggleMode)
connect(bSense.Activated, toggleSense)
connect(bDash.Activated, dash)
connect(bClear.Activated, clearEffects)

connect(UserInputService.InputBegan, function(input, processed)
    if not alive or processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local k = input.KeyCode
    if k == Enum.KeyCode.Q then shootWeb()
    elseif k == Enum.KeyCode.E then pullWeb()
    elseif k == Enum.KeyCode.R then toggleClimb()
    elseif k == Enum.KeyCode.T then toggleSense()
    elseif k == Enum.KeyCode.F then dash()
    elseif k == Enum.KeyCode.G then toggleMode()
    elseif k == Enum.KeyCode.C then clearEffects() end
end)

connect(RunService.PreSimulation, function(dt)
    if not alive then return end
    animateSpider(dt)
    if spiderSense and currentLight and currentLight.Parent then
        currentLight.Brightness = 0.48 + (math.sin(os.clock() * 5) + 1) * 0.3
    end
    if not climbing then return end
    local ch, hum, root = characterParts()
    if not ch or not hum or not root or hum.Health <= 0 then return end
    local move = hum.MoveDirection
    if move.Magnitude < 0.08 then return end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {ch}
    params.IgnoreWater = true
    local wall = Workspace:Raycast(root.Position + Vector3.new(0, 0.25, 0), root.CFrame.LookVector * 3.1, params)
    if not wall then
        wall = Workspace:Raycast(root.Position + Vector3.new(0, 0.25, 0), move.Unit * 3.1, params)
    end
    if wall and math.abs(wall.Normal.Y) < 0.35 then
        local v = root.AssemblyLinearVelocity
        root.AssemblyLinearVelocity = Vector3.new(v.X * 0.3, CONFIG.ClimbSpeed, v.Z * 0.3)
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
    end
end)

connect(player.CharacterAdded, function(ch)
    currentCharacter = nil
    jointCache = {}
    task.delay(0.5, function()
        if not alive then return end
        refreshJoints(ch)
        if spiderSense and ch.Parent then
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
    end)
end)

local function stopAll()
    if not alive then return end
    alive = false
    for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
    connections = {}
    for _, m in pairs(jointCache) do pcall(function() m.Transform = CFrame.identity end) end
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
notify("SPIDER//WEB V4 PRONTO", C.green)
print("[SPIDER//WEB V4] HUD iniciado. Teia=botao/Q, Puxao=botao/E, Escalada=botao/R, Sentido=botao/T, Arrancada=botao/F, Animacao=botao/G, Limpar=botao/C.")
