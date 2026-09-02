"""Find rows in the extracted Icarus data tables that mention a term.

Usage:
    python tools/find_rows.py <term> [--full] [--tables D_ItemsStatic,D_ItemTemplate]

Scans every *.json under data/original, and prints table name + row Name for
each row whose JSON text contains <term>. With --full the entire row is printed.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "data" / "original"


def rows_of(table: dict):
    for key in ("Rows", "Defaults"):
        pass
    return table.get("Rows") or []


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 1
    term = args[0]
    full = "--full" in sys.argv
    only = None
    for a in sys.argv[1:]:
        if a.startswith("--tables="):
            only = set(a.split("=", 1)[1].split(","))
    hits = 0
    for path in sorted(ROOT.rglob("*.json")):
        if only and path.stem not in only:
            continue
        try:
            table = json.loads(path.read_text(encoding="utf-8-sig"))
        except Exception as exc:  # noqa: BLE001
            print(f"!! {path.relative_to(ROOT)}: {exc}")
            continue
        if not isinstance(table, dict):
            continue
        for row in rows_of(table):
            text = json.dumps(row)
            if term.lower() in text.lower():
                hits += 1
                name = row.get("Name", "?")
                print(f"{path.relative_to(ROOT)} :: {name}")
                if full:
                    print(json.dumps(row, indent=2))
                    print()
    print(f"-- {hits} rows matched '{term}'")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
