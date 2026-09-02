# HorizonScout

HorizonScout is an Ashita v4 addon for finding nearby monsters, NPCs, and
interactable objects in Final Fantasy XI.

It provides:

- Exact-name alerts with separate custom sounds for monsters, NPCs, and objects.
- A small nearby-results panel with compact mode, an icon-only settings button,
  `Add current target`, `Target`, and `Remove` controls.
- Your current area, Vana'diel time, and map-grid position, such as `H-9`.
- A compass radar with blue player dots, red monster dots, and green NPC/object
  dots.
- Gold rings around tracked radar dots and a white diamond around your selected
  target. The dot itself keeps its normal category colour.
- A thin 20-yalm reference circle, category filters, optional north-up mode, and
  optional dot hover details showing the entity name, category, distance, and
  relative-height hint.
- `[Above]` / `[Below]` hints beside nearby matches with a height difference of
  at least 4 yalms by default. The threshold is adjustable. These indicate
  relative height, not a floor number or a route.
- Optional warnings when a nearby monster is marked aggressive by MobDB.
- Gold star markers for monsters identified as Notorious by MobDB, with an
  optional edge-triggered chat notification.
- Named tracking presets with optional automatic per-area activation.

HorizonScout only observes nearby rendered entities. It does not move your
character, interact with targets, send gameplay commands, or search an entire
zone.

> HorizonScout is a custom addon. Check the current HorizonXI addon rules before
> using it on the live server.

## Preview

Real in-game screenshots showing the nearby tracker, radar, and settings. These
show example configurations from an earlier interface revision, so some labels
and the newer Presets tab differ from v0.16.1.

<table>
  <tr>
    <th>Nearby tracker</th>
    <th>Radar</th>
  </tr>
  <tr>
    <td valign="top"><img src="docs/images/horizonscout-tracker.png" alt="HorizonScout tracking NPC Abelard, with map position, distance, Target and Remove buttons" width="594"></td>
    <td valign="top"><img src="docs/images/horizonscout-radar.png" alt="Player-facing radar with blue player dots, red monster dots, and green NPC or object dots" width="215"></td>
  </tr>
</table>

Blue dots are players, red dots are monsters, and green dots are NPCs or objects.
`Target` selects a detected entity without interacting with it.

<details>
<summary>View earlier settings examples</summary>

### Settings

Shared scanning, display, radar, volume, and tracking-range controls.

![HorizonScout Settings tab with display scale, radar size and alert volume controls](docs/images/horizonscout-settings.png)

### Monsters

Tracked-monster sound, aggressive warning range and cooldown, chocobo suppression,
and level filtering. The database status here shows `Ready: MobDB`.

![HorizonScout Monsters tab with aggressive warning settings and a ready MobDB database](docs/images/horizonscout-monsters.png)

### NPC's

Exact-name NPC tracking and its separate sound control.

![HorizonScout NPC tab with Abelard configured for tracking](docs/images/horizonscout-npcs.png)

### Objects

Exact-name object tracking and its separate sound control.

![HorizonScout Objects tab with Stone Monument configured for tracking](docs/images/horizonscout-objects.png)

</details>

## Requirements

- Final Fantasy XI running through Ashita v4.
- MobDB or XIUI's included MobDB data for aggressive-monster warnings and
  Notorious Monster identification.

Normal name tracking, the compass, map position, and radar do not require MobDB.

## Installation

1. Download `HorizonScout-v0.16.1.zip` from the
   [GitHub Releases page](https://github.com/ryuutatsuo23-max/HorizonScout/releases/latest).
2. Extract the ZIP. It contains one folder named `HorizonScout`.
3. Copy that folder to your Ashita addons directory. A typical HorizonXI path is:

   ```text
   C:\Games\HorizonXI\Game\addons\HorizonScout
   ```

4. In game, load the addon:

   ```text
   /addon load HorizonScout
   ```

5. Open the settings window:

   ```text
   /horizonscout
   ```

After updating an existing installation, use:

```text
/addon reload HorizonScout
```

## Everyday use

The settings window has five tabs:

### Settings

- Enable or pause scanning.
- Show, resize, or hide the small results panel.
- Collapse the results panel into a compact one-line information header.
- Lock the small results panel after placing it.
- Show your map-grid position.
- Show or hide above/below hints and adjust their yalm threshold.
- Show, move, lock, resize, or hide the radar, and optionally keep north upward.
- Enable or disable tracked-dot rings and the selected-target diamond.
- Show or hide players and enable optional radar hover details.
- Adjust the shared alert volume from 0% to 150%.
- Adjust the normal tracked-name and radar range.

### Monsters

- Show all monsters, only MobDB-classified aggressive monsters, or no monsters
  on the radar.
- Show or hide MobDB-backed Notorious Monster stars and optionally print one
  chat notification when a newly seen NM enters the radar.
- Add exact monster names to track.
- Add the currently selected monster without typing its name.
- Enable or test `mobalert.wav`.
- Enable or test aggressive-monster warnings.
- Adjust the aggressive warning range and sound cooldown.
- Suppress aggressive warnings while riding a chocobo.
- Ignore aggressive monsters far below your current main-job level.

### NPC's

- Show or hide NPCs on the radar.
- Add exact NPC names to track.
- Add the currently selected NPC without typing its name.
- Enable or test `npcalert.wav`.

### Objects

- Show or hide interactable objects on the radar.
- Add exact names for doors, monuments, `???` targets, and other interactable
  objects.
- Add the currently selected object without typing its name.
- Enable or test `interactablealert.wav`.

### Presets

- The existing monster, NPC, and object lists migrate into `Default`.
- Create an empty preset or copy the currently active preset.
- Choose the fallback preset used in areas without an assignment.
- Assign a preset to the current area so HorizonScout activates it
  automatically whenever you enter that area.
- Remove an area assignment to return that area to the fallback preset.
- `Default` cannot be deleted, which preserves a safe compatible list.

Names match exactly, but capitalization does not matter. For example, `Sand Bat`
will also match `sand bat`.

When a tracked result is nearby, the small panel offers:

- Gear: opens or closes the settings window using Ashita's bundled
  `ICON_FA_GEAR` glyph. It uses a transparent icon-only button, so no image file
  is required.
- Compact control: collapses the panel to a one-line area/time/position header;
  expand it again to use match and target controls.
- `Add current target`: adds the selected monster automatically. NPC-class
  targets without a reliable object flag ask whether to add them as an NPC or
  Object, because Horizon can expose world objects as ordinary NPC entities.
- `Target`: selects the entity without interacting with it.
- `Remove`: stops watching that exact name.

## Default settings

| Setting | Default |
| --- | ---: |
| Tracked-name and radar range | 50 yalms |
| Aggressive warning range | 18 yalms |
| Aggressive sound cooldown | 10 seconds |
| Ignore aggressive monsters below your level | 15 levels |
| Chocobo suppression | On |
| Overlay position lock | Off |
| Compact overlay mode | Off |
| Above/below threshold | 4 yalms |
| Player, monster, NPC and object radar categories | On |
| Aggressive-only monster radar filter | Off |
| Notorious Monster star markers | On |
| Notorious Monster chat notification | Off |
| Radar hover details | Off |
| Keep radar north-up | Off |
| Active/fallback tracking preset | Default |
| Automatic area assignments | None |
| Alert volume | 100% |
| Small results-panel scale | 100% |
| Radar size | 112 px |

The aggressive cooldown prevents a second aggressive monster, or rapid movement
in and out of range, from restarting the WAV. Set it to `0` to disable the
cooldown. Detection and the nearby count continue normally during the cooldown.

## Useful commands

`/hs` is the short alias for `/horizonscout`. The older `/mobalert` name is also
accepted. HorizonScout deliberately does not use `/ma`, because `/ma` is FFXI's
magic command.

```text
/horizonscout                         Open or close settings
/horizonscout add <monster name>      Add a monster name
/horizonscout remove <monster name>   Remove a monster name
/horizonscout addnpc <NPC name>       Add an NPC name
/horizonscout removenpc <NPC name>    Remove an NPC name
/horizonscout addobject <name>        Add an object name
/horizonscout removeobject <name>     Remove an object name
/horizonscout on|off                  Resume or pause scanning
/horizonscout show|hide               Show or hide the results panel
/horizonscout compass on|off          Show or hide the compass
/horizonscout range <1-50>            Set tracked-name/radar range
/horizonscout aggrorange <1-50>       Set aggressive warning range
/horizonscout aggrocooldown <0-60>    Set aggressive sound cooldown
/horizonscout sound on|off|test       Monster alert sound
/horizonscout npcsound on|off|test    NPC alert sound
/horizonscout objectsound on|off|test Object alert sound
/horizonscout aggrosound on|off|test  Aggressive warning sound
/horizonscout help                    Show all commands in settings
```

## Custom sound files

HorizonScout includes these sounds:

- `mobalert.wav` for tracked monsters.
- `npcalert.wav` for tracked NPCs.
- `interactablealert.wav` for tracked objects.
- `aggressivealert.wav` for aggressive-monster warnings.

You can replace a sound by keeping the same filename. For best compatibility
with the volume control, use an uncompressed PCM WAV: mono, 16-bit, 48 kHz.

## Aggressive-monster warning

This feature reads local MobDB data. HorizonScout prefers the exact spawn-index
record, then falls back to the monster name when no spawn record exists.

By default, a monster is ignored when its maximum MobDB level is at least 15
levels below your current synchronized main-job level. Monsters with missing or
zero level data still warn so that uncertain data does not silently hide a
possible threat.

The warning is a nearby safety reminder, not a guarantee that a monster will
aggro. MobDB cannot account for walls, facing direction, Sneak, Invisible,
time/weather rules, or special conditions such as low-HP blood aggro.

Notorious Monster stars use the same local database and are therefore
best-effort. HorizonScout only marks entries whose MobDB record explicitly has
the `Notorious` field; missing or unknown records are never guessed. The
optional NM notification is a chat message rather than a sound, because no
separate NM recording is bundled.

## Troubleshooting

### The settings window does not open

Use `/horizonscout` or `/hs`. Then try reloading the addon:

```text
/addon reload HorizonScout
```

### A normal name alert does not appear

- Confirm the name was added to the correct tab.
- Confirm the spelling matches the in-game name exactly.
- The entity must be rendered and within the configured range.

### Aggressive warnings do not work

- Open the Monsters tab and check the database status.
- It should show `Ready: MobDB` or `Ready: XIUI MobDB`.
- Confirm the warning sound is enabled.
- Check the chocobo, level-gap, range, and cooldown settings.

### A sound does not play

- Check that alert volume is above 0%.
- Use the category's `Test` button.
- Confirm the matching WAV file is present in the HorizonScout folder.

## License

HorizonScout is released under the [MIT License](LICENSE).
