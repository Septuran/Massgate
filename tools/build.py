"""Build (and optionally install) the Massgate mod.

Usage:
    python tools/build.py                 # base = pristine game tables (data/original)
    python tools/build.py --merge-installed
                                          # base = tables as replaced by the other mod paks
                                          #   currently installed (data/installed/*), layered in
                                          #   alphabetical pak order, so our pak does not undo them
    python tools/build.py --dev           # DEV MODE: recipe needs no blueprint, costs 1 Fiber and
                                          #   is craftable from the inventory; the installed Lua
                                          #   config gets DevMode = true (no power / exotics /
                                          #   cooldown, 10 m interference). Never ship a dev build.
    python tools/build.py --install       # also copy the pak into the game's Paks/mods folder and
                                          #   both Lua mods (Massgate, TameRegen) into the UE4SS Mods folder
    python tools/build.py --install --lua-only
                                          # skip the pak: refresh only the Lua mods (works while the
                                          #   game runs; UE4SS Ctrl+R reloads them)
    python tools/build.py --repak PATH    # explicit path to repak.exe (else tools/bin/repak.exe)

Steps:
  1. load base tables (original, optionally overlaid with installed mod versions)
  2. apply mod/data/patches.json  (rows to add / replace, per table)
  3. (--dev) rewrite our recipe so it is free and unlocked
  4. validate every row reference we introduce points at an existing row
  5. write the full tables to build/pak/Icarus/Content/Data/...
  6. pack build/pak into build/Massgate_v<ver>_P.pak with repak (V11, zlib); then the same for
     mod/data/tameregen_patches.json -> build/TameRegen_v<ver>_P.pak (Prospect Settings rows)
  7. (--install) copy both paks + both Lua mods into the game, writing config.lua for the chosen mode
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ORIGINAL = REPO / "data" / "original"
INSTALLED = REPO / "data" / "installed"
PATCHES = REPO / "mod" / "data" / "patches.json"
LUA_MOD = REPO / "mod" / "ue4ss" / "Massgate"
REGEN_MOD = REPO / "mod" / "ue4ss" / "TameRegen"   # second mod: fast healing for tames on Follow
REGEN_PATCHES = REPO / "mod" / "data" / "tameregen_patches.json"  # its Prospect Settings rows
AISETUP_TABLE = "AI/D_AISetup.json"
MOUNT_CLASS_PREFIX = "/Game/BP/Mounts/"            # every mount, pet and farm animal actor class
BUILD = REPO / "build"
PAK_ROOT = BUILD / "pak"
REGEN_PAK_ROOT = BUILD / "regen_pak"
VERSION_FILE = REPO / "VERSION"


def git(*args: str) -> str:
    try:
        return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


def build_version(dev: bool) -> str:
    """e.g. 0.5.17-dev  (VERSION file . commit count, -dev for dev builds, + if uncommitted changes)."""
    base = VERSION_FILE.read_text(encoding="utf-8").strip() if VERSION_FILE.exists() else "0.0"
    count = git("rev-list", "--count", "HEAD") or "0"
    dirty = "+" if git("status", "--porcelain") else ""
    return f"{base}.{count}{dirty}{'-dev' if dev else ''}"


def pak_name(version: str) -> str:
    return f"Massgate_v{version}_P.pak"

GAME = Path(r"D:\SteamLibrary\steamapps\common\Icarus\Icarus")
GAME_MODS = GAME / "Content" / "Paks" / "mods"
UE4SS_MODS = GAME / "Binaries" / "Win64" / "ue4ss" / "Mods"

RECIPE_TABLE = "Crafting/D_ProcessorRecipes.json"
RECIPE_ROW = "Massgate_"  # prefix: every recipe we add

# A bare {"RowName": ...} under field X normally points at table D_X (the ItemsStatic
# trait convention). These fields break that convention.
TRAIT_TABLE_OVERRIDES = {
    "Audio": "D_ItemAudioData",
    "D_ProcessorRecipes.Audio": "D_CraftingAudioData",
    "Requirement": "D_Talents",
    "TalentTree": "D_TalentTrees",
    "EnergyFlow": "D_Energy",
    "ItemStaticData": "D_ItemsStatic",
    "SlotTemplate": "D_TagQueries",
    "Stat": "D_Stats",
    "StatCategory": "D_StatCategories",
}


def hinted_table(table_stem: str, field: str) -> str:
    return (
        TRAIT_TABLE_OVERRIDES.get(f"{table_stem}.{field}")
        or TRAIT_TABLE_OVERRIDES.get(field)
        or f"D_{field}"
    )


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, data: dict) -> None:
    # Match the game's own formatting: 4-space indent, CRLF, unicode kept.
    text = json.dumps(data, indent=4, ensure_ascii=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.replace("\n", "\r\n") + "\r\n", encoding="utf-8")


def load_base_tables(merge_installed: bool, quiet: bool = False) -> dict[str, tuple[Path, dict]]:
    """Return {rel_path: (rel_path, table_json)} for every original table (fresh copies each call)."""
    tables: dict[str, tuple[Path, dict]] = {}
    for path in sorted(ORIGINAL.rglob("*.json")):
        rel = path.relative_to(ORIGINAL)
        tables[str(rel).replace("\\", "/")] = (rel, read_json(path))
    if not merge_installed:
        return tables
    if not INSTALLED.exists():
        print("!! --merge-installed given but data/installed is missing; using originals only")
        return tables
    for pak_dir in sorted(INSTALLED.iterdir()):  # alphabetical = game load order
        for path in pak_dir.rglob("*.json"):
            parts = [p.lower() for p in path.relative_to(pak_dir).parts]
            if "data" not in parts:
                continue
            rel = Path(*path.relative_to(pak_dir).parts[parts.index("data") + 1 :])
            key = str(rel).replace("\\", "/")
            if key in tables:
                tables[key] = (rel, read_json(path))
                if not quiet:
                    print(f"   overlay {key:45s} <- {pak_dir.name}")
    return tables


def expand_channels(patches: dict) -> dict:
    """Clone every row of a per_channel table once per channel, replacing {CH}."""
    channels = patches.get("channels", [])
    colors = patches.get("channel_colors", {})

    def fill(node, channel):
        if isinstance(node, str):
            if node == "{CH_COLOR}":
                if channel not in colors:
                    sys.exit(f"!! no channel_colors entry for {channel}")
                return colors[channel]
            if node == "{CH_ICON}":
                icons = patches.get("channel_icons", {})
                if channel not in icons:
                    sys.exit(f"!! no channel_icons entry for {channel}")
                return icons[channel]
            return node.replace("{CH}", channel)
        if isinstance(node, dict):
            return {k: fill(v, channel) for k, v in node.items()}
        if isinstance(node, list):
            return [fill(v, channel) for v in node]
        return node

    expanded = []
    for patch in patches["tables"]:
        if not patch.get("per_channel"):
            expanded.append(patch)
            continue
        if not channels:
            sys.exit(f"!! {patch['table']} is per_channel but no channels are defined")
        clone = {k: v for k, v in patch.items() if k != "per_channel"}
        for op in ("add", "replace"):
            if op in patch:
                clone[op] = [fill(row, ch) for row in patch[op] for ch in channels]
        expanded.append(clone)
    return {**patches, "tables": expanded}


def apply_patches(tables: dict[str, tuple[Path, dict]], patches: dict) -> list[tuple[str, dict]]:
    """Add/replace rows. Returns the list of (table_key, row) we introduced."""
    introduced: list[tuple[str, dict]] = []
    for patch in patches["tables"]:
        key = patch["table"]
        if key not in tables:
            sys.exit(f"!! patch targets unknown table {key}")
        _, table = tables[key]
        rows = table["Rows"]
        index = {r["Name"]: i for i, r in enumerate(rows)}
        for row in patch.get("add", []):
            if row["Name"] in index:
                sys.exit(f"!! {key}: row {row['Name']} already exists (use 'replace')")
            rows.append(row)
            introduced.append((key, row))
        for row in patch.get("replace", []):
            if row["Name"] not in index:
                sys.exit(f"!! {key}: row {row['Name']} to replace does not exist")
            rows[index[row["Name"]]] = row
            introduced.append((key, row))
    return introduced


def apply_dev_mode(tables: dict[str, tuple[Path, dict]], introduced: list[tuple[str, dict]]) -> None:
    """Make the gates free: no blueprint, 1 Fiber, craftable from the inventory.
    (Trip costs are switched off by the Lua side when DevMode is true.)"""
    count = 0
    for key, row in introduced:
        if key == RECIPE_TABLE and row["Name"].startswith(RECIPE_ROW):
            row.pop("Requirement", None)
            row["RequiredMillijoules"] = 1000
            row["RecipeSets"] = [
                {"RowName": "Character", "DataTableName": "D_RecipeSets"},
                {"RowName": "Fabricator", "DataTableName": "D_RecipeSets"},
            ]
            row["Inputs"] = [
                {"Element": {"RowName": "Fiber", "DataTableName": "D_ItemsStatic"}, "Count": 1}
            ]
            count += 1
    if not count:
        sys.exit("!! dev mode: no recipe rows found among introduced rows")
    print(f"   DEV: {count} recipe(s) are free, unlocked and craftable from the inventory")


def collect_refs(node, table_stem: str, field_hint: str | None = None):
    """Yield (table_name, row_name) for every row handle in a row."""
    if isinstance(node, dict):
        if "RowName" in node and isinstance(node["RowName"], str):
            table = node.get("DataTableName")
            if table is None and field_hint:
                table = hinted_table(table_stem, field_hint)
            if table:
                yield table, node["RowName"]
        for k, v in node.items():
            yield from collect_refs(v, table_stem, k)
    elif isinstance(node, list):
        for v in node:
            yield from collect_refs(v, table_stem, field_hint)


def validate(tables: dict[str, tuple[Path, dict]], introduced: list[tuple[str, dict]]) -> None:
    by_name: dict[str, set[str]] = {}
    for key, (_, table) in tables.items():
        rows = table.get("Rows")
        if isinstance(rows, list):  # DataTableMetadata.json and friends have no rows
            by_name[Path(key).stem] = {r["Name"] for r in rows}
    problems = 0
    for key, row in introduced:
        for table, row_name in collect_refs(row, Path(key).stem):
            if row_name in ("", "None"):
                continue
            if table not in by_name:
                print(f"   ?  {key}:{row['Name']} -> {table}.{row_name}  (table not in data.pak, cannot check)")
                continue
            if row_name not in by_name[table]:
                print(f"!! {key}:{row['Name']} -> {table}.{row_name}  MISSING")
                problems += 1
    if problems:
        sys.exit(f"!! {problems} broken reference(s); aborting")
    print(f"   validated {len(introduced)} rows, all references resolve")


def pack(repak: Path, version: str, pak_root: Path = PAK_ROOT, prefix: str = "Massgate") -> Path:
    for old in BUILD.glob(f"{prefix}*_P.pak"):
        old.unlink()
    out = BUILD / f"{prefix}_v{version}_P.pak"
    cmd = [str(repak), "pack", "--version", "V11", "--compression", "Zlib", str(pak_root), str(out)]
    subprocess.run(cmd, check=True)
    return out


def write_tables(pak_root: Path, tables: dict[str, tuple[Path, dict]], touched: list[str]) -> None:
    if pak_root.exists():
        shutil.rmtree(pak_root)
    for key in touched:
        rel, table = tables[key]
        write_json(pak_root / "Icarus" / "Content" / "Data" / rel, table)
        print(f"   {key}")


def build_regen_pak(repak: Path, merge_installed: bool, version: str, massgate_touched: list[str]) -> Path:
    """TameRegen's own pak: the Prospect Settings rows from tameregen_patches.json. Built on a fresh
    copy of the base tables. Both paks replace whole tables and load alphabetically, so a table
    touched by both would lose Massgate's rows; refuse that."""
    tables = load_base_tables(merge_installed, quiet=True)
    introduced = apply_patches(tables, read_json(REGEN_PATCHES))
    touched = sorted({key for key, _ in introduced})
    overlap = sorted(set(touched) & set(massgate_touched))
    if overlap:
        sys.exit(f"!! tameregen_patches.json and patches.json both touch {overlap}; move the rows into one file")
    validate(tables, introduced)
    write_tables(REGEN_PAK_ROOT, tables, touched)
    return pack(repak, version, REGEN_PAK_ROOT, "TameRegen")


def write_config(scripts_dir: Path, dev: bool, channels: list[str], version: str) -> None:
    lua_channels = ", ".join(f'"{c}"' for c in channels)
    (scripts_dir / "config.lua").write_text(
        "-- Written by tools/build.py. Edit the repo copy, not this file.\n"
        "return {\n"
        f"    Version = \"{version}\",\n"
        f"    DevMode = {'true' if dev else 'false'},\n"
        f"    Channels = {{ {lua_channels} }},\n"
        "}\n",
        encoding="utf-8",
    )


def mount_classes(tables: dict[str, tuple[Path, dict]]) -> list[str]:
    """Actor classes the game spawns under /Game/BP/Mounts/ (mounts, pets, farm animals), from D_AISetup.
    TameRegen watches these in addition to their common base class BP_Mount_Base_C."""
    _, table = tables[AISETUP_TABLE]
    return sorted({
        str(row["ActorClass"]) for row in table.get("Rows", [])
        if str(row.get("ActorClass", "")).startswith(MOUNT_CLASS_PREFIX)
    })


TALENTS_TABLE = "Talents/D_Talents.json"
REGEN_STAT_KEY = '(Value="BaseHealthRegen_+%")'


def regen_talents(tables: dict[str, tuple[Path, dict]]) -> dict[str, list[int]]:
    """The creature talent 'Nurtured Recovery' (one row per species, e.g.
    Creature_Base_HealthRegeneration_Buffalo): row name -> the health-regen bonus of each rank.
    TameRegen scales its heal by the unlocked rank's share of the top rank."""
    _, table = tables[TALENTS_TABLE]
    found: dict[str, list[int]] = {}
    for row in table.get("Rows", []):
        if not str(row.get("TalentTree", {}).get("RowName", "")).startswith("Creature_"):
            continue
        rewards = row.get("Rewards") or []
        stats = [r.get("GrantedStats", {}) for r in rewards]
        if rewards and all(list(s.keys()) == [REGEN_STAT_KEY] for s in stats):
            found[row["Name"]] = [int(s[REGEN_STAT_KEY]) for s in stats]
    if not found:
        sys.exit("!! no creature health-regen talents found in D_Talents; the table format changed?")
    return found


def write_regen_config(scripts_dir: Path, version: str, classes: list[str], talents: dict[str, list[int]]) -> None:
    lua_classes = "".join(f'        "{c}",\n' for c in classes)
    lua_talents = "".join(
        f'        ["{name}"] = {{ {", ".join(str(v) for v in ranks)} }},\n' for name, ranks in sorted(talents.items())
    )
    (scripts_dir / "config.lua").write_text(
        "-- Written by tools/build.py. Edit the repo copy, not this file.\n"
        "-- Tunables (PercentPerSecond, CombatGraceSeconds, ...) are documented in the repo's config.lua.\n"
        "return {\n"
        f"    Version = \"{version}\",\n"
        "    MountClasses = {\n"
        f"{lua_classes}"
        "    },\n"
        "    -- Nurtured Recovery rows from D_Talents: per-rank regen bonus, used to scale the heal\n"
        "    RegenTalents = {\n"
        f"{lua_talents}"
        "    },\n"
        "}\n",
        encoding="utf-8",
    )


def install_lua_mod(source: Path, write: callable) -> Path:
    target = UE4SS_MODS / source.name
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    write(target / "Scripts")
    return target


RELEASE_README = """Massgate {version} for Icarus
================================

Two parts, both required. Needs UE4SS 3.0.1 (the layout with Icarus\\Binaries\\Win64\\ue4ss\\).

1. Copy {pak} into
   <Icarus>\\Icarus\\Content\\Paks\\mods\\      (lowercase "mods"; create it if missing;
                                              remove any older Massgate_v*_P.pak first)
2. Copy the folder "Massgate" into
   <Icarus>\\Icarus\\Binaries\\Win64\\ue4ss\\Mods\\
3. Start the game. The "Mods Detected" dialog lists the pak; ue4ss\\UE4SS.log shows
   "Massgate v{version} loaded".

Everyone in a multiplayer session needs both parts. Dedicated servers must run UE4SS (Windows).

Also in this zip, optional and independent: TameRegen. Copy the folder "TameRegen" next to
"Massgate" in ue4ss\\Mods\\ and {marker} into Paks\\mods\\. Tames set to Follow then heal a share
of their maximum health every second while out of combat, scaled by their Nurtured Recovery
talent. Switch it on or off and set the rate in game: Escape -> Prospect Settings -> Creatures
(host only). Only the host / server needs the Lua; everyone needs the pak.

Source, docs and issues: https://github.com/Septuran/Massgate
"""


def package(pak: Path, marker: Path, dev: bool, channels: list[str], version: str, classes: list[str],
            talents: dict[str, list[int]]) -> Path:
    """Build the distributable zip: both paks, both Lua mod folders and a README."""
    release_dir = BUILD / "release"
    staging = release_dir / f"Massgate_v{version}"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copy2(pak, staging / pak.name)
    shutil.copy2(marker, staging / marker.name)
    shutil.copytree(LUA_MOD, staging / LUA_MOD.name)
    write_config(staging / LUA_MOD.name / "Scripts", dev, channels, version)
    shutil.copytree(REGEN_MOD, staging / REGEN_MOD.name)
    write_regen_config(staging / REGEN_MOD.name / "Scripts", version, classes, talents)
    (staging / "README.txt").write_text(
        RELEASE_README.format(version=version, pak=pak.name, marker=marker.name), encoding="utf-8")
    archive = shutil.make_archive(str(release_dir / f"Massgate_v{version}"), "zip", root_dir=staging)
    return Path(archive)


def install(pak: Path | None, marker: Path | None, dev: bool, channels: list[str], version: str,
            classes: list[str], talents: dict[str, list[int]]) -> None:
    """Copy the paks (unless None: --lua-only) and both Lua mods into the game."""
    if not GAME_MODS.exists():
        sys.exit(f"!! game mods folder not found: {GAME_MODS}")
    if not UE4SS_MODS.exists():
        sys.exit(f"!! UE4SS Mods folder not found: {UE4SS_MODS}")
    stale: list[str] = []
    for prefix, new in (("Massgate", pak), ("TameRegen", marker)):
        if new is None:
            continue
        try:
            # Only one pak per mod may be installed at a time; the name carries the version.
            for old in GAME_MODS.glob(f"{prefix}*_P.pak"):
                old.unlink()
            shutil.copy2(new, GAME_MODS / new.name)
        except PermissionError:
            # A mounted pak is held open by the running game. Install everything else and say so.
            stale.append(prefix)
            print(f"!! {prefix} pak NOT replaced: Icarus is running and holds the installed one open")
            continue
        print(f"   pak      -> {GAME_MODS / new.name}")

    target = install_lua_mod(LUA_MOD, lambda scripts: write_config(scripts, dev, channels, version))
    print(f"   lua mod  -> {target}  (Version = {version}, DevMode = {'true' if dev else 'false'}, channels = {channels})")
    target = install_lua_mod(REGEN_MOD, lambda scripts: write_regen_config(scripts, version, classes, talents))
    print(f"   lua mod  -> {target}  (Version = {version}, {len(classes)} mount classes, {len(talents)} regen talents)")
    if stale:
        sys.exit(
            f"!! stale pak(s) still installed: {', '.join(stale)}. Close the game, then run:\n"
            "   python tools/build.py --merge-installed" + (" --dev" if dev else "") + " --install"
        )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--merge-installed", action="store_true")
    ap.add_argument("--dev", action="store_true")
    ap.add_argument("--install", action="store_true")
    ap.add_argument("--package", action="store_true", help="build the release zip in build/release/")
    ap.add_argument("--lua-only", action="store_true",
                    help="with --install: refresh only the Lua mods (no pak build; works while Icarus runs)")
    ap.add_argument("--repak", type=Path, default=REPO / "tools" / "bin" / "repak.exe")
    args = ap.parse_args()

    if not ORIGINAL.exists():
        sys.exit("!! data/original missing: unpack data.pak first (see README)")
    if args.lua_only:
        if not args.install or args.package:
            sys.exit("!! --lua-only only makes sense together with --install (and not --package)")
        tables = load_base_tables(False)
        patches = read_json(PATCHES)
        version = build_version(args.dev)
        print(f"installing Lua mods only, version {version}")
        install(None, None, args.dev, patches.get("channels", []), version, mount_classes(tables), regen_talents(tables))
        return 0
    if not args.repak.exists():
        sys.exit(f"!! repak not found at {args.repak}")
    if args.package:
        # A release must be reproducible from the pristine game tables and the committed tree.
        if args.merge_installed:
            sys.exit("!! --package cannot be combined with --merge-installed: a release is built on the original tables only")
        if args.dev:
            sys.exit("!! --package cannot be combined with --dev: never ship a dev build")
        if git("status", "--porcelain"):
            sys.exit("!! --package needs a clean git tree: commit first so the version number is reproducible")

    print("1. loading base tables")
    tables = load_base_tables(args.merge_installed)
    print("2. applying patches")
    patches = read_json(PATCHES)
    introduced = apply_patches(tables, expand_channels(patches))
    touched = sorted({key for key, _ in introduced})
    if args.dev:
        print("3. DEV MODE")
        apply_dev_mode(tables, introduced)
    print("4. validating references")
    validate(tables, introduced)
    print("5. writing tables")
    write_tables(PAK_ROOT, tables, touched)
    version = build_version(args.dev)
    print(f"6. packing version {version}")
    out = pack(args.repak, version)
    print(f"   -> {out} ({out.stat().st_size:,} bytes){'  [DEV BUILD]' if args.dev else ''}")
    print("6b. TameRegen pak (Prospect Settings rows)")
    marker = build_regen_pak(args.repak, args.merge_installed, version, touched)
    print(f"   -> {marker} ({marker.stat().st_size:,} bytes)")
    classes, talents = mount_classes(tables), regen_talents(tables)
    if args.install:
        print("7. installing")
        install(out, marker, args.dev, patches.get("channels", []), version, classes, talents)
    if args.package:
        print("8. packaging")
        archive = package(out, marker, args.dev, patches.get("channels", []), version, classes, talents)
        print(f"   -> {archive} ({archive.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
