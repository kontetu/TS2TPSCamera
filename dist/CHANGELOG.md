# Changelog

## 0.9.2 - 2026-11-24

- Keyboard: W/A/S/D now walk; Shift + W/A/S/D runs, following the game's own run button as in the fixed camera.
- Mouse wheel switches to the next / previous weapon of the four shortcut slots (order of the number keys 1-4,
  empty slots skipped).
- F1 settings screen works with the mouse: point to select, click the left / right side of a value, wheel,
  right click or the x to close. On the camera position screen the wheel moves the camera nearer / farther and a
  right click goes back.
- The control help on both screens is drawn as button icons ("icon: description") for the gamepad, keyboard and
  mouse; the panels widen to fit it.
- Fixed: closing the settings screen with ESC also opened the game's pause menu.
- Fixed: with a gamepad, A sometimes had to be pressed twice, or clicked the row under the hidden mouse cursor.
- Camera position defaults (also what "reset all" restores): distance 120, height 52, side 24, FOV 72.

## 0.9.1 - 2026-11-20

- Fixed: near the dimension mirror and after crossing it (in both worlds) the camera kept falling back to the
  fixed camera and the F1 settings screen would not open. The game leaves a puzzle flag set there although no
  puzzle is running; it is now ignored unless a puzzle is really in progress.
- Fixed: the darkness effect (the screen flickers while you stand in the dark without a light) now shows in the
  TPS view too.
- Tested with the game update of November 2026.

## 0.9.0 - 2026-11-07 (first public beta)

- Third-person camera behind the character; 360-degree look with mouse / right stick.
- Camera turns to the locked-on enemy when aiming and when the target changes, then is free again.
- Movies, events, puzzles, QTEs keep the original camera; seamless return to the TPS camera.
- TPS kept during eye-mark examination, ladders, cart pushing and while grabbed.
- Item / inventory / menu screens unchanged (item rotation works).
- Right stick click puts the camera behind the character; optional auto-turn behind the character while moving.
- Flashlight moved to left stick click on the gamepad (the right stick belongs to the camera).
- Camera is set up again after loading a save.
- F1 settings screen (camera, gamepad look, mouse look) with a camera position screen; settings are saved.
- Japanese / English text following the game language.
