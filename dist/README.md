# Tormented Souls 2 - Third-Person Camera (TS2TPSCamera) v0.9.2

Turns the fixed-camera game **Tormented Souls 2** into a third-person game: the camera follows the
character from behind and you can look all the way around with the mouse or the right stick.

It is a UE4SS Lua mod. It does **not** change any game file or save file - it only adds files next to the
game executable. Delete them (see "Uninstall") and the game is exactly as it was.

*Unofficial fan-made mod. Not affiliated with or endorsed by the developer or publisher of Tormented Souls 2.*

## What it does

- Camera behind the character, 360-degree look with mouse / right stick.
- Aiming a weapon swings the camera to the enemy the game locked on to (and again when you switch targets);
  afterwards you can look around freely. Aiming and shooting themselves are unchanged.
- Movies, scripted events, puzzles, QTEs and similar scenes keep the original camera; the TPS camera comes back
  the moment they end.
- Stays in third person while examining eye-mark objects, climbing ladders, pushing carts and while grabbed.
- Item / inventory / menu screens work as before (rotating items with the right stick etc.).
- Press **F1** for a settings screen: camera position, look sensitivity, inversion, dead zone, auto-turn.
  Settings are saved.
- The settings screen is shown in Japanese or English, following the game's language (other languages: English).

## Requirements

- Tormented Souls 2 (Steam, Windows). Last tested with the build whose
  `TormentedSouls2-Win64-Shipping.exe` has the SHA-256
  `FB761DABD9E61A446CB2DDEAF44BA0432A8EE1A5A1F0A818EB204F3F6F2EE488` (game update of November 2026). A game update may break the mod.
- **Gamepad: an Xbox-style controller (XInput) is assumed.** Button names in these docs (A / B / X, LB / RB, right/left stick click) are Xbox names. Other controllers are untested; they may work if the game sees them as an Xbox controller (for example through Steam Input).
- **UE4SS** - the official **experimental-latest** build: `UE4SS_v3.0.1-1217-g4fb9b615.zip` (not the `zDEV-` one)
  from <https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest>.
  It needs the Lua delayed-action API (`LoopInGameThreadWithDelay`) and the layout where only `dwmapi.dll`
  sits next to the game executable and everything else is in a `ue4ss` folder.
  A clean install with exactly that official zip was tested (SHA-256 of its files:
  `dwmapi.dll` `6460773222A8C19BFBF6FA23342F41DFD0CCA5A6E5A89F06218F1EF1AE6A9BDF`,
  `ue4ss\UE4SS.dll` `AAB30033E336DF1FEAE7EE5F175A7DBDBDC0630C9C3D70F3086D212F25009F8B`).
  The plain v3.0.0 / v3.0.1 tag releases (early 2024) and other builds are untested.

## Install

1. Close the game.
2. Install UE4SS: copy `dwmapi.dll` and the `ue4ss` folder from the UE4SS package into  
   `...\steamapps\common\Tormented Souls 2\TormentedSouls2\Binaries\Win64\`  
   (the folder that contains `TormentedSouls2-Win64-Shipping.exe`). Skip this if UE4SS is already installed.
3. Extract this zip somewhere, then copy its **`ue4ss`** folder into that same `Win64` folder and merge /
   overwrite when asked. You end up with  
   `Win64\ue4ss\Mods\TS2TPSCamera\Scripts\main.lua` and `Win64\ue4ss\Mods\TS2TPSCamera\enabled.txt`.
4. Start the game. Load a save. The camera should now be behind the character.
   Press **F1** during normal play to open the settings.

If the game does not start or the camera does not change, see "Troubleshooting".

## Controls

| Action | Gamepad | Keyboard / mouse |
| --- | --- | --- |
| Look | Right stick | Mouse |
| Move (camera relative) | Left stick | W A S D (walk) |
| Run | Push the left stick fully | Shift + W A S D (as in the original) |
| Weapon select | D-pad | Number keys 1-4 (as in the original), mouse wheel (next / previous) |
| Put the camera behind the character | Right stick click | - |
| Flashlight on/off | Left stick click | F (as in the original) |
| Settings screen | - | F1 |

- While the TPS camera is on, the D-pad no longer does tank-style movement; it only selects weapons.
- The right stick turns the camera, so the original "right stick = weapon shortcut" is moved to the D-pad.
- The mouse wheel goes through the four weapon shortcut slots in the order of the number keys 1-4 and skips
  empty slots.
- While the original fixed camera is active (TPS switched off, movies, puzzles ...) all controls are the
  game's own.

## Settings screen (F1)

- **Camera**: TPS camera on/off, open the camera position screen, turn the camera behind you while moving
  (on/off, speed).
- **Look (gamepad)**: right-stick sensitivity (left/right, up/down), dead zone, invert left/right, invert up/down.
- **Look (mouse)**: mouse sensitivity (left/right, up/down), invert left/right, invert up/down.
- **Camera position screen**: distance, height, side offset and field of view, adjusted live while you see
  the character. Mouse wheel: nearer / farther. Hold X / R to reset all four. B, ESC or a right click goes back.
- Gamepad: D-pad up/down = item, left/right = value, RB/LB = x10, X = reset each item, A = confirm, B = close.
  Keyboard: arrows = item / value, PgUp/PgDn = x10, R = reset each item, Enter = confirm, ESC or F1 = close.
  Mouse: point at an item to select it, click the left / right side of a value to lower / raise it (ON/OFF
  toggles on a click), wheel = change the value, right click or the x in the corner = close.
- The controls are shown on the screen as button icons.
- The game is paused while a settings screen is open. Values are saved to
  `ue4ss\Mods\TS2TPSCamera\settings_values.lua`.

## Uninstall

- Disable only this mod: delete or rename `Win64\ue4ss\Mods\TS2TPSCamera\enabled.txt`.
- Switch back to the fixed camera without leaving the game: F1, then turn "TPS camera" off.
- Remove everything: delete `Win64\ue4ss\Mods\TS2TPSCamera`. To remove UE4SS too, delete `Win64\dwmapi.dll` and
  the `Win64\ue4ss` folder.

## Known limitations

- The levels were built for fixed cameras. Expect some odd views: missing geometry behind the character, low
  ceilings, narrow corridors. Wall collision for the camera is on by default.
- Not every scene has been tested (full playthrough, every boss and QTE).
- English text on the settings screen was tested less than the Japanese text.
- A game update can break the mod until it is updated.

## Troubleshooting

- Look at `Win64\ue4ss\UE4SS.log` and search for `[TS2TPS]`. The line
  `[TS2TPS] loaded v0.9.2 ...` means the mod started.
- No `[TS2TPS]` lines: UE4SS is not loading the mod. Check that `dwmapi.dll` and `ue4ss\UE4SS.dll` are where
  step 2 says, and that `TS2TPSCamera\enabled.txt` exists.
- `[TS2TPS]` lines about a missing function / `LoopInGameThreadWithDelay`: your UE4SS build is too old.
- Please attach the `[TS2TPS]` lines of the log when reporting a problem.

## Credits and license

- Uses [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT license). UE4SS is not included in this package.
- This mod is released under the MIT license (see `LICENSE.txt`).
