# Massgate design

Paired exotic-matter gates that let a mid-to-late-game prospector move between two fixed
points on a prospect. The point is comfort, not omnipotence: a gate pair is expensive,
needs power on both ends, costs Exotics per trip, and cannot be spammed across the map.

## Lore

Exotics are the reason anyone is on Icarus. The UDA's official line is that they are a
power source. The classified addendum is that exotic matter does not move through space
so much as space moves around it. A Massgate is two lattices of stabilised exotic matter
held in powered containment frames. Once both are powered and far enough from any other
lattice not to interfere, they tune to one another, and whatever stands inside one field is
reconstructed in the other. Re-stabilising the lattice after a transit burns Exotics, which
is why every trip has a price and why the UDA never shipped it to the colonists.

## Rules

| Rule | Value | Why |
| ---- | ----- | --- |
| Unlock | Tier 4 Fabricator tree, requires the Exotic Processor blueprint | Mid-to-late game only; you must already understand exotics |
| Crafted at | Fabricator | Forces a powered T4 base before you can build one |
| Build cost | 200 Exotics, 40 Electronics, 60 Composites, 100 Copper Wire, 30 Platinum Ingot, 4 Powerbanks | Each gate is a serious investment, and you need two |
| Power draw | 2500 units per gate while running | Comparable to a Material Processor; both ends must be on the grid |
| Channels | Three item variants: Alpha, Beta, Gamma | Up to three pairs per prospect; a gate only tunes to the other gate on its channel |
| Pairing | Exactly two gates per channel | A third gate on a channel breaks the pair until removed |
| Interference | No other gate, on any channel, within 500 m | Stops short hops and gate spam; forces long-distance use |
| Charge-up | 3 s after engaging; you must stay within 8 m of the gate | Gives the transit weight and a window to abort |
| Trip cost | 5 Exotics per transit (not yet deducted) | Ongoing cost so it never becomes free travel |
| Cooldown | 20 s per gate after use | Prevents rapid back-and-forth abuse |
| Tames | Your dismounted mounts and pets within 8 m travel with you | F dismounts, so you engage on foot; the field carries what stands in it |
| Placement | Must be outside | Fits the interference lore and keeps gates visible |

Dev mode (see README) removes power, exotics and cooldown, shrinks interference to 10 m and
makes the recipes free. It exists only for testing on an early-game character.

## How it is built

Two layers, both required:

1. **Data-table pak** (`mod/data/patches.json`, built by `tools/build.py`). Adds rows for the
   items, their traits, the deployable, power draw, a custom interaction prompt, the
   recipes and the tech-tree node. Per-channel tables are expanded once per channel with
   `{CH}` replaced. The rows reuse the game's Spotlight tripod actor as the physical
   deployable because it is powered, passive and has no side effects.
2. **UE4SS Lua mod** (`mod/ue4ss/Massgate`). Hooks the generic button-press interaction,
   checks the owning actor is our gate by its item row (which also encodes the channel),
   applies the rules above, and moves the player with the engine's teleport after a ground
   trace at the destination. At spawn it swaps the tripod mesh for the orbital-exchange
   landing pad so the gate looks like a pad you step onto. Messages reach the player through
   the game's chat box.

Row map (all prefixed `Massgate_`, `<CH>` = Alpha, Beta or Gamma):

| Table | Row | Purpose |
| ----- | --- | ------- |
| D_ItemsStatic | Massgate_Gate_<CH> | The item; links every trait below |
| D_ItemTemplate | Massgate_Gate_<CH> | Craft output template |
| D_Itemable | Item_Massgate_Gate_<CH> | Name, description, flavour text, icon, weight |
| D_Deployable | Massgate_Gate | Variants, must be outside (shared) |
| D_DeployableSetup | Massgate_Gate | Which Blueprint actor and preview mesh to spawn (shared) |
| D_Resource, D_Energy | Massgate_Gate | Electric connection and 2500 draw (shared) |
| D_Interactable | Massgate_Gate | Press = engage, hold = power toggle, alt-hold = pick up (shared) |
| D_Interactions | Massgate_Activate | "Engage Massgate" prompt on the button-trigger behaviour |
| D_ProcessorRecipes | Massgate_Gate_<CH> | Fabricator recipe per channel |
| D_Talents | Massgate_Gate | One tech-tree node at (4550, 700) unlocking all three recipes |

## Roadmap

- Deduct Exotics per trip from the player's inventory, refuse when short.
- Real-rules test with power once a T4 base is available.
- Placement-time interference check with a visible refusal.
- Proper toast notification instead of the chat box.
- Light or particle effect during charge-up.
- Strip the dev toggle before release.
