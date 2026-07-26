# ESPLibraryV3

ESP library V3, should be my last ESP Library for a while. Completely unique style from my other libraries, designed for a specific look. Will continue to add features in the future. This library is specifically meant to support standard no-custom rig games, as well as games that have custom rigs, unorthodox character design (such as obfuscated names), and more. Supports NPCS, Players, and eventually will have support for objects.

There's no player loop or Humanoid requirement by design, specifically for custom rigs. `Track()` is the whole idea.

```lua
local ESP = loadstring(game:HttpGet("https://raw.githubusercontent.com/Atlas425/ESPLibraryV3/main/ESPLibrary.luau"))()

ESP:Init()
ESP:Track(game.Players.LocalPlayer.Character)
```

`CreatePanel()` gives you a settings UI if you want to mess with the look at runtime.
RightAlt toggles it, or pass your own keycode.

```lua
ESP:CreatePanel()
ESP:CreatePanel(Enum.KeyCode.Insert)
```

## Basic usage

```lua
ESP:Init()

--players, if the game is player-based
ESP:TrackPlayers()

--or anything else
for _, mob in ipairs(workspace.Mobs:GetChildren()) do
    ESP:Track(mob)
end

workspace.Mobs.ChildAdded:Connect(function(m) ESP:Track(m) end)
```

Settings are located at `ESP.Config`, you can change them to your liking:

```lua
ESP.Config.Style = "Glass"
ESP.Config.MaxDistance = 1200
ESP.Config.Echo = false
```

## Health

More custom rig support. Allows you to pass health values that may not be stored on the Humanoid.

```lua
ESP:Track(m, { health = 250 })                    -- constant
ESP:Track(m, { health = m.Config.Life })          -- NumberValue / IntValue
ESP:Track(m, { health = "CurrentHP" })            -- attribute on the model
ESP:Track(m, { health = "Stats.HP" })             -- child Stats, then child HP
ESP:Track(m, { health = "Config.Health" })        -- last part can be an attribute too
ESP:Track(m, { health = function(m) return State.hp, State.max end })
```

`maxHealth` takes the same forms. String paths get re-walked every read instead of
resolved once, so they survive respawns and part swaps.

If the number only exists inside your own script and there's nothing in the game tree to point at,
push it in instead. This is a plain write with no re-probe, so it's fine to call every frame:

```lua
ESP:SetHealth(mob, currentHP, maxHP)   -- overrides everything until you pass nil
```

If you don't pass anything, then it will try, in order: a Humanoid, then attributes named in
`Config.HealthAttributes`, then a NumberValue/IntValue.

That last step only looks 2 levels deep and only matches exact names, which is on purpose.
`Config.HealthValueSearch = false` turns it off if you'd rather have no health bar than a wrong one,
which matters when you're mass-tracking NPCs without passing health for each. Targets that come up
empty get re-checked every 2s so late-loading NPCs still work.

## Custom rigs

Parts are found by geometry, not by name, so randomly-named parts and arbitrary nesting are
fine and there's nothing to configure.

- Invisible parts and tiny slivers get skipped, unless skipping them would leave nothing at
  all, in which case it takes everything.
- A part that's both bigger than the rest of the model combined and invisible is treated as
  a collision hitbox and left out of the bounding box. It has to be both.
- Rigs get re-scanned every 2s.
- `Config.PartFilter = function(part, model) return keep end` if you want to override it.
  Or pass `parts = {...}` per target and skip discovery entirely.

Cloned parts get their textures cleared and `UsePartColor` set on unions.

## API

```
ESP:Init()
ESP:Track(model, opts?)              model or a bare BasePart
ESP:Untrack(model)
ESP:UntrackAll()
ESP:IsTracked(model)
ESP:GetTracked()
ESP:Refresh(model)                   re-scan parts + re-probe health
ESP:SetHealth(model, cur, max?)      push a value in, cheap enough to call every frame
ESP:SetHealthSource(model, h, max?)  point an existing target at a health source
ESP:SetConfig({ ... })
ESP:TrackPlayers(includeSelf?)
ESP:CreatePanel(keycode?)
ESP:Destroy()
```

`opts` for Track: `name`, `color`, `health`, `maxHealth`, `parts`. `name` and `color` also
take a function so you can drive them off team, faction, rarity, whatever.

```lua
ESP:Track(boss, {
    name = "BOSS",
    health = "Stats.HP",
    maxHealth = 5000,
    color = Color3.fromRGB(255, 60, 60),
})
```

## Config

```lua
Enabled = true              MaxDistance = 500

Body = true                 Style = "Gradient"        BodyTransparency = 0.55
GradientTop, GradientBottom                           OcclusionSplit = true
VisibleColor, HiddenColor                             RayHz = 15
Hull = false                HullThick = 0.14          HullByHealth = false, HullColor

Card = true                 Ring = true               RingRadius = 3.2, RingSegments = 28

Echo = true                 EchoCount = 8             EchoSpacing = 0.07
EchoTint = true, EchoTailColor                        Velocity = true, VelocitySecs = 0.45

OffScreen = true            OffScreenRadius = 0.42    DamageFlash = true, FlashTime = 0.16
Accent                      Debug = false

MinPartVolume = 0.02        MaxPartsPerRig = 64       SkipTransparent = true
HitboxRatio = 1             PartFilter = nil

HealthAttributes, MaxHealthAttributes
HealthValueSearch = true    HealthSearchDepth = 2
HealthValueNames, MaxHealthValueNames
```

Styles: `Outline`, `Solid`, `Glass`, `Gradient`, `Ghost`.

`RingSegments` is read when a target is first tracked, so set it before you track anything.

## Notes

Chams go through stacked ViewportFrames, so the real parts are never touched (slight AC measure + looks cool anyways)

Target rendering is pcall wrapped. If you don't see drawings,
`Config.Debug = true` prints the errors instead of swallowing them.