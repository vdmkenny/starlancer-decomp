# Sound

How the game plays its sounds through the Miles Sound System (`MSS32.DLL`): the banks' sounds on voices of their own, the effects placed in 3D around the camera, and the music. OpenReliant's code is [`game/hog_snd.zig`](../../src/engine/game/hog_snd.zig) and [`game/sound3d.zig`](../../src/engine/game/sound3d.zig); what stands in for Miles is in [Sound in OpenReliant](../port/sound.md). The banks are [`.fat` files](../formats/fat.md).

## Start-up

`WinMain` calls `sound_init` (`0x00481440`) with 10 voices. It starts Miles, opens a digital driver at 22,050 Hz in 16-bit stereo, or at 11,025 Hz where that fails (`sound_driver_open`, `0x00482D10`), allocates a sample for each voice, and starts the 100 Hz timer, `tick_timer` (`0x004827C0`). Asked for them, it also opens the CD's audio and sets aside two more samples and a double buffer for the radio's speech. `sound_3d_providers` (`0x004817E0`) lists Miles's 3D providers and `sound_3d_open` (`0x00481900`) opens the one the settings name, else the first of `Miles Fast 2D Positional Audio`, `Aureal A3D Interactive (TM)`, `Creative Labs EAX (TM)` and `RAD Game Tools RSX 3D Audio`, with `Dolby Surround` for one of them where asked. It allocates a 3D voice for each sample the provider supports, up to 64, and sets the effects up on them (`sound3d_init`). That sets the provider's room to EAX's generic one (`AIL_set_3D_room_type`, 0), with a damping of 1 and an effect volume and decay time of 0, and each 3D sound it plays gets an effects level of 0, with no obstruction or occlusion: the room's reverb is never heard.

As the game's window is put away (`window_suspended`, `0x005DDD28`, which `0x004A8260` sets and `input_init` clears) while the renderer runs (`app_active`, `0x005D6CAC`), the message pump (`message_pump`, `0x004AAB20`) pauses the music, the 3D voices and the voices, where no video is playing, and waits on the window's messages; once the window is back, it resumes the sound. `app_inactive_paused` (`0x005D6CAD`) remembers that it paused. Only in a multiplayer session with a mission loaded does it pause the mission too (`game_pause`), which then stays in its [pause menu](pause-menu.md). In single player the mission is not paused, and the timer's ticks go on while the pump waits. **Unverified:** that the mission runs the ticks it missed once the window is active again.

## Volumes

Four settings, each from 0 to 127, in `[Sound]` of `starlancer.ini`, which the options screen resets
to their defaults:

| Key | Address | Default | Scales |
|---|---|---|---|
| `Mastervolume` | `0x005D5A70` | 127 | everything |
| `Fxvolume` | `0x005D5A74` | 80 | the banks' sounds and the 3D sounds |
| `Musicvolume` | `0x005D55EC` | 80 | the music |
| `Speechvolume` | `0x005D5E88` | 127 | the radio's speech |

`sound_volumes_apply` (`0x00482990`) sets them again on the music and every voice playing when one
changes.

## The banks' sounds

A voice of `sound_voices` (`0x00565080`) is `0x20` bytes:

| Offset | Field |
|---|---|
| `0x00` | Miles's sample |
| `0x04` | Set while the display holds the voice (`hud_draw`) |
| `0x08` | The playing sound's priority, from its bank entry |
| `0x10` | Set while it fades out |
| `0x14` | What each step of the fade takes off its volume |
| `0x18` | The sound's own rate |
| `0x1C` | Its volume as asked, 0 to 127 |

`sound_play` (`0x00481F80`) plays sound `n` of a bank at a volume, a loop count, a pan and a pitch.
It takes the first voice past voice 0 that has finished; else the first that was stopped; else the
voice of lowest priority not held by the display, which it ends, if that priority is below the new
sound's. `sound_play_on_voice` (`0x004820C0`) plays on a given voice. `sound_start` (`0x004826A0`)
hands Miles the WAVE file at the entry's offset in the bank, at its own rate times `2^(n/24)` for a
pitch of `n` quarter tones (`0x00481400`, clamped to 96 each way), and at the volume
`round(((Fxvolume × volume) / 128) × Mastervolume / 127)`.

**Improvement:** OpenReliant divides by 127 where the game multiplies by a rounded reciprocal, for
the master volume's share (`0x004DC6B0`) and the engine's volume (`0x004DC9C8`), and divides a 3D
sound's length by the bytes a tick plays where the game multiplies by their reciprocal
(`0x004DC8B8`).

Every five ticks `tick_timer` steps the fades: a fading voice loses its step of volume and ends at
nothing. `sound_voice_fade` (`0x004824C0`) and `sound_fade_all` (`0x00482510`) start them;
`sound_pause_all` (`0x004825D0`) and `sound_resume_all` (`0x00482630`) stop the playing voices and
start them again.

### Positional sounds of a frame

`sound_buffer_at` (`0x00482160`) gathers a sound of the first 18 slots at a place in the world: its
level in each ear from its distance and which side of the camera it lies. Once a frame
`sound_buffers_play` (`0x004822F0`) plays each slot gathered as sound `n` of `bank_stdsmp`, panned
by its two levels and as loud as the louder, then clears them.

## 3D sounds

Each effect is a definition of the table at `0x00507140`, `0x44` bytes each, closed by a record
whose entry is -1; `make sound-tables` derives
[`sound3d/sounds.zig`](../../src/engine/game/sound3d/sounds.zig) from it.

| Offset | Field |
|---|---|
| `0x00` | The sound in `smp3d.fat` |
| `0x04` | Its share of the effects volume |
| `0x08` | Loop count, 0 for ever |
| `0x0C` | What it follows (below) |
| `0x10` | Minimum distance: heard at full volume within it |
| `0x14` | Maximum distance: not started, and ended, beyond it |
| `0x18`, `0x1C` | The cone's inner and outer angles, in degrees |
| `0x20` | The volume outside the outer cone, of 127 |
| `0x24` | Its name, such as `GUN01`, `EXPLOSION01`, `PSHIP01` |

What a sound follows sets its place as it starts and each frame after:

| Value | Follows |
|---|---|
| 0 | A shot, by its record in the bullet pool: where it is, and its heading |
| 1 | A point and a direction given as it starts |
| 2 | A point given as it starts |
| 3 | A missile, by its record at `0x005887F0` |
| 4 | An object, by its slot; the player's own 200 units from its ship |

A 3D voice is `0x44` bytes at `0x00563F60`: Miles's 3D sample at `0x00`, what it follows at
`0x04`, its owner at `0x08` (-1 while free), the priority at `0x10`, the maximum distance at `0x14`,
the point and direction at `0x18` and `0x24`, whether it was borrowed at `0x34`, the sound at
`0x38`, the frame it started at `0x3C`, and the sound decompressed to PCM at `0x40`.

### Voice classes

Each 3D voice has a class (`0x0058CB1C`), from one of three rows at `0x005085B4` by how many voices
the provider has: up to 14, up to 30, or more. The names are the executable's own (`0x00508614`):

| Class | Name |
|---|---|
| 0 | not reserved |
| 1 | player guns |
| 2 | player fx |
| 3 | explosions |
| 4 | guaranteed |
| 5 | player engines |
| 6 | player burners |
| 7 | flyby |

A sound of classes 5 and 6 plays on the one voice of its class. Any other takes a voice of its own
class that is free or borrowed, else such a voice of class 0, else borrows a free voice of any
class but 4, 5 and 6.

### Playing

`sound3d_play` (`0x0049D360`) takes a place and a direction, an owner, the sound, a volume and a
class; a further argument goes unread. It places the sound by what it follows, relative to the
camera and scaled by 0.0004 into Miles's units, its velocity by `1e-5` into a millisecond's. A
sound beyond its maximum distance is not started, but for the engines' (`PSHIP01` to `PSHIP12`) and
`BURNER01`. It decompresses the bank's ADPCM into PCM (`AIL_decompress_ADPCM`), since Miles's 3D
samples play PCM only, and plays it at the volume `Mastervolume / 127 × Fxvolume × share × volume`,
with the definition's loop count, cone and distances, at 22,050 Hz; the two explosions at
`18050 + 7000 × rand() / 32767`. Miles's `y` points up where the camera's points down, so every
place, direction and velocity goes over with `y` negated.

Once a frame `sound_3d_update` (`0x00481BF0`) runs the engine's sound, then each voice playing. A
voice past its sound's length, `length / 441` ticks of 16-bit sound at 22,050 Hz, is freed but for
the engine's and the afterburner's. A shot's and a missile's stay where they started; the rest are
placed again by what they follow, and freed once beyond their maximum distance or once their object
has gone. Nothing gives an object its voice (`+0xB96` stays `0xFFFF`), so `missile_end`, which ends
a missile's, never does.

**Improvement:** a missile's voice follows it as an object's does, and is its own, so it ends with
it; it keeps its full volume half as far again (`sound3d.MissileSound.follows`).

### The player's engine

`sound3d_engine_sound` (`0x0049DCB0`) picks the engine's sound for the player's ship type:
`PSHIP01` on, by type; types from 244 count again from 0. A mission starts it as the ship launches
(`launch_reliant_run`). `sound3d_engine_update` (`0x0049DCF0`) keeps it going through three states
(`0x0058CB04`):

- Idle: the engine's rate and volume by the ship type's row of the tables at `0x00508740`,
  `0x00508774`, `0x005087A8` and `0x005087DC`, at no throttle plus the throttle's share of what full
  throttle adds.
- Burning, while the afterburner or reverse thrust is on: `BURNER01` on the afterburner's voice, its
  volume growing from 5 by 0.8 a tick to 70, and its rate `12000 + 90 × that`, or 7000 in reverse.
- Cooling, once let go: the afterburner's sound fades over 25 ticks while the engine's plays on.

In view 13 neither is heard.

### Ships flying past

The same update hears each fighter flying past the camera: within 10,000 units, not disabled,
hidden or exploding, at a throttle of 0.4 or more and moving at 100 or more, its velocity at least
a right angle from where the camera looks, or for a hostile one at least 41 degrees. A hostile
ship sounds `PASS01`, another `PASS02`, on a voice of class 7, no more than once in 500 ticks, or
200 for the player's own, which is not heard in views 0 to 3, 12 and 15. The frame it was heard is
kept at `+0x67C`.

## Music

`music_play` (`0x00482A80`) plays a file as a Miles stream at a level, a loop count and now, or
once the music playing has faded out. The mission script's `PlayMusic` (`cmd_PlayMusic`) plays
`music\` and the name it is given, for ever, at level 80. A piece the table at `0x005017A0` names
loops back to its own point, a byte offset into its data, once it has played through; the rest from
the start. The stream's volume is `round(((Musicvolume × level) / 127) × Mastervolume / 127)`.
`music_fade_out` (`0x00482960`) takes 5 off the level every five ticks until the stream closes, and
`music_update` (`0x00482C30`) then starts the piece waiting. Mission 1 plays `new_launch.wav` as its
wing launches, and `new_searching mission 09.wav` once it is out.

## Where the sounds come from

- A shot the step hears (`guns.heard`) plays its gun type's sound following it, on a voice of the
  player's guns for the player's shots, of the guaranteed ones for the Huge Guns'.
- A flak shell plays `FLAK01` as it bursts.
- The player's ship warns, sound 1 of `betty.fat`, once a quadrant has lost its shield and half its
  armour ([Objects](objects.md)).
- A Huge Gun's shot striking a component plays `EXPLOSION01` where it strikes.
- A shot through to a hull plays `ARMOUR01` where it struck, facing the camera, or `PLAYERHIT` on
  the player's ship, following it, at most every 30 ticks (`shieldfx_create`, `0x004A0310`). The
  game plays `ARMOUR01` at the point in the part's own frame, taken for one in the world.
  **Improvement:** OpenReliant plays it where the shot struck.
- A shield generator whose part `node_draw` finds destroyed plays `SHLDDOWN` at the part, facing
  its way, and its object loses flag `0x4000`.
- Turning the missile ring plays `MISSILESELECT` at the player's ship (`hud_target_keys`).

The display's own sounds are in [The display's sounds](hud.md#the-displays-sounds).

Not ported: the radio's speech and its double buffer; and the CD's audio.