# Massgate

An [Icarus](https://store.steampowered.com/app/1149460/ICARUS/) mod that adds paired,
powered exotic-matter gates for mid-to-late-game fast travel that still costs something.
See [docs/design.md](docs/design.md) for the rules and lore.

Two parts ship together and both are required:

- `Massgate_P.pak` — data tables (item, recipe, tech tree, power draw). Goes in
  `Icarus\Content\Paks\mods`.
- `Massgate` UE4SS Lua mod — the gate behaviour. Goes in
  `Icarus\Binaries\Win64\ue4ss\Mods` (UE4SS 3.0.1 layout).

## Requirements

- Icarus on Windows.
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) **3.0.1** installed in
  `Icarus\Binaries\Win64` (the `ue4ss` sub-folder layout).
- Python 3.10+ to build the pak.
- [repak](https://github.com/trumank/repak) 0.2.x at `tools/bin/repak.exe` (not committed).

## Building

1. Unpack the game's data tables once:
   ```
   tools\bin\repak.exe unpack -s "C:/BA/work/92bbbfa44df12262/Temp/Data/" -o data\original "D:\SteamLibrary\steamapps\common\Icarus\Icarus\Content\Data\data.pak"
   ```
   The mount prefix inside data.pak is that odd build-machine path; strip it or the
   files land in the wrong place.
2. Build the pak:
   ```
   python tools\build.py --merge-installed --install
   ```
   `--merge-installed` layers the tables from other mod paks you have installed (unpacked
   into `data/installed/<pakname>/`) under ours, so our full-table replacement does not
   undo them. `--install` copies the pak into the game's mods folder.
   `--install` also copies the Lua mod into `Icarus\Binaries\Win64\ue4ss\Mods\Massgate`
   and writes its `config.lua` for the chosen mode.

### Dev mode (testing on an early-game character)

```
python tools\build.py --merge-installed --dev --install
```

`--dev` makes the recipe free (1 Fiber), removes the blueprint requirement and lets you
craft it from your inventory, and sets `DevMode = true` in the installed `config.lua`, which
turns off the power, Exotics and cooldown checks and shrinks the interference radius to
10 m. Rebuild without `--dev` to get the real rules back. Never ship a dev build.

## Layout

```
mod/data/patches.json     rows we add to the data tables
mod/ue4ss/Massgate/       UE4SS Lua mod (Scripts/main.lua, enabled.txt)
tools/build.py            applies patches, validates references, packs with repak
tools/find_rows.py        search the extracted tables for a term
docs/design.md            concept, lore, rules, row map, roadmap
data/original/            extracted game tables (gitignored)
data/installed/           tables from other installed mod paks (gitignored)
```

## Configuration

`mod/ue4ss/Massgate/Scripts/config.lua` (rewritten in the game folder by `--install`):

- `DevMode` — see above.
- `Meshes` — optional table `{ Anchor = path, Resonator = path }` overriding the meshes the two
  gate kinds wear instead of the spotlight tripod. Defaults are the orbital-exchange landing pad
  and the survey laser uplink. Keep them in sync with `PreviewStaticMesh` in `patches.json` so
  the placement preview matches.

Channels are defined in `patches.json` under `channels`; each becomes an Anchor item and a
Resonator item with their own recipes. Add a name to the list and rebuild to add a channel.

## Testing notes

- Progress and errors are logged to `Icarus\Binaries\Win64\ue4ss\UE4SS.log` with a
  `[Massgate]` prefix.
- With the UE4SS console enabled, `massgate` lists the gates found on the prospect.
