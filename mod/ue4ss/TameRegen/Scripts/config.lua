-- TameRegen runtime switches. tools/build.py --install rewrites this file in the game
-- folder (Version and the MountClasses list come from the game's D_AISetup table); the
-- repo copy is the shipped default. Any key here overrides the CONFIG table in main.lua:
--   PercentPerSecond   % of max health healed per second (default 0.5)
--   CombatGraceSeconds seconds without damage or a target before healing resumes (default 10)
--   RequireFollow      false heals tames in every movement mode (default true)
--   HealWhileRidden    false pauses healing while someone rides the mount (default true)
--   Debug              log registrations and heal start/stop to UE4SS.log (default true)
return {
    Version = "dev",
}
