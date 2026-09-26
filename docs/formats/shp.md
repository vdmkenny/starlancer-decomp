# `.SHP` models

Every ship, station, weapon, asteroid and piece of debris in the game is a `.SHP` file in
`resource.hog`.

```bash
sltool shp info <model>                 # header flags, bounds, arcs, parts, levels, turrets
sltool shp chunks <model>               # the raw chunk stream
sltool shp check <model>                # validate indices, parents and bounds
sltool shp obj <model> <out.obj> [--lod n]
make models                             # export every model to game/models
make check-models                       # validate every model
```

## Chunk stream

A model is a flat sequence of chunks with no nesting. Each is a 6-byte header followed by its
records, and the stream ends with a chunk whose tag is `0xFFFF`.

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | Tag |
| 2 | 2 | Record size **in this file** |
| 4 | 2 | Record count |
| 6 | count x size | Records |

All fields are little-endian, unlike the `.HOG` container around them.

`record_size` is the format's versioning mechanism. Older exporters wrote shorter records, and the
loader copies `min(record_size, sizeof(struct))` bytes per record, leaving the rest of the
destination untouched. A reader must do the same; this one zero-fills, so a field a later exporter
added reads as zero in a file written by an earlier one.

The loader locates a chunk by scanning forward from a cursor until the tag matches or the
terminator is reached. A miss leaves the cursor where it was, so a chunk the exporter omitted is
simply skipped and the next request still finds what follows. Chunks must therefore appear in the
order the loader asks for them, because a miss never rewinds.

### Tags

| Tag | Record | Record sizes seen | Belongs to |
|---|---|---|---|
| `0x00` | header | 88, 24, 20 | model |
| `0x01` | part | 312, 288, 264, 260, 244 | model |
| `0x02` | level of detail | 4 | part |
| `0x03` | face | 80, 72 | level |
| `0x04` | vertex | 32, 28 | level |
| `0x06` | material | 64 | level |
| `0x07` | tree node | 72, 64 | part |
| `0x08` | node face list | 4 | node |
| `0x09` | attachment point | 168, 136, 124, 100 | part |
| `0x0A` | animation clip | 24, 8 | part |
| `0x0B` | keyframe | 28 | clip |
| `0x0C` | clip event | 12 | clip |
| `0x0D` | point list | 4 | part |
| `0x0E` | point | 20 | point list |
| `0x0F` | trigger polygon | 16 | part |
| `0x10` | firing arc | 76, 12 | model |

### Order

```
header, parts, then for each part:
    levels, nodes, attachments, clips, point lists, trigger polygons
    for each level:       vertices, faces, materials
    for each node:        face list
    for each clip:        keyframes, events
    for each point list:  points
firing arcs
```

Every model follows this order and ends with the terminator at the last byte of the file.

## Records

Offsets below are within a record. Only the fields this project reads are listed; the rest are
noted in [§ Unread fields](#unread-fields).

### Header (tag `0x00`)

| Off | Type | Field |
|---|---|---|
| `0x00` | u32 | Version: `107`, or `200` in a few models. Not read by the loader. |
| `0x08` | vec3 | The cockpit views' eye point, in the model's frame ([Camera](../engine/camera.md#cockpit)): `object_add_part` (`0x004760C0`) copies it to the object at `0x628` |
| `0x14` | u32 | Flags. Bit 0: objects of the model list their [components](../engine/objects.md#components) and get no renderer object of their own. Bit 1 makes the loader build a second mesh set, used for the cloak effect. |

### Part (tag `0x01`)

A part is a hull section, cockpit, turret, engine, door or similar. Parts form a tree and each
carries its own levels of detail.

| Off | Type | Field |
|---|---|---|
| `0x00` | char[64] | Name, NUL-terminated: `Crusader Cockpit`, `Rus Big Tur Guns`, `Stalag Door 1 DEST` |
| `0x40` | u32 | Subsystem class. 5 marks engines and 6 shield generators, which the engine counts; 3, 9, 10 and 18 are turrets; 1 marks hull sections, going by their names; 2 the cockpit, which leaves the ship as the pilot's pod ([Ejection](../engine/ejection.md#the-pod)) |
| `0x44` | vec3 | Origin, in the model's frame whatever the parent |
| `0x50` | vec3 | Bounding box minimum (see [Bounding boxes](#bounding-boxes)) |
| `0x5C` | vec3 | Bounding box maximum |
| `0x68` | f32[3] | Mass properties in the part's frame: the integrals of x², y² and z² over its volume |
| `0x74` | f32[3] | The integrals of xy, yz and xz |
| `0x80` | f32[3] | The integrals of x, y and z |
| `0x8C` | f32 | The volume |
| `0x90` | f32 | The mass of a unit of volume |
| `0x94` | i32 | Parent part index, or `-1` for a root |
| `0x98` | vec3 | The mount point, which the part's [animation](../engine/objects.md#animation) turns it about: the far end of a gun, the base of a mount |
| `0xA4` | f32[9] | Orientation, row-major 3x3: the frame the part's animation turns it in, often a quarter turn about X from the model's |
| `0xC8` | u32[3] | Axes the part's animation doesn't turn it about, one flag each for X, Y and Z |
| `0xD4` | u32 | Link id. Parts sharing a non-zero id form one assembly, such as a turret and its barrels |
| `0xD8` | f32[3] | How far a turret's part turns at least about its own X, Y and Z axes, which the file calls yaw, pitch and roll, in degrees |
| `0xE4` | f32[3] | And at most. Equal limits leave the axis free |
| `0xF0` | u32 | Flags (below) |
| `0xF4` | u32 | [Turret](../engine/guns.md#turrets) kind: 0 none, 1 aimed, 2 spinning, 3 missile turret |
| `0xF8` | i32 | Which of its turret's parts it is, by turret kind; -1 for none |
| `0x104` | i32 | What the part takes as a [component](../engine/objects.md#components) before it is destroyed, which `node_add_part` (`0x00499430`) gives its node. The Reliant's turrets hold 100 and its body 20000 |
| `0x108` | u32 | Component group. Parts sharing a non-zero group count a hit on any of them against the component among them, which the mission's ShotAt names (`component_damage`, [Script VM](../engine/script-vm.md#events)); a part of none counts it against its assembly's. The Coalition's prototype gate's plates count against its inner core so |

Part flags at `0xF0`:

| Bit | Meaning |
|---|---|
| `0x02` | A component: the live object lists the part among its [components](../engine/objects.md#components) |
| `0x04` | A part of a component's damaged model: hidden while the component is intact, shown when it is disabled, or destroyed with its damaged model kept. Static lights are baked separately for the two classes |
| `0x10` | Geomorph normals: the mesh builder also copies each vertex's next-level normal |
| `0x20` | Geomorph positions, likewise |
| `0x40` | Set by the loader when a static light exists in this part's class; the part's meshes then hold [baked colours](../engine/rendering.md#meshes) |
| `0x80` | With `Lmaps` set, bind a second texture, `l<material>`, which a hardware renderer adds over the part's lit faces ([Rendering](../engine/rendering.md#shading-modes)) |
| `0x1000` | A component the player can target: the live object marks the component's node [targetable](../engine/objects.md#the-model-hierarchy) |

### Attachment point (tag `0x09`)

A point on a part where the engine mounts something. Exporters wrote records of 100 to 168 bytes;
the engine keeps 124 bytes of each.

| Off | Type | Field |
|---|---|---|
| `0x00` | u32 | Kind |
| `0x04` | vec3 | Position, relative to the part |
| `0x10` | f32[9] | Orientation, row-major 3x3 |
| `0x34` | u32 | Id: which model of its kind. A missile hardpoint's (kind 0) missile for loadout tier 0 |
| `0x38` | u32[4] | A missile hardpoint's missile for loadout tiers 1 to 4, the low half of each (`object_loadout_by_tier`) |
| `0x64` | u32 | For kind 3, the gun type it fires, into `gun_stats`: the Sabre's muzzles hold 1 to 3 and an allied turret's 12 |

The engine's attachment table, filled when the game starts, gives the models and sprites for each
kind and id; [`src/engine/game/create/models.zig`](../../src/engine/game/create/models.zig)
transcribes it (`make model-tables`). Kind 0 holds missiles and their pods, 1 guns and turrets, 4
flare and light sprites, 5 cargo and fuel pods. Kind 3 is a gun's muzzle: an object takes one gun
for each, of the type at `0x64`, and its muzzle flash is drawn there. Kind 7 is where a spinning
gun's spent cases fly from ([Guns](../engine/guns.md#particles-and-bursts)). Kind 6 is a cockpit's
eject point: the flash of a pilot's ejection goes off at the last, and the pod shoots out along its
Z axis ([Ejection](../engine/ejection.md#the-pod)). Kind 8 is a launch point, where a ship stands
to launch from the model, turned as the point is: a carrier's torpedo tubes and the Reliant's hangar
hold them ([Launches](../engine/launch.md#launch-points)). Kind 9 is a docking point, turned as a
ship docks there: a ship's own, its first, and a station's ports, counted part by part
([Docking](../engine/orders.md#docking)). Kind 2 is an engine's glow
([Rendering](../engine/rendering.md#engine-glows)).

For kinds 1 and 5 the engine mounts the model as an object of its own, hanging from the part's
node, whose components join the owner's.

### Animation clip (tag `0x0A`)

One of a part's animation tracks ([Animation](../engine/objects.md#animation)). Its keyframes and
events follow the level geometry, one keyframe chunk and one event chunk for each clip in turn.
Older exporters wrote 8-byte records, which stop two bytes into the name.

| Off | Type | Field |
|---|---|---|
| `0x00` | i32 | Length, in the track's own time |
| `0x04` | i16 | How it plays unless its starter says otherwise: 0 not at all, 1 once, 2 looping, 3 back and forth |
| `0x06` | char[18] | Name. The engine starts the tracks named `startup`, `fire` and `deploy` by name |

### Keyframe (tag `0x0B`)

| Off | Type | Field |
|---|---|---|
| `0x00` | i32 | Time |
| `0x04` | vec3 | Angles in radians about X, Y and Z, in the part's own frame |
| `0x10` | vec3 | Offset from the part's origin |

### Clip event (tag `0x0C`)

| Off | Type | Field |
|---|---|---|
| `0x00` | i32 | Time |
| `0x04` | i32 | Kind: 0 fires a shot from each of the part's muzzles, 2 puffs particles from its attachments of kind 7. The engine's update ignores any other kind, such as 3 |
| `0x08` | i32 | **Unknown.** `node_tree_update` doesn't read it |

### Point list (tags `0x0D`, `0x0E`)

A part can carry lists of points on its mesh, which the game's asserts call point lists. Each `0x0D` record is a list's kind, a u32, and each list's points follow in a `0x0E` chunk after the part's clips. `model_load` keeps a list as `{kind, count, points}`, and `node_point_group` (`0x004ADD50`) finds a part's list of a kind. A point:

| Off | Type | Field |
|---|---|---|
| `0x00` | u32 | **Unknown.** 0 in the models read |
| `0x04` | u32 | The vertex it stands on |
| `0x08` | vec3 | Where it stands in the part's frame |

The kinds the game reads:

| Kind | Read by | What the points are |
|---|---|---|
| 0 | `order_scoop_up` (`0x0041BCC0`) | Where a ship takes in a pilot's pod: the first point, which the pod is drawn toward along the part's Z axis ([Ejection](../engine/ejection.md#scoop-up)) |
| 1 | `explode_part_burn` (`0x00471290`) | Pairs of points an electric ray runs between as a wreck burns |
| 2 | `split_create` (`0x0046F480`) | Where a capital ship is cut as it splits in two |
| 3 | `part_streams` (`0x004715D0`) | Where smoke streams from a burning wreck, along each point's vertex's normal |
| 4 | `part_burn_lights` (`0x00471470`) | Where a burning wreck's light stands: the first point |
| 5 | `split_update` (`0x00470030`) | Where fireballs go off as a split ship's halves part |
| 6 | `order_scoop_up` | Where a ship's two tractor beams come from: the first two points |

`shp.PointList` holds a list, and `sltool shp info` counts each part's lists.

### Firing arc (tag `0x10`)

One for each of the model's [components](../engine/objects.md#components), in the order the
object lists them: the directions a turret standing on the component may fire in. Some exporters
wrote 12-byte records, with no mask, which the loader leaves zeroed.

| Off | Type | Field |
|---|---|---|
| `0x00` | vec3 | Unknown; nothing reads it. (0, -1, 0) or (0, 1, 0) in the shipped models |
| `0x0C` | u16[32] | 32 rows about the component's Y axis by 16 columns from it, a bit a direction, set where a turret may fire |

### Level of detail (tag `0x02`)

One 4-byte record per level, up to nine per part, holding only the distance beyond which the level
applies: `0` for single-level parts, otherwise a rising sequence such as 5000, 10000, 15000. The
geometry follows in the vertex, face and material chunks, in level order.

### Vertex (tag `0x04`)

| Off | Type | Field |
|---|---|---|
| `0x00` | vec3 | Position, in model units |
| `0x0C` | vec3 | Normal |
| `0x1C` | i32 | This vertex's counterpart in the next, coarser level, for geomorphing; `-1` when it has none. Absent from 28-byte records |

### Face (tag `0x03`)

Every record is one triangle.

| Off | Type | Field |
|---|---|---|
| `0x00` | u32 | Material index, into this level's material list |
| `0x04` | u32 | Shading: low nibble is the mode, high nibble a sub-mode |
| `0x08` | u32 | Flags: `0x01` a cap, hidden on an intact object; `0x02` two-sided ([Rendering](../engine/rendering.md#culling)) |
| `0x0C` | u32[3] | Vertex indices, into this level's vertex list |
| `0x18` | f32[3] | Texture coordinate u, per corner |
| `0x24` | f32[3] | Texture coordinate v, per corner |
| `0x30` | vec3 | Face normal. The loader compares a fan's records' normals to [merge](../engine/rendering.md#meshes) them |
| `0x40` | f32 | Sort bias: a third of it is added to the depth by which blended faces are sorted |
| `0x44` | u32 | Edge mask for wire shading: edge *k* is drawn unless bit *k* is set |
| `0x48` | u32 | Polygon encoding: `0` plain triangle, `1` member of a fan, `2` or `3` member of a strip |
| `0x4C` | u32 | Records still to come in the same polygon, counting down |

Shading modes: `0` untextured, `1` wire, `2` untextured and added, `3` unlit, `4` unlit and added,
`5` unlit and blended by alpha, `6` lit, `7` lit with a highlight, `8` lit and added. Mode 1 draws
lines rather than a filled triangle. The sub-mode picks mode 7's highlight and means nothing to the
rest. [Rendering](../engine/rendering.md#shading-modes) gives what each draws.

The loader merges a fan's records into one polygon when each later record's normal lies within a
dot product of 0.999, about 2.6 degrees, of the first's; the Direct3D driver draws the records of a
strip, or of a fan left unmerged, together ([Rendering](../engine/rendering.md#meshes)). Each record
is already a complete triangle of its polygon, so treating every record as its own triangle renders
the same surface. 72-byte records stop before the polygon fields and are always plain triangles.

A face's front is the side `(v1 - v0) x (v2 - v0)` points to. A `3` record lists its last two
corners the other way round: its front is the side of `(v2 - v0) x (v1 - v0)`.

### Tree node (tag `0x07`)

A part's collision tree, the root first. The engine descends it to find which part of a ship another
object has hit (`0x0049BD30`), in place of the sphere test the two objects' own radii give.

| Off | Type | Field |
|---|---|---|
| `0x00` | u32 | **Unknown.** Zero in every shipped model but one, which holds 100 |
| `0x04` | f32[9] | The box's axes in the part's frame, row-major |
| `0x28` | vec3 | Half the box's size along each of its own axes |
| `0x34` | vec3 | The box's centre in the part's frame |
| `0x40` | i32[2] | The two nodes it splits into, or `-1` |

Each node is followed later in the file by a node face list (tag `0x08`, one u32 a record) holding
the faces inside its box, as indices into the part's first level. A node with faces is a leaf and
its children are not read; the loader decides by the list, not by the `-1`s, and two models have a
leaf whose child fields hold something else.

One model's records are 64 bytes and stop before the children. Its single node is a leaf, so
nothing reads them.

148 of the 421 models carry a tree, 6582 nodes in all: capital ships, stations and gates, which are
also the models whose objects list components. Fighters carry none and collide as spheres.

### Material (tag `0x06`)

A single NUL-terminated 64-byte texture name without its extension. The engine looks it up in the
[texture cache](tcache.md) with a context-dependent prefix: `g` while the loadout screen preloads
ships, `r` for its missile and gun loops, bare in flight, and a second `l<name>` lookup when the
part's `0x80` flag is set on multitexture hardware.

## Bounding boxes

The box stored in each part is derived from its finest level's vertices, but not always in the
part's own frame. In the shipped models it is one of:

- the level-0 vertex extent as stored, in most parts;
- that extent after applying the part's orientation matrix;
- the same box up to an axis swap or reflection the record does not describe;
- zero-sized, never filled in;
- a different box.

`sltool shp check` classifies each part rather than requiring a match, since all five occur in
shipped, working models. The vertices are authoritative; the stored box is a hint.

## Coordinate frame

The model frame is **X lateral, Y down, Z forward**. Neither axis direction is recorded in the
file; both are settled by what the parts are named and where they sit:

- every part named `Lower`, `bottom` or `under` is at **positive Y**;
- most parts named `cockpit` or `canopy` are at **negative Y** and **positive Z**;
- most parts named `engine`, `exhaust`, `thruster`, `rear`, `back` or `aft` are at **negative Z**;
- most parts named `nose` or `front` are at **positive Z**.

So `+Y` points at the ship's belly and `+Z` out of its nose. A model loaded without accounting for
this is upside down.

Righting it is a half turn about the forward axis: negate X and Y, keep Z. That keeps the nose on
`+Z`, where a viewer's default camera looks, and does not mirror the model, since negating two axes
keeps the determinant positive. Negating Y alone would mirror it; negating Y and Z would face it away
from the camera.

`sltool shp obj` applies that half turn to positions and normals; `--model-space` writes the
coordinates exactly as the file stores them. `shp info` and `shp check` always report model space.
The export leaves out wire faces and caps, and swaps the last two corners of odd strip members so
that every face winds alike.

Wavefront OBJ also numbers texture coordinates from the bottom up, the opposite of this format, so
the exporter emits `1 - v`.

Positions are in model units. The Predator light fighter spans about 1,100 units nose to tail, which
puts a unit near a centimetre (**unverified**: it assumes a fighter about 11 m long). A part's
origin is in the model's frame, whatever its parent: `object_add_part` (`0x004760C0`) hangs every
part's node from the object's root at it, and `object_link_parts` (`0x00476130`) then hangs each
from its parent part's, keeping it where it is.

## Unread fields

These are present in every record and read by nothing in the engine: the header's `0x04` scalar
and the face's `0x3C` word. The reader preserves them.

The mass properties at `0x68` to `0x90` place an object's origin at its parts' centre of mass
(`object_recentre`, `0x004769F0`) and give it a moment of inertia (`object_bounds`, `0x00476680`),
moved from each part's origin to the object's. **Unverified:** that they are integrals over the
part's volume; the engine uses them as such
([Live objects](../engine/objects.md#the-model-hierarchy)).

**Unknown:** the interpretation of trigger polygons (`0x0F`). They are parsed and counted, and their
records are available, but their fields are not decoded here. One model carries two of them; the
engine tests the player's ship against them before it descends the collision tree.

## Prior art

The container and chunk framing here were read from the files directly. The record field
semantics, the loader's search-forward rule and the chunk catalogue come from the independent
analysis in
[Starlancer-OSS `docs/shp-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/shp-format.md),
which traced them to the engine's own loader. Every structure offset and count in this document was
re-verified against the 440 shipped models; the bounding-box frames above are a refinement, since
the box does not always match the vertex extent as stored.
