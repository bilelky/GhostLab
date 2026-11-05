# GhostLab

A ghost car for Assetto Corsa (Custom Shaders Patch Lua app).

Record a ghost of **any car** from a replay, or let GhostLab keep your own best lap, then drive against it with a live delta. In time attack mode the ghost is always your best lap: beat it and your lap becomes the new ghost the moment you cross the line.

Visual only: no collision, nothing is applied to your car.

## Features

- **Ghost from any replay**: pick any car of a replay (yours or someone else's), click "Find laps", export the lap you want. No need to watch the lap play.
- **Full car or see-through ghost**: the see-through ghost lets you see the track through the car, with adjustable opacity.
- **Progressive fade**: the ghost fades out as you get close and fades back in as it pulls away, so it never pops in or out.
- **Your best lap as a ghost**, saved automatically for each car and track.
- **Time attack mode**: as soon as you beat the ghost on a valid lap, your lap replaces it at the line, with no manual step.
- **Live delta** against the ghost, in its own small window.
- **Ghost list sorted by track and lap time**, with filters for the current track and the current car.
- **Other versions of a circuit**: a ghost recorded on one version (e.g. Spa OSRW) is aligned automatically on another version (e.g. Spa Kunos).
- **Glued to the ground** of the loaded track, gone when it overlaps your car (cockpit view).
- **GhostLab Exchange**: share your ghosts online and download other drivers' ghosts, with titles, likes, comments, filters by track and car, and search.
- **Shareable**: a ghost is a single `.csv` file.

## Requirements

- Assetto Corsa with Custom Shaders Patch **0.2.3 (build 2578) or newer**.
- The ghost's car should be installed (`content/cars`) to see its own 3D model. If it is not, your car's model stands in for it.
- To record from a replay, the replay must open in your game (its track and cars installed).

## Installation

1. Download the latest release zip.
2. Copy the `apps` folder into your Assetto Corsa root folder (`...\steamapps\common\assettocorsa\`), merging with the existing one.
3. In game, open the CSP app bar and add:
   - **GhostLab**: main window (ghost list, settings, replay recording);
   - **GhostLab Delta**: live delta, place it wherever you like.

Updating: when a new version is out, GhostLab shows a message at the top of its window when you open it (one small background request the first time the window opens, nothing at game start). **Install update** downloads it, replaces the app files (your ghosts and settings are kept) and reloads GhostLab in game: no need to restart Assetto Corsa. **Release page** opens the download page, **Skip this version** hides the message for that version. You can also replace the files by hand.

## Usage

### Record a ghost from a replay

1. Put the `.acreplay` file in `Documents\Assetto Corsa\replay\`.
2. Open it (Content Manager > Replays, or the in-game replay).
3. Focus the car you want (camera on that car).
4. GhostLab > **Replay** tab > **Find laps**. GhostLab moves through the replay on its own (about 5 s for a 5-minute replay) and lists every complete lap of that car with its time.
5. Click **Export as ghost** next to the lap you want. GhostLab records that lap by moving through the replay (about a third of the lap time, e.g. ~30 s for a 1:30 lap at 60 fps), saves it, and puts the replay back where it was.

Do not touch the replay controls while it scans (a progress percentage is shown, with a Cancel button).

**Live recording** (previous method, still available under "Live recording"): click **Start recording**, play the replay at x1 from before the finish line, and every complete lap appears with a **Save as ghost** button. Do not rewind during a lap.

### Drive with a ghost

1. Start a session on the same circuit.
2. GhostLab > **Ghost** tab: click a ghost in the list.
3. The ghost starts when you cross the line and drives at its own pace. The delta compares your time with the ghost's at the same point of the lap (green: you are ahead).
4. As you get close it fades out progressively (from 12 m by default) and is gone under 4 m, so it does not get in the way in the cockpit. It fades back in as it pulls away. Both distances are adjustable.
5. If a model sits slightly too high or too low, use the **Height** slider (±50 cm).

### Time attack mode

On by default (**Time attack** checkbox in the Ghost tab).

1. Pick a starting ghost (for example the fastest lap of a replay), or none.
2. Drive. When a valid lap is faster than the ghost, your lap becomes the ghost as you cross the line and starts again with you on the next lap. A message shows the gain.
3. A slower lap, an invalid lap (cut, off track) or a pit stop does not change the ghost.
4. The lap is saved to the list 2 s after the line and stays selected, so your next session starts against your best lap.
5. With no ghost selected, your first valid lap becomes the ghost, then each faster lap.

Performance: the see-through ghost of a car that is in the session (yours, typically) is drawn from Custom Shaders Patch's own simple shape of that car: nothing to load. The full car look needs the car's textured 3D model: it is loaded once, in the background, while you are still in the start menu (lower detail model by default); this can take a moment the first time. The delta works right away in every case. Ghost settings shows the slowest steps and the longest frame, to spot anything that could freeze the game.

### Ghost list

- **Current track only** (on by default): only the ghosts recorded on the loaded track and layout.
- **Current car only**: only the ghosts of the car you are driving.
- With **Current track only** off, ghosts are grouped by track (current track first, open), each group sorted by lap time.
- **Delete ghost file** deletes the selected ghost (click twice to confirm).
- **Open ghosts folder** opens `Documents\Assetto Corsa\cfg\apps\GhostLab\ghosts\`.

### GhostLab Exchange

Open the **Exchange** tab.

1. The first time, choose your Exchange name (shown on your ghosts and comments). No account or password: GhostLab is identified by Custom Shaders Patch's own signature, like CSP's Setup Exchange.
2. **Browse**: by default you see the ghosts shared on the loaded track, fastest first. Filters: this track, other versions of this track, all tracks; my car only; cars I have; my ghosts. Search by title, driver or car. Sort by fastest, newest, most liked, most downloaded or trending.
3. **Download**: the ghost is saved in your ghosts folder and selected right away when it was recorded on the loaded track (another version of the track is aligned automatically). Then the button becomes **Drive against it**.
4. **Like, dislike, comment** on any ghost; **Report** a fake or broken one (a ghost reported several times is hidden until a moderator checks it).
5. **Share**: select a ghost in the Ghost tab and click **Share on the Exchange** (or pick one in "Share a ghost"), give it a title and an optional description (setup, conditions, tips), click **Share on the Exchange**. **Remove** takes it back at any time.

What happens when cars differ:

- **Car not installed**: the ghost is drawn with your own car's 3D model as a stand-in (its trajectory, timing and delta are its own). A **Get the car** button opens the car's page when its author gave one. Turn off "Car not installed: show my car instead" in Ghost settings to get the delta only.
- **Two mods of the same real car** (two "Mercedes GT3" from different modders): they have different folder names, so they are different cars on the Exchange. Their times are not comparable.
- **Same car, other version** (same folder, modified physics): shown as "Other version of this car than yours", times not directly comparable.
- **Same car, other skin**: no problem. Skins are never shared. By default the ghost shows the car's built-in look; with "Use the ghost's skin" on, it uses the ghost's skin if you have it, else yours.

Shared files are checked by the server (coherent time, speed and distance, lap length close to the track's). This filters out broken or edited files, but a lap time on the Exchange is not proof of a clean lap.

Privacy: the server stores an anonymous ID derived from your PC, your Exchange name, your ghosts and comments, and a salted hash of your IP address for abuse limits. Details on the server's `/privacy` page.

### Another version of the same circuit

A ghost recorded on another version of the circuit (e.g. made on Spa OSRW, driven on Spa Kunos) is aligned automatically when you select it. GhostLab compares the centerlines of both tracks (AI spline), finds the start line offset, rotation, translation and scale, corrects the height, and restarts the ghost's lap timer at your finish line.

The result is shown as a mean error: under 3 m is good; above 15 m a warning says the tracks are probably too different. Both tracks need an AI spline (almost all have one).

### Sharing ghosts

Send the `.csv` file from the ghosts folder. The other driver only needs GhostLab and the car installed, not the replay.

## Settings

"Show ghost" and "Ghost look" are always shown in the Ghost tab. The other look settings are in the **Ghost settings** section below them (folded by default, click to open).

| Setting | Default | Effect |
|---|---|---|
| Show ghost | on | Shows or hides the ghost car (the delta keeps working). |
| Ghost look | Full car | **Full car**: the car with its own paint. **See-through ghost**: a light blue glass-like ghost, the track stays visible through it. |
| Opacity | 30 % | See-through ghost only (5 to 70 %). |
| Ghost shadow | on | Shadow of the ghost car (full car look only). |
| Light ghost model | on | Full car look: the car's lower detail model (LOD B) when it has one, much quicker to load and hard to tell apart a few metres away. Off: full detail model. |
| Use the ghost's skin | off | Off: the car's built-in look, nothing to load. On: the skin recorded with the ghost (or yours); loading its textures can freeze the game for a moment when a ghost loads. |
| Fade over | 8 m | Length of the fade zone above "Fully hidden within": the ghost fades out across it as you get closer (0: no fade). |
| Fully hidden within | 4 m | The ghost is gone when it is closer than this to your car. |
| Height | 0 cm | Vertical offset of the ghost model. |
| Save my best lap as a ghost | on | Saves your best valid lap for each car and track. |
| Time attack | on | The ghost is always the best lap (see above). |
| Current track only | on | Ghost list filter. |
| Current car only | off | Ghost list filter. |

## Ghost file format

Plain text, one file per ghost: `<track[-layout]>__<car>__<driver>__<m-ss-mmm>.csv`

- Header lines `# key=value`: `car`, `carName`, `driver`, `track`, `layout`, `lapMs`, `source` (`replay` or `live`), `skin` (1.6+), `date`; ghosts downloaded from the Exchange also have `exchangeID` and `sharedBy`.
- Lines `S,x,y,z`: centerline of the track it was recorded on (used for alignment).
- Samples: `t,pos,x,y,z,lx,ly,lz,ux,uy,uz,spd,gas,brk,gear,hg` (time, lap position, position, look and up vectors, speed, pedals, gear, height above ground).

## Limitations

- Wheels and suspension are frozen on the model (no wheel rotation, steering or travel).
- Full car look inside the fade zone: AC's car shader cannot be made transparent, so the fading car is GhostLab's own rendering of the model (livery colour and lighting, no reflections or decals), and it is not shown in the mirrors while it fades.
- The see-through ghost and the fade need CSP's render.mesh drawing; on a CSP version without it, the full car is shown and hidden halfway through the fade zone.
- Online: the ghost is visible only to you, and only on servers that allow Lua apps.
- A ghost from a completely different circuit cannot be aligned meaningfully.

## Publishing an update (maintainers)

1. Raise `VERSION` in `apps/lua/GhostLab/GhostLab.lua` and in `apps/lua/GhostLab/manifest.ini` (same value).
2. Zip `apps`, `README.md`, `LICENSE` and `CHANGELOG.md` as `GhostLab-<version>.zip` (the zip must contain `apps/lua/GhostLab/`).
3. Create a GitHub release with the tag `v<version>`, a short description (shown in the app) and the zip attached.
4. The Exchange server reads the latest release of the repository set in its `GITHUB_REPO` variable (checked every 10 minutes); players see the message the next time they open GhostLab.

## Running your own Exchange server

The server is in the `server` folder: one Cloudflare Worker file with a D1 database and an R2 bucket. See `server/README.md`. The address GhostLab uses is in `apps/lua/GhostLab/ExchangeConfig.lua`.

## License

MIT, see [LICENSE](LICENSE).
