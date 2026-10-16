# OMetaVR's LiveContainer fork

A fork of [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer) that tracks upstream `main` (the nightly line) automatically, with this fork's changes on top. The goal is an OS-style shell (home screen, app switcher, system services) built on LiveContainer's multitasking backend.

Builds: every update to `main` publishes the **nightly** release in this repo with `LiveContainer.ipa` and `LiveContainer+SideStore.ipa` (install the latter with iLoader → Import IPA).

## Customizations

Every change this fork makes to upstream behavior is listed here. **The upstream-sync fixer reads this list and must keep all of it working**, so keep it current.

| Customization | Where | Notes |
| --- | --- | --- |
| Upstream sync + local fixer | `.fork/`, `.github/workflows/sync-upstream.yml`, `FORK.md` | Fork-only files; upstream never touches them. |
| pseudOS shell (home screen, app switcher, stock apps) | `LiveContainerSwiftUI/Fork/pseudOS/` | All shell code. Guests are hosted with `AppSceneViewController` the same way upstream's native-window mode does (`MultitaskSupport/MultitaskAppWindow.swift`); keep `GuestHost.swift` in step with it. |
| Shell as the root view | `LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift` (`// FORK:`) | `WindowGroup("Main")` shows `PseudoOSRoot()`, which shows upstream's `LCTabView()` when classic UI is on. |
| Multitask launches go to the shell | `LiveContainerSwiftUI/Utilities/LCUtils.m` `+launchMultitaskGuestApp:` (`// FORK:`) | When `PseudoShellBridge.isActive`, hand bundleId/dataUUID/completion to the shell instead of creating `DecoratedAppSceneViewController`. |
| Bring running apps to front via the shell | `LiveContainerSwiftUI/Models/LCAppModel.swift` `bringExistingMultitaskWindowIfNeeded`, `LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift` `runButtonTapped` (`// FORK:`) | Upstream's fallback creates `MultitaskDockManager.shared`, which builds the floating dock; the shell must answer first. |
| Status-bar taps without the dock | `MultitaskSupport/LCStatusBarManager.m` `handleTapAction:` (`// FORK:`) | Same reason: never touch `MultitaskDockManager.shared` while the shell is active. |
| Built-in SideStore refresh from Settings | `SideStoreSupport/Fork/PseudoRefreshBridge.swift` | `@objc(PseudoRefreshBridge)` wrapper around `performIntentRefresh` (`SideStoreSupport/SideStore.swift`), looked up with `NSClassFromString`. |
| Display name "pseudOS" | `LiveContainer/Info.plist` `CFBundleDisplayName` (`<!-- FORK: -->`) | Bundle ID stays `com.kdt.livecontainer` on purpose: SideStore hooks, certificate import and URL schemes depend on it. |
| Geist font | `LiveContainerSwiftUI/Fork/pseudOS/Fonts/` | SIL OFL (licence alongside); registered at runtime, so no `UIAppFonts` edit. |
| Design mockup | `design/pseudos-beta1-mockup.html` | Reference only, not in the app. |
| App icon | `Resources/Assets.xcassets/AppIcon.appiconset/*.png` | Same file names as upstream (default, dark, tinted); regenerate rather than merge if upstream changes them. |
| pseudOS release | `.github/workflows/pseudos-release.yml`; `.github/workflows/build.yml` gains `workflow_call:` (`# FORK:`) | Reuses upstream's build, renames the IPAs to `pseudOS.ipa` / `pseudOS+SideStore.ipa`, publishes a prerelease. |

## Where fork code goes

Conflicts happen when the fork and upstream edit the same lines, so keep fork code out of upstream's files:

1. **New code goes in a `Fork/` subfolder of an existing synchronized group**, e.g. `LiveContainerSwiftUI/Fork/` or `MultitaskSupport/Fork/`. The Xcode project uses synchronized folders (`objectVersion 73`), so files there are compiled into that target automatically. **No `project.pbxproj` edit, no conflict.** Synchronized folders: `LiveContainerSwiftUI`, `MultitaskSupport`, `LiveProcess`, `TweakLoader`, `Tweaks`, `SideStoreSupport`, `Resources`, `ZSign`, `litehook`, `LaunchAppExtension`, `ShareExtension`. `LiveContainer/` itself is a classic group: new files there *do* need a `project.pbxproj` edit, so avoid it.
2. **Hook in, don't rewrite.** When upstream code has to call fork code, make the smallest possible edit (one call, one `if`), and mark it:
   ```objc
   // FORK: open the shell instead of the app list (see FORK.md: OS shell)
   ```
   `git grep -n "FORK:"` lists every edit inside upstream files.
3. **Prefer runtime extension points** (Swift extensions, categories, method swizzling of upstream's own classes, SwiftUI view wrappers) over editing upstream files.
4. Only touch `project.pbxproj` for things synchronized folders can't do (new targets, build settings), and note it in the table above.

## Upstream sync

`.github/workflows/sync-upstream.yml` runs every 4 hours (and on demand from Actions):

1. Merges upstream `main` into the fork (`.fork/sync.sh`). It builds on top of `sync/upstream` when a fixed merge is waiting there, so fixes aren't lost when upstream moves again.
2. Pushes the merge to `sync/upstream` and builds it with upstream's own `build.yml`.
3. **Only if the build passes**, fast-forwards `main`, starts the nightly release build, deletes `sync/upstream` and closes sync issues.
4. On a merge conflict or a failed build, `main` is left alone and an issue labelled `upstream-sync` + `needs-ai-fix` is opened.

### Local fixer

`.fork/fixer/` runs on the PC as a systemd user timer (every 5 minutes; catches up after sleep). For each `needs-ai-fix` issue opened by github-actions it:

1. Sends a desktop notification and labels the issue `ai-fixing`.
2. Runs Claude Code headless (Opus 5.5, medium effort, via `claude-selected`) in a private clone at `~/.local/share/lc-fork-fixer/LiveContainer`, with `.fork/fixer/prompt.md`: resolve the conflict or build error on `sync/upstream`, keeping every customization above, push, and comment on the issue.
3. Re-runs the sync workflow, which builds the fix and promotes it to `main` if it compiles.
4. After 3 attempts for the same upstream commit, or if Claude decides it needs a decision, labels the issue `needs-human` and sends a critical notification.

Claude is limited to file edits, `git`, and reading/commenting on issues and runs. It never pushes to `main`; only a passing build does.

```sh
.fork/fixer/install.sh             # install or update the timer (re-run after changing the fixer)
.fork/fixer/install.sh --remove    # uninstall
systemctl --user list-timers lc-fork-fixer.timer
journalctl --user -u lc-fork-fixer.service
ls ~/.local/state/lc-fork-fixer/logs/   # one log per Claude run
```

### Fixing a sync by hand

```sh
git fetch origin && git fetch upstream
git checkout -B sync/upstream origin/main
git merge upstream/main          # resolve, keeping the customizations above
git push -f origin sync/upstream
gh workflow run sync-upstream.yml
```
