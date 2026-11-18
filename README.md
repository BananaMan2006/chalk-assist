# Chalk Assist 2.41

Chalk Assist is available in the public [BananaMan2006/chalk-assist repository](https://github.com/BananaMan2006/chalk-assist). The ready-to-run file is `chalk-it-up-1v1.lua`. This repository contains the assist's own source and tests; it does not include copied Roblox game scripts, account settings, recordings, or credentials.

Join Chalk It Up, attach your executor, and run this to load the public repository version:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/BananaMan2006/chalk-assist/main/chalk-it-up-1v1.lua"))()
```

No GitHub account or token is needed to download public files. Your executor must support HTTP requests and `loadstring`.

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

Full Auto now favors varied routes that begin through the middle, then cut left or right toward a deep end-zone finish. Catch movement uses a checked detour or paced arrival when it can preserve the contact window, so a reachable timed approach does not park early. A clear diving goal catch may take priority over a shorter upright catch on these submitted deep routes; ordinary receiving keeps its upright-first behavior. DB coverage normally stays slightly shallower than the receiver, conserving sprint, and adjusts deeper after observed deep-floater catches against that opponent. These are local movement and reach estimates, not guaranteed catches or wins.

The **Auto-leave usernames (separate with commas)** field accepts multiple exact Roblox account usernames, for example `@stupieddaniel, @AnotherPlayer, @ThirdPlayer`. Commas, semicolons, spaces, and pasted line breaks work as separators; `@` is optional and duplicates are removed without regard to capitalization. Press Enter or click outside the field to save the whole list. Invalid entries leave the last valid list unchanged. Clear the field to stop matching anyone. The initial list is `@stupieddaniel` when no saved setting exists; upgrading preserves your previous single username and ON/OFF setting. **AUTO LEAVE ON/OFF** controls this setting independently. Detection uses a verified current opponent, not someone merely present in the lobby, and ignores display-name matches. If any verified opponent matches a name in the list, the script requests a leave and rejoin of the public lobby. The server decides whether that departure counts as a forfeit or awards the other account a win; the script cannot guarantee the result. The toggle and full username list persist across joins on that laptop.

The 2.41 auto-leave feature checks passed **100/100** across match skipping, identity validation, autoplay, and mode handling. The gameplay update also passed **182/182** planner, approach, steering, sprint, and fullplay checks, for **282/282** total offline checks. You can rerun those offline checks with Lupa installed into a temporary dependency folder:

```sh
python3 -m pip install --target /tmp/chalk-test-deps lupa
python3 run-chalk-tests.py --deps /tmp/chalk-test-deps --suite match-skip --suite match-skip-identity --suite autoplay --suite mode
```

Windows PowerShell:

```powershell
py -3 -m pip install --target "$env:TEMP\chalk-test-deps" lupa
py -3 run-chalk-tests.py --deps "$env:TEMP\chalk-test-deps" --suite match-skip --suite match-skip-identity --suite autoplay --suite mode
```

These tests check local logic, not live Roblox physics, server decisions, successful interceptions, or awarded wins. The optional fullplay suite requires a separately available native RouteMath fixture; that game source is not shipped in this repository. For troubleshooting, inspect the script window's message, the executor console, or `ciu_autoload_status.txt` in the workspace when using autoexec.
