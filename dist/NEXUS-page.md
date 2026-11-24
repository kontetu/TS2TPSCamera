# Nexus Mods page text (paste into the mod page; not part of the zip)

Suggested mod name: **Third-Person Camera**  (game: Tormented Souls 2)
Suggested category: Gameplay / Camera
Version: 0.9.2

## Short summary (one or two sentences)

Turns the fixed-camera game into a third-person game: the camera follows the character from behind and you can
look around 360 degrees with the mouse or right stick. Movies, puzzles and QTEs keep the original camera.

## Description

**Third-Person Camera** replaces Tormented Souls 2's fixed camera angles with a camera behind the character.

**Features**
- 360-degree look with the mouse or the right stick; left stick / WASD move relative to the camera.
- Aiming swings the camera to the enemy the game locked on to, then you can look around freely.
- Movies, scripted events, puzzles and QTEs keep the original camera and hand back seamlessly.
- Stays in third person while examining eye-mark objects, climbing ladders, pushing carts and while grabbed.
- Right stick click puts the camera behind the character; optional auto-turn behind you while moving.
- F1 settings screen: camera position, sensitivity, inversion, dead zone. Settings are saved.
- Japanese / English settings screen (follows the game language).

**It changes no game or save file.** Delete the mod folder (or switch "TPS camera" off in the F1 screen) and
the game is back to normal.

**Beta notes**
- The levels were built for fixed cameras: expect some odd views (missing geometry behind the character,
  low ceilings, narrow corridors).
- Not every scene has been tested.

## Requirements

- Tormented Souls 2 (Steam, Windows).
- Gamepad: an Xbox-style controller (XInput) is assumed; button names (A / B / X, LB / RB, stick clicks) are Xbox names. Other controllers are untested (they may work if the game sees them as an Xbox controller, e.g. through Steam Input).
- UE4SS, official **experimental-latest** build `UE4SS_v3.0.1-1217-g4fb9b615.zip` (not the `zDEV-` one). Not included.
  Get it from <https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest>. Tested with a clean install
  of exactly that zip. The older v3.0.0 / v3.0.1 tag releases are untested.

## Installation

1. Install UE4SS: put `dwmapi.dll` and the `ue4ss` folder next to `TormentedSouls2-Win64-Shipping.exe`
   (`...\Tormented Souls 2\TormentedSouls2\Binaries\Win64`).
2. Copy this mod's `ue4ss` folder into the same `Win64` folder (merge).
3. Start the game, load a save, press F1 for the settings.

## Controls

Gamepad controls are written for an **Xbox-style controller (XInput)**; the button names are Xbox names.

| Action | Gamepad (Xbox controller) | Keyboard / mouse |
| --- | --- | --- |
| Look | Right stick | Mouse |
| Move | Left stick | WASD (walk) |
| Run | Push the left stick fully | Shift + WASD |
| Weapon select | D-pad | 1-4, mouse wheel |
| Camera behind the character | Right stick click | - |
| Flashlight | Left stick click | F |
| Settings | - | F1 (mouse works on the screen too) |

## Uninstall

Delete `Win64\ue4ss\Mods\TS2TPSCamera` (and `dwmapi.dll` + `ue4ss` if you want UE4SS gone too).

## Credits

- UE4SS (MIT) - https://github.com/UE4SS-RE/RE-UE4SS
- Unofficial fan-made mod, not affiliated with the developer or publisher of Tormented Souls 2.
- Developed with the help of AI (Claude).

## Permissions / Author notes (suggested)

- Open source (MIT). Source and issue tracker: <https://github.com/kontetu/TS2TPSCamera>.
- Please attach the `[TS2TPS]` lines from `Win64\ue4ss\UE4SS.log` when reporting a problem.
