# Tormented Souls 2 - Third-Person Camera (TS2TPSCamera) v0.9.0

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

- Tormented Souls 2 (Steam, Windows). Developed against the build whose
  `TormentedSouls2-Win64-Shipping.exe` has the SHA-256
  `6C71AB55143ADD71E56C9477CDBFCB8F44E16D8D5C4DF7C8C678396A6275CB4F`. A game update may break the mod.
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
| Move (camera relative) | Left stick | W A S D |
| Weapon select | D-pad | Number keys 1-4 (as in the original) |
| Put the camera behind the character | Right stick click | - |
| Flashlight on/off | Left stick click | F (as in the original) |
| Settings screen | - | F1 |

- While the TPS camera is on, the D-pad no longer does tank-style movement; it only selects weapons.
- The right stick turns the camera, so the original "right stick = weapon shortcut" is moved to the D-pad.
- While the original fixed camera is active (TPS switched off, movies, puzzles ...) all controls are the
  game's own.

## Settings screen (F1)

- **Camera**: TPS camera on/off, open the camera position screen, turn the camera behind you while moving
  (on/off, speed).
- **Look (gamepad)**: right-stick sensitivity (left/right, up/down), dead zone, invert left/right, invert up/down.
- **Look (mouse)**: mouse sensitivity (left/right, up/down), invert left/right, invert up/down.
- **Camera position screen**: distance, height, side offset and field of view, adjusted live while you see
  the character. Hold X / R to reset.
- Gamepad: D-pad up/down = item, left/right = value, RB/LB = x10, X = reset the item, A = confirm, B = close.  
  Keyboard: arrows = item / value, PgUp/PgDn = x10, R = reset the item, Enter = confirm, ESC or F1 = close.
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
  `[TS2TPS] loaded v0.9.0 ...` means the mod started.
- No `[TS2TPS]` lines: UE4SS is not loading the mod. Check that `dwmapi.dll` and `ue4ss\UE4SS.dll` are where
  step 2 says, and that `TS2TPSCamera\enabled.txt` exists.
- `[TS2TPS]` lines about a missing function / `LoopInGameThreadWithDelay`: your UE4SS build is too old.
- Please attach the `[TS2TPS]` lines of the log when reporting a problem.

## Credits and license

- Uses [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT license). UE4SS is not included in this package.
- This mod is released under the MIT license (see `LICENSE.txt`).

---

## Development

- Source: `TS2TPSCamera/` (the mod, plain Lua for UE4SS). Pure logic (camera math, settings model) is unit tested:
  `python tests/run_tests.py` (needs the `lupa` Python package).
- Release zip: `.\Build-Release.ps1` (PowerShell) builds `release\TS2TPSCamera-v<version>.zip` from the mod and the
  documents in `dist/`. Bump `VERSION` in `TS2TPSCamera/Scripts/main.lua`, the two READMEs and `dist/CHANGELOG.md` together.
- `Install-TS2TPS.ps1` is the author's own development installer (it copies from the author's machine); users should
  follow the install steps above instead.
- Research and design notes (Japanese): `HANDOFF.md`, `research/PHASE0-NOTES-ja.md`.
- Issues and pull requests are welcome. For bug reports please include the `[TS2TPS]` lines of `UE4SS.log`.
