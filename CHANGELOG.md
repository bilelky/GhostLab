# Changelog

## 1.0.6
- Ghost per car: at start, the ghost of the car you drive. The ghost you pick for a car on a track (or the new best lap it saves) is remembered for that car and that track; without one, your best lap with this car here, else the fastest ghost of this car here, else no ghost. No more ghost of another car left over from a previous session. "Remove ghost" is remembered too.

## 1.0.5
- Fix: some valid laps were not saved. A finished lap is now checked half a second after the line, once AC has updated the lap time and the "last lap valid" flag; the pit and validity flags are ignored during the first half second of a lap (they could still be those of the lap before, so a clean lap right after a cut or an out lap was thrown away).
- Lap log (Ghost tab, and cfg\apps\GhostLab\laps.log): every lap with what happened to it (saved, slower than your best, invalid, pit lane, save failed).

## 1.0.4
- Ghost in replays: while you drive, the ghost's position and the delta are written into the replay. In the replay (photo mode included, any camera) the ghost is exactly where it was, and the delta window shows the delta of that moment.
- Exchange: up to 50 shared ghosts per 24 h (was 15); the message says when the next one is possible.

## 1.0.3
- Exchange search: title, description, car, track and name, on every track. Several words: all must match ("bmw monza"). Clear button.
- Exchange: the track of a ghost is shown whenever it is not the loaded track.

## 1.0.2
- In-app update: the release zip is read in memory and written file by file (the way CSP's AppShelf installs apps), no temporary extraction. Fixes "Install failed: GhostLab not found in the zip".

## 1.0.1
- Exchange: the Comments button opens and closes the comments window (its X closes it too).
- Exchange: a shared ghost is credited to the person who shares it, never to the original driver of a replay lap.
- Exchange: description hint (track temperature, weather, setup, tips) above the description box.
- Replay: found laps listed fastest first, with a sort button (slowest first, lap order).
- Ghost tab: with "Show ghost" off, the ghost settings are hidden.

## 1.0 (first public release)
- Ghost of any car from a replay: "Find laps" lists every lap of the focused car (fastest first, sortable), "Export as ghost" records the one you pick without playing it in real time. Live recording also available.
- Your best lap saved as a ghost for each car and track, and time attack mode: a faster valid lap becomes the ghost as you cross the line.
- Live delta in its own window.
- Ghost look: full car or see-through ghost, with a progressive fade as you get close and as it pulls away.
- Ghost glued to the ground, aligned automatically on another version of the same circuit.
- Car not installed: your car's 3D model stands in for it (trajectory, timing and delta stay the ghost's).
- GhostLab Exchange: share and download ghosts online, with titles, likes, comments, reports, filters (track, other versions of the track, car, cars you have, your ghosts), search and sorting. No account: identity through Custom Shaders Patch's signature. A shared ghost is credited to the person who shares it, never to the original driver of a replay lap.
- Update message in the app when a new version is released, with one-click install and reload in game.
- Light on performance: the see-through ghost of a car in the session loads nothing (CSP's simple car shape); the full car model loads in the background during the start menu (lower detail model by default); the last ghost loads over a few frames.
