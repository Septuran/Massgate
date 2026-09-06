# Massgate

An [Icarus](https://store.steampowered.com/app/1149460/ICARUS/) mod that adds paired,
powered exotic-matter gates for mid-to-late-game fast travel that still costs something.
See [docs/design.md](docs/design.md) for the rules and lore.

Two parts ship together and both are required:

- `Massgate_v<version>_P.pak` — data tables (items, recipes, tech tree, power draw, map icons).
  Goes in `Icarus\Content\Paks\mods`. The version in the name is `VERSION` + the git commit
  count, with `-dev` for dev builds and `+` if built from uncommitted changes; the game's
  "Mods Detected" dialog shows it at every launch, and the Lua logs the same string.
- `Massgate` UE4SS Lua mod — the gate behaviour. Goes in
  `Icarus\Binaries\Win64\ue4ss\Mods` (UE4SS 3.0.1 layout).

## Requirements

- Icarus on Windows.
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) **3.0.1** installed in
  `Icarus\Binaries\Win64` (the `ue4ss` sub-folder layout).
- Python 3.10+ to build the pak.
- [repak](https://github.com/trumank/repak) 0.2.x at `tools/bin/repak.exe` (not committed).

## Building

1. Unpack the game's data tables:
   ```
   python tools\build.py --extract
   ```
   (runs `repak unpack` with the odd build-machine mount prefix stripped). **Redo this after
   every game update**: both paks replace whole tables, so stale tables silently undo the
   update (2026-09-04: Sulfur lost its icon that way). The build refuses to run while
   `data.pak` is newer than the extracted tables.
2. Build the pak:
   ```
   python tools\build.py --merge-installed --install
   ```
   `--merge-installed` layers the tables from other mod paks you have installed (unpacked
   into `data/installed/<pakname>/`) under ours, so our full-table replacement does not
   undo them. The merge is row by row: rows a mod adds are taken; rows that differ from the
   fresh game table are taken only if they also differ from the previous game version
   (`data/previous/`, kept by `--extract`), because a row equal to the old game row is just
   the mod's stale copy of something the game update changed (2026-09-05: Gold Ore lost its
   icon that way). Without a baseline, differing rows are taken and listed.
   `--install` copies the pak into the game's mods folder.
   `--install` also copies the Lua mod into `Icarus\Binaries\Win64\ue4ss\Mods\Massgate`
   and writes its `config.lua` for the chosen mode.

### Dev mode (testing on an early-game character)

```
python tools\build.py --merge-installed --dev --install
```

`--dev` makes every Massgate recipe free (1 Fiber), removes the blueprint requirement and lets you
craft from your inventory. It sets `DevMode = true` in the installed `config.lua`: anchors count as
powered, the cooldown is off, the interference radius is 10 m and trips cost no Exotics. Resonators
still need power or a Phase Coupler. Rebuild without `--dev` for the real rules (the Exotics buffer
was verified on a dev build with real costs before they were switched off). Never ship a dev build.

## Fieldkit (second mod in this repo)

`mod/ue4ss/Fieldkit/` is an independent UE4SS Lua mod with a small pak of its own: a kit of
quality-of-life features, one file each under `Scripts/features/`, switched on and off from
the game's own **Custom World Settings** screen (Escape, then Custom World Settings, host
only). The pak `Fieldkit_v<version>_P.pak`, built from `mod/data/fieldkit_patches.json`,
adds the features' rows to that screen; the game renders, saves and replicates them, and the
Lua reads them from the ProspectSubsystem, applying changes the moment the host presses
Apply. A prospect where the rows were never applied runs on the defaults. Only the host or
server needs the Lua; everyone needs the pak.

Features:

- **tameregen** (Creatures section): every tame set to **Follow** heals a share of its
  maximum health every second while out of combat (no attack target and no damage for 10 s),
  on top of the game's flat 10-50 HP/minute. Rate row: percent of maximum health per minute,
  1 to 60, default 15 = 0.25 %/s, so a 2,200 HP mount is back to full in about 7 minutes.
  Scales with the creature talent **Nurtured Recovery**: rank 4 gives the full rate, ranks
  1-3 give 8 / 25 / 50 % of it, no talent gives nothing (`NoTalentFraction`). Mounts, pets
  and farm animals all count (everything derived from `BP_Mount_Base_C`).
- **stow** (Misc section): one key puts the backpack away. Every storage container can be
  **pinned** to a set of item types: open the chest, put in what belongs there and press
  **Shift+P** (or the "Pin contents" button the mod adds to the chest window); the chest is
  now pinned to exactly the types it holds, and pinning an empty chest clears it. With
  **learning** on (default) opening a chest also adds its contents to its pins, so a chest
  that crafting emptied still attracts its item. **Shift+E** then moves every backpack stack
  whose type is pinned on a chest within range (default 30 m) into that chest, nearest first,
  spilling into the next pinned chest when one is full; the hotbar is never touched. The
  pins show in the chest window title (short form) and on the Pin bar (full list), as an
  extra line in the in-world tooltip when you look at the chest, and in the message lines
  after pinning and depositing. Pins are saved per prospect in
  `<ue4ss>\FieldkitData\stow\`, keyed by the chest's class and position (pick a chest up and
  place it again and it starts unpinned). Moves go through the game's own server-side
  shift-item action, so it works as a client too. If NearbyCrafting is installed, set
  `DepositEnabled = false` in its ini (its Quick Deposit also sits on Shift+E) and keep its
  nearby crafting.
- **scour** (Misc section): the **Sonic Scourer**, a craftable powered device (Fabricator:
  steel, electronics, copper wire, composites) that clears the snow, sand and ash storms pile
  onto building pieces. Every few minutes (default 180 s) while switched on and powered it
  pulses and clears every piece within range (default 25 m) whose build-up stopped growing
  since the previous pulse, so it waits a storm out. Each pulse spends one matching cartridge
  from its hopper per ten pieces: **Thermal Cartridge** for snow, **Cyclone Filter** for sand,
  **Scrubber Filter** for ash (Fabricator or Machining Bench, four per craft). Draws 1 kW.
  Press interact to load cartridges, hold to switch it on or off. A `--dev` build needs neither
  power nor cartridges. Placed as the small metal crate actor wearing the thumper mesh, the
  same trick as Massgate's gates. Both mods now add rows to shared tables: `build.py` applies
  both patch files to one table set and writes every touched table into both paks.

Adding a feature: a file `Scripts/features/<id>.lua` returning `{ id, title, init, tick,
settingsChanged, console, status }` (see the header of `main.lua`), its id in
`CONFIG.Features`, and its rows in `fieldkit_patches.json` (a `D_CustomGameStats` row per
switch, bound to a hidden world stat row in `D_Stats`, names prefixed `Fieldkit_`).

`--install` installs the Lua next to Massgate and the pak next to the Massgate pak, and
removes the old TameRegen copies. Always pass `--merge-installed` when installing on a game
that has other table mods (both paks replace whole tables and load after most mods
alphabetically; an un-merged install silently reverts those mods' rows). `--install
--lua-only` refreshes just the Lua mods without touching either pak, which also works while
the game runs: UE4SS reloads Lua with Ctrl+R provided `EnableHotReloadSystem = 1` in
`ue4ss\UE4SS-settings.ini`. Fieldkit prints "Fieldkit v... loaded: ..." in the chat area on
every load, and walks the object table once after a reload to pick up the actors that
already exist (spawn notifications only cover new ones).
Per-feature tunables are documented in `mod/ue4ss/Fieldkit/Scripts/config.lua`. Console:
`fieldkit` (overview), `fieldkit tames`, `fieldkit tameregen` (per-tame health and why each
is or is not healing), `fieldkit tameregen rate <percent per second>` (session override),
`fieldkit stow` (containers in range and their pins), `fieldkit stow pins`, `fieldkit stow
deposit`, `fieldkit stow pin|unpin <item row>` and `fieldkit stow clear` (on the open chest),
`fieldkit stow names <text>` (item rows by display name), `fieldkit scour` (each scourer's
power, hopper, pieces in range and last pulse), `fieldkit scour pulse` (pulse now),
`fieldkit scour probe` (nearest building pieces with raw build-up amount and type),
`fieldkit scan` / `fieldkit stow scan` / `fieldkit scour scan` (one-off object walks to pick up
actors that spawned before the mod loaded, diagnostic only). Log prefixes `[Fieldkit]` and
`[Fieldkit:<feature>]`.

## Layout

```
mod/data/patches.json     rows we add to the data tables
mod/ue4ss/Massgate/       UE4SS Lua mod (Scripts/main.lua, enabled.txt)
mod/ue4ss/Fieldkit/       second UE4SS Lua mod: quality-of-life features (Scripts/features/*.lua)
mod/data/fieldkit_patches.json   their Custom World Settings rows -> Fieldkit_v<ver>_P.pak
tools/build.py            applies patches, validates references, packs with repak
tools/find_rows.py        search the extracted tables for a term
docs/design.md            concept, lore, rules, row map, roadmap
data/original/            extracted game tables (gitignored)
data/installed/           tables from other installed mod paks (gitignored)
```

### Release package

```
python toolsuild.py --package
```

Builds from the original tables only, refuses dev mode and uncommitted changes, and writes
`build
elease\Massgate_v<version>.zip` (pak + Lua folder + README.txt). Full procedure in
[docs/releasing.md](docs/releasing.md).

## Configuration

`mod/ue4ss/Massgate/Scripts/config.lua` (rewritten in the game folder by `--install`):

- `DevMode` — see above.
- `Channels` — the colour names; written from `patches.json` at install.

Channels are the three colour charges (Red, Green, Blue) defined in `patches.json` under
`channels` with their icon colours in `channel_colors`. The lore fixes the count at three.

## Testing notes

- Progress and errors are logged to `Icarus\Binaries\Win64\ue4ss\UE4SS.log` with a
  `[Massgate]` prefix.
- With the UE4SS console enabled, `massgate` lists the gates found on the prospect.
