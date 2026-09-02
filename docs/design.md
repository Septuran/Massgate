# Massgate design

Paired exotic-matter gates that let a mid-to-late-game prospector move between two fixed
points on a prospect. The point is comfort, not omnipotence: a gate pair is expensive,
needs power on both ends, costs Exotics per trip, and cannot be spammed across the map.

## Lore

Exotics are the reason anyone is on Icarus. The UDA's official line is that they are a
power source. The classified addendum is that exotic matter does not move through space
so much as space moves around it. A Massgate is two lattices of stabilised exotic matter
held in powered containment frames. Once both are powered and far enough apart not to
interfere, they tune to one another, and whatever stands inside one field is reconstructed
in the other. Re-stabilising the lattice after a transit burns Exotics, which is why every
trip has a price and why the UDA never shipped it to the colonists.

## Rules (MVP)

| Rule | Value | Why |
| ---- | ----- | --- |
| Unlock | Tier 4 Fabricator tree, requires the Exotic Processor blueprint | Mid-to-late game only; you must already understand exotics |
| Crafted at | Fabricator | Forces a powered T4 base before you can build one |
| Build cost | 200 Exotics, 40 Electronics, 60 Composites, 100 Copper Wire, 30 Platinum Ingot, 4 Powerbanks | Each gate is a serious investment, and you need two |
| Power draw | 2500 units per gate while running | Comparable to a Material Processor; both ends must be on the grid |
| Pairing | Exactly one pair per prospect | A third gate breaks the pair until removed |
| Interference | Gates closer than 500 m refuse to tune | Stops short hops and gate spam; forces long-distance use |
| Trip cost | 5 Exotics per transit (not yet deducted in v0.1) | Ongoing cost so it never becomes free travel |
| Cooldown | 20 s per gate after use | Prevents rapid back-and-forth abuse |
| Mounts | No travel while mounted | Keeps mounts relevant; you walk through the gate |
| Placement | Must be outside | Fits the interference lore and keeps gates visible |

## How it is built

Two layers, both required:

1. **Data-table pak** (`mod/data/patches.json`, built by `tools/build.py`). Adds rows for the
   item, its traits, the deployable, power draw, a custom interaction prompt, the recipe
   and the tech-tree node. The rows reuse the game's Spotlight tripod actor as the physical
   deployable for now; the visual is a placeholder.
2. **UE4SS Lua mod** (`mod/ue4ss/Massgate`). Hooks the generic button-press interaction,
   checks the owning actor is our gate by its item row, applies the rules above and moves
   the player with the engine's teleport.

Row map (all prefixed `Massgate_`):

| Table | Row | Purpose |
| ----- | --- | ------- |
| D_ItemsStatic | Massgate_Gate | The item; links every trait below |
| D_ItemTemplate | Massgate_Gate | Craft output template |
| D_Itemable | Item_Massgate_Gate | Name, description, flavour text, icon, weight |
| D_Deployable | Massgate_Gate | Variants, must be outside |
| D_DeployableSetup | Massgate_Gate | Which Blueprint actor and preview mesh to spawn |
| D_Resource, D_Energy | Massgate_Gate | Electric connection and 2500 draw |
| D_Interactable | Massgate_Gate | Press = engage, hold = power toggle, alt-hold = pick up |
| D_Interactions | Massgate_Activate | "Engage Massgate" prompt on the button-trigger behaviour |
| D_ProcessorRecipes | Massgate_Gate | Fabricator recipe |
| D_Talents | Massgate_Gate | Tech-tree node at (4550, 700) in the T4 tree |

## Roadmap after the MVP

- Deduct Exotics per trip from the player's inventory, refuse when short.
- On-screen notifications instead of log lines.
- Placement-time interference check with a visible refusal.
- Swap the placeholder mesh for a fitting one (the Exotic Delivery Interface pad or similar)
  by setting the static mesh at spawn.
- Channels so more than one pair can exist per prospect.
- Charge-up delay with the light effects as a visual cue.
