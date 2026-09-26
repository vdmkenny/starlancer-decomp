# Renderer

OpenReliant draws with Surrender's own pipeline, ported function by function into the modules of its original files, and with its Direct3D 7 driver, ported to draw through a device interface in place of `IDirect3DDevice7`.

| Module | Original | Does |
|---|---|---|
| [`surrenderlib/srcore.zig`](../../src/engine/surrender/surrenderlib/srcore.zig) | `srCore.cpp` | The scene's lists; a frame, layer by layer; the sort of what the driver puts aside |
| [`surrenderlib/srmesh.zig`](../../src/engine/surrender/surrenderlib/srmesh.zig) | `srMesh.cpp` | The mesh pipeline: view test, level of detail, culling, projection or clipping, lighting |
| [`surrenderlib/srbmo.zig`](../../src/engine/surrender/surrenderlib/srbmo.zig) | `srBMO.cpp` | The sprite pipeline |
| [`surrenderlib/srstars.zig`](../../src/engine/surrender/surrenderlib/srstars.zig) | `srstars.cpp` | The star pipeline |
| [`surrenderlib/srapi.zig`](../../src/engine/surrender/surrenderlib/srapi.zig) | `srAPI.cpp` | The projection; a mesh's planes and bounds |
| [`surrenderlib/srapiext.zig`](../../src/engine/surrender/surrenderlib/srapiext.zig) | `srAPIext.cpp` | Meshes, mesh objects, sprite sets |
| [`srd3d/srd3d.zig`](../../src/engine/surrender/srd3d/srd3d.zig) | `srd3d.dll` | The driver: render states, batching, clipping, the sun test |
| [`srd3d/device.zig`](../../src/engine/surrender/srd3d/device.zig) | Direct3D 7 | The device the driver draws with |
| [`srd3d/software.zig`](../../src/engine/surrender/srd3d/software.zig) | | A device that rasterizes as Direct3D 7 does, in software |
| [`platform/gpu.zig`](../../src/platform/gpu.zig) | Direct3D 7 | The device the `openreliant` executable draws with: SDL's GPU interface |
| [`platform/shaders/device.glsl`](../../src/platform/shaders/device.glsl) | Direct3D 7's texture stages | The GPU device's shader |
| [`surrenderlib/srshadow.zig`](../../src/engine/surrender/surrenderlib/srshadow.zig), [`platform/gpu/shadows.zig`](../../src/platform/gpu/shadows.zig), [`platform/shaders/shadow.glsl`](../../src/platform/shaders/shadow.glsl) | | OpenReliant's shadows: the maps' boxes and casters, and the GPU's depth passes |
| [`platform/gpu/geometry.zig`](../../src/platform/gpu/geometry.zig) | | The GPU device's vertex and index buffers |
| [`game/srofiles.zig`](../../src/engine/game/srofiles.zig) | `srofiles.cpp` | Meshes from `.SHP` models |
| [`game/objects.zig`](../../src/engine/game/objects.zig) | `objects.cpp` | A live object's part nodes, placed and drawn |
| [`game/nebula.zig`](../../src/engine/game/nebula.zig), [`game/backdrop.zig`](../../src/engine/game/backdrop.zig) | `nebula.cpp`, backdrop | The sky dome, the nebula, the stars, the dust, the sun, the lights |
| [`game/xtrabits.zig`](../../src/engine/game/xtrabits.zig) | `xtrabits.cpp` | `scene_add` |

A scene object's kind picks its pipeline: 1 a mesh, 4 a sprite set and 7 a star field. Kinds 5 and 6 are dead, and are described below.

The software device is the reference the GPU device is checked against: the same scene gives the same image. Pixel centres lie at whole numbers, as in Direct3D 7; screen positions are kept in sixteenths of a pixel, and a pixel whose centre lies on an edge belongs to the triangle whose top or left edge it is. Colours, alpha and texture coordinates are interpolated in perspective, depth straight across the screen. Textures are sampled bilinearly, wrapping, from the mip level nearest to the texels a pixel spans.

The `openreliant` executable draws with the GPU device, or with the software device when asked ([Platform](platform.md)). `sltool render` draws a model against the backdrop through all of it onto the software device, two frames as the game draws them one after another, the first finding how much of the sun shows; `make render` draws the Predator toward the nebula and toward the sun into `game/renders/`.

## The GPU device

The GPU device draws what the driver hands over with SDL's GPU interface: Metal on macOS, Vulkan elsewhere. The driver draws a strip, a fan or a single blended polygon at a time, and the game's textures are small, so the device gathers a frame before drawing it:

- Each texture is a layer of a texture array holding the textures of its width, height and number of levels, up to 256 layers, the fewest Vulkan guarantees; a texture goes up to the GPU, every level, the first time it is drawn, and the device keeps its array and layer in the image's `device`, as the driver's `texture_upload` keeps the device texture it makes.
- Each vertex names its texture's layer, or none. Strips and fans become lists of triangles, and consecutive draws with the same primitive and render states, whose textures share an array, go to the GPU as one draw.
- A pipeline is made for each primitive and set of render states the frame uses: the depth test greater or equal, depth being reversed, and the driver's blend factors. Depth is clamped rather than clipped, as Direct3D 7 did not clip transformed vertices in depth, and the pipelines write colour only, as the original's back buffer kept no alpha.

The device's shader, [`device.glsl`](../../src/platform/shaders/device.glsl), takes the driver's vertices as they are: screen positions with pixel centres at whole numbers, reversed depth, and `rhw`, whose inverse as the clip-space `w` makes colours and texture coordinates vary in perspective. The fragment is the texel times the vertex colour, or the vertex colour alone. For a lit mesh, the shader first adds the frame's directional and point lights to the vertex colour for the pixel, the key lights' share scaled by the [shadows](#shadows) ([Improvements](#improvements)). `make shaders` compiles it and the shadows' depth pass, [`shadow.glsl`](../../src/platform/shaders/shadow.glsl), with `glslc` into SPIR-V, and from that into Metal's language with SPIRV-Cross, which `make` builds; the outputs are committed, so building the game needs neither.

## Shadows

**Improvement:** the key lights cast shadows, where the original drew none. [`srshadow.zig`](../../src/engine/surrender/surrenderlib/srshadow.zig) gathers them each frame and the GPU device draws them ([`gpu/shadows.zig`](../../src/platform/gpu/shadows.zig)):

- **The maps.** The view is split by depth into four cascades, each an orthographic box along the sun around the sphere that holds its slice of the view. Its centre is moved to a whole texel of the world and its axes follow the world, so the shadows hold still as the camera moves and turns. The cockpit, where the scene holds one, gets a fifth box around its parts. The maps are the layers of one depth texture.
- **The casters.** Every lit mesh of the world's layer casts, whatever the camera sees of it: its opaque surfaces at its current level of detail, each polygon a fan of its corners, turned into the camera's frame each frame. A mesh whose light mask keeps out every key light casts none, as the sun lights it not: the Reliant's hangar keeps the sun off its hull and doors so, and the ship launching within it shows lit, as in the original ([Launches](../engine/launch.md#in-openreliant)). The ship the camera sits in casts without being drawn (`srcore.Scene.casters`), into the cascades alone, as the cockpit sits inside it. The cockpit's parts cast into its map alone, and a ship between the cockpit and the sun casts into it too. Each caster goes into the maps its bounding sphere can reach. A mesh cut by a portal casts only what the portal keeps, as a splitting capital ship is drawn. Blended surfaces and sprites cast nothing, but for a cloaking part's see-through hull (`srapiext.MeshObject.alpha_shadow`), which casts as strongly as the hull is solid, so a ship's shadow fades out with it as it cloaks ([The cloak](../engine/cloak.md#in-openreliant)).
- **The depth pass.** Before the frame, each map is cleared and its casters drawn, depth alone and both faces, with a slope-scaled bias. What lies nearer the sun than a box is held at its near side rather than cut off, so that it still casts. A caster that casts less than a whole shadow is drawn into that share of the texels, in an ordered pattern over each four by four, which the lookup's taps blend into a lighter shadow.
- **The lookup.** A world pixel takes its shadow from the first cascade that reaches as deep as it stands, the cockpit's from its own map. Its place is moved a texel and a half along its normal, so that a surface does not shade itself, and a square of taps, each comparing the four texels around it, softens the edge. Only the key lights (`srlight.Light.shadowed`) are scaled, and only where they face the pixel; the fill and ambient lights are not, so a shadowed hull keeps the nebula's colour. The last cascade fades out toward its end. Point lights cast no shadows.
- **The cockpit's** are fainter and softer: a full shadow takes away 40% of the sun, and the taps spread three times as wide. The cockpit takes both key lights, and its map's texels are fine enough to make the edges razor sharp otherwise.

| `--shadows` | Maps | Taps | Cascades end at |
|---|---|---|---|
| `low` | 1024 texels across | 4, a texel apart | 1,500, 6,000, 20,000 and 60,000 |
| `high`, the default | 4096 texels across | 16, 1.4 texels apart | 2,500, 10,000, 35,000 and 120,000 |

`--shadows off`, `--original` and `--no-pixel-lighting` leave them out, and `--no-cockpit-shadows` the cockpit's alone. The software device draws none. Not yet: fitting the cascades to the objects in them, which space leaves mostly empty ([#196](https://github.com/vdmkenny/openreliant/issues/196)).

## Improvements

Deliberate differences from the original, each marked **Improvement** where it is made:

- The view is unstretched on any screen: the factor across keeps pixels square, and a wider screen shows more at the sides ([Camera](../engine/camera.md#projection)).
- The driver tests a sorted polygon's triangles against the sun with the polygon's own corners, where the original uses indices left over from the last list it drew. Only a solid polygon hides the sun: what is blended, such as a canopy's glass, lets it through.
- A vertex with no counterpart in the next level of detail morphs toward itself, where the original reads whatever lies before that level's vertices.
- The finer levels of detail reach eight times as far as the original's (`srapi.Context.finer`), so that a ship keeps its finest mesh until it is far off. Its last level still ends where the original's does at the high detail setting, depths divided by 3 (`game.main.high_detail`), and the ship leaves sight there.
- A frame may draw 200000 vertices and as many polygons, ten times the original's 19999 (`srapi.Context.budget`). The layers are drawn from what went into them last, so once the budget is spent the objects that went in first are left out, and those are the ships' parts. OpenReliant keeps up to 4000 burning bits where the original keeps 500, and a view full of them and of a split's bodies takes the original's budget, so a wreck's parts would vanish while they are in view.
- The GPU device draws at the display's own resolution, with four samples a pixel, where the original drew one.
- It filters textures trilinearly, sixteen times anisotropic, where the original sampled bilinearly from the nearest level, and magnifies them with a Catmull-Rom filter, which keeps the small textures sharp up close.
- The frame's bright parts, its lights, flares and the sun, bleed a little light into what stands around them, as a camera does. What passes a threshold is taken into a half-size target, blurred along each axis in turn and added back, so that a light reads as a light rather than as a bright texel. The original drew none.
- It lights each pixel of a lit mesh with the game's directional and point lights, where the original lit each vertex and interpolated the colours across each polygon. A hull of few polygons shades smoothly, and a point light falls off across a face rather than only between its corners. The pipeline still works out each vertex's own colour, ambient lights and baked colours, and hands the driver the vertex's normal in the camera's frame as well. The driver hands the device the frame's directional and point lights, also in the camera's frame, and the shader adds them with `mesh_light`'s sums, to the normal interpolated and made unit length again, and holds each channel to 1. The shader takes up to 64 lights a frame, which keeps them within the 4 KiB of uniform data SDL's Vulkan device binds: the directional lights first, then the point lights nearest the camera. The pipeline adds any others to each vertex, as the original adds them all. The software device lights each vertex. `--no-pixel-lighting` turns it off.
- Every shot a gun fires casts its light, where the original lit only the latest two of the player's shots and the latest two of everyone else's, so that sustained fire lights the hulls it passes ([Guns](../engine/guns.md#how-a-shot-is-drawn)). The shader's 64 nearest point lights take them per pixel and the pipeline adds any past that to each vertex. `--few-shot-lights` restores the original's two.
- A gun's muzzle flash casts a light while it lasts, of its flares' own colour, so that each shot lights the hull round the gun, where the original's flash lit nothing. The turrets' guns flash too, blue or orange as their shots are, where the original gave them none ([Guns](../engine/guns.md#muzzle-flashes)).
- An explosion's burning bits take the lights a ship takes, one of each pair, where the original let every light reach them, both suns and both fills, which washed them out ([Effects](../engine/effects.md#burning-bits)).
- Explosions are fuller: there is room for 128 fireballs where the original kept 30, each one's light moves with it and starts 50% brighter, shockwaves' rings are round where the original's were octagons, and bursts far off are not thinned, into a pool of 4000 particles ([Effects](../engine/effects.md#fireballs)). Burning bits stay until their place is needed, with room for 4000, where the original keeps up to 500 for about 20 seconds ([Effects](../engine/effects.md#burning-bits)). A fireball's frames fade into each other, and every effect is drawn between the ticks as the ships are ([Effects](../engine/effects.md#drawn-between-the-ticks)).
- It lights and filters in linear light, where the original worked on the colours as they are encoded, gamma and all. The textures are kept as sRGB, so sampling, filtering and the mipmaps decode them, and the device decodes the lights' colours before they are added up, a point light's intensity after its colour. Each pixel's directional and point lights are added up and multiplied by the texture in linear light, the key light's share falling off as light does, and encoded again as the pixel is written. A fill light, the nebula's glow, keeps the original's falloff, and the vertex's own colour, its ambient and baked light, is added to the encoded texture as the original added it: the lights' colours were chosen against that neutral floor, and without it the side of a ship away from the sun glows with the nebula. What is blended, the game's glows, particles, fireballs and shields, is blended on the encoded colours, as the effects were made to be, into a frame of floats, 32 bits a pixel where the GPU draws into `R11G11B10_UFLOAT` and 64 otherwise, so that what is stacked past white is kept. The bloom's last pass, which runs whether the frame blooms or not, eases each channel past 0.8 toward 1 rather than clipping it, so a fireball's heart still goes white but what lies around it keeps its shading, and dithers the frame; the bloom takes the eased colours too. `--gamma-space` restores the original's way, as `--original` and 16-bit colour do.
- It draws in 32-bit colour, where the original drew in 16 bits, and dithers that too, which costs nothing and keeps a dark gradient, such as the nebula or a light's falloff, from banding. `--original` restores the original's look: 16-bit colour, dithered, into a 16-bit buffer where the GPU has one, with a 16-bit depth buffer, one sample a pixel, bilinear filtering, lighting each vertex, the levels of detail changing as near as the original's, as little drawn a frame as the original allows, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, an explosion's debris lit by every light, its fireballs, rings, particles and burning bits as few, plain and brief as the original's, the Uber Explode as coarse, unlit and tied to the frame rate as the original's, no shadows, and light worked out on encoded colours.

## Scene objects of kinds 5 and 6

Nothing in the shipped game draws a line or a ball, and nothing makes one:

- `SR_driver_init` fills every entry of the payload's device table from `+0x3C` to `+0x84` and leaves `+0x5C` and `+0x60` null. Those two are what `sr_draw_layers` (`0x004C7960`) calls for kinds 5 and 6, so an object of either kind would call through a null pointer.
- The linker pulled one function out of `srline.cpp` and one out of `srballs.cpp`, `line_pipe` (`0x004CE830`) and `balls_pipe` (`0x004CE7B0`), each reached only from the switch in `sr_draw_layers`. Whatever creates such an object was never linked in, because nothing calls it.

The weapons' tracers are ordinary mesh objects and sprite sets ([Guns](../engine/guns.md#shots)), not these.

Both pipes begin with `SR_object_rotate`, which leaves the object's transform in the camera's frame at `+0x7C` (three rows) and `+0xA0` (the place), and both work as the mesh pipeline does.

`line_pipe` walks the object's vertices, `+0xB4` of them at `+0xD4`, four floats each. It transforms each into the camera's frame and gives it the same [outcode](../../src/engine/surrender/surrenderlib/srapi.zig) the mesh pipeline uses: `0x10` for a vertex in front of the near plane, then `1` and `2` for a vertex outside the view's left and right at its depth, `4` and `8` for below and above. A vertex inside keeps `1/z` as its fourth float, and its place on the screen, `x` and `y` over `z`, goes to `+0xD8` as a pair of floats. The codes go to `+0xCC`, one byte a vertex. Then each of the `+0xB8` segments at `+0xDC`, 28 bytes each, holding the two vertices it joins at `+0x04` and `+0x08`, is marked at `+0x10` when both ends are off the same side, which rejects it.

`balls_pipe` is a point with a size. A depth below the near plane returns `0x100`, which `sr_draw_layers` takes as nothing to draw. Otherwise `1/z` scales the size at `+0xF8` into the radius at `+0xD0` and the camera-space place into the screen place at `+0xC4` and `+0xC8`, and the drawn record at `+0xC0` points back at the object.

## Not yet ported

- The software renderer, `srddraw.dll`, and the software renderer's sky dome.
- The mesh sets `model_load` builds for cloaking.
- Hanging each part from its parent part's node (`object_link_parts`), which leaves every part where it is, and the moment of inertia `object_bounds` sums.
- What `node_draw` draws for the cloak and for nodes of kind 6.
- `backdrop_place`, which aims the sun, the lights and the nebula from a mission's markers, and the objects `backdrop_frame` turns and makes glow.
