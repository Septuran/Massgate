-- TameRegen runtime switches. tools/build.py --install rewrites this file in the game
-- folder (Version and the MountClasses list come from the game's D_AISetup table); the
-- repo copy is the shipped default. Any key here overrides the CONFIG table in main.lua:
--   PercentPerSecond   % of max health healed per second when a prospect has no rate setting
--                      yet (default 0.25). In game the rate comes from Escape -> Custom World
--                      Settings -> Creatures (percent per minute; 15 = 0.25 %/s).
--   ProspectSettings   false ignores the Custom World Settings rows and uses this file only (default true)
--   CombatGraceSeconds seconds without damage or a target before healing resumes (default 10)
--   RequireFollow      false heals tames in every movement mode (default true)
--   HealWhileRidden    false pauses healing while someone rides the mount (default true)
--   TalentScaling      "reward" = rank's Nurtured Recovery bonus / top rank's bonus (8/25/50/100 %),
--                      "rank" = rank / 4 (default "reward"); rank 4 is always the full rate
--   NoTalentFraction   share of the rate for a tame without the talent (default 0 = game regen only)
--   Debug              log registrations and heal start/stop to UE4SS.log (default true)
return {
    Version = "dev",
}
