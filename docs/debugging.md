# Debugging

## Run a local build

```sh
./script/build_and_run.sh verify   # build, sign, launch, and confirm it runs
./script/build_and_run.sh logs     # launch and stream its log lines
```

- The dev bundle id is `com.robinebers.openusage.dev`. It keeps its own settings and Keychain items
  and runs beside an installed OpenUsage.
- It has no update feed, so the Updates controls are disabled. It leaves alone the OpenRouter and Z.ai
  keys 0.7.x saved.
- Only one dev build runs at a time. If one from another folder is running, `run` and `verify` fail
  and print its path.

The build's scratch directory — SwiftPM's build database, index store, module cache and fetched
dependencies — lives on the local disk (`~/build` by default, `SWIFT_SCRATCH_PATH` to change it),
not next to the sources. On a checkout that sits on a network volume those files get corrupted
(stale NFS handles, module maps truncated mid-write) and the build fails at random. Override the
path with `SWIFT_SCRATCH_PATH` when a different location is wanted.

## The build engine

The scripts build with Swift Build (`swift build --build-system swiftbuild`), not SwiftPM's older
native engine. The difference matters for the packaged app: Swift Build generates a resource
accessor that looks in the app's `Contents/Resources`, where the scripts stage every resource
bundle, while the native engine's accessor looks only in the app root and in the build tree baked
in at compile time. An app packaged with the native engine therefore dies with "Fatal error: could
not load resource bundle" the first time a dependency reads its resources — opening Settings does
it, through the shortcut recorder — but only on a machine that does not have the build tree, so a
locally built app hides it.

`SWIFT_BUILD_SYSTEM=native` switches the scripts back to the old engine. Do not package a release
with it: `script/release.sh` refuses a binary whose resource accessor cannot find
`Contents/Resources`.

Swift Build builds a universal binary unless told otherwise. The development and test scripts build
the host's own architecture, because nothing here runs the other slice and it doubles both the
build time and the size of what is produced; `SWIFT_ARCHS="arm64 x86_64"` asks for both. The
release always builds both.

## Sample Data (Development Only)

The local build script stages `dist/OpenUsage.app` and `dist/OpenUsage Demo.app`. In the normal dev
app, turn on **Settings → Advanced → Development → Sample Data**. The switch restarts in the isolated
demo app. Turn it off to restart the normal dev app with its existing accounts and settings.

- Each launch draws a random seed, shown beside **Demo Data** in the footer. The seed picks every
  provider's account count and names, which limits show, their usage, and their resets.
- Every seed shows at least one Warning, Critical, Burning Fast, Used Up, empty balance, Use It or
  Lose It, and account notice. Resets fall between the next hour and the next week.
- **Reshuffle**, under Development in the demo app, swaps in a new seed's accounts without a restart.
- To reproduce a seed, launch the demo with it:
  `open "dist/OpenUsage Demo.app" --args -DemoSeed 4242`.
- The demo uses `com.robinebers.openusage.dev.demo` and memory-only credential vaults. Its accounts,
  layout, and settings reset at each launch. It never reads or changes the normal dev app's or the
  installed app's accounts, settings, or Keychain items.
- Usage reads and hub calls are blocked, and telemetry is off. Add Account still runs the provider's
  real sign-in; the new account then shows sample usage.
- The script passes `OPENUSAGE_DEVELOPMENT` only for local development identities. Releases and the
  downloaded Test Build DMGs do not include Sample Data, and CI checks that release binaries don't.

## Read the logs

OpenUsage logs through unified logging under the subsystem `OpenUsage`, with categories such as
`refresh`, `http`, `auth`, `updates`, and `config`.

```sh
log stream --info --predicate 'subsystem == "OpenUsage"'
log stream --info --predicate 'subsystem == "OpenUsage" AND category == "refresh"'
log show --last 2h --predicate 'subsystem == "OpenUsage" AND category == "refresh"'
```

- macOS keeps info lines in memory only, so `log show` finds them for a few minutes at most. Each
  refresh pass's `batch start` and `batch end` lines go to disk, so the last command lists every pass.
- **Settings → Advanced → Log Level** sets how much is written: Info (the default), Debug (read with
  `--debug`), Warning, or Error.
- Logs never hold a URL's query, a header, or a response body. Tokens, keys, and home paths are masked.

## Tests

```sh
script/test_quiet.sh
script/test_quiet.sh --filter CursorTokenRefreshTests
script/test_quiet.sh -Xswiftc -DOPENUSAGE_DEVELOPMENT --filter 'DevelopmentDemoTests|DevelopmentDataModeTests'
```

The script runs the suite niced, keeps it from taking the keyboard or the screen, and fails the run if
a test process came to the front.

It builds in the same local-disk scratch directory as the app build, so it does not hit the
corrupted-module-cache failures a network volume causes. Pass `--scratch-path` yourself to put the
build somewhere else.
