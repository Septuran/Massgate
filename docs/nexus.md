# Massgate — Nexus page text

Paste each section into the matching heading of the Nexus "Full description" editor.

---

## Description

Massgate adds exotic-matter gates to Icarus: fast travel for the mid-to-late game that stays a
choice rather than a free ride.

Every gate is a pair with two unequal ends. The **Anchor Lattice** is the base end: heavy,
expensive, and hungry for power. The **Resonator** is the field end: light, cheap, and needing
only a small power supply. Tune both to the same colour charge (Red, Green or Blue) and they
lock to each other across any distance. Stand in the field of one, engage it, wait three seconds
while the lattice charges, and you step out in front of the other.

The trip is not symmetrical. Going out to a Resonator burns Exotics loaded into the Anchor. Coming
home is free, carried by the Anchor's mass. Your mounts and pets that are set to Follow and
standing in the field travel with you.

The lore fixes the number of channels at three, because there are exactly three colour charges
and no fourth. A base can hold one Anchor per colour side by side, since a red-green-blue triplet
is colour-neutral and stable. A Resonator has no such protection: any other gate within 500 m
pulls it off frequency, so outposts must be far from each other and far from home.

## Installation instructions

Massgate has two parts and both are required.

1. Install **UE4SS 3.0.1** for Icarus if you do not have it (see Requirements). After installing,
   your game folder has `Icarus\Binaries\Win64\ue4ss\` with a `Mods` folder inside it.
2. Download the Massgate archive and open it. It contains a pak file named
   `Massgate_v<version>_P.pak` and a folder named `Massgate`.
3. Copy the pak file into `Icarus\Content\Paks\mods\` (create the `mods` folder, lowercase, if it
   does not exist). Remove any older `Massgate_v..._P.pak` first; only one may be present.
4. Copy the `Massgate` folder into `Icarus\Binaries\Win64\ue4ss\Mods\`. You should end up with
   `...\ue4ss\Mods\Massgate\Scripts\main.lua` and `...\ue4ss\Mods\Massgate\enabled.txt`.
5. Start the game. The "Mods Detected" dialog lists the Massgate pak with its version. The
   file `Icarus\Binaries\Win64\ue4ss\UE4SS.log` contains a line `Massgate v... loaded` if the Lua
   side started.

**Getting started in game**

- Unlock the **Massgate** blueprint in the Tier 4 Fabricator tree. It sits next to the Exotic
  Processor and requires it.
- Craft an **Anchor Lattice** and a **Resonator** at a Fabricator.
- Place the Anchor at your base on the power grid. Place the Resonator at least 500 m away,
  outdoors, with its own small power source (a wind turbine or two solar panels are enough).
- Look at each gate and use the alternate-interact key (the one that opens radial menus on
  other deployables) to open the **Lattice controls** wheel. Pick the same colour on both.
- Hold interact on the Anchor to open its panel and load Exotics into the four fuel slots.
- Press interact on a gate to **Engage**. Stay inside the field (8 m) for three seconds.

**Multiplayer**: every player needs the pak, and everyone should install the Lua as well. On a
dedicated server the server must run UE4SS (Windows only). Hosted co-op works from the host.

## Main features

- **Paired gates, two kinds.** Anchor Lattice at base, Resonator in the field. One pair per colour
  charge, three colours per prospect.
- **Asymmetric cost.** Outbound trips cost Exotics from the Anchor's buffer; inbound trips are
  free.
- **Real constraints.** Both ends need power. Resonators refuse to tune with any other gate within
  500 m. Three-second charge-up; leave the field and it aborts. Cooldown after each trip.
- **Tames travel with you** if they are set to Follow and stand in the field. Your farm stays put.
- **Lattice panel.** Hold interact for the game's storage panel: four Exotics-only slots and one
  module slot.
- **Phase Coupler module.** Slot it into an Anchor and its Resonator no longer needs a power
  supply: the Anchor pushes energy along the colour channel. Outbound trips then cost extra.
- **Control wheel.** Alternate-interact opens the game's radial menu: Tune Red, Tune Green,
  Tune Blue, Power On/Off, Pick Up.
- **Map and compass icons** per gate, coloured by channel, with the kind and colour on hover.
- **Safe arrival.** You land on traced ground in front of the destination gate.
- Colours are stored per gate and survive save and load.

Balance numbers (may change between versions): Anchor 2500 power and a heavy recipe including
200 Exotics; Resonator 500 power and a light recipe including 60 Exotics; 5 Exotics per outbound
trip, 8 when coupled; 20 s cooldown; 500 m interference.

## Requirements

- **Icarus** on Windows (PC, Steam). Not tested on other storefronts.
- **UE4SS 3.0.1** (the version with the `ue4ss` sub-folder layout under `Binaries\Win64`). Newer
  UE4SS releases changed the folder layout and are not supported by this release.
- **Load order and other mods.** Massgate ships full copies of the data tables it changes
  (items, recipes, talents, interactions, map icons and a few trait tables). If another mod also
  replaces one of those tables, whichever pak loads last wins. Use the Icarus Mod Manager to merge
  mods that touch the same tables, or make sure Massgate is the only one touching them.
- **Dedicated servers** must be Windows and run UE4SS with the Massgate Lua installed; clients
  need the pak (and should have the Lua for the correct looks and icons).
- Source and issue tracker: https://github.com/Septuran/Massgate
