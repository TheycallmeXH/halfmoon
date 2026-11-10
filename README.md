# Katuria's SEISHIN ATTACK

A retro ink-and-paper horizontal shooter by Katuria, made with Godot 4.7.
Pixel aircraft, evolving stage palettes, procedural backdrops, elite encounters,
passive upgrades and a CRT presentation.

## Run

Open `project.godot` in Godot 4.7 and run the main scene.
The project uses the Compatibility renderer.

## Controls

- Move: WASD or arrow keys.
- Fire: X, Z, J or left mouse button.
- Reload: R.
- Weapon selection: mouse wheel or Q/E.
- Focus: Shift.
- Pause: Escape.
- Menu: mouse, arrows/W/S/Tab and Enter.

The title screen supports pointer parallax, a player aircraft preview,
portrait scanning and interactive signal disturbances.
START launches the aircraft, fades to black and reveals gameplay automatically.

## Project

- `scripts/`: gameplay, drawing and menu systems.
- `shaders/`: CRT, bloom and portrait effects.
- `assets/`: artwork, author logo and font resources.
- `design/`: design decisions and verification notes.
- `.scripts/`: reproducible checks and asset preparation tools.

Run the menu integration check with:

```powershell
godot --path . res://.scripts/check_front_menu.tscn
```

Windows export settings are in `export_presets.cfg`.
Build output and generated screenshots are excluded from Git.
BM SPACE includes its author's original usage terms in
`assets/fonts/bm_space/read me.txt`.
