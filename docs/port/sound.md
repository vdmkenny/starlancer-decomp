# Sound in OpenReliant

The game's sound code ([Sound](../engine/sound.md)) calls the Miles Sound System. In OpenReliant it calls `mss.Driver` in [`engine/mss.zig`](../../src/engine/mss.zig), an interface with two players behind it: OpenAL Soft by default, and OpenReliant's own software mixer as the reference, which `--original` plays with. SDL3 plays either. Nothing of Miles is carried over but what its calls mean.

| Module | In place of |
|---|---|
| [`formats/wave.zig`](../../src/formats/wave.zig) | Miles's reading of WAVE files: 8- and 16-bit PCM and IMA ADPCM, decoded a frame at a time |
| [`engine/mss.zig`](../../src/engine/mss.zig) | `MSS32.DLL`: the digital driver, its samples, 3D samples and streams; `Driver`, and `Mixer`, which mixes them in software |
| [`engine/mss/voice.zig`](../../src/engine/mss/voice.zig) | Playing one sound in the software mixer: its rate, its loops, and resampling to the output's rate |
| [`engine/mss/positional.zig`](../../src/engine/mss/positional.zig) | The 3D providers the game chooses from, in the software mixer |
| [`engine/mss/master.zig`](../../src/engine/mss/master.zig) | Nothing: the master bus |
| [`platform/openal.zig`](../../src/platform/openal.zig) | The 3D providers the game chooses from (`Miles Fast 2D Positional Audio`, A3D, EAX, RSX), and the mix, with OpenAL Soft |
| [`platform/audio.zig`](../../src/platform/audio.zig) | The wave-out device Miles opened (`AIL_waveOutOpen`) |

## The driver

`mss.Driver` has a call for each `AIL_` function the game makes, named for it, on handles to samples, 3D samples and streams. A handle's status is Miles's: done once finished or never started, playing, or stopped part of the way. Samples, 3D samples and streams play a WAVE sound from memory the caller keeps, at a rate of their own, as many times as their loop count says (0 for ever). The game's decompression of its 3D sounds into PCM (`AIL_decompress_ADPCM`) has nothing to do in OpenReliant: both players decode IMA ADPCM themselves. A stream's loop block and position, byte offsets into its data, fall on the start of their ADPCM block.

What Miles made of a volume or a pan, and how its providers placed a sound, is not known here; OpenReliant takes:

- A volume's share of 127 as its gain.
- A 3D sample as DirectSound3D would have it, which the providers followed: full volume within its `min_distance`, falling off as the minimum over the distance and no further past its maximum; quietened by its cone when it faces away, to its outside volume past the outer angle; and shifted in pitch by its velocity along the line to the listener, against a speed of sound of 343 metres a second in Miles's units a millisecond. The velocity along that line is held within half the speed of sound either way.

The game sets EAX's room to the generic one, with an effect volume of 0, and each 3D sample's effects level to 0, so the original's reverb is silent. It opens no listener, so the listener stands still, and it places every sound at a point.

Three calls are not Miles's: the listener's velocity, which the 3D update sets to the player's ship's each frame; a 3D sample's radius, which a sound following an object takes from its model's radius; and a sample's room, the cockpit for a sound of `betty.fat`, the cockpit's warnings, and none for any other. They serve OpenAL's improvements; the software mixer leaves them out.

## The software mixer

`mss.Mixer` holds fixed pools of 32 samples, 32 3D samples and 4 streams, each handle an index into its pool. It resamples each sound to the output's rate by linear interpolation, pans a sample as a balance, 64 in the middle leaving both ears at full volume, 0 the left alone and 127 the right alone, and a 3D sample by how far to the side it lies, with the same power in both ears, which places it left and right only. With 32 3D samples, the game picks the voice classes' third row. The mix adds everything playing and clips the sum to full scale.

The platform mixes on a thread of its own, so the mixer takes the platform's lock around every call the game makes.

## OpenAL Soft

[`platform/openal.zig`](../../src/platform/openal.zig) plays the driver's calls with [OpenAL Soft](https://github.com/kcat/openal-soft), which renders into memory through its loopback device; the platform's audio stream pulls from it, so none of OpenAL's own device backends are built. [`deps/openal-soft`](../../deps/openal-soft/build.zig) builds it from source for the target, as a static library with its default HRTF data embedded, and always optimized, whatever the game's own build: its mixer runs in the audio stream's callback and must keep up with the device, which an unoptimized build does not under HRTF with many voices playing. OpenAL Soft takes calls from any thread, so there is no lock.

Each sample, 3D sample and stream is an OpenAL source. A bank's sound is decoded into a buffer the first time it is played and kept, by a hash of its file; a stream decodes its piece into a buffer of its own. A loop count of 0 loops the source, and a count of more than one queues the buffer that many times. A stream's loop block is its buffer's loop points (`AL_SOFT_loop_points`), and any loop count but once loops it for ever.

- A sample plays from a point a metre ahead, turned to the side by its pan, with no distance; a stereo one plays to the speakers as it is.
- A 3D sample is placed where the game puts it, in Miles's frame with `z` turned round for OpenAL's, and falls off by OpenAL's inverse distance clamped model, which is DirectSound3D's. Its cone, playback rate and velocity are OpenAL's own, its velocity in metres a second, against the same speed of sound and held as the software mixer holds it. The provider has 64 3D samples, the most the game takes; it picks the same row of voice classes as for 32 and leaves the rest to any sound.
- A stream plays to the speakers as it is.

**Improvements**, where OpenAL Soft goes past Miles:

- Every source is resampled with the 23rd order band-limited sinc resampler, where the software mixer interpolates linearly, and every change of gain, pitch or place is smoothed.
- On headphones the mix is rendered through a head-related transfer function (HRTF), which places a sound all around; on any other stereo device it is encoded as UHJ, which carries front and back as well as left and right. The output counts as headphones where Core Audio says it is wired headphones or a Bluetooth device, on macOS, or where its name says so, as Windows names them. The output is looked at again every second, and HRTF turns on or off as it changes. `--hrtf` and `--no-hrtf` have it whatever the output. A device with 4, 6 or 8 channels gets them all.
- The listener moves with the player's ship, so a sound's Doppler shift comes of how the two move against each other, and the player's own engine is not shifted.
- The Doppler shift is ten times what the game's velocities give. In Miles's metres a missile flies at a few metres a second, where at the models' scale, about a centimetre a unit, it flies at over a hundred. The listener's speed, and a sound's along the line to it, are held within half the speed of sound over that.
- A sound that follows an object spreads around the listener as it comes within the object's model's radius (`AL_SOURCE_RADIUS`), so a capital ship close by fills the space rather than sitting at a point.
- The 3D sounds lose their high frequencies with distance (`AL_AIR_ABSORPTION_FACTOR`).
- On a device with a subwoofer, 5.1 or 7.1, the 3D sounds send about half their level to it through OpenAL Soft's dedicated low-frequency effect, with their highs taken off and falling off with distance as the sound does; the receiver's crossover takes the rest.
- The 3D sounds send to a reverb, the generic room of EFX's presets, the room the game asks EAX for, at a fairly low level, falling off with distance as the sound does.
- The cockpit's warnings send to a reverb of the cockpit's cabin: EFX's race car cabin preset, the nearest of its presets to a fighter's cockpit, short and hard, at half its level. The other samples play dry. `--no-reverb` leaves both reverbs out.
- A sample's pan keeps its power, as a 3D sample's does.

## The master bus

[`engine/mss/master.zig`](../../src/engine/mss/master.zig) is the last thing the mix passes through. **Improvement:** a gentle compressor, from -18 dBFS at a ratio of 2 with a 6 dB soft knee, 10 ms attack, 200 ms release and 2 dB of make-up gain, evens out the mix's loudness; then a limiter that looks 3 ms ahead holds the peaks under -0.3 dBFS, so that a dozen guns firing close by stay clean. `--no-compressor` leaves the compressor out and keeps the limiter; `--original` leaves the bus out. OpenAL Soft's own limiter is off, since the bus comes after it.

## Output

The game opens Miles's driver at 22,050 Hz in 16-bit stereo, or at 11,025 Hz where that fails (`sound_driver_open`, `0x00482D10`). Its sounds are nearly all 4-bit IMA ADPCM, most of them mono at 22,050 Hz, so most hold nothing above 11 kHz.

[`platform/audio.zig`](../../src/platform/audio.zig) opens the default playback device as an SDL audio stream, in 32-bit float at the device's own rate: in as many channels as the device has with OpenAL Soft, in stereo with the software mixer. SDL asks for more from its own thread; the player renders it and the master bus passes it through. Where OpenAL Soft cannot start, the software mixer plays instead; where no device opens, the game runs silent.

As the window goes inactive, the message pump's part in [`game/winmain.zig`](../../src/engine/game/winmain.zig) pauses the music, and the game pauses into its [pause menu](../engine/pause-menu.md), which pauses the 3D voices, the voices and the clock. Active again, the music goes on; the rest waits for the menu's CONTINUE ([Sound](../engine/sound.md#start-up)). **Improvement:** the game pauses the mission for the window only in multiplayer, and in single player lets the timer's ticks pile up while the window is away.

`openreliant` sets the sound up as `WinMain` does, with 10 voices, the volumes of `[Sound]` in `starlancer.ini`, `bank_stdsmp` and `smp3d.fat`, and runs the frame's sound once the camera is placed. The fades step then too, where `tick_timer` steps them on a timer of its own every five ticks, which comes to the same while frames come faster. The player's engine starts sounding as its launch does, and a mission's script plays its music (`PlayMusic`); `--music` plays a piece from `music` from the start, until the script plays its own, and `--no-sound` runs silent ([Platform](platform.md#running)).

## Improvements

- **Improvement:** `sound_pitch_factor` works a quarter tone's factor out, `2^(n/24)`, where the game looks it up in a table of rounded values.
- **Improvement:** a missile's sound follows the missile, moving with it, so it can be told where it is and heard passing by, and ends with it (`sound3d.MissileSound.follows`). It keeps its full volume half as far again as its definition has it, so it carries a little as the missile flies off. The game leaves it where the missile was launched. `--original` leaves it there too.
- OpenAL Soft's resampling, placing, moving listener, sizes, air absorption, subwoofer and reverbs, and the master bus, above.

A reverb for the hangar during launch and landing is gathered in [#164](https://github.com/vdmkenny/openreliant/issues/164).

## Not ported

- The radio's speech, its double buffer and the speech volume.
- The CD's own audio.
