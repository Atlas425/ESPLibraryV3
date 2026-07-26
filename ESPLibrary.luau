local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer
local ESP = {}
ESP.__index = ESP
ESP.Version = "1.0.0"
ESP.Config = {
    Enabled          = true,
    MaxDistance      = 500,

    MaxRendered      = 25,
    Body             = true,
    Style            = "Gradient",
    BodyTransparency = 0.55,
    GradientTop      = Color3.fromRGB(120, 240, 255),
    GradientBottom   = Color3.fromRGB(140, 40, 200),
    OcclusionSplit   = true,
    VisibleColor     = Color3.fromRGB(30, 45, 70),
    HiddenColor      = Color3.fromRGB(110, 240, 255),
    RayHz            = 15,
    Hull             = false,
    HullThick        = 0.14,
    HullByHealth     = false,
    HullColor        = Color3.fromRGB(255, 40, 130),
    Card             = true,
    Ring             = true,
    RingRadius       = 3.2,
    RingSegments     = 28,
    Echo             = true,
    EchoCount        = 8,
    EchoSpacing      = 0.07,
    EchoMaxDistance  = 150,
    EchoTint         = true,
    EchoTailColor    = Color3.fromRGB(150, 40, 220),
    Velocity         = true,
    VelocitySecs     = 0.45,

    OffScreen        = true,
    OffScreenRadius  = 0.42,
    DamageFlash      = true,
    FlashTime        = 0.16,

    Accent           = Color3.fromRGB(120, 240, 255),
    Debug            = false,
    DisplayOrder     = 9999,

    HealthAttributes    = { "Health", "HP", "CurrentHealth", "Hp", "health" },
    MaxHealthAttributes = { "MaxHealth", "MaxHP", "maxHealth", "MaxHp" },
    HealthValueSearch   = true,
    HealthSearchDepth   = 2,
    HealthValueNames    = { "Health", "HP", "CurrentHealth" },
    MaxHealthValueNames = { "MaxHealth", "MaxHP" },

    MinPartVolume    = 0.02,
    MaxPartsPerRig   = 64,
    SkipTransparent  = true,
    HitboxRatio      = 1,

    PartFilter       = nil,
}
local C = ESP.Config

local STYLES = { Outline = true, Solid = true, Glass = true, Gradient = true, Ghost = true }
local gui, overlay
local echoVP, hullVP, bodyVP
local echoWorld, hullWorld, bodyWorld
local echoCam, hullCam, bodyCam
local vpCams = {}
local renderConn
local tracked = {}
local started = false
local playerConns = {}
local playerAddedConn
local playerLeftConn
local panelConns = {}
local wantHull, wantBody, wantEcho = false, false, false
local disabledDone = false
local cand, candDist = {}, {}
local candPrev = 0
local trackSeq = 0
local function create(cls, props)
    local i = Instance.new(cls)
    for k, v in pairs(props) do i[k] = v end
    return i
end
local unitCircles = {}
local function unitCircle(n)
    local u = unitCircles[n]
    if u then return u end
    u = {}
    for i = 1, n do
        local a = (i - 1) / n * math.pi * 2
        u[i] = { math.cos(a), math.sin(a) }
    end
    unitCircles[n] = u
    return u
end
local function healthColor(f)
    f = math.clamp(f, 0, 1)
    if f > 0.5 then
        return Color3.fromRGB(255, 210, 60):Lerp(Color3.fromRGB(80, 255, 210), (f - 0.5) * 2)
    end
    return Color3.fromRGB(255, 55, 90):Lerp(Color3.fromRGB(255, 210, 60), f * 2)
end

local PER_TARGET = {
    MaxDistance = true, Echo = true, Ring = true, Card = true,
    Velocity = true, Hull = true, Body = true, Style = true, OffScreen = true,
}
local function cfgOf(oc, k)
    if oc then
        local v = oc[k]
        if v ~= nil then return v end
    end
    return C[k]
end
local function optValue(v, model)
    if type(v) == "function" then
        local ok, r = pcall(v, model)
        return ok and r or nil
    end
    return v
end
local function line2D(f, a, b, thick)
    local d = b - a
    local len = d.Magnitude
    if len < 1 then f.Visible = false return end
    f.Visible = true
    f.Size = UDim2.fromOffset(len, thick)
    f.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
    f.Rotation = math.deg(math.atan2(d.Y, d.X))
end

local function compileSource(model, spec)
    if spec == nil then return nil end
    local t = type(spec)
    if t == "number" then
        return function() return spec end
    elseif t == "function" then
        return spec
    elseif typeof(spec) == "Instance" then
        return function()
            if not spec.Parent then return nil end
            local ok, v = pcall(function() return spec.Value end)
            return (ok and type(v) == "number") and v or nil
        end
    elseif t == "string" then
        local segs = {}
        for s in string.gmatch(spec, "[^%.]+") do segs[#segs + 1] = s end
        if #segs == 0 then return nil end
        return function()
            local node = model
            for i, s in ipairs(segs) do
                if typeof(node) ~= "Instance" then return nil end
                local nxt = node:FindFirstChild(s)
                if nxt then
                    node = nxt
                elseif i == #segs then
                    local a = node:GetAttribute(s)
                    return type(a) == "number" and a or nil
                else
                    return nil
                end
            end
            local ok, v = pcall(function() return node.Value end)
            return (ok and type(v) == "number") and v or nil
        end
    end
    return nil
end
local function findHealthValue(model)
    local names = {}
    for _, n in ipairs(C.HealthValueNames) do names[string.lower(n)] = true end
    local best
    local function scan(node, depth)
        if depth > C.HealthSearchDepth then return end
        for _, ch in ipairs(node:GetChildren()) do
            if (ch:IsA("NumberValue") or ch:IsA("IntValue")) and names[string.lower(ch.Name)] then
                local mx
                for _, mn in ipairs(C.MaxHealthValueNames) do
                    mx = ch.Parent:FindFirstChild(mn)
                    if mx and (mx:IsA("NumberValue") or mx:IsA("IntValue")) then break end
                    mx = nil
                end

                local score = (mx and 2 or 0) + (depth == 1 and 1 or 0)
                if score > 0 and (not best or score > best.score) then
                    best = { obj = ch, maxObj = mx, score = score }
                end
            elseif ch:IsA("Folder") or ch:IsA("Configuration") or ch:IsA("Model") then
                scan(ch, depth + 1)
            end
        end
    end
    scan(model, 1)
    return best
end
local function probeHealth(e)
    local model = e.model
    local opts = e.opts or {}
    local get = compileSource(model, opts.health)
    if get then
        return { kind = "custom", get = get, getMax = compileSource(model, opts.maxHealth) }
    end
    if typeof(model) ~= "Instance" then return { kind = "none" } end
    local hum = model:FindFirstChildWhichIsA("Humanoid")
    if hum then return { kind = "hum", hum = hum } end
    for _, key in ipairs(C.HealthAttributes) do
        if type(model:GetAttribute(key)) == "number" then
            local maxKey
            for _, mk in ipairs(C.MaxHealthAttributes) do
                if type(model:GetAttribute(mk)) == "number" then maxKey = mk break end
            end
            return { kind = "attr", key = key, maxKey = maxKey }
        end
    end
    if C.HealthValueSearch then
        local hit = findHealthValue(model)
        if hit then return { kind = "val", obj = hit.obj, maxObj = hit.maxObj } end
    end
    return { kind = "none" }
end
local function resolveHealth(e, now)

    if e.pushCur then
        return e.pushCur, math.max(e.pushMax or e.pushCur, 1)
    end
    local h = e.hres
    if not h or (h.kind == "none" and now - (e.hprobe or 0) > 2)
             or (h.kind == "hum" and not h.hum.Parent)
             or (h.kind == "val" and not h.obj.Parent) then
        h = probeHealth(e)
        e.hres, e.hprobe = h, now
    end
    if h.kind == "custom" then
        local ok, cur, curMax = pcall(h.get, e.model)
        if ok and type(cur) == "number" then
            local mx
            if h.getMax then
                local ok2, m = pcall(h.getMax, e.model)
                if ok2 and type(m) == "number" then mx = m end
            end
            mx = mx or (type(curMax) == "number" and curMax) or math.max(cur, 100)
            return cur, math.max(mx, 1)
        end
    elseif h.kind == "hum" then
        return h.hum.Health, math.max(h.hum.MaxHealth, 1)
    elseif h.kind == "attr" then
        local v = e.model:GetAttribute(h.key)
        if type(v) == "number" then
            local mx = h.maxKey and e.model:GetAttribute(h.maxKey) or v
            return v, math.max(tonumber(mx) or v, 1)
        end
    elseif h.kind == "val" and h.obj.Parent then
        return h.obj.Value, math.max(h.maxObj and h.maxObj.Value or h.obj.Value, 1)
    end
    return 1, 1
end
local function partVolume(p)
    local s = p.Size
    return s.X * s.Y * s.Z
end
local function collectParts(model, opts)
    if opts and opts.parts then return opts.parts end
    local out = {}
    if typeof(model) ~= "Instance" then return out end
    if model:IsA("BasePart") then return { model } end
    local function gather(relaxed)
        local all = {}
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then
                local skip = false
                if not relaxed then
                    if C.SkipTransparent and d.Transparency >= 1 then skip = true end
                    if partVolume(d) < C.MinPartVolume then skip = true end
                end
                if C.PartFilter then
                    local ok, keep = pcall(C.PartFilter, d, model)
                    if ok and keep == false then skip = true end
                end
                if not skip then all[#all + 1] = d end
            end
        end
        return all
    end
    local all = gather(false)
    if #all == 0 then all = gather(true) end
    if #all == 0 then return out end
    local total = 0
    for _, p in ipairs(all) do total = total + partVolume(p) end
    for _, p in ipairs(all) do
        local v = partVolume(p)
        local dominant = #all >= 3 and v > (total - v) * C.HitboxRatio
        if not (dominant and p.Transparency >= 0.9) then
            out[#out + 1] = p
            if #out >= C.MaxPartsPerRig then break end
        end
    end
    if #out == 0 then return all end
    return out
end
local function partsBBox(parts)
    local has = false
    local nx, ny, nz = math.huge, math.huge, math.huge
    local xx, xy, xz = -math.huge, -math.huge, -math.huge
    local abs = math.abs
    for _, p in ipairs(parts) do
        if p.Parent then
            local cf, sz = p.CFrame, p.Size
            local rv, uv, lv = cf.RightVector, cf.UpVector, cf.LookVector
            local sX, sY, sZ = sz.X, sz.Y, sz.Z
            local hx = (abs(rv.X) * sX + abs(uv.X) * sY + abs(lv.X) * sZ) * 0.5
            local hy = (abs(rv.Y) * sX + abs(uv.Y) * sY + abs(lv.Y) * sZ) * 0.5
            local hz = (abs(rv.Z) * sX + abs(uv.Z) * sY + abs(lv.Z) * sZ) * 0.5
            local pos = cf.Position
            local px, py, pz = pos.X, pos.Y, pos.Z
            if px - hx < nx then nx = px - hx end
            if py - hy < ny then ny = py - hy end
            if pz - hz < nz then nz = pz - hz end
            if px + hx > xx then xx = px + hx end
            if py + hy > xy then xy = py + hy end
            if pz + hz > xz then xz = pz + hz end
            has = true
        end
    end
    if not has then return nil end
    return Vector3.new((nx + xx) * 0.5, (ny + xy) * 0.5, (nz + xz) * 0.5),
           Vector3.new(xx - nx, xy - ny, xz - nz)
end

local function chamClone(src, world)
    local ok, c = pcall(function() return src:Clone() end)
    if not ok or not c then return nil end
    c.Anchored, c.CanCollide, c.CastShadow = true, false, false
    c.Material = Enum.Material.Neon
    c.Transparency = 0
    if c:IsA("MeshPart") then c.TextureID = "" end
    if c:IsA("UnionOperation") then c.UsePartColor = true end
    for _, d in ipairs(c:GetDescendants()) do
        if d:IsA("SpecialMesh") then d.TextureId = ""
        elseif not d:IsA("DataModelMesh") then d:Destroy() end
    end
    c.Parent = world
    return c
end

local function buildGui()
    local parent = (typeof(gethui) == "function" and gethui())
        or LocalPlayer:FindFirstChildOfClass("PlayerGui")
    gui = create("ScreenGui", {
        Name = "ESPLib", ResetOnSpawn = false, IgnoreGuiInset = true,
        DisplayOrder = C.DisplayOrder, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = parent,
    })
    ESP.Gui = gui
    local function vp(name, z)
        local v = create("ViewportFrame", {
            Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
            Ambient = Color3.new(1,1,1), LightColor = Color3.new(1,1,1),
            ZIndex = z, Parent = gui,
        })
        local w = create("WorldModel", { Parent = v })
        local c = create("Camera", { Parent = v })
        v.CurrentCamera = c
        return v, w, c
    end
    echoVP, echoWorld, echoCam = vp("Echo", 1)
    hullVP, hullWorld, hullCam = vp("Hull", 2)
    bodyVP, bodyWorld, bodyCam = vp("Body", 3)
    vpCams = { echoCam, hullCam, bodyCam }
    overlay = create("Frame", {
        Name = "Overlay", Size = UDim2.fromScale(1,1),
        BackgroundTransparency = 1, ZIndex = 4, Parent = gui,
    })
end
local function buildArrow()
    local holder = create("Frame", {
        Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5), Visible = false, ZIndex = 6, Parent = overlay,
    })
    for _, arm in ipairs({ { rot = 27, y = 7 }, { rot = -27, y = 15 } }) do
        local bar = create("Frame", {
            Size = UDim2.fromOffset(16, 3), BackgroundColor3 = C.Accent, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5), Rotation = arm.rot,
            Position = UDim2.fromOffset(11, arm.y), ZIndex = 6, Parent = holder,
        })
        create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = bar })
    end
    return holder
end
local function buildEntryGui(e)
    local card = create("Frame", {
        Size = UDim2.fromOffset(132, 44), BackgroundColor3 = Color3.fromRGB(10, 12, 18),
        BackgroundTransparency = 0.15, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
        Visible = false, ZIndex = 6, Parent = overlay,
    })
    create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = card })
    create("UIStroke", { Color = C.Accent, Thickness = 1, Transparency = 0.45, Parent = card })
    e.cardName = create("TextLabel", {
        Position = UDim2.fromOffset(8, 4), Size = UDim2.new(1, -16, 0, 15),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = Color3.new(1,1,1), TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 7, Parent = card,
    })
    e.cardMeta = create("TextLabel", {
        Position = UDim2.fromOffset(8, 18), Size = UDim2.new(1, -16, 0, 12),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
        TextColor3 = Color3.fromRGB(150, 160, 175), TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 7, Parent = card,
    })
    local barBg = create("Frame", {
        Position = UDim2.fromOffset(8, 33), Size = UDim2.new(1, -16, 0, 4),
        BackgroundColor3 = Color3.fromRGB(28, 30, 38), BorderSizePixel = 0, ZIndex = 7, Parent = card,
    })
    create("UICorner", { CornerRadius = UDim.new(0, 2), Parent = barBg })
    e.cardBar = create("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.Accent,
        BorderSizePixel = 0, ZIndex = 8, Parent = barBg,
    })
    create("UICorner", { CornerRadius = UDim.new(0, 2), Parent = e.cardBar })
    e.card = card
    e.leader = create("Frame", {
        BackgroundColor3 = C.Accent, BackgroundTransparency = 0.35, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5), Visible = false, ZIndex = 5, Parent = overlay,
    })
    e.velLine = create("Frame", {
        BackgroundColor3 = C.Accent, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
        Visible = false, ZIndex = 5, Parent = overlay,
    })
    e.velTip = create("Frame", {
        Size = UDim2.fromOffset(6, 6), BackgroundColor3 = C.Accent, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5), Visible = false, ZIndex = 6, Parent = overlay,
    })
    create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = e.velTip })
    e.arrow = buildArrow()
    e.arrowDist = create("TextLabel", {
        Size = UDim2.fromOffset(46, 12), BackgroundTransparency = 1,
        Font = Enum.Font.Gotham, Text = "", TextSize = 10,
        TextColor3 = Color3.fromRGB(170, 180, 195), AnchorPoint = Vector2.new(0.5, 0.5),
        Visible = false, ZIndex = 6, Parent = overlay,
    })
    e.ring = {}
    for i = 1, C.RingSegments do
        e.ring[i] = create("Frame", {
            Size = UDim2.fromOffset(3, 3), BackgroundColor3 = C.Accent, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5), Visible = false, ZIndex = 4, Parent = overlay,
        })
        create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = e.ring[i] })
    end
end
local function clearEcho(e)
    for _, set in ipairs(e.echo) do
        for _, rec in ipairs(set) do
            if rec.clone then pcall(function() rec.clone:Destroy() end) end
        end
    end
    e.echo = {}
end
local function destroyEntry(e)
    for _, pair in pairs(e.parts) do
        if pair.hull then pcall(function() pair.hull:Destroy() end) end
        if pair.body then pcall(function() pair.body:Destroy() end) end
    end
    clearEcho(e)
    for _, f in ipairs(e.ring or {}) do pcall(function() f:Destroy() end) end
    for _, o in ipairs({ e.card, e.leader, e.velLine, e.velTip, e.arrow, e.arrowDist }) do
        if o then pcall(function() o:Destroy() end) end
    end
end

local function rebuildParts(e)
    for _, pair in pairs(e.parts) do
        if pair.hull then pcall(function() pair.hull:Destroy() end) end
        if pair.body then pcall(function() pair.body:Destroy() end) end
    end
    e.parts = {}
    clearEcho(e)
    local list = collectParts(e.model, e.opts)
    local wantHullNow = cfgOf(e.opts and e.opts.config, "Hull")
    for _, p in ipairs(list) do
        local body = chamClone(p, bodyWorld)
        if body then
            local hull = wantHullNow and chamClone(p, hullWorld) or nil
            e.parts[p] = { hull = hull, body = body, occluded = true }
        end
    end
    e.discovered = #list
    e.discSet = {}
    for _, p in ipairs(list) do e.discSet[p] = true end
    e.lastRebuild = os.clock() + (e.phase or 0)
    e.ref = nil
    e.hidden = false
end
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local lastRay = 0
local function hideEntry(e)
    if e.hidden then return end
    e.hidden = true
    for _, f in ipairs(e.ring or {}) do f.Visible = false end
    e.card.Visible, e.leader.Visible = false, false
    e.velLine.Visible, e.velTip.Visible = false, false
    e.arrow.Visible, e.arrowDist.Visible = false, false
    for _, pair in pairs(e.parts) do
        if pair.hull then pair.hull.Transparency = 1 end
        if pair.body then pair.body.Transparency = 1 end
    end
    for _, set in ipairs(e.echo or {}) do
        for _, rec in ipairs(set) do
            if rec.clone then rec.clone.Transparency = 1 end
        end
    end
end
local function renderEntry(model, e, cam, camPos, now, doRay)
    local parts = e.parts
    local oc        = e.opts and e.opts.config
    local cMaxDist  = cfgOf(oc, "MaxDistance")
    local cEcho     = cfgOf(oc, "Echo")
    local cRing     = cfgOf(oc, "Ring")
    local cCard     = cfgOf(oc, "Card")
    local cVelocity = cfgOf(oc, "Velocity")
    local cHull     = cfgOf(oc, "Hull")
    local cBody     = cfgOf(oc, "Body")
    local cStyle    = cfgOf(oc, "Style")
    local cOffScr   = cfgOf(oc, "OffScreen")

    if now - (e.lastRebuild or 0) > 2 then
        e.lastRebuild = now
        local list = collectParts(e.model, e.opts)
        local changed = #list ~= e.discovered
        if not changed and e.discSet then
            for _, p in ipairs(list) do
                if not e.discSet[p] then changed = true break end
            end
        end
        if changed then
            rebuildParts(e)
            parts = e.parts
        end
    end
    local ordered = e.ordered
    if not ordered then ordered = {}; e.ordered = ordered
    else table.clear(ordered) end
    for p in pairs(parts) do ordered[#ordered + 1] = p end
    local centre, size = partsBBox(ordered)
    if not centre then
        if next(parts) then rebuildParts(e) end
        hideEntry(e)
        return
    end
    local dist = (centre - camPos).Magnitude
    if not (C.Enabled and dist <= cMaxDist) then
        hideEntry(e)
        return
    end
    e.hidden = false
    if cHull then wantHull = true end
    if cBody then wantBody = true end
    if cEcho then wantEcho = true end
    local cur, max = resolveHealth(e, now)
    local hp = math.clamp(cur / math.max(max, 1), 0, 1)
    local forced = e.opts and optValue(e.opts.color, model) or nil
    local hc = forced or healthColor(hp)
    if e.lastHP and cur < e.lastHP - 0.01 then e.flashUntil = now + C.FlashTime end
    e.lastHP = cur
    local flashing = C.DamageFlash and e.flashUntil and now < e.flashUntil
    local style = STYLES[cStyle] and cStyle or "Gradient"

    if doRay and C.OcclusionSplit then
        rayParams.FilterDescendantsInstances = { model, LocalPlayer.Character or model }
    end
    for real, pair in pairs(parts) do
        if not real.Parent then
            if pair.hull then pcall(function() pair.hull:Destroy() end) end
            if pair.body then pcall(function() pair.body:Destroy() end) end
            parts[real] = nil
        else
            local sz = real.Size
            if cHull then
                if not pair.hull then pair.hull = chamClone(real, hullWorld) end
                if pair.hull then
                    local t = C.HullThick
                    pair.hull.Size = sz + Vector3.new(t, t, t) * 2
                    pair.hull.CFrame = real.CFrame
                    pair.hull.Color = C.HullByHealth and hc or C.HullColor
                    pair.hull.Transparency = 0
                end
            elseif pair.hull and pair.hull.Transparency ~= 1 then
                pair.hull.Transparency = 1
            end
            if not cBody then
                if pair.body.Transparency ~= 1 then pair.body.Transparency = 1 end
                continue
            end
            if pair.lastSize ~= sz then
                pair.body.Size = sz
                pair.lastSize = sz
            end
            pair.body.CFrame = real.CFrame
            if doRay and C.OcclusionSplit then
                pair.occluded = Workspace:Raycast(camPos, real.Position - camPos, rayParams) ~= nil
            end
            local col = (C.OcclusionSplit and pair.occluded) and C.HiddenColor or C.VisibleColor
            local mat, alpha = Enum.Material.Neon, C.BodyTransparency
            if style == "Outline" then alpha = 1
            elseif style == "Solid" then alpha = 0
            elseif style == "Glass" then mat, alpha = Enum.Material.ForceField, 0
            elseif style == "Gradient" then
                local bottom = centre.Y - size.Y / 2
                local f = math.clamp((real.Position.Y - bottom) / math.max(size.Y, 0.1), 0, 1)
                col = C.GradientBottom:Lerp(C.GradientTop, f)
            elseif style == "Ghost" then alpha = math.max(C.BodyTransparency, 0.78) end
            if forced then col = forced end
            if flashing then col, alpha = Color3.new(1,1,1), math.min(alpha, 0.1) end

            if pair.lastMat ~= mat then
                pair.body.Material = mat
                pair.lastMat = mat
            end
            pair.body.Color = col
            pair.body.Transparency = alpha
        end
    end
    if cEcho and dist <= C.EchoMaxDistance then
        local want = math.max(1, math.floor(C.EchoCount))
        if now - (e.lastSample or 0) >= C.EchoSpacing then
            e.lastSample = now
            table.insert(e.hist, 1, CFrame.new(centre))
            while #e.hist > want do table.remove(e.hist) end
        end
        while #e.echo < want do
            local set = {}
            for real in pairs(parts) do
                local c = chamClone(real, echoWorld)
                if c then set[#set + 1] = { clone = c, src = real } end
            end
            e.echo[#e.echo + 1] = set
        end
        while #e.echo > want do
            local set = table.remove(e.echo)
            for _, rec in ipairs(set) do
                if rec.clone then pcall(function() rec.clone:Destroy() end) end
            end
        end
        local originCF = CFrame.new(centre)
        for gi, set in ipairs(e.echo) do
            local snap = e.hist[gi]
            local fade = 0.45 + 0.5 * (gi / want)
            for _, rec in ipairs(set) do
                if snap and rec.src and rec.src.Parent then
                    rec.clone.CFrame = snap * originCF:ToObjectSpace(rec.src.CFrame)
                    rec.clone.Color = C.EchoTint and hc:Lerp(C.EchoTailColor, gi / want) or hc
                    rec.clone.Transparency = fade
                else
                    rec.clone.Transparency = 1
                end
            end
        end
    elseif #e.echo > 0 then
        clearEcho(e); e.hist = {}
    end
    local nseg = #e.ring
    if cRing and nseg > 0 then
        local base = centre - Vector3.new(0, size.Y / 2, 0)
        local camCF = cam.CFrame
        local r = C.RingRadius
        local fwd = camCF.LookVector
        local fx, fz = fwd.X, fwd.Z
        local fm = math.sqrt(fx * fx + fz * fz)
        if fm < 1e-4 then fx, fz, fm = 0, -1, 1 end
        local flatFwd = Vector3.new(fx / fm, 0, fz / fm)
        local flatRight = Vector3.new(-flatFwd.Z, 0, flatFwd.X)
        local sc = cam:WorldToViewportPoint(base)
        if sc.Z > 0 then
            local sr = cam:WorldToViewportPoint(base + flatRight * r)
            local sf = cam:WorldToViewportPoint(base + flatFwd * r)
            local cx, cy = sc.X, sc.Y
            local ax, ay = sr.X - cx, sr.Y - cy
            local bx, by = sf.X - cx, sf.Y - cy
            local unit = unitCircle(nseg)
            local lit = math.floor(nseg * hp + 0.5)
            local px = math.floor(math.clamp(220 / math.max(dist, 1), 2, 7) + 0.5)
            local restyle = (e.ringLit ~= lit) or (e.ringHc ~= hc) or (e.ringPx ~= px)
            local sz2, dim
            if restyle then
                sz2 = UDim2.fromOffset(px, px)
                dim = Color3.fromRGB(60, 65, 80)
                e.ringLit, e.ringHc, e.ringPx = lit, hc, px
            end

            for i = 1, nseg do
                local f = e.ring[i]
                local u = unit[i]
                f.Position = UDim2.fromOffset(cx + ax * u[1] + bx * u[2],
                                              cy + ay * u[1] + by * u[2])
                if restyle then
                    f.Size = sz2
                    if i <= lit then
                        f.BackgroundColor3 = hc
                        f.BackgroundTransparency = 0
                    else
                        f.BackgroundColor3 = dim
                        f.BackgroundTransparency = 0.55
                    end
                end
                if not f.Visible then f.Visible = true end
            end
        else
            for _, f in ipairs(e.ring) do f.Visible = false end
        end
    elseif nseg > 0 then
        for _, f in ipairs(e.ring) do f.Visible = false end
    end

    if cCard then
        local sp = cam:WorldToViewportPoint(centre + Vector3.new(0, size.Y / 2 + 1.2, 0))
        if sp.Z > 0 then
            local at = Vector2.new(sp.X, sp.Y)
            local cardPos = at + Vector2.new(34, -30)
            e.card.Visible = true
            e.card.Position = UDim2.fromOffset(cardPos.X, cardPos.Y)
            local nm = tostring((e.opts and optValue(e.opts.name, model)) or model.Name)
            if e.lastName ~= nm then e.cardName.Text = nm; e.lastName = nm end
            local meta = (max > 1)
                and string.format("%dm   ·   %d hp", math.floor(dist), math.floor(cur))
                or string.format("%dm", math.floor(dist))
            if e.lastMeta ~= meta then e.cardMeta.Text = meta; e.lastMeta = meta end
            e.cardBar.Size = UDim2.fromScale(hp, 1)
            e.cardBar.BackgroundColor3 = hc
            line2D(e.leader, at, cardPos, 1)
            e.leader.BackgroundColor3 = hc
        else
            e.card.Visible, e.leader.Visible = false, false
        end
    else
        e.card.Visible, e.leader.Visible = false, false
    end
    if cVelocity then
        local ref
        for p in pairs(parts) do ref = p break end
        local vel = ref and ref.AssemblyLinearVelocity or Vector3.zero
        local flat = Vector3.new(vel.X, 0, vel.Z)
        if flat.Magnitude > 3 then
            local from = centre - Vector3.new(0, size.Y / 2 - 0.2, 0)
            local a = cam:WorldToViewportPoint(from)
            local b = cam:WorldToViewportPoint(from + flat * C.VelocitySecs)
            if a.Z > 0 and b.Z > 0 then
                local av, bv = Vector2.new(a.X, a.Y), Vector2.new(b.X, b.Y)
                line2D(e.velLine, av, bv, 2)
                e.velLine.BackgroundColor3 = hc
                e.velTip.Visible = true
                e.velTip.Position = UDim2.fromOffset(bv.X, bv.Y)
                e.velTip.BackgroundColor3 = hc
            else
                e.velLine.Visible, e.velTip.Visible = false, false
            end
        else
            e.velLine.Visible, e.velTip.Visible = false, false
        end
    else
        e.velLine.Visible, e.velTip.Visible = false, false
    end
    if cOffScr then
        local vpSize = cam.ViewportSize
        local sp = cam:WorldToViewportPoint(centre)
        local onScreen = sp.Z > 0
            and sp.X >= 0 and sp.X <= vpSize.X and sp.Y >= 0 and sp.Y <= vpSize.Y
        if onScreen then
            e.arrow.Visible, e.arrowDist.Visible = false, false
        else
            local rel = cam.CFrame:PointToObjectSpace(centre)
            local d = Vector2.new(rel.X, -rel.Y)
            d = d.Magnitude > 1e-4 and d.Unit or Vector2.new(0, -1)
            local mid = Vector2.new(vpSize.X / 2, vpSize.Y / 2)
            local at = mid + d * (math.min(vpSize.X, vpSize.Y) * C.OffScreenRadius)
            e.arrow.Visible = true
            e.arrow.Position = UDim2.fromOffset(at.X, at.Y)
            e.arrow.Rotation = math.deg(math.atan2(d.Y, d.X))
            for _, bar in ipairs(e.arrow:GetChildren()) do
                if bar:IsA("Frame") then bar.BackgroundColor3 = hc end
            end
            e.arrowDist.Visible = true
            e.arrowDist.Position = UDim2.fromOffset(at.X - d.X * 24, at.Y - d.Y * 24)
            e.arrowDist.Text = math.floor(dist) .. "m"
        end
    else
        e.arrow.Visible, e.arrowDist.Visible = false, false
    end
end
function ESP:Init()
    if started then return self end
    started = true
    buildGui()
    renderConn = RunService.RenderStepped:Connect(function()
        local cam = Workspace.CurrentCamera
        if not cam then return end
        for _, c in ipairs(vpCams) do
            c.CFrame, c.FieldOfView = cam.CFrame, cam.FieldOfView
        end
        if not C.Enabled then
            if not disabledDone then
                for _, e in pairs(tracked) do pcall(hideEntry, e) end
                echoVP.Visible, hullVP.Visible, bodyVP.Visible = false, false, false
                disabledDone = true
            end
            return
        end
        disabledDone = false
        wantHull, wantBody, wantEcho = false, false, false
        local now = os.clock()
        local doRay = false
        if now - lastRay >= 1 / math.max(C.RayHz, 1) then doRay = true; lastRay = now end
        local camPos = cam.CFrame.Position
        local n = 0
        for model, e in pairs(tracked) do
            if typeof(model) ~= "Instance" or not model.Parent then
                ESP:Untrack(model)
            else
                local ref = e.ref
                if not ref or not ref.Parent then
                    ref = next(e.parts)
                    e.ref = ref
                end
                local md = cfgOf(e.opts and e.opts.config, "MaxDistance")
                local d
                if ref then
                    d = (ref.Position - camPos).Magnitude
                else
                    d = 0
                end
                if d > md then
                    hideEntry(e)
                else
                    n = n + 1
                    cand[n] = e
                    candDist[n] = d
                    e.model = model
                end
            end
        end
        for i = n + 1, candPrev do cand[i] = nil; candDist[i] = nil end
        candPrev = n
        local budget = math.max(1, math.floor(C.MaxRendered))
        if n > budget then
            for i = 1, n do cand[i].sortD = candDist[i] end
            table.sort(cand, function(a, b) return a.sortD < b.sortD end)
            for i = budget + 1, n do hideEntry(cand[i]) end
            n = budget
        end
        for i = 1, n do
            local e = cand[i]
            local ok, err = pcall(renderEntry, e.model, e, cam, camPos, now, doRay)
            if not ok and C.Debug then warn("[ESP] " .. tostring(err)) end
        end
        echoVP.Visible = C.Enabled and wantEcho
        hullVP.Visible = C.Enabled and wantHull
        bodyVP.Visible = C.Enabled and wantBody
    end)
    return self
end

function ESP:Track(model, opts)
    if typeof(model) ~= "Instance" or tracked[model] then return end
    if not started then self:Init() end
    if opts and opts.config then
        for k in pairs(opts.config) do
            if not PER_TARGET[k] then
                warn(("[ESP] opts.config.%s is not overridable per target; set ESP.Config.%s instead")
                    :format(tostring(k), tostring(k)))
            end
        end
    end
    trackSeq = trackSeq + 1
    local e = {
        model = model, opts = opts, parts = {}, echo = {}, hist = {},
        phase = (trackSeq % 20) * 0.1,
    }
    buildEntryGui(e)
    tracked[model] = e
    rebuildParts(e)
    return e
end
function ESP:Refresh(model)
    local e = tracked[model]
    if e then e.hres = nil rebuildParts(e) end
end
function ESP:SetHealth(model, cur, max)
    local e = tracked[model]
    if not e then return end
    e.pushCur, e.pushMax = cur, max
    return e
end

function ESP:SetHealthSource(model, spec, maxSpec)
    local e = tracked[model]
    if not e then return end
    e.opts = e.opts or {}
    e.opts.health, e.opts.maxHealth = spec, maxSpec
    e.hres = nil
    return e
end
function ESP:SetConfig(tbl)
    for k, v in pairs(tbl) do C[k] = v end
    return C
end
function ESP:GetTracked()
    local t = {}
    for m in pairs(tracked) do t[#t + 1] = m end
    return t
end
function ESP:Untrack(model)
    local e = tracked[model]
    if not e then return end
    destroyEntry(e)
    tracked[model] = nil
end
function ESP:IsTracked(model) return tracked[model] ~= nil end
function ESP:UntrackAll()
    for m in pairs(tracked) do self:Untrack(m) end
end
function ESP:TrackPlayers(includeSelf)
    if not started then self:Init() end
    local function hook(plr)
        if playerConns[plr] then return end
        local function onChar(ch)
            if not ch then return end
            task.defer(function()

                if started then self:Track(ch, { name = plr.Name }) end
            end)
        end
        playerConns[plr] = plr.CharacterAdded:Connect(onChar)
        if plr.Character then onChar(plr.Character) end
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if includeSelf or plr ~= LocalPlayer then hook(plr) end
    end
    if not playerAddedConn then
        playerAddedConn = Players.PlayerAdded:Connect(function(plr)
            if includeSelf or plr ~= LocalPlayer then hook(plr) end
        end)
    end
    if not playerLeftConn then
        playerLeftConn = Players.PlayerRemoving:Connect(function(plr)
            local c = playerConns[plr]
            if c then pcall(function() c:Disconnect() end) playerConns[plr] = nil end
        end)
    end
end
function ESP:Destroy()
    started = false
    self:UntrackAll()
    if playerAddedConn then playerAddedConn:Disconnect(); playerAddedConn = nil end
    if playerLeftConn then playerLeftConn:Disconnect(); playerLeftConn = nil end
    for plr, conn in pairs(playerConns) do
        pcall(function() conn:Disconnect() end)
        playerConns[plr] = nil
    end
    for _, conn in ipairs(panelConns) do pcall(function() conn:Disconnect() end) end
    table.clear(panelConns)
    if renderConn then renderConn:Disconnect(); renderConn = nil end
    if gui then pcall(function() gui:Destroy() end) end
end
function ESP:CreatePanel(hotkey)
    if not started then self:Init() end
    local panel = create("Frame", {
        Size = UDim2.fromOffset(236, 624), Position = UDim2.fromOffset(24, 60),
        BackgroundColor3 = Color3.fromRGB(14, 15, 20), BorderSizePixel = 0,
        Active = true, Draggable = true, ZIndex = 20, Parent = gui,
    })
    create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = panel })
    create("UIStroke", { Color = C.Accent, Thickness = 1, Transparency = 0.6, Parent = panel })
    create("UIListLayout", {
        Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = panel,
    })
    create("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8), Parent = panel })
    local ord = 0
    local function nextOrd() ord = ord + 1 return ord end
    create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
        Text = "ESP  v" .. ESP.Version, TextSize = 11, TextColor3 = C.Accent,
        TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = nextOrd(),
        ZIndex = 20, Parent = panel,
    })
    local ORDER = { "Outline", "Solid", "Glass", "Gradient", "Ghost" }
    do
        local b = create("TextButton", {
            Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Color3.fromRGB(34, 36, 46),
            AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 11,
            TextColor3 = C.Accent, LayoutOrder = nextOrd(), ZIndex = 20, Parent = panel,
        })
        create("UICorner", { CornerRadius = UDim.new(0, 5), Parent = b })
        local function paint() b.Text = "STYLE  ‹ " .. C.Style .. " ›" end
        paint()
        b.MouseButton1Click:Connect(function()
            local i = 1
            for k, v in ipairs(ORDER) do if v == C.Style then i = k break end end
            C.Style = ORDER[(i % #ORDER) + 1]
            paint()
        end)
    end
    local function toggle(name, key)
        local b = create("TextButton", {
            Size = UDim2.new(1, 0, 0, 23), BackgroundColor3 = Color3.fromRGB(26, 28, 36),
            AutoButtonColor = false, Font = Enum.Font.Gotham, TextSize = 11,
            LayoutOrder = nextOrd(), ZIndex = 20, Parent = panel,
        })
        create("UICorner", { CornerRadius = UDim.new(0, 5), Parent = b })
        local function paint()
            b.Text = (C[key] and "● " or "○ ") .. name
            b.TextColor3 = C[key] and C.Accent or Color3.fromRGB(130, 135, 148)
        end
        paint()
        b.MouseButton1Click:Connect(function() C[key] = not C[key]; paint() end)
    end
    local function slider(name, key, min, max)
        local row = create("Frame", {
            Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = Color3.fromRGB(26, 28, 36),
            BorderSizePixel = 0, LayoutOrder = nextOrd(), ZIndex = 20, Parent = panel,
        })
        create("UICorner", { CornerRadius = UDim.new(0, 5), Parent = row })
        local lbl = create("TextLabel", {
            Size = UDim2.new(1, -10, 0, 15), Position = UDim2.fromOffset(6, 1),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
            TextColor3 = Color3.new(1,1,1), TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 20, Parent = row,
        })
        local track = create("Frame", {
            Position = UDim2.fromOffset(6, 21), Size = UDim2.new(1, -12, 0, 4),
            BackgroundColor3 = Color3.fromRGB(10, 11, 15), BorderSizePixel = 0,
            ZIndex = 20, Parent = row,
        })
        create("UICorner", { CornerRadius = UDim.new(0, 2), Parent = track })
        local fill = create("Frame", {
            Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Accent,
            BorderSizePixel = 0, ZIndex = 20, Parent = track,
        })
        create("UICorner", { CornerRadius = UDim.new(0, 2), Parent = fill })
        local function paint()
            lbl.Text = name .. "   " .. string.format("%.2f", C[key])
            fill.Size = UDim2.fromScale((C[key] - min) / (max - min), 1)
        end
        paint()
        local drag = false
        local function set(x)
            C[key] = min + (max - min)
                * math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
            paint()
        end
        track.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = true; set(i.Position.X) end
        end)
        panelConns[#panelConns + 1] = UserInputService.InputChanged:Connect(function(i)
            if drag and i.UserInputType == Enum.UserInputType.MouseMovement then set(i.Position.X) end
        end)
        panelConns[#panelConns + 1] = UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
        end)
    end
    toggle("Inverted hull", "Hull")
    toggle("Hull colour = health", "HullByHealth")
    toggle("Body chams", "Body")
    toggle("Occlusion split", "OcclusionSplit")
    toggle("Info card", "Card")
    toggle("Radial health ring", "Ring")
    toggle("Motion echo", "Echo")
    toggle("Echo age tint", "EchoTint")
    toggle("Velocity vector", "Velocity")
    toggle("Off-screen arrows", "OffScreen")
    toggle("Damage flash", "DamageFlash")
    slider("Hull thickness", "HullThick", 0.02, 0.5)
    slider("Body transparency", "BodyTransparency", 0, 0.95)
    slider("Ring radius", "RingRadius", 1, 7)
    slider("Echo ghosts", "EchoCount", 1, 8)
    slider("Echo spacing", "EchoSpacing", 0.02, 0.25)
    slider("Velocity length", "VelocitySecs", 0.1, 1.5)
    local key = hotkey or Enum.KeyCode.RightAlt
    panelConns[#panelConns + 1] = UserInputService.InputBegan:Connect(function(i, gp)
        if not gp and i.KeyCode == key and panel.Parent then
            panel.Visible = not panel.Visible
        end
    end)
    return panel
end
return ESP
