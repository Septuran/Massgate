-- Massgate runtime switches. tools/build.py --install rewrites this file in the game
-- folder; the repo copy is the shipped default.
--
-- DevMode = true  : gates need no power, cost no Exotics, have no cooldown, and only
--                   need 10 m of separation. For testing on an early-game character.
--                   Pair it with a `--dev` pak build so the recipe is free too.
-- DevMode = false : the real rules (see docs/design.md).
return {
    DevMode = false,
}
