# The ejection

A pilot leaves a doomed ship in its cockpit, which becomes a pod of its own, while the ship drifts
on and is destroyed. The player's pilot is then picked up by a nanny ship, taken by the enemy's
Antanov, or shot down by a Sabre, as the mission's odds fall, in a cutaway the mission ends on.

The orders are [`aieject.zig`](../../src/engine/game/aieject.zig)'s, and Scoop Up and the tractors
[`tractor.zig`](../../src/engine/game/tractor.zig)'s ([Source files](#source-files)). The views the
camera watches it from are in [Camera](camera.md#the-ejections-views).

## Ejecting

The player's pilot ejects with EJECT (`0x00413D8D`, once a press): while the mission goes on or the
ship waits to blow up (`mission_ending` 0 or 8), outside a multiplayer game, not in the Kamov, not
where the mission disabled it (object flag `0x40000`), and with the ship's current order Player
Control (100) or Eject Player (118). The key clears the ship's ejected flag (`0x800`), switches the
camera to view 7 of the ship, locked and forced, uncloaks the ship, and pushes Eject (30).

Eject Player is the player's warning ([Destruction](objects.md#destruction)): `object_destroyed`
gives it the player's ship as its armour runs out, and the ship drifts, unpowered, for 400 to 599
ticks before it explodes. `order_eject_player_init` (`0x00416310`) lights the display's eject marker
([HUD](hud.md#the-jump-prompt-the-eject-marker-and-the-scanner)) and has the cockpit glow red: every
part of the cockpit's model takes the colour (1, 0, 0) (`0x00416383`) and light mask 1
(`0x004163E1`), so the fill lights reach it but not the first key light, until the mission ends.

An AI pilot ejects under Eject Spin (108), which `object_destroyed` gives a ship of the player's
wing whose eject roll falls below 40, or one told to eject before exploding. `order_eject_spin_init`
(`0x004160D0`) marks the ship unpowered and ejected, and sets it turning by up to 0.1 a tick either
way about each axis, drawn from `rand` roll first. 200 ticks on, `order_eject_spin` (`0x00416190`)
pops it and pushes Eject, the flag cleared for the push and set again, and the pod harmed by nothing
but a player's ship.

## The pod

`order_eject_init` (`0x00415BD0`) finds the first child of the ship's root that is a part of class
2, the cockpit ([`shp.md`](../formats/shp.md#part-tag-0x01)), and `eject_separate` (`0x004156C0`)
splits the ship there:

- A new object of the ship's type takes every other part of the root, and the ship's place, velocity
  and rotation. It is marked ejected and flag `0x1000000`, which lets its smoke go, and nothing
  else: neither targetable nor powered. It is neutral, passes through the pod, recharges no shields,
  and drifts, keeping 0.99 of its velocity each update. Its rotation turns on by a pitch of 0.02 and
  a yaw and a roll of up to 0.005 either way (`0x004158CB`), and `EJECT01` sounds from it, on the
  guaranteed voices for the player. It takes the Eject order 106, whose `init` (`0x00416080`) gives
  it 200 ticks before `object_destroyed` ends it (`0x004160A0`).
- The pod keeps the ship's slot and its cockpit. Its smoke goes, and it is unpowered and ejected,
  passes through the new object and aims its order at it, and has no guns, racks, shields or armour,
  no shields recharging, no motion routine, and nothing able to harm it. Its invulnerability is kept
  for later.

Each part at either object's root has bit 0 of its face mask cleared (`+0xD4`), so its cap faces
show ([Rendering](rendering.md#culling)): the cockpit, open beneath on the ship, closes into the
pod, and the ship closes where the cockpit left it.

Both objects move their origin to their parts' centre (`object_recentre`). At the cockpit's last
eject point (attachment kind 6), 100 puffs of `eject_flash_template` (`0x0051CF94`) burst out: 50 to
100 ticks each, growing to 100 across, from yellow to orange to nothing (`eject_init`,
`0x00415610`), turned as the pod, spread (1, 1, 0.2), at 20 to 25 a tick, carrying a quarter of the
pod's velocity. The pod's velocity gains 50 along the eject point's Z axis (`0x00415B9B`). The game
also gives the point a smoke effect of kind 4 along the other way, which it never draws.

`order_eject` (`0x00415C50`) runs the pod in stages, its state holding when the stage ends
(`+0x00`), the stage (`+0x04`) and the kept invulnerability (`+0x08`):

| Stage | What happens |
|---|---|
| 0 | Clearing the ship, for 100 ticks (`0x00415BB5`). Then the pod brakes, keeping 0.97 of its velocity each update, powered again, its invulnerability back. An AI pilot's goes to 1, the player's to 2 |
| 1 | An AI pilot's pod, adrift for good |
| 2 | The player's pod drifts for 100 ticks; then the pilot calls on the radio (`ejt_015` or `ejt_016`) |
| 3 | It waits 500 ticks more; then the pickup |
| 4 | The pickup under way |

In a multiplayer game the order ends at once, and a player's pod is disabled once clear.

## The pickup

At the pickup the mission shows only its end (`mission_showing`, `0x00587CD4`, set to 4):
`mission_frame` draws every object but the player's pod and the ship in the cutaway slot as hidden.
A roll of `rand`, over `rescue_odds_rescued`, `rescue_odds_captured` and `rescue_odds_killed`
(`0x0051CF98`, `0x0051CF90`, `0x0051CF9C`) together, settles the pilot's fate: below the first the
pilot is rescued (`mission_ending` 2), below the first two captured (3), and past both killed (1). A
mission starts with 100, 0 and 0, which its `SetRescueProbabilities` command sets
(`cmd_SetRescueProbabilities`, `0x004598D0`).

The pod moves out of everything's way to (0, -10000000, 0) (`0x00415CFE`), turned to the world's
axes, and the cutaway slot's ship is made:

| Fate | Ship | Where | Order | View |
|---|---|---|---|---|
| Rescued | A nanny ship (`0x18`) | 15000 short of the pod along Z (`0x004DC564`), turned to the world's axes | Scoop Up (107) | `0x1C` |
| Captured | The Antanov (`0x46`) | Likewise | Scoop Up | `0x1C` |
| Killed | A Sabre (`0x2B`) | (20000, 10000, -20000) from the pod, turned a quarter turn back about Y from it (`0x00415EFE`) | Eject Fighter Attack (113) | `0x1D` |

The camera takes the view of the ship, locked and forced. For the Sabre the pod's radius doubles,
which makes it a larger target. The pilot's word goes out on the radio: `nanpkup`, `antpkup` or
`ejtkll`.

### Scoop Up

A nanny ship or the Antanov takes the pod in with a tractor (`tractors`, `0x0051D10C`): two beams, a
bubble round the pod and a light on it. `tractors_init` (`0x0041BB90`) clears the five as a mission
loads and holds `laser2` for the beams (`tractor_texture`, `0x0051D120`), and `tractors_free`
(`0x0041BBC0`) frees those in use as it ends.

`order_scoop_up_init` (`0x0041BBF0`) takes the first free tractor (`tractor_create`, `0x0041D090`)
with its light, `Tractor Light`, green, reaching 10000, hanging from the pod; and the ship and the
pod pass through each other. `order_scoop_up` (`0x0041BCC0`) keeps the tractor (`+0x00`), the stage
(`+0x04`), when the stage began (`+0x08`), the pod (`+0x0C`), when it last ran (`+0x10`) and how far
the second beam lags the first (`+0x14`). While the stage is below 4 it steers at the pod. Should
the pod be gone first, a stand-in or exploding, the ship closes its doors and gives up.

| Stage | Lasts (`0x004E3E1C`) | What happens |
|---|---|---|
| 0 | | Claims the pod, marking it with object flag `0x1000`; a pod already claimed ends the order |
| 1 | | Flies at the pod: full throttle beyond 20000, 0.4 beyond 10000, and none nearer. Near the pod, within six times its flight model's speed over its pitch rate, where its nose points less than 0.7 toward the pod, it stops. Once its inputs and throttle are within 0.025 and its rates of turn within 0.02, it moves on |
| 2 | | Stops, makes its beams at the first two tractor points of its hull (point list kind 6 on the part named `Nanny` or `Antanov`) and a bubble 1.5 times the pod's radius, opens its doors and sounds `dooropen` from the root's second child, facing along it. The second beam lags by up to 0.2 of the time, from `rand` |
| 3 | 100 | The first beam comes on over the time and the second after its lag; the bubble glows to its full by half the time. The light shines at its full throughout. Then the pod is frozen |
| 4 | | Draws the pod toward 6300 out from the door point (point list kind 0 on the part named `nan_door3` or `Antanov`), along the part's Z axis: at 900 a second at the point, rising to 1800 at 3000 away and beyond. Within 500 it moves on |
| 5 | | Draws it on to 3000 out from a nanny ship's door, 3400 from the Antanov's, at 900 a second. Within 300 it closes its doors and sounds `doorclos` |
| 6 | 50 | The beams, the light's reach and the bubble go out, the bubble by half the time. The beams hang as they were last aimed |
| 7 | 250 | Waits, showing nothing |
| 8 | | The order ends, and the pod, aboard, leaves the mission (`object_retire`) |

The doors are the root's second child of a nanny ship, and its second and third of the Antanov:
their `opendoor` track plays forward from its start to open them, and back from where it is to close
them. In a multiplayer game the order waits for every player before making the beams and before the
pod leaves. `order_scoop_up_exit` (`0x0041BC70`) clears the pod's flag `0x1000` and frees the
tractor (`tractor_free`, `0x0041D1A0`).

A beam (`tractor_beam_mesh`, `0x0041CBC0`, `TractorBeam_Mesh`) is a square 100 across at its emitter
and three ribbons 100 across and 400 long crossing on its axis at a third of a half turn apart, over
`laser2` from 0.04 to 0.99 of the way across it, added by the alpha of the object's own colours,
never culled nor tested against the view (object flags `0x87800`). It hangs from the hull's part at
its point. `tractor_beam_aim` (`0x0041CE00`), in stages 3 to 5, turns it to the pod and stretches
the ribbons' far corners to reach it. `tractor_beam_fade` (`0x0041CED0`) sets each quad's near
corners clear and its far ones green at an alpha from 0 to 1.

The bubble (`shield_bubble_object`, `0x0049E370`) is the shields' finest sphere with colours of its
own, its texture laid on by each vertex's X and Y, hanging from the pod. `tractor_bubble_glow`
(`0x0041CF80`) runs green waves round it: vertex `n` takes `(sin(0.3 n + 3 t) + 1)` times the
brightness, 0 to 1, times 0.05, solid. In stages 4 and 5 it glows at its full, `t` being the seconds
the stage has run. Each stage from 3 to 6 adds the beams, the bubble and the light to the scene.

### Eject Fighter Attack

`order_eject_fighter_attack` (`0x004161F0`) flies the Sabre at the pod, its target, and sets the
throttle full. Within 20000 of the pod it fires its guns for 100 ticks, and rolls where its nose
points within 0.95 of the pod. Once the pod is exploding it flies on at full throttle.

The pod's end is a halt ([Destruction](objects.md#destruction)): while `mission_showing` is not 0,
the player's exploding object bursts at once, and neither switches the camera nor sets the ending.

## The mission's end

`mission_frame` ends the mission once the camera has watched long enough (`mission_over`,
`0x0052A414`): views 8, `0x1A` and `0x1B`, the player's ship destroyed, after 600 ticks
(`0x0049267E`); view `0x1C`, the pickup, after 1200 (`0x0049268D`); and view `0x1D` 500 ticks after
the pod began to explode (`0x004926AD`), the view holding its time until then.

## Source files

**Unknown:** the ejection's orders' source file. Their code lies after `airipper.cpp`'s and before
`jump.cpp`'s, and no string places it. `tractor.cpp`'s asserting code is `tractor_create`;
**Unverified:** that the code before it from `tractors_init`, Scoop Up's among it, is the file's
too.

## In OpenReliant

- OpenReliant moves the parts between the objects its own way: the new object takes the ship's model
  as it stands, the pod a new model of the type, and each has the other's parts taken out of it
  (`objects.destroyPart`). A part taken out counts toward neither its object's size nor its smoke's
  engine glow.
- OpenReliant adds the tractors' beams, bubble and light to the scene as it draws the frame, where
  the ship and the pod are drawn, rather than as Scoop Up runs; the beams are aimed there too.
- **Improvement:** in the smooth shield style ([Shields](effects.md#shields)) the bubble is drawn
  on the shields' finer sphere of 48 slices by 40 bands, so its outline is round. Its glow is worked
  out on the game's sphere's vertices, and the finer sphere's take their colours from between them,
  so its waves run as the game's do. `--original` keeps the game's sphere.
- **Improvement:** with smooth motion the pod glides on between the ticks as it is drawn in, as
  what flies does (`create.Slot.glide`); the game places it a tick at a time. Scoop Up measures from
  where it placed the pod, which the game's frame has it at.
- **Fix:** `tractor_create` returns -1 with all five tractors in use, which Scoop Up then reads past
  the five with; OpenReliant has the ship take the pod in without beams, bubble or light.
- **Fix:** odds of nothing at all divide by zero in the game; OpenReliant has the pilot rescued.
- Mission 0, OpenReliant's sandbox, gives the three fates even odds, and `openreliant` starts a
  mission again once it is over.

Eject and Eject Spin post the ship's Destroyed event as they begin, and Scoop Up the ship's
ObjectScooped as it has the pod aboard ([Script VM](script-vm.md#events)).

Not ported: the radio's words ([#48](https://github.com/vdmkenny/openreliant/issues/48)), and a
multiplayer game ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
