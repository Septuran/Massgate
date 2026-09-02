# Massgate design

Exotic-matter gates that let a mid-to-late-game prospector move between a base and fixed
points out in the field. The point is comfort, not omnipotence: a gate pair is expensive,
needs power on both ends, costs Exotics to push outward, and cannot be spammed across the map.

## Lore

Exotics are the reason anyone is on Icarus. The UDA's official line is that they are a
power source. The classified addendum is that exotic matter does not move through space
so much as space moves around it.

A stabilised exotic lattice carries a colour charge, in the sense of quantum chromodynamics:
red, green or blue. There are exactly three, and there is no fourth. That is not a limit of the
machine but of the universe, the same confinement that binds quarks. Two lattices of the same
colour tune to one another across any distance; lattices of different colours ignore each other.
So a prospect can carry at most three channels, one per colour, and a Massgate is always a pair.

A Massgate pair has two unequal ends. The **Anchor Lattice** holds the bulk of the stabilised
exotic matter and does the actual work: it bends space toward itself. Anchors can stand side by
side because a triplet of red, green and blue is colour-neutral, the most stable arrangement
exotic matter can take, which is why every base ends up with three pads in a row. The
**Resonator** holds only a sliver of exotics, just enough to carry one colour and phase-lock to
the anchor of that colour, which is why it is light and cheap. It has no neutral partners to lean
on: its tiny lattice is unshielded, so any other lattice nearby, anchor or resonator, pulls it
off frequency and it refuses to tune.

Coming home is cheap because the anchor's mass does the pulling. Going out is expensive
because the anchor has to push you against its own gradient, and the lattice has to be
re-stabilised with fresh Exotics afterwards, which is why an anchor is loaded like a furnace.
That asymmetry is why the UDA never shipped it to the colonists: it is a leash, not a road.

## Rules

| Rule | Value | Why |
| ---- | ----- | --- |
| Unlock | Tier 4 Fabricator tree, requires the Exotic Processor blueprint | Mid-to-late game only; you must already understand exotics |
| Crafted at | Fabricator | Forces a powered T4 base before you can build one |
| Anchor cost | 200 Exotics, 40 Electronics, 60 Composites, 100 Copper Wire, 30 Platinum Ingot, 4 Powerbanks | The base end is the serious investment |
| Resonator cost | 60 Exotics, 15 Electronics, 20 Composites, 40 Copper Wire, 10 Platinum Ingot, 1 Powerbank | Cheap enough to plant several outposts |
| Anchor power | 2500 units while running | Comparable to a Material Processor; needs the base grid |
| Resonator power | 500 units while running | A wind turbine or a couple of solar panels at the outpost |
| Channels | Exactly three colour charges: Red, Green, Blue | QCD allows no fourth colour; picked on the placed gate from the alt-press wheel, stored per gate across saves |
| Pairing | Exactly one Anchor and one Resonator per channel | Two of the same kind on a channel never tune |
| Anchor placement | Anchors ignore each other for interference | A base can hold one pad per channel in a row |
| Resonator placement | No other gate of any kind within 500 m, its own anchor included | Stops short hops and gate spam; forces outposts far apart and far from base |
| Charge-up | 3 s after engaging; you must stay within 8 m of the gate | Gives the transit weight and a window to abort |
| Outbound trip | 5 Exotics drawn from the anchor's own buffer | Pushing out is the expensive choice; the lattice is loaded like a furnace |
| Exotics buffer | Hold interact opens the panel: four Exotics-only slots plus one module slot | The game's storage panel doubles as the lattice's fuel and upgrade bay |
| Phase Coupler | Module slotted in an Anchor; its Resonator then counts as powered by the anchor | Outposts need no generator; outbound trips cost 3 extra Exotics because the anchor pushes power too |
| Wheel | Alt-press opens the game's radial menu: Tune Red / Green / Blue, Power On/Off, Pick Up | One pick instead of cycling a button |
| Inbound trip | Free, resonator to anchor | The anchor pulls you home |
| Cooldown | 20 s per gate after use | Prevents rapid back-and-forth abuse |
| Tames | Your mounts and pets set to Follow within 8 m travel with you | F dismounts, so you engage on foot; only followers travel, so a farm stays put |
| Placement | Must be outside | Fits the interference lore and keeps gates visible |

Dev mode (see README) treats anchors as powered, drops the cooldown, shrinks interference to
10 m, makes the recipes free and adds a fiber-to-Exotics recipe. Resonators still need power or a
coupler, and trips still cost Exotics, so the buffer and the coupler are testable early.

## How it is built

Two layers, both required:

1. **Data-table pak** (`mod/data/patches.json`, built by `tools/build.py`). Adds rows for the
   items, their traits, the deployables, power draw, a custom interaction prompt, the
   recipes and the tech-tree node. Per-channel tables are expanded once per channel with
   `{CH}` replaced. The rows reuse the game's small metal crate actor as the physical
   deployable because it brings the standard storage panel, and power comes from the Resource trait.
2. **UE4SS Lua mod** (`mod/ue4ss/Massgate`). Hooks the generic button-press interaction,
   reads the kind from the owning actor's item row and the channel from its per-gate store
   (`channels.txt` next to the mod, keyed by the item's database GUID), applies the rules above, and
   moves the player with the engine's teleport after a ground trace at the destination. At
   spawn it swaps the tripod mesh per kind: the orbital-exchange landing pad for anchors, the
   survey laser uplink for resonators. Power is read from the game's resource component, the
   Exotics buffer from the gate's inventory. Messages reach the player through the game's chat box.

Row map (`<CH>` = channel, `<K>` = Anchor or Resonator):

| Table | Row | Purpose |
| ----- | --- | ------- |
| D_ItemsStatic | Massgate_<K> | The item; links every trait below |
| D_ItemTemplate | Massgate_<K> | Craft output template |
| D_Itemable | Item_Massgate_<K> | Name, description, flavour text, icon, weight |
| D_Deployable | Massgate_<K> | Variants, must be outside |
| D_DeployableSetup | Massgate_<K> | Which Blueprint actor and preview mesh to spawn |
| D_Resource, D_Energy | Massgate_<K> | Electric connection and draw (2500 / 500) |
| D_Interactable | Massgate_Gate | Press = engage, hold = open the panel, alt-press = wheel, alt-hold = pick up (shared) |
| D_Inventory, D_InventoryInfo | Massgate_Buffer | Slots 0-3 Exotics-only (Any_Meta), slot 4 module-only (reuses the T4 communicator-upgrade tag query) |
| D_RadialMenuData, D_RadialOptions | Massgate, Massgate_<CH> | The wheel and its colour options |
| D_ItemsStatic etc. | Massgate_Coupler | The Phase Coupler module item and its Fabricator recipe |
| D_Interactions | Massgate_Activate, Massgate_Radial | "Engage Massgate" (press, button-trigger behaviour) and "Lattice controls" (alt-press, radial behaviour) |
| D_ProcessorRecipes | Massgate_<K> | Two Fabricator recipes |
| D_Talents | Massgate_Gate | One tech-tree node at (4550, 700) unlocking every recipe |
| D_MapIcons | Massgate_<K>_<CH> | Map and compass icon per kind and channel; the Lua attaches the game's map-icon component and repoints it on tune |
| D_ItemsStatic etc. | Massgate_Gate, Massgate_<K>_<CH> | Legacy items from earlier builds kept so placed gates load; no recipes |

## Multiplayer

The engage interaction is server-only in the game's own data, so the Lua's gameplay path
runs where the game has authority: solo, the host of a hosted game, or a dedicated server that
runs UE4SS (Windows only). The handler checks authority and does nothing on a pure client.
Looks and map icons are local and run on every machine with the Lua installed.

- Every player needs the pak, or the gate items do not exist for them.
- Every player should have the Lua for the looks and icons; only the authority needs it for
  gameplay.
- Messages go to the local chat box for the local player and through the controller's client
  RPC for remote players.
- A gate charging for one player refuses a second player until the transit resolves.
- Tame ownership is checked against the engaging player's state, so only their followers travel.

Not yet tested with a second player.

## Roadmap

- More modules: wider field, faster charge, stabiliser for cheaper trips.
- Real-rules test with power once a T4 base is available.
- Placement-time interference check with a visible refusal.
- Proper toast notification instead of the chat box.
- Light or particle effect during charge-up.
- Strip the dev toggle before release.
