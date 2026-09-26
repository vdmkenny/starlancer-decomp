# Changelog

## [0.5.0](https://github.com/vdmkenny/openreliant/compare/v0.4.0...v0.5.0) (2026-09-26)


### Features

* joysticks --watch shows every axis and button by its number, in place ([#299](https://github.com/vdmkenny/openreliant/issues/299)) ([53e34b6](https://github.com/vdmkenny/openreliant/commit/53e34b6f3256082937034541821c9085fd6a2e24))
* missions load and bind as a mission's start does ([#284](https://github.com/vdmkenny/openreliant/issues/284)) ([ee4a103](https://github.com/vdmkenny/openreliant/commit/ee4a1038a0091025c6947005523821f3a6f6d58e))
* the sandbox is mission 0, a mission file played through the mission's start ([#302](https://github.com/vdmkenny/openreliant/issues/302)) ([8f9a795](https://github.com/vdmkenny/openreliant/commit/8f9a795719230406191279ddd325dc6fa0f3f649))
* the script VM runs a mission's threads, calls, clock and timers ([#296](https://github.com/vdmkenny/openreliant/issues/296)) ([63192ab](https://github.com/vdmkenny/openreliant/commit/63192ab0c3f30dba4290032223328fb2c6456209))
* write mission files and assemble their scripts ([#286](https://github.com/vdmkenny/openreliant/issues/286)) ([88ef23c](https://github.com/vdmkenny/openreliant/commit/88ef23c37fad77e027e243ac7ca199a81ac7b1c5))

## [0.4.0](https://github.com/vdmkenny/openreliant/compare/v0.3.0...v0.4.0) (2026-09-25)


### Features

* a capital ship's engine exhaust burns the player's ship ([#273](https://github.com/vdmkenny/openreliant/issues/273)) ([da7fdd4](https://github.com/vdmkenny/openreliant/commit/da7fdd43ff332f07347146e1e28cf6f40f856644))
* a smooth, crisp sun and lens flares ([#275](https://github.com/vdmkenny/openreliant/issues/275)) ([124466f](https://github.com/vdmkenny/openreliant/commit/124466f226ee0c74a33a4e1fc1bb7d028a3dc376))
* blind fire aims the player's shots at the lead cursor ([#251](https://github.com/vdmkenny/openreliant/issues/251)) ([cd47041](https://github.com/vdmkenny/openreliant/commit/cd47041c88e57a58a94574019516df71da30884b)), closes [#183](https://github.com/vdmkenny/openreliant/issues/183)
* objects the orders place glide on between the ticks ([#274](https://github.com/vdmkenny/openreliant/issues/274)) ([98ee211](https://github.com/vdmkenny/openreliant/commit/98ee2112501e143af93052ada12f229653b7c73f))
* steering by the mouse ([#276](https://github.com/vdmkenny/openreliant/issues/276)) ([7ab1e92](https://github.com/vdmkenny/openreliant/commit/7ab1e92bb3bdb3ec6e49397b1f34aa2d41687c8f))
* the chase view's sight, blind fire mark and target pointer ([#260](https://github.com/vdmkenny/openreliant/issues/260)) ([f2765db](https://github.com/vdmkenny/openreliant/commit/f2765db35736ad8d1656dafb51bccef731f55406)), closes [#182](https://github.com/vdmkenny/openreliant/issues/182)
* the cloak ([#267](https://github.com/vdmkenny/openreliant/issues/267)) ([636de88](https://github.com/vdmkenny/openreliant/commit/636de8882530e9af82572057881359aa0728d779))
* the damage window shows the weapons, engines and shields ([#255](https://github.com/vdmkenny/openreliant/issues/255)) ([08d4912](https://github.com/vdmkenny/openreliant/commit/08d49124bc10925f999c6dec69c0b0aa535f53b1)), closes [#96](https://github.com/vdmkenny/openreliant/issues/96)
* the display shakes and the view reddens as the player is hit ([#259](https://github.com/vdmkenny/openreliant/issues/259)) ([00fa29b](https://github.com/vdmkenny/openreliant/commit/00fa29b4604d5f87fad7d91f0ec0d6519f44beed)), closes [#236](https://github.com/vdmkenny/openreliant/issues/236)
* the display's sounds for its windows, keys and warnings ([#258](https://github.com/vdmkenny/openreliant/issues/258)) ([b5ab30f](https://github.com/vdmkenny/openreliant/commit/b5ab30f185e5bb2ce7554779d520e4c0c02eb206))
* the gunnery display and choosing the guns ([#247](https://github.com/vdmkenny/openreliant/issues/247)) ([2177fed](https://github.com/vdmkenny/openreliant/commit/2177fed6ec624850039a3febef0d502af3a88731)), closes [#92](https://github.com/vdmkenny/openreliant/issues/92)
* the Nova Cannon charges and strikes ([#250](https://github.com/vdmkenny/openreliant/issues/250)) ([c719f50](https://github.com/vdmkenny/openreliant/commit/c719f50d1635e329504708d22b00fe176ce4ab77))
* the pilot ejects, and is rescued, captured or shot down ([#270](https://github.com/vdmkenny/openreliant/issues/270)) ([522328a](https://github.com/vdmkenny/openreliant/commit/522328adb51effbab3e1b70678f134dd86794808))
* the rest of the explosions ([#261](https://github.com/vdmkenny/openreliant/issues/261)) ([f368a31](https://github.com/vdmkenny/openreliant/commit/f368a31691fa77f7170736c0c1b47b5f367a169f))
* the wing status window, and wingmen in the sandbox ([#257](https://github.com/vdmkenny/openreliant/issues/257)) ([48a1a7b](https://github.com/vdmkenny/openreliant/commit/48a1a7b185989d1f690374228a2d98764af4ae7b)), closes [#100](https://github.com/vdmkenny/openreliant/issues/100)


### Fixes

* a shot keeps its candidate parts by number ([#254](https://github.com/vdmkenny/openreliant/issues/254)) ([2568f14](https://github.com/vdmkenny/openreliant/commit/2568f14e5cf97c934aa2bd7a8d376afea9d08b0e)), closes [#253](https://github.com/vdmkenny/openreliant/issues/253)
* the player's schematic keeps its place while shaken. ([00fa29b](https://github.com/vdmkenny/openreliant/commit/00fa29b4604d5f87fad7d91f0ec0d6519f44beed))


### Documentation

* a contributing guide for people and coding agents ([#252](https://github.com/vdmkenny/openreliant/issues/252)) ([0cbd044](https://github.com/vdmkenny/openreliant/commit/0cbd0443b25341e3e59754d9424593fe2f9593fc)), closes [#249](https://github.com/vdmkenny/openreliant/issues/249)
* what keeps the hit's red away ([#272](https://github.com/vdmkenny/openreliant/issues/272)) ([f36690c](https://github.com/vdmkenny/openreliant/commit/f36690c3a52b8194e8bafd1f826b884de92edb59))

## [0.3.0](https://github.com/vdmkenny/openreliant/compare/v0.2.0...v0.3.0) (2026-09-24)


### Features

* a component's destruction ([#227](https://github.com/vdmkenny/openreliant/issues/227)) ([a2f9ec1](https://github.com/vdmkenny/openreliant/commit/a2f9ec147927744977e760b072295cf1efb6efc5))
* a component's hit bursts into orange puffs ([#240](https://github.com/vdmkenny/openreliant/issues/240)) ([52ad22a](https://github.com/vdmkenny/openreliant/commit/52ad22a9bae98886bd799538b497f6a663f66393)), closes [#40](https://github.com/vdmkenny/openreliant/issues/40)
* a field of rocks in the sandbox ([#241](https://github.com/vdmkenny/openreliant/issues/241)) ([563c0fe](https://github.com/vdmkenny/openreliant/commit/563c0fecfba9fd4b7c79b431d96b4b9bea40a387))
* burning wrecks and electric rays ([#235](https://github.com/vdmkenny/openreliant/issues/235)) ([04085dd](https://github.com/vdmkenny/openreliant/commit/04085dd33f941ee29b4a6432a5e1c189c3a6ef07))
* capital ships split in two ([#230](https://github.com/vdmkenny/openreliant/issues/230)) ([c15bd1d](https://github.com/vdmkenny/openreliant/commit/c15bd1d48d7ae0eb75aede3c25cff3c4bbd8ced1))
* capital ships' shields glow where struck ([#231](https://github.com/vdmkenny/openreliant/issues/231)) ([e8ef948](https://github.com/vdmkenny/openreliant/commit/e8ef948d73d3998bc8e3daa6d8705b37b06f646b)), closes [#179](https://github.com/vdmkenny/openreliant/issues/179)
* fade fireballs out as they finish ([#200](https://github.com/vdmkenny/openreliant/issues/200)) ([f768c92](https://github.com/vdmkenny/openreliant/commit/f768c920a93894890ce93eac24aa907d3973bac2))
* gamma-correct lighting ([#199](https://github.com/vdmkenny/openreliant/issues/199)) ([97c8429](https://github.com/vdmkenny/openreliant/commit/97c84299a8c4047c9e73c7122ed129d30a5c5202))
* guns flash at the muzzle as they fire ([#242](https://github.com/vdmkenny/openreliant/issues/242)) ([b683a9c](https://github.com/vdmkenny/openreliant/commit/b683a9c270d983c3cb867137e032cd56fc1b3f0f)), closes [#63](https://github.com/vdmkenny/openreliant/issues/63)
* install the full game from both discs ([#205](https://github.com/vdmkenny/openreliant/issues/205)) ([f7e662d](https://github.com/vdmkenny/openreliant/commit/f7e662ddde9079ec36d5427f1f4e48f6e952df93))
* missiles ([#215](https://github.com/vdmkenny/openreliant/issues/215)) ([3044c9d](https://github.com/vdmkenny/openreliant/commit/3044c9da3a1834381e6e4926e4f3b24aa252b98e))
* openreliant --version ([#204](https://github.com/vdmkenny/openreliant/issues/204)) ([d29c304](https://github.com/vdmkenny/openreliant/commit/d29c304fe9f0a5d3ef4154da381ffbe43fa2bbf5))
* shadows from the key lights ([#197](https://github.com/vdmkenny/openreliant/issues/197)) ([55686eb](https://github.com/vdmkenny/openreliant/commit/55686ebc7271e4f7ca967c7d82687cfc4ab89c47))
* shots strike the parts of capital ships ([#222](https://github.com/vdmkenny/openreliant/issues/222)) ([9773acc](https://github.com/vdmkenny/openreliant/commit/9773acc5ce8bf41a2baac6e739fe49b36dfb756e))
* the AI's avoidance ([#217](https://github.com/vdmkenny/openreliant/issues/217)) ([cbb59fe](https://github.com/vdmkenny/openreliant/commit/cbb59fefb092e7832bf6e55081ee880e5e671a54))
* the controller rumbles with the game's force feedback ([#245](https://github.com/vdmkenny/openreliant/issues/245)) ([ce9f27d](https://github.com/vdmkenny/openreliant/commit/ce9f27df2b1c7786f96555d7c1f28d6ec40d3484)), closes [#83](https://github.com/vdmkenny/openreliant/issues/83) [#118](https://github.com/vdmkenny/openreliant/issues/118)
* the levels of detail reach as far as the high setting's, and the finer ones further ([#224](https://github.com/vdmkenny/openreliant/issues/224)) ([fe134e8](https://github.com/vdmkenny/openreliant/commit/fe134e8c2e8498f50b6c1e0d97728fdf6e322bd9))
* the missile window ([#216](https://github.com/vdmkenny/openreliant/issues/216)) ([41a493b](https://github.com/vdmkenny/openreliant/commit/41a493bff77e2eb9d2739e3fda5a441dbdc91119))
* the pause menu ([#212](https://github.com/vdmkenny/openreliant/issues/212)) ([8fc47a1](https://github.com/vdmkenny/openreliant/commit/8fc47a1a39be74811aaf33f97838fa02dfef021e))
* the screen's flash and bodies among the burning bits ([#237](https://github.com/vdmkenny/openreliant/issues/237)) ([8234872](https://github.com/vdmkenny/openreliant/commit/8234872751ae28f583b0de4aa5dbf6e1d94f5ded))
* the turrets ([#221](https://github.com/vdmkenny/openreliant/issues/221)) ([9e5d1ff](https://github.com/vdmkenny/openreliant/commit/9e5d1ffdbeb4151ef3d2fec9fceef45baa97f35e))


### Fixes

* every part node hangs in its root's child list ([#228](https://github.com/vdmkenny/openreliant/issues/228)) ([0f0481c](https://github.com/vdmkenny/openreliant/commit/0f0481c5c9a07691c27bc71a1ba6e3ce7479a2b5))
* missiles hurt the player's raised shields ([#243](https://github.com/vdmkenny/openreliant/issues/243)) ([86c1c9a](https://github.com/vdmkenny/openreliant/commit/86c1c9a65f44b00bfb720bae020e9581d28d5b46)), closes [#214](https://github.com/vdmkenny/openreliant/issues/214)


### Documentation

* separate user guide and rewrite documentation with concise, natural phrasing ([#229](https://github.com/vdmkenny/openreliant/issues/229)) ([ed481db](https://github.com/vdmkenny/openreliant/commit/ed481dbab7cab794b7738475fb3fe511c3ce0260))

## [0.2.0](https://github.com/vdmkenny/openreliant/compare/v0.1.0...v0.2.0) (2026-09-23)


### Features

* a component takes damage and is destroyed ([#148](https://github.com/vdmkenny/openreliant/issues/148)) ([185d9c6](https://github.com/vdmkenny/openreliant/commit/185d9c6593339369b0a82cf9d47893ec1e6e8f46))
* a help page for the command line ([#166](https://github.com/vdmkenny/openreliant/issues/166)) ([e2f9b14](https://github.com/vdmkenny/openreliant/commit/e2f9b14924639798ad03bd828cb06b458a27b79d))
* an object lists its model's components ([#147](https://github.com/vdmkenny/openreliant/issues/147)) ([539116b](https://github.com/vdmkenny/openreliant/commit/539116b4ac93e62b27a6060586eac85c649e3dc4))
* count the pilot's kills ([#189](https://github.com/vdmkenny/openreliant/issues/189)) ([60e59c5](https://github.com/vdmkenny/openreliant/commit/60e59c5c9a0333e8de2a239bb6158bbc763837f5))
* explosion effects: particles, fireballs, debris, shockwaves, break-up and sparks ([#172](https://github.com/vdmkenny/openreliant/issues/172)) ([941e635](https://github.com/vdmkenny/openreliant/commit/941e635c5fea1dc95df90e3a1f6840b2824f4a2b))
* fuller explosions ([#174](https://github.com/vdmkenny/openreliant/issues/174)) ([9b0a120](https://github.com/vdmkenny/openreliant/commit/9b0a120708cecb675928b45004be16d34955cb95))
* objects collide, and shove each other ([#145](https://github.com/vdmkenny/openreliant/issues/145)) ([f906227](https://github.com/vdmkenny/openreliant/commit/f9062271b708e3ae5468eb517478f8538745acab))
* pick and draw the player's target ([#184](https://github.com/vdmkenny/openreliant/issues/184)) ([56ae68b](https://github.com/vdmkenny/openreliant/commit/56ae68b2d5a15849c24721812d7426f4e0bbbfa0))
* port the order system and steering ([#142](https://github.com/vdmkenny/openreliant/issues/142)) ([aa775a3](https://github.com/vdmkenny/openreliant/commit/aa775a30932b15281ed784d6336ded858f52e44e))
* shield flares and hull hit sounds ([#180](https://github.com/vdmkenny/openreliant/issues/180)) ([dcda937](https://github.com/vdmkenny/openreliant/commit/dcda937b90c6bf90faa70bdb52eaa9be9fa634c4))
* ships are destroyed when their armour runs out ([#169](https://github.com/vdmkenny/openreliant/issues/169)) ([0791403](https://github.com/vdmkenny/openreliant/commit/07914039e227c1927cfed28fe9af5e33d2e07398)), closes [#41](https://github.com/vdmkenny/openreliant/issues/41)
* ships carry the guns their models hold ([#149](https://github.com/vdmkenny/openreliant/issues/149)) ([a2c66c5](https://github.com/vdmkenny/openreliant/commit/a2c66c5c4fd010aded4f5243e548aad47c10630e))
* ships fire the guns they carry ([#152](https://github.com/vdmkenny/openreliant/issues/152)) ([a5f9694](https://github.com/vdmkenny/openreliant/commit/a5f9694031bc9e66d55bf15fafb3ea8cf3cb830d))
* ships hit a capital ship's hull, and the hit hurts ([#146](https://github.com/vdmkenny/openreliant/issues/146)) ([eade58d](https://github.com/vdmkenny/openreliant/commit/eade58d85527fba31da2f8e03243cd417d6740ec))
* shots fly, hit, and are drawn as the game draws them ([#156](https://github.com/vdmkenny/openreliant/issues/156)) ([a2b59f5](https://github.com/vdmkenny/openreliant/commit/a2b59f59babd1bf1bdb5005edcd18931d2fee9f3))
* smoke and fireballs from damaged ships ([#193](https://github.com/vdmkenny/openreliant/issues/193)) ([51f741b](https://github.com/vdmkenny/openreliant/commit/51f741bf8728aacfe631215d22518392b9e4bfcc))
* smooth explosion effects between ticks ([#175](https://github.com/vdmkenny/openreliant/issues/175)) ([59541e9](https://github.com/vdmkenny/openreliant/commit/59541e9ba10962cee35597d8c241ba1fa171f47b))
* sound through OpenAL Soft, with HRTF, reverbs and a master bus ([#165](https://github.com/vdmkenny/openreliant/issues/165)) ([7a2ddb0](https://github.com/vdmkenny/openreliant/commit/7a2ddb0139886cd3f4b603511faeaacc17ae9f6f))
* sound, faithful to the original, through SDL3 ([#163](https://github.com/vdmkenny/openreliant/issues/163)) ([ab06271](https://github.com/vdmkenny/openreliant/commit/ab062719d5912995a37022eef0d4ff8e0b6c45df))
* the Fight order and its combat maneuvers ([#177](https://github.com/vdmkenny/openreliant/issues/177)) ([10a199e](https://github.com/vdmkenny/openreliant/commit/10a199e91dd80c44f96f6f20f1ccc3f3c7069f91))
* the object array, with the Reliant and a Coalition wing in the sandbox ([#137](https://github.com/vdmkenny/openreliant/issues/137)) ([fc725bf](https://github.com/vdmkenny/openreliant/commit/fc725bfa46288d16c6281da16181a198659d6638))
* the radar's contacts ([#190](https://github.com/vdmkenny/openreliant/issues/190)) ([d2fcdd5](https://github.com/vdmkenny/openreliant/commit/d2fcdd5dca370ea1511769a707d913f583d66c3d))
* the target display and the ship status indicator's armour ([#188](https://github.com/vdmkenny/openreliant/issues/188)) ([5f2fc17](https://github.com/vdmkenny/openreliant/commit/5f2fc17ddde550c103402019fc9fd3211b981caf))


### Fixes

* build OpenAL Soft optimized so HRTF keeps up with gunfire ([#173](https://github.com/vdmkenny/openreliant/issues/173)) ([03dd6c1](https://github.com/vdmkenny/openreliant/commit/03dd6c118964702b8e4187cf89c36910172581d8)), closes [#170](https://github.com/vdmkenny/openreliant/issues/170)
* scale damage by the difficulty setting ([#178](https://github.com/vdmkenny/openreliant/issues/178)) ([c1f2fd1](https://github.com/vdmkenny/openreliant/commit/c1f2fd16fd9d92a689b04365c21e65f722176ecd)), closes [#176](https://github.com/vdmkenny/openreliant/issues/176)
* start the sandbox's Sabres 150000 off ([#161](https://github.com/vdmkenny/openreliant/issues/161)) ([10517ea](https://github.com/vdmkenny/openreliant/commit/10517ea526e1b33e02b2a989b667f16810d00944))
* start the sandbox's Sabres further off ([#160](https://github.com/vdmkenny/openreliant/issues/160)) ([bfce022](https://github.com/vdmkenny/openreliant/commit/bfce0222f299efe2a295618c24bdf068d59779ff))

## [0.1.0](https://github.com/vdmkenny/openreliant/compare/v0.0.1...v0.1.0) (2026-09-22)


### Features

* blinking lights cast light, and every light shows its lamp ([#126](https://github.com/vdmkenny/openreliant/issues/126)) ([ae7a01b](https://github.com/vdmkenny/openreliant/commit/ae7a01b296689f5ae4f185785bc162d1d9e7ddb0))
* finish object_move and add knocks ([#121](https://github.com/vdmkenny/openreliant/issues/121)) ([344fb35](https://github.com/vdmkenny/openreliant/commit/344fb3570a95419209863cba770ca31e2abaea7b))
* install the game's files from your discs ([#112](https://github.com/vdmkenny/openreliant/issues/112)) ([60fd69d](https://github.com/vdmkenny/openreliant/commit/60fd69d19cff7d13b28229cf5fe633feb2eca574))
* joysticks and gamepads ([#116](https://github.com/vdmkenny/openreliant/issues/116)) ([8120219](https://github.com/vdmkenny/openreliant/commit/8120219a0ba763868439be217d55e210178971c7))
* light each pixel with the game's own lights ([#125](https://github.com/vdmkenny/openreliant/issues/125)) ([2c1bac4](https://github.com/vdmkenny/openreliant/commit/2c1bac4404701579cf7cd6232690c62426a10e5b))
* part animation, drawn between simulation steps ([#128](https://github.com/vdmkenny/openreliant/issues/128)) ([a931f1f](https://github.com/vdmkenny/openreliant/commit/a931f1faccf139eeabded9e582abf87b11a3bb28))
* the power distribution ([#124](https://github.com/vdmkenny/openreliant/issues/124)) ([7231d46](https://github.com/vdmkenny/openreliant/commit/7231d468487bb670024e5f2bea9785e880d0ab2d))


### Fixes

* commit an object's next place where the game does ([#120](https://github.com/vdmkenny/openreliant/issues/120)) ([8cb1956](https://github.com/vdmkenny/openreliant/commit/8cb19560f303d2fcd8f4dbc452afb31b113c802f))
* orthonormalize each object's orientation in turn, as the game does ([#123](https://github.com/vdmkenny/openreliant/issues/123)) ([c73d117](https://github.com/vdmkenny/openreliant/commit/c73d1172ed04467ba15d7f05dc1d3235b62a02f7))


### Documentation

* describe OpenReliant as a faithful reimplementation on SDL3 and Vulkan ([#108](https://github.com/vdmkenny/openreliant/issues/108)) ([d451d23](https://github.com/vdmkenny/openreliant/commit/d451d238b0d3fd14e808f12132c9a6a3aa098f41))
* the software device draws the display's text ([#129](https://github.com/vdmkenny/openreliant/issues/129)) ([a45c43c](https://github.com/vdmkenny/openreliant/commit/a45c43cc837d79cfb2cc737009f851626e327248))

## 0.0.1 (2026-09-22)


### Documentation

* describe the flying sandbox and the release builds in the README ([a033728](https://github.com/vdmkenny/openreliant/commit/a033728ab9349116056454a5f7e0a34dac082f90))
* rewrite the README status and download instructions in plain language ([6f76d3c](https://github.com/vdmkenny/openreliant/commit/6f76d3ccffd3c59ad90aef7d3208145cd3ba396b))
* say the sandbox is what OpenReliant runs as for now ([ea24b1a](https://github.com/vdmkenny/openreliant/commit/ea24b1a229d94e3daa8d2ac74277b199fc647e05))
