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
                                          #   the Lua mod into the UE4SS Mods folder
    python tools/build.py --repak PATH    # explicit path to repak.exe (else tools/bin/repak.exe)

Steps:
  1. load base tables (original, optionally overlaid with installed mod versions)
  2. apply mod/data/patches.json  (rows to add / replace, per table)
  3. (--dev) rewrite our recipe so it is free and unlocked
  4. validate every row reference we introduce points at an existing row
  5. write the full tables to build/pak/Icarus/Content/Data/...
  6. pack build/pak into build/Massgate_P.pak with repak (V11, zlib)
  7. (--install) copy pak + Lua mod into the game, writing config.lua for the chosen mode
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
BUILD = REPO / "build"
PAK_ROOT = BUILD / "pak"
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


def load_base_tables(merge_installed: bool) -> dict[str, tuple[Path, dict]]:
    """Return {rel_path: (rel_path, table_json)} for every original table."""
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


DEV_EXOTICS_RECIPE = {
    "Name": "Massgate_Dev_Exotics",
    "RequiredMillijoules": 1000,
    "RecipeSets": [{"RowName": "Character", "DataTableName": "D_RecipeSets"}],
    "Inputs": [{"Element": {"RowName": "Fiber", "DataTableName": "D_ItemsStatic"}, "Count": 1}],
    "Outputs": [
        {"Element": {"RowName": "ExoticsReward_200", "DataTableName": "D_ItemTemplate"}, "Count": 1,
         "DynamicProperties": [], "Alterations": []}
    ],
    "Audio": {"RowName": "MachiningBench"},
}


def apply_dev_mode(tables: dict[str, tuple[Path, dict]], introduced: list[tuple[str, dict]]) -> None:
    """Make the gates free: no blueprint, 1 Fiber, craftable from the inventory.
    Also adds a dev-only recipe turning 1 Fiber into 200 Exotics so buffers and trip
    costs can be tested on an early-game character."""
    _, recipes = tables[RECIPE_TABLE]
    recipes["Rows"].append(DEV_EXOTICS_RECIPE)
    introduced.append((RECIPE_TABLE, DEV_EXOTICS_RECIPE))
    count = 0
    for key, row in introduced:
        if key == RECIPE_TABLE and row["Name"].startswith(RECIPE_ROW) and row["Name"] != DEV_EXOTICS_RECIPE["Name"]:
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


def pack(repak: Path, version: str) -> Path:
    for old in BUILD.glob("Massgate*_P.pak"):
        old.unlink()
    out = BUILD / pak_name(version)
    cmd = [str(repak), "pack", "--version", "V11", "--compression", "Zlib", str(PAK_ROOT), str(out)]
    subprocess.run(cmd, check=True)
    return out


def install(pak: Path, dev: bool, channels: list[str], version: str) -> None:
    if not GAME_MODS.exists():
        sys.exit(f"!! game mods folder not found: {GAME_MODS}")
    if not UE4SS_MODS.exists():
        sys.exit(f"!! UE4SS Mods folder not found: {UE4SS_MODS}")
    try:
        # Only one Massgate pak may be installed at a time; the name carries the version.
        for old in GAME_MODS.glob("Massgate*_P.pak"):
            old.unlink()
        shutil.copy2(pak, GAME_MODS / pak.name)
    except PermissionError:
        sys.exit(
            "!! cannot replace the installed pak: Icarus is running and holds it open.\n"
            "   Close the game, then run:  python tools/build.py --merge-installed"
            + (" --dev" if dev else "") + " --install"
        )
    print(f"   pak      -> {GAME_MODS / pak.name}")

    target = UE4SS_MODS / LUA_MOD.name
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(LUA_MOD, target)
    config = target / "Scripts" / "config.lua"
    lua_channels = ", ".join(f'"{c}"' for c in channels)
    config.write_text(
        "-- Written by tools/build.py at install time. Edit the repo copy, not this file.\n"
        "return {\n"
        f"    Version = \"{version}\",\n"
        f"    DevMode = {'true' if dev else 'false'},\n"
        f"    Channels = {{ {lua_channels} }},\n"
        "}\n",
        encoding="utf-8",
    )
    print(f"   lua mod  -> {target}  (Version = {version}, DevMode = {'true' if dev else 'false'}, channels = {channels})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--merge-installed", action="store_true")
    ap.add_argument("--dev", action="store_true")
    ap.add_argument("--install", action="store_true")
    ap.add_argument("--repak", type=Path, default=REPO / "tools" / "bin" / "repak.exe")
    args = ap.parse_args()

    if not ORIGINAL.exists():
        sys.exit("!! data/original missing: unpack data.pak first (see README)")
    if not args.repak.exists():
        sys.exit(f"!! repak not found at {args.repak}")

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
    if PAK_ROOT.exists():
        shutil.rmtree(PAK_ROOT)
    for key in touched:
        rel, table = tables[key]
        write_json(PAK_ROOT / "Icarus" / "Content" / "Data" / rel, table)
        print(f"   {key}")
    version = build_version(args.dev)
    print(f"6. packing version {version}")
    out = pack(args.repak, version)
    print(f"   -> {out} ({out.stat().st_size:,} bytes){'  [DEV BUILD]' if args.dev else ''}")
    if args.install:
        print("7. installing")
        install(out, args.dev, patches.get("channels", []), version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
