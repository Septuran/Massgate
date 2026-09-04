-- Fieldkit runtime switches. tools/build.py --install rewrites this file in the game folder
-- (Version, Tames.MountClasses from D_AISetup, FeatureConfig.tameregen.RegenTalents from
-- D_Talents); the repo copy is the shipped default. Keys deep-merge into the CONFIG table in
-- main.lua; FeatureConfig.<feature> merges into that feature's own CONFIG.
--
-- Core:
--   Features             list of feature ids to load (Scripts/features/<id>.lua)
--   CustomWorldSettings  false ignores the in-game rows and runs on the defaults here (default true)
--   Debug                log registrations and feature start/stop to UE4SS.log (default true)
--
-- FeatureConfig.tameregen (in game: Escape -> Custom World Settings -> Creatures wins over these):
--   PercentPerSecond     % of max health per second at Nurtured Recovery rank 4 when the prospect
--                        has no rate row applied yet (default 0.25; the in-game row is per minute, 15 = 0.25 %/s)
--   CombatGraceSeconds   seconds without damage or a target before healing resumes (default 10)
--   RequireFollow        false heals tames in every movement mode (default true)
--   HealWhileRidden      false pauses healing while someone rides the mount (default true)
--   TalentScaling        "reward" = rank's talent bonus / top rank's bonus (8/25/50/100 %),
--                        "rank" = rank / 4 (default "reward"); rank 4 is always the full rate
--   NoTalentFraction     share of the rate for a tame without the talent (default 0 = game regen only)
return {
    Version = "dev",
}
