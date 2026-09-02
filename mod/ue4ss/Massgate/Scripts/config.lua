-- Massgate runtime switches. tools/build.py --install rewrites this file in the game
-- folder; the repo copy is the shipped default.
--
-- DevMode  = true  : gates need no power, cost no Exotics, have no cooldown, and only
--                    need 10 m of separation. For testing on an early-game character.
--                    Pair it with a `--dev` pak build so the recipes are free too.
-- DevMode  = false : the real rules (see docs/design.md).
-- Meshes           : optional table { Anchor = path, Resonator = path } overriding the
--                    meshes the two kinds wear; false keeps the spotlight tripod for that
--                    kind. Omit to use the defaults.
return {
    DevMode = false,
}
