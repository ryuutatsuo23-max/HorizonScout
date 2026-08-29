# HorizonScout

HorizonScout is a small Ashita v4 addon candidate for nearby navigation and
exact-name monster/NPC alerts plus nearby interactable-object alerts. Detection
and radar are read-only. The compact nearby-match panel
offers explicit `Target` and watched-name `Remove` buttons for each current
match; it never
targets automatically, interacts, moves the player, sends commands, or alters
packets.

The compass includes cardinal labels and bounded dots for rendered players,
living monsters, NPCs, and interactable world objects. The separate
nearby-match overlay retains the
current map-grid position. HorizonScout is implemented locally and does not
depend on FancyCompass.

## Approval boundary

This is a new custom addon and is not known to be on HorizonXI's approved-addon
list. Do not install or load it on HorizonXI until server staff have confirmed
that this specific behavior is allowed.

## Default behavior

- Starts with empty monster, NPC, and interactable-object name lists.
- Scans every 0.5 seconds while enabled.
- Requires the entity to be rendered, non-hidden, correctly classified by the
  client, and within 50 yalms. Tracked monsters must also be living.
- Shows matching names, distances, guarded `Target` buttons, and watched-name
  `Remove` buttons in a draggable compact overlay. Removing a live row stops
  watching that exact monster, NPC, or object name. The settings window keeps
  showing configured names but no longer duplicates individual Remove buttons;
  `Clear names` and slash-command removal remain available for entries that are
  not currently detected. A saved `Small UI scale` setting resizes
  this panel from `50%` through `200%` without resizing the compass or settings
  window; its reset button restores `100%`.
- Shows the player's current map-grid position, such as `Position: H-9`, in
  that compact overlay by default. The settings window can hide it.
- Shows a separate draggable compass by default. `/horizonscout` can hide it, lock
  its position, resize it, or reset it to the default position. The compass
  uses the local player's heading and does not patch or hide the game's HUD.
- Uses a compact outlined player pointer so dots near the center remain visible.
  The redundant bearing/map-grid line beneath the compass is intentionally
  omitted; map position remains in the nearby-match overlay.
- Shows rendered entities within the configured range as blue player dots, red
  living-monster dots, and green NPC/object dots. Interactable objects are
  distinguished from ordinary NPCs by the client spawn flags used for NPC
  environment targets (`0x02 + 0x20`, value `34`). Pets and trusts are excluded
  when the client exposes their ownership relationship. This is a nearby
  display, not a whole-zone search.
- Some Horizon objects, including locally observed monuments, can be exposed as
  ordinary NPC-class entities without the environment bit. An exact name added
  to the Interactable object list takes precedence over NPC tracking for that
  NPC-class entity. This permits explicit object tracking without treating all
  ordinary NPCs as objects.
- Applies a saved `-90 deg` heading correction based on the supplied Selbina
  screenshot. The settings window can adjust it from `-180` through `180`
  degrees while comparing against the static north-up map.
- Plays `mobalert.wav` for a newly detected named monster, `npcalert.wav` for a
  newly detected named NPC, or `interactablealert.wav` for a newly detected
  named interactable object. All three lists use exact names without caring
  about capitalization. Each category is independently switchable and
  edge-triggered, so it does not replay every scan while the same entity
  remains nearby. Unlisted interactable objects can still appear as green
  radar dots.
- Applies one shared alert-volume slider to all three WAV files from `0%` (true mute)
  through `150%`. `100%` uses Ashita's native playback; other non-zero levels
  scale the validated 16-bit PCM samples before Windows wave playback. Boosted
  samples are clamped and may sound compressed near `150%`.
- Keeps routine chat output off by default. Detection notices, successful
  command confirmations, and the load notice remain silent unless `Print
  routine notices in chat` is explicitly enabled. Errors still appear.
- Lists current matches in the compact panel with `Target` and `Remove` buttons.
  A Target click only
  changes the selected target after revalidating the same entity index, server
  ID, kind, name, visibility, life status, and configured range. It does not
  interact with the target.
- Forgets observations during zoning, logout, pause, range/name changes, or
  addon unload.

Version 0.2 removes the old automatically seeded `Sand Bat` entry once while
retaining any other configured names.

Ashita can only report entities currently known and rendered by the client.
HorizonScout cannot search a whole zone, locate an unloaded floor or interior, or
prove that an absent entity is elsewhere. An NPC alert confirms local presence,
not its route or exact floor.

Map-grid conversion uses FFXI's internal per-zone map table, following the same
read-only approach as the locally installed FancyCompass addon. Zones without a
usable mapping show `Position: ?-?` rather than an estimated grid. Multi-map
zones still require manual comparison with the currently open map.

## Commands

```text
/horizonscout
/horizonscout help
/horizonscout add <monster name>
/horizonscout remove <monster name>
/horizonscout addnpc <NPC name>
/horizonscout removenpc <NPC name>
/horizonscout addobject <object name>
/horizonscout removeobject <object name>
/horizonscout list
/horizonscout clear
/horizonscout clearnpcs
/horizonscout clearobjects
/horizonscout on
/horizonscout off
/horizonscout show
/horizonscout hide
/horizonscout compass on
/horizonscout compass off
/horizonscout sound on
/horizonscout sound off
/horizonscout sound test
/horizonscout npcsound on
/horizonscout npcsound off
/horizonscout npcsound test
/horizonscout objectsound on
/horizonscout objectsound off
/horizonscout objectsound test
/horizonscout range <1-50>
```

Bare `/horizonscout` opens or closes the settings window, including when the
command has trailing whitespace. It provides separate monster, NPC, and
interactable-object lists, sound controls, and the shared scanning, overlay,
and range settings. Explicit Target and watched-name Remove buttons for current
matches live in the compact nearby-match overlay.
`/horizonscout help` opens a command-help section inside that window rather
than printing it into chat. Unknown subcommands do the same and show an
in-window explanation.

`/hs` is the short alias. Legacy `/mobalert` remains accepted. Version 0.9.1
removes the old `/ma` alias because `/ma` is FFXI's normal magic command and
intercepting it prevents spell macros from working. Names containing spaces can
be entered normally, for example `/horizonscout add Sand Bat`.

## Installation after approval

Copy the complete `HorizonScout` folder to:

```text
C:\Games\HorizonXI\Game\addons\HorizonScout
```

Then load it in game:

```text
/addon load HorizonScout
```

Run the `sound test`, `npcsound test`, and `objectsound test` commands before
attempting live detection tests. The source folder must contain
`HorizonScout.lua`, `mobalert.wav`, `npcalert.wav`, `interactablealert.wav`,
`map_grid.lua`, `compass.lua`, and `sound_player.lua`.

## Validation status

The implementation is based on APIs and filtering patterns present in the
locally installed HorizonXI/Ashita v4 addons. Lua parsing and focused offline
contract tests cover the source and WAV files. The user manually confirmed addon
loading and the original sound test on a local server. Alerting and target
buttons have also been manually exercised. The screenshot-backed heading
correction and radar-dot placement require manual local-server comparison
against the open north-up map. Interactable detection uses the environment bit
when present and the explicit object-name override otherwise; representative
Horizon local-server doors, chests, monuments, and `???` targets still require
manual comparison because their server-side classifications may differ.
