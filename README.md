# SEBLERSKERS — a viking island saga

A 3D open-world viking adventure: sail, row, fly, swim, loot and defend
the village. Built with Godot 4.7.

## Controls

**Keyboard + mouse:** WASD / arrows move · mouse look · Space jump (boards
the longship) · click / V attack · Shift sprint · C crouch & swap boat seats
· Tab / Q unroll the elder's scroll · V (hold) camera · Esc pause.

**Gamepad:** left stick move · right stick look · A jump · X attack ·
D-pad UP/DOWN toggles the elder's scroll · Y (hold) tiller eyes · Start pause.
(The D-pad no longer zooms the camera — it used to strand players in
first person.)

**In flight (F / R3):** the attack key alternates air strikes — one press
dive-bombs, the next slings a fireball mid-flight along the camera aim,
then repeat. Pressing it during a dive pulls out without spending the
throw. The body now leans deeper into cruise (and harder still on a
dive-energy swoop).

**Touch (phone/tablet browsers):** on-screen joystick lower-left (start a
drag high on the screen to also pitch the camera), drag anywhere on the
right half to look, and buttons: JUMP · ATK · RUN (tap to latch) · SEAT ·
scroll and pause pills up top.

## Playing in the browser

`build/web/index.html` is a self-contained web build (single-threaded, no
special hosting headers needed) — upload the whole `build/web` folder to
any static host. First load is large (~580 MB of game data); the page
shows a progress bar, then a Set Sail button (required by browser
autoplay rules). Phones are asked to rotate to landscape.

Rebuild it with:

```sh
godot --headless --path . --export-release "Web" build/web/index.html
```

`export_presets.cfg` holds the Web and Windows presets; the web preset
enables GDExtension support (terrain_3d ships as a side wasm module).

## Native build

```sh
godot --headless --path . --export-release "Windows Desktop" build/windows/SEBLERSKERS.exe
```

## Credits
- Grid Texture/s from [KenneyNL](https://www.kenney.nl/assets/prototype-textures)
- To create this project I watched [Jeremy Bullock's Godot First Person Controller Series](https://www.youtube.com/watch?v=Etpq-d5af6M&list=PLTZoMpB5Z4aD-rCpluXsQjkGYgUGUZNIV)
- Thanks to the awesome Godot community for being helpful to anyone with problems, for making amazing tutorials, for writing the documentation and being supportive.