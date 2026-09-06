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
                                          #   both Lua mods (Massgate, Fieldkit) into the UE4SS Mods folder
    python tools/build.py --install --lua-only
                                          # skip the pak: refresh only the Lua mods (works while the
                                          #   game runs; UE4SS Ctrl+R reloads them)
    python tools/build.py --extract ...   # re-extract data/original from the game's data.pak first;
                                          #   required after every game update (the build refuses to
                                          #   run on tables older than data.pak)
    python tools/build.py --repak PATH    # explicit path to repak.exe (else tools/bin/repak.exe)

Steps:
  1. load base tables (original, optionally overlaid with installed mod versions)
  2. apply mod/data/patches.json  (rows to add / replace, per table)
  3. (--dev) rewrite our recipe so it is free and unlocked
  4. validate every row reference we introduce points at an existing row
  5. write the full tables to build/pak/Icarus/Content/Data/...
  6. pack build/pak into build/Massgate_v<ver>_P.pak with repak (V11, zlib); then the same for
     mod/data/fieldkit_patches.json -> build/Fieldkit_v<ver>_P.pak (Custom World Settings rows)
  7. (--install) copy both paks + both Lua mods into the game, writing config.lua for the chosen mode
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ORIGINAL = REPO / "data" / "original"
PREVIOUS = REPO / "data" / "previous"   # the extraction before the last --extract: merge baseline
INSTALLED = REPO / "data" / "installed"
PATCHES = REPO / "mod" / "data" / "patches.json"
LUA_MOD = REPO / "mod" / "ue4ss" / "Massgate"
FIELDKIT_MOD = REPO / "mod" / "ue4ss" / "Fieldkit"   # second mod: quality-of-life features, one file each
LEGACY_MODS = ("TameRegen",)                         # earlier names; --install removes their game copies
FIELDKIT_PATCHES = REPO / "mod" / "data" / "fieldkit_patches.json"  # its Custom World Settings rows
AISETUP_TABLE = "AI/D_AISetup.json"
MOUNT_CLASS_PREFIX = "/Game/BP/Mounts/"            # every mount, pet and farm animal actor class
BUILD = REPO / "build"
PAK_ROOT = BUILD / "pak"
FIELDKIT_PAK_ROOT = BUILD / "fieldkit_pak"
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
GAME_DATA_PAK = GAME / "Content" / "Data" / "data.pak"
DATA_MOUNT_PREFIX = "C:/BA/work/92bbbfa44df12262/Temp/Data/"  # odd build-machine path inside data.pak


def extract_game_tables(repak: Path) -> None:
    """Re-extract data/original from the game's data.pak (after a game update)."""
    if not GAME_DATA_PAK.exists():
        sys.exit(f"!! game data.pak not found: {GAME_DATA_PAK}")
    if ORIGINAL.exists():
        # Keep the outgoing tables: --merge-installed uses them to tell an installed mod's real
        # changes from its stale copies of rows the game update changed.
        if PREVIOUS.exists():
            shutil.rmtree(PREVIOUS)
        ORIGINAL.rename(PREVIOUS)
        print(f"   previous tables kept at {PREVIOUS}")
    ORIGINAL.mkdir(parents=True)
    subprocess.run([str(repak), "unpack", "-s", DATA_MOUNT_PREFIX, "-o", str(ORIGINAL), str(GAME_DATA_PAK)], check=True)
    print(f"   extracted {sum(1 for _ in ORIGINAL.rglob('*.json'))} tables from {GAME_DATA_PAK}")


def check_tables_current() -> None:
    """Our paks replace whole tables, so tables extracted before a game update silently undo that
    update (2026-09-04: Sulfur lost its icon because its texture was renamed). Refuse to build."""
    probe = ORIGINAL / "Items" / "D_ItemsStatic.json"
    if not GAME_DATA_PAK.exists() or not probe.exists():
        return
    if GAME_DATA_PAK.stat().st_mtime > probe.stat().st_mtime:
        sys.exit(
            "!! the game's data.pak is newer than data/original: Icarus updated since the tables were extracted.\n"
            "   Re-extract first:  python tools/build.py --extract   (then build as usual)"
        )

RECIPE_TABLE = "Crafting/D_ProcessorRecipes.json"
RECIPE_ROWS = ("Massgate_", "Fieldkit_")  # prefixes: every recipe the two mods add

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


def row_json(row: dict) -> str:
    return json.dumps(row, sort_keys=True, ensure_ascii=False)


def merge_installed_table(key: str, table: dict, mod_table: dict, previous: dict | None, pak_dir: Path,
                          quiet: bool) -> None:
    """Row-level overlay of an installed mod's full-table copy onto the fresh game table.

    Installed mods ship whole tables built against the game version of their day. Copying the
    table wholesale would drag their stale copies of rows the game has since changed into our
    pak (2026-09-04: Sulfur and Gold Ore lost their icons that way). So: rows the mod adds are
    taken; rows that differ from the fresh game row are taken only if they also differ from the
    PREVIOUS game version (data/previous, snapshotted by --extract) -- a row equal to the old
    game row is just the mod's untouched copy of it. Without a baseline every differing row is
    taken and listed, so the ambiguity is at least visible."""
    rows = table["Rows"]
    index = {r["Name"]: i for i, r in enumerate(rows)}
    prev_rows = {r["Name"]: r for r in (previous or {}).get("Rows", [])} if previous else None
    added, applied, skipped, unsure, conflicts = 0, [], 0, [], []
    for mod_row in mod_table.get("Rows", []):
        name = mod_row["Name"]
        if name not in index:
            rows.append(mod_row)
            index[name] = len(rows) - 1
            added += 1
            continue
        fresh = rows[index[name]]
        if row_json(fresh) == row_json(mod_row):
            continue
        prev = prev_rows.get(name) if prev_rows is not None else None
        if prev is None:
            unsure.append(name)  # no baseline: take the mod's row whole
            rows[index[name]] = mod_row
            applied.append(name)
            continue
        # Three-way merge per field: start from the fresh game row, apply only the fields the mod
        # actually changed relative to the previous game version. (Deyvid's AIO changes Weight and
        # MaxStack on nearly every item; a whole-row comparison would drag its stale Icon along.)
        # A field the mod's row simply lacks is not a change: modding tools drop fields (Different
        # Pouch's Kiwi bait row has no Icon), and deleting a field is never what a mod means.
        merged = dict(fresh)
        for field in mod_row:
            if row_json(mod_row[field]) != row_json(prev.get(field)):
                if row_json(fresh.get(field)) != row_json(prev.get(field)):
                    conflicts.append(f"{name}.{field}")  # game and mod both changed it; mod wins
                merged[field] = mod_row[field]
        if row_json(merged) == row_json(fresh):
            skipped += 1  # only stale copies of rows the game has since changed
        else:
            rows[index[name]] = merged
            applied.append(name)
    if not quiet:
        print(f"   overlay {key:45s} <- {pak_dir.name}: +{added} rows, {len(applied)} changed"
              + (f", {skipped} stale game rows ignored" if skipped else "")
              + (f", {len(conflicts)} field(s) changed by both game and mod (mod wins): {conflicts[:4]}" if conflicts else "")
              + (f", no baseline for {len(unsure)}: {unsure[:6]}{'...' if len(unsure) > 6 else ''}" if unsure else ""))


def load_base_tables(merge_installed: bool, quiet: bool = False, only: set[str] | None = None) -> dict[str, tuple[Path, dict]]:
    """Return {rel_path: (rel_path, table_json)} for every original table (fresh copies each call).
    Installed-mod overlays are applied only to the tables in `only` (the ones our pak will ship);
    the rest never leave this process, so merging them would only add noise."""
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
            # the LAST "data" folder: the mod's own folder may sit under data/installed
            idx = len(parts) - 1 - parts[::-1].index("data")
            rel = Path(*path.relative_to(pak_dir).parts[idx + 1 :])
            key = str(rel).replace("\\", "/")
            if key not in tables or (only is not None and key not in only):
                continue
            prev_path = PREVIOUS / rel
            previous = read_json(prev_path) if prev_path.exists() else None
            merge_installed_table(key, tables[key][1], read_json(path), previous, pak_dir, quiet)
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
        if key == RECIPE_TABLE and row["Name"].startswith(RECIPE_ROWS):
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


def build_fieldkit_pak(repak: Path, version: str, tables: dict[str, tuple[Path, dict]], touched: list[str]) -> Path:
    """Fieldkit's own pak, written from the SAME fully patched table set as the Massgate pak. Both
    paks replace whole tables and load alphabetically, so a table both mods add rows to must hold
    both mods' rows in both paks; sharing one table set guarantees that."""
    write_tables(FIELDKIT_PAK_ROOT, tables, touched)
    return pack(repak, version, FIELDKIT_PAK_ROOT, "Fieldkit")


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
    Fieldkit watches these in addition to their common base class BP_Mount_Base_C."""
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
    Fieldkit scales its heal by the unlocked rank's share of the top rank."""
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


ITEMS_TABLE = "Items/D_ItemsStatic.json"
ITEMABLE_TABLE = "Traits/D_Itemable.json"
LOCTEXT_RE = re.compile(r'^(?:NSLOCTEXT\("[^"]*",\s*"[^"]*",\s*|INVTEXT\()"((?:[^"\\]|\\.)*)"\)$')


def display_text(value: object) -> str:
    """The user-visible string of an FText export ('NSLOCTEXT("ns", "key", "Fiber")' or 'INVTEXT("x")')."""
    text = str(value or "")
    match = LOCTEXT_RE.match(text)
    return match.group(1).encode().decode("unicode_escape") if match else text


def item_names(tables: dict[str, tuple[Path, dict]]) -> dict[str, str]:
    """Item row name -> display name (D_ItemsStatic.Itemable -> D_Itemable.DisplayName), so Fieldkit
    can show 'Wood' instead of 'Wood' row names or 'Item_Fiber' without struct-passing library calls."""
    _, itemable = tables[ITEMABLE_TABLE]
    names = {row["Name"]: display_text(row.get("DisplayName")) for row in itemable.get("Rows", [])}
    _, items = tables[ITEMS_TABLE]
    found: dict[str, str] = {}
    for row in items.get("Rows", []):
        name = names.get(str(row.get("Itemable", {}).get("RowName", "")))
        if name:
            found[row["Name"]] = name
    if len(found) < 100:
        sys.exit("!! fewer than 100 item display names found in D_ItemsStatic/D_Itemable; the table format changed?")
    return found


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def write_fieldkit_config(scripts_dir: Path, version: str, classes: list[str], talents: dict[str, list[int]],
                          items: dict[str, str], dev: bool = False) -> None:
    lua_classes = "".join(f'        "{c}",\n' for c in classes)
    lua_talents = "".join(
        f'        ["{name}"] = {{ {", ".join(str(v) for v in ranks)} }},\n' for name, ranks in sorted(talents.items())
    )
    lua_items = "".join(f"        [{lua_string(row)}] = {lua_string(name)},\n" for row, name in sorted(items.items()))
    (scripts_dir / "config.lua").write_text(
        "-- Written by tools/build.py. Edit the repo copy, not this file.\n"
        "-- Tunables are documented in the repo's config.lua; keys deep-merge into main.lua's CONFIG.\n"
        "return {\n"
        f"    Version = \"{version}\",\n"
        "    Tames = {\n"
        "        -- every mount, pet and farm animal class from D_AISetup\n"
        "        MountClasses = {\n"
        f"{''.join('    ' + line + chr(10) for line in lua_classes.splitlines())}"
        "        },\n"
        "    },\n"
        "    FeatureConfig = {\n"
        "        tameregen = {\n"
        "            -- Nurtured Recovery rows from D_Talents: per-rank regen bonus, used to scale the heal\n"
        "            RegenTalents = {\n"
        f"{''.join('        ' + line + chr(10) for line in lua_talents.splitlines())}"
        "            },\n"
        "        },\n"
        "        stow = {\n"
        "            -- item row -> display name, from D_ItemsStatic/D_Itemable (chest titles, messages)\n"
        "            ItemNames = {\n"
        f"{''.join('        ' + line + chr(10) for line in lua_items.splitlines())}"
        "            },\n"
        "        },\n"
        "        scour = {\n"
        f"            DevMode = {'true' if dev else 'false'},  -- --dev build: pulses need no power and no cartridges\n"
        "        },\n"
        "    },\n"
        "}\n",
        encoding="utf-8",
    )
    # Pins and other per-prospect files live outside the mod folder (install replaces that folder).
    data_dir = scripts_dir.parent.parent.parent / "FieldkitData" / "stow"
    if scripts_dir.parent.parent == UE4SS_MODS:
        data_dir.mkdir(parents=True, exist_ok=True)


SAVES = Path.home() / "AppData" / "Local" / "Icarus" / "Saved" / "PlayerData"
SAVE_BACKUPS_KEPT = 10


def backup_saves() -> None:
    """Copy every prospect save folder (all Steam ids) to build/save-backup-<timestamp>/ before an
    install touches the game, and keep only the newest SAVE_BACKUPS_KEPT backups. Table paks can
    change what a save means (2026-09-06: an un-merged install broke the pouch mod's inventories),
    so every install starts with a copy to fall back on."""
    import datetime
    if not SAVES.exists():
        print(f"   saves    -> not found at {SAVES}; nothing backed up")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    target = BUILD / f"save-backup-{stamp}"
    files = 0
    for player_dir in SAVES.iterdir():
        prospects = player_dir / "Prospects"
        if prospects.is_dir():
            dest = target / player_dir.name
            shutil.copytree(prospects, dest)
            files += sum(1 for _ in dest.iterdir())
    print(f"   saves    -> {target}  ({files} files)")
    backups = sorted(p for p in BUILD.glob("save-backup-*") if p.is_dir())
    for old in backups[:-SAVE_BACKUPS_KEPT]:
        shutil.rmtree(old)


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

Also in this zip, optional and independent: Fieldkit, a kit of quality-of-life features. Copy the
folder "Fieldkit" next to "Massgate" in ue4ss\\Mods\\ and {fk_pak} into Paks\\mods\\ (remove any
older Fieldkit or TameRegen files first). Every feature is switched on or off in game: Escape ->
Custom World Settings (host only). Features: Tame Regeneration (tames set to Follow heal a share of
their maximum health every second while out of combat, scaled by their Nurtured Recovery talent;
Creatures section, with a rate row). Only the host / server needs the Lua; everyone needs the pak.

Source, docs and issues: https://github.com/Septuran/Massgate
"""


def package(pak: Path, fk_pak: Path, dev: bool, channels: list[str], version: str, classes: list[str],
            talents: dict[str, list[int]], items: dict[str, str]) -> Path:
    """Build the distributable zip: both paks, both Lua mod folders and a README."""
    release_dir = BUILD / "release"
    staging = release_dir / f"Massgate_v{version}"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copy2(pak, staging / pak.name)
    shutil.copy2(fk_pak, staging / fk_pak.name)
    shutil.copytree(LUA_MOD, staging / LUA_MOD.name)
    write_config(staging / LUA_MOD.name / "Scripts", dev, channels, version)
    shutil.copytree(FIELDKIT_MOD, staging / FIELDKIT_MOD.name)
    write_fieldkit_config(staging / FIELDKIT_MOD.name / "Scripts", version, classes, talents, items)
    (staging / "README.txt").write_text(
        RELEASE_README.format(version=version, pak=pak.name, fk_pak=fk_pak.name), encoding="utf-8")
    archive = shutil.make_archive(str(release_dir / f"Massgate_v{version}"), "zip", root_dir=staging)
    return Path(archive)


def install(pak: Path | None, fk_pak: Path | None, dev: bool, channels: list[str], version: str,
            classes: list[str], talents: dict[str, list[int]], items: dict[str, str]) -> None:
    """Copy the paks (unless None: --lua-only) and both Lua mods into the game."""
    if not GAME_MODS.exists():
        sys.exit(f"!! game mods folder not found: {GAME_MODS}")
    if not UE4SS_MODS.exists():
        sys.exit(f"!! UE4SS Mods folder not found: {UE4SS_MODS}")
    backup_saves()
    stale: list[str] = []
    for prefix, new in (("Massgate", pak), ("Fieldkit", fk_pak)):
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

    for legacy in LEGACY_MODS:
        old_lua = UE4SS_MODS / legacy
        if old_lua.exists():
            shutil.rmtree(old_lua)
            print(f"   removed old lua mod {old_lua}")
        for old in GAME_MODS.glob(f"{legacy}*_P.pak"):
            try:
                old.unlink()
                print(f"   removed old pak {old}")
            except PermissionError:
                stale.append(legacy)
                print(f"!! old {legacy} pak NOT removed: Icarus is running and holds it open")

    target = install_lua_mod(LUA_MOD, lambda scripts: write_config(scripts, dev, channels, version))
    print(f"   lua mod  -> {target}  (Version = {version}, DevMode = {'true' if dev else 'false'}, channels = {channels})")
    target = install_lua_mod(FIELDKIT_MOD, lambda scripts: write_fieldkit_config(scripts, version, classes, talents, items, dev))
    print(f"   lua mod  -> {target}  (Version = {version}, {len(classes)} mount classes, {len(talents)} regen talents, "
          f"{len(items)} item names)")
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
    ap.add_argument("--extract", action="store_true",
                    help="re-extract data/original from the game's data.pak first (after a game update)")
    ap.add_argument("--repak", type=Path, default=REPO / "tools" / "bin" / "repak.exe")
    args = ap.parse_args()

    if args.extract:
        if not args.repak.exists():
            sys.exit(f"!! repak not found at {args.repak}")
        print("0. extracting game tables")
        extract_game_tables(args.repak)
    if not ORIGINAL.exists():
        sys.exit("!! data/original missing: run  python tools/build.py --extract")
    check_tables_current()
    if args.lua_only:
        if not args.install or args.package:
            sys.exit("!! --lua-only only makes sense together with --install (and not --package)")
        tables = load_base_tables(False)
        patches = read_json(PATCHES)
        apply_patches(tables, expand_channels(patches))  # so both mods' own items get display names too
        apply_patches(tables, read_json(FIELDKIT_PATCHES))
        version = build_version(args.dev)
        print(f"installing Lua mods only, version {version}")
        install(None, None, args.dev, patches.get("channels", []), version, mount_classes(tables), regen_talents(tables),
                item_names(tables))
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

    patches = read_json(PATCHES)
    fk_patches = read_json(FIELDKIT_PATCHES)
    print("1. loading base tables")
    tables = load_base_tables(args.merge_installed,
                              only={p["table"] for p in patches["tables"]} | {p["table"] for p in fk_patches["tables"]})
    print("2. applying patches (Massgate, then Fieldkit, into one table set)")
    introduced = apply_patches(tables, expand_channels(patches))
    fk_introduced = apply_patches(tables, fk_patches)
    touched = sorted({key for key, _ in introduced})
    fk_touched = sorted({key for key, _ in fk_introduced})
    if args.dev:
        print("3. DEV MODE")
        apply_dev_mode(tables, introduced + fk_introduced)
    print("4. validating references")
    validate(tables, introduced + fk_introduced)
    print("5. writing tables")
    write_tables(PAK_ROOT, tables, touched)
    version = build_version(args.dev)
    print(f"6. packing version {version}")
    out = pack(args.repak, version)
    print(f"   -> {out} ({out.stat().st_size:,} bytes){'  [DEV BUILD]' if args.dev else ''}")
    print("6b. Fieldkit pak (Custom World Settings rows, Fieldkit items)")
    fk_pak = build_fieldkit_pak(args.repak, version, tables, fk_touched)
    print(f"   -> {fk_pak} ({fk_pak.stat().st_size:,} bytes)")
    classes, talents, items = mount_classes(tables), regen_talents(tables), item_names(tables)
    if args.install:
        print("7. installing")
        install(out, fk_pak, args.dev, patches.get("channels", []), version, classes, talents, items)
    if args.package:
        print("8. packaging")
        archive = package(out, fk_pak, args.dev, patches.get("channels", []), version, classes, talents, items)
        print(f"   -> {archive} ({archive.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
