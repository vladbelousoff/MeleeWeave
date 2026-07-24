# MeleeWeave

MeleeWeave is a lightweight range indicator for Hunters who melee weave. It
shows the estimated distance to your current hostile target and makes the
transition between ranged and melee distance easy to see.

The WoW API does not expose an exact target distance. MeleeWeave combines item
range checks and interaction distances to show the tightest range bracket
available on the current game client.

## Range indicator

| Colour | Range | Meaning |
| --- | --- | --- |
| Red | Over 35 yards | Out of ranged range |
| Blue | 10–35 yards | Comfortable ranged distance |
| Yellow | 5–10 yards | Closing in on melee distance |
| Green | 0–5 yards | Melee range—weave |

The white marker in the middle of the bar represents the 5-yard transition to
melee range. The available range checks differ between WoW versions, so some
clients display wider distance brackets than others.

## Supported versions

- Retail
- Mists of Pandaria Classic
- Cataclysm Classic
- Wrath of the Lich King Classic
- Burning Crusade Anniversary
- Classic Era

Each release provides a separate ZIP for every supported version.

## Installation

1. Download the ZIP matching your WoW version from the
   [latest release](https://github.com/vladbelousoff/MeleeWeave/releases/latest).
2. Extract it into the `Interface/AddOns` directory for that WoW installation.
3. Check that the resulting path is `Interface/AddOns/MeleeWeave/MeleeWeave.toc`.
4. Restart WoW or type `/reload` if the addon was already installed.

## Commands

Both `/mw` and `/meleeweave` open the command list.

| Command | Description |
| --- | --- |
| `/mw show` | Show the range bar |
| `/mw hide` | Hide the range bar |
| `/mw toggle` | Toggle the range bar |
| `/mw unlock` | Unlock the bar, then drag it with the left mouse button |
| `/mw lock` | Lock the bar in place |
| `/mw reset` | Reset the bar position |

Position, visibility, and lock state are saved between sessions.

## Limitations

WoW only answers whether a unit is within particular ranges; it does not return
an exact distance. The displayed value is therefore a bracket rather than an
exact yard measurement. No available check can measure below 5 yards, so the
green state is the important signal once the target is in melee range.

## Building releases

Pushing a tag beginning with `v` packages every supported WoW flavor in GitHub
Actions and attaches the resulting ZIP files to a GitHub release:

```bash
git tag -a v1.1 -m "MeleeWeave v1.1"
git push origin v1.1
```
