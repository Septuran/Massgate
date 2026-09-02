# Releasing Massgate

How a Nexus package is produced. One command does the work; the steps around it keep the
version number honest.

## 1. Decide the version

- `VERSION` holds the base version (for example `0.5`). Bump it for a milestone; leave it for
  small fixes. The build appends the git commit count, so every commit yields a new number
  (`0.5.14`, `0.5.15`, ...).
- `-dev` marks dev builds and `+` marks uncommitted changes. A release must have neither, and
  the tool refuses to package otherwise.

## 2. Test the exact build you will ship

Dev builds differ from releases (free recipes, powered anchors, fiber-to-Exotics). Before
packaging, install a **non-dev** build and play it:

```
python tools\build.py --merge-installed --install
```

Check: recipes cost what the design says, gates refuse without power, the buffer deducts
Exotics, the wheel and coupler work. Then reinstall the dev build if you want to keep testing.

## 3. Commit everything

```
git status          # must be clean
git add -A && git commit -m "..." && git push
```

## 4. Package

```
python tools\build.py --package
```

This builds the pak on the **original** game tables only (never merged with locally
installed mods), refuses dev mode and a dirty tree, and writes:

```
build\release\Massgate_v<version>.zip
build\release\Massgate_v<version>\           (the unzipped staging copy)
    Massgate_v<version>_P.pak                 data tables
    Massgate\                                 UE4SS Lua mod
        enabled.txt
        Scripts\main.lua
        Scripts\config.lua                    DevMode=false, Version, Channels written in
    README.txt                                install steps for the end user
```

## 5. Upload to Nexus

- Files tab: upload the zip. Name the file `Massgate <version>`; version field `<version>`.
- Description: paste `docs/nexus.bbcode.txt` (BBCode). Short description is in `docs/nexus.md`.
- Changelog: summarise from `git log --oneline <previous-tag>..HEAD`.

## 6. Tag the release

```
git tag v<version> && git push --tags
```

## Notes

- Never upload a pak built with `--merge-installed`: it would contain other authors' table
  changes.
- Every player needs both the pak and the Lua folder. The README.txt inside the zip says so.
- If UE4SS moves to a newer layout, the install paths in `README.txt` and the Nexus page
  need updating together with `tools/build.py` (`UE4SS_MODS`).
