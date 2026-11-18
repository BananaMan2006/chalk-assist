# Chalk Assist 2.44

Chalk Assist is available in the public [BananaMan2006/chalk-assist repository](https://github.com/BananaMan2006/chalk-assist). The ready-to-run file is `chalk-it-up-1v1.lua`. This repository contains the assist's own source and tests; it does not include copied Roblox game scripts, account settings, recordings, or credentials.

Join Chalk It Up, attach your executor, and run this to load the public repository version:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/BananaMan2006/chalk-assist/main/chalk-it-up-1v1.lua"))()
```

No GitHub account or token is needed to download public files. Your executor must support HTTP requests and `loadstring`. After loading, Chalk Assist automatically queues itself for the next teleport when the executor provides `queue_on_teleport`, `queueonteleport`, or `syn.queue_on_teleport`. This works without an account-specific username or local computer path. The queued startup waits for game dependencies and can use a previously successful download or installed local copy if the public download is unavailable.

A script cannot attach an executor to Roblox itself. For a fresh Roblox launch, enable your executor’s own auto-attach/autoexec feature and install the loader using the steps below. Executors without a teleport queue need autoexec on every join. Automatic loading is limited to the verified Chalk It Up place. F8 keeps it unloaded in the current server; a later join may load it again.

For a local installation, open the repository, choose **Code → Download ZIP**, and extract it. Alternatively, clone it with Git:

```sh
git clone https://github.com/BananaMan2006/chalk-assist.git
cd chalk-assist
```

Open a terminal in the downloaded folder and install with Python 3. Replace the example paths with your executor's actual workspace and autoexec folders. The installer uses only Python's standard library; it does not open Roblox or attach the executor.

macOS example:

```sh
python3 install-chalk.py --workspace "$HOME/Opiumware/workspace" --autoexec "$HOME/Opiumware/autoexec"
```

Windows PowerShell example:

```powershell
py -3 install-chalk.py --workspace "C:\path\to\executor\workspace" --autoexec "C:\path\to\executor\autoexec"
```

Omit `--autoexec` if you prefer manual loading. Add `--dry-run` to check the paths without changing anything. Keep the executor folders outside the downloaded repository. The installer replaces only the bundled assist and optional local autoexec loader; it preserves existing `ciu_*` settings and other workspace files. Running it again after downloading an update installs that update.

To load your installed local copy, run:

```lua
loadstring(readfile("chalk-it-up-1v1.lua"))()
```

The optional autoexec loader loads that local copy when you join the verified Chalk It Up place. It does not download updates or attach the executor. It runs once per joined server; unloading with F8 keeps it unloaded until a new join or a manual load.

The on-screen window can be dragged and minimized. Right Shift hides or shows it. **B** toggles the assist, **V** toggles catch assistance, and **F8** unloads it. Full Auto handles the supported 1v1 route and movement decisions; catch assistance also handles team contexts. Autoplay lets you select the supported game mode and queue again after a completed match. Movement uses the game's normal walk and sprint settings, currently 20 and 27, rather than setting an extra movement speed. For desktop alerts on macOS, extract `macos-match-alerts-source.zip` and follow [MACOS_ALERTS.md](MACOS_ALERTS.md). Its portable source and 21 passing self-tests are included. The in-game loader does not install or start that separate desktop helper. Other operating systems need their own desktop notifier.

Full Auto WR now walks the middle stem to preserve stamina, then commits to a continuous native-speed sprint through the final left/right cut and planned diving finish. The new routes aim at the closest legal sideline edge (the game clamps the route one stud inside the boundary), with varied cut timings and a deep end-zone target. Route selection checks the actual slower launch position, the full sprint duration, remaining stamina, and native dive travel before accepting a sideline plan. These submitted Full Auto routes request a real dive before contact; ordinary manual receiving retains its upright-first behavior. When a jam, low stamina, or field layout prevents this route family, the status reports a fallback instead of claiming a guaranteed sideline finish.

DB starts with a loose 3–5 yard cushion, tracks small changes less aggressively, and uses short sprint bursts. Prethrow defense usually keeps at least 70 stamina, or 60 when recovery is urgent. Ball pursuit keeps a 40-point reserve; WR final pursuit keeps 10, with a small input-delay allowance. Coverage tightens near the goal and still adjusts deeper against opponents who repeatedly win with deep floaters. All movement uses native game speed. These are local movement and reach estimates, not guaranteed catches or wins.

Full Auto also checks short-range player collisions. It measures actual position changes, keeps a stable side while moving around a blocker, and releases sprint while the path is blocked. The checked detour controls its own smooth turn and stays inside the field. It waits for the original path to remain clear for 0.12 seconds before returning, preventing brief left-right oscillation around a blocker; the held path is still checked for collisions and field bounds. Catch movement keeps priority during the final action window; tackle and carrier moves keep their existing priority. The throw handoff preserves an already-owned sprint instead of briefly toggling it off and on.

Opening DB spacing narrows gradually after the first part of the route, using walking targets without lowering the existing sprint thresholds. Once a receiver clearly advances and DB is already level or behind, DB walks forward instead of backing away to manufacture extra spacing. Defensive learning can identify an unlabeled throw only when its flight time and arc height uniquely match the game’s configured Bullet or Floater values.

The **Auto-leave usernames (separate with commas)** field accepts multiple exact Roblox account usernames, for example `@stupieddaniel, @AnotherPlayer, @ThirdPlayer`. Commas, semicolons, spaces, and pasted line breaks work as separators; `@` is optional and duplicates are removed without regard to capitalization. Press Enter or click outside the field to save the whole list. Invalid entries leave the last valid list unchanged. Clear the field to stop matching anyone. The initial list is `@stupieddaniel` when no saved setting exists; upgrading preserves your previous single username and ON/OFF setting. **AUTO LEAVE ON/OFF** controls this setting independently. Detection uses a verified current opponent, not someone merely present in the lobby, and ignores display-name matches. If any verified opponent matches a name in the list, the script requests a leave and rejoin of the public lobby. The server decides whether that departure counts as a forfeit or awards the other account a win; the script cannot guarantee the result. The toggle and full username list persist across joins on that laptop.

The 2.44 changes pass **172/172** affected offline checks: 22 collision-path tests, 15 controller integration tests, 18 steering/sprint checks, and 117 fullplay checks. Recorded defensive situations were also replayed with the new positioning. These are local checks, not guaranteed live catches. You can run the self-contained collision and movement checks with Lupa installed into a temporary dependency folder:

```sh
python3 -m pip install --target /tmp/chalk-test-deps lupa
python3 run-chalk-tests.py --deps /tmp/chalk-test-deps --suite avoidance --suite avoidance-controller --suite fullplay-steering --suite pending-sprint
```

Windows PowerShell:

```powershell
py -3 -m pip install --target "$env:TEMP\chalk-test-deps" lupa
py -3 run-chalk-tests.py --deps "$env:TEMP\chalk-test-deps" --suite avoidance --suite avoidance-controller --suite fullplay-steering --suite pending-sprint
```

These tests check local logic, not live Roblox physics, server decisions, successful interceptions, or awarded wins. The optional fullplay suite requires a separately available native RouteMath fixture; that game source is not shipped in this repository. For troubleshooting, inspect the script window's message, the executor console, or `ciu_autoload_status.txt` in the workspace when using autoexec.
