# Unity Crashpad fork — build & Stevedore packaging

This directory holds Unity-specific build infrastructure for the Crashpad fork.
The fork itself is a checkout of upstream Crashpad with a set of Unity patches
(see *Unity modifications* below). The build produces static libraries and
headers that Unity consumes via Stevedore.

## Layout

```
.yamato/
├── publish.yml         # Yamato job: build both arches, pack, tag, upload
├── scripts/
│   ├── build-and-pack.sh        # depot_tools bootstrap + gclient sync + build + pack
│   ├── pack-stevedore.sh        # Builds the Stevedore artifact from local ninja output
│   ├── tag-and-push.sh          # compute & push unity-YYYY.MM.DD-<upstream-12char>[-N] tag
│   └── upload-to-stevedore.sh   # StevedoreUpload invocation
└── README.md           # this file
```

Build outputs land in `out/<config>/` (already covered by Crashpad's root
`.gitignore`). The packaged `.7z` archives land in `out/dist/`.

---

## Prerequisites

- **macOS** with Xcode (provides clang and the system SDK)
- **depot_tools** on `$PATH` — provides `gn`, `ninja`, `gclient`
- **7-Zip** (`7z`) on `$PATH` — used by the pack script

Install depot_tools if you don't have it:

```bash
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
export PATH="$HOME/depot_tools:$PATH"
# add the export to ~/.zshrc to persist
```

---

## One-time setup

Crashpad uses `gclient` to manage its non-source dependencies (mini_chromium,
ninja binaries, etc.). The `.gclient` config file lives **one level above** the
Crashpad checkout — create it once:

```bash
# Adjust the path if your checkout lives elsewhere
cat > ../.gclient <<'EOF'
solutions = [
  {
    "name": "crashpad",
    "url": "https://chromium.googlesource.com/crashpad/crashpad.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
EOF
```

`managed: False` is important — it stops gclient from touching your existing
fork branch / remote. The URL is effectively a label in this mode.

Then sync dependencies:

```bash
cd ..  # the .gclient parent
gclient sync --no-history
```

This downloads `third_party/mini_chromium`, GN, ninja, etc. into the fork.

---

## Building

The fork builds for two macOS architectures. Both are needed for Unity (Editor
and player) to consume the artifact on Intel and Apple Silicon machines.

```bash
cd <fork>  # /Users/.../crashpad/unity/crashpad in this checkout

gn gen out/arm64-release --args='is_debug=false target_cpu="arm64" mac_deployment_target="12.0"'
ninja -C out/arm64-release

gn gen out/x64-release --args='is_debug=false target_cpu="x64" mac_deployment_target="12.0"'
ninja -C out/x64-release
```

Notes:

- **`mac_deployment_target="12.0"`** is required because upstream Crashpad
  unconditionally references `kIOMainPortDefault`, which is a macOS 12+ symbol.
  Setting the deployment target lower triggers a compile error in
  `util/mac/mac_util.cc`. The linker will emit a warning when Unity (targeting
  macOS 11) links these libs; the warning is *metadata only* — both
  `kIOMainPortDefault` and the older `kIOMasterPortDefault` resolve to the same
  runtime value, so the binary works on macOS 11+ regardless. Open item: patch
  Crashpad source to handle macOS 11 in `mac_util.cc` so we can lower the
  deployment target and eliminate the warning.
- Ninja builds the whole tree (libs, the standalone `crashpad_handler` binary,
  tests). Unity only links the libs; the standalone binary is unused but is
  produced as a byproduct.

---

## Packing the Stevedore artifact

```bash
.yamato/scripts/pack-stevedore.sh
```

Outputs `out/dist/crashpad-unity-mac-arm64.7z` and `out/dist/crashpad-unity-mac-x64.7z`
plus prints the full Stevedore artifact ID for each.

The script:

1. Copies the production static libraries (`libclient.a`, `libcommon.a`, …) from
   `out/<config>/obj/...` into `lib/macos/<arch>/`, renaming to short names.
2. Copies Crashpad and mini_chromium headers into `include/`.
3. Copies the **11 Crashpad source files Unity compiles directly** (the
   `handler_main.cc` chain, `tool_support.cc`, `notify_server.cc`, etc.)
   into `src/`.
4. Copies generated MIG stubs into `gen/`.
5. Generates `LICENSE`, `NOTICE`, `AUTHORS`, `README.txt` inline (no checked-in
   copies — single source of truth is the fork's own LICENSE/AUTHORS).

### Environment knobs

| Variable | Default | Purpose |
|---|---|---|
| `CRASHPAD_SRC` | two levels above the script | Path to the fork checkout |
| `ARM64_BUILD` | `$CRASHPAD_SRC/out/arm64-release` | arm64 ninja output dir |
| `X64_BUILD` | `$CRASHPAD_SRC/out/x64-release` | x64 ninja output dir |
| `FORK_URL` | `https://github.com/Unity-Technologies/crashpad` | Embedded in `NOTICE` / `README.txt` |
| `VERSION` | 12-char git SHA of HEAD | Stevedore version string |
| `SKIP_X64=1` | — | Pack only the arm64 archive |

---

## Uploading to Stevedore

### One-off (web UI)

Drag-and-drop the `.7z` files onto <https://stevedore.unity3d.com/upload/>.
The web UI computes the SHA, displays the full artifact ID after upload, and
puts the file in the `testing` repo.

### One-off (curl)

Get your personal upload token from the same upload page, then:

```bash
ID="crashpad-unity-mac-arm64/<version>_<sha>.7z"      # printed by pack-stevedore.sh
curl -H "Authorization: Bearer alexgu@unity3d.com:<TOKEN>" \
  --request POST \
  --upload-file out/dist/crashpad-unity-mac-arm64.7z \
  "https://stevedore-upload.ds.unity3d.com/upload/r/testing/$ID"
```

### Verify the upload

In the Unity repo:

```bash
./Tools/Bee/bee steve internal-unpack testing "$ID" /tmp/crashpad-check
ls /tmp/crashpad-check/lib/macos/arm64/
```

### From CI

`publish.yml` defines two manually-triggered Yamato jobs on macOS Bokken
agents. They diverge in what they do but share most steps.

**`publish_testing`** — iterative builds for validation:

1. **build-and-pack.sh** — installs `depot_tools` (if missing), writes the
   `.gclient` config one level above the checkout, runs `gclient sync`, then
   `gn gen` + `ninja` for both arm64 and x64, then `pack-stevedore.sh`.
2. **upload-to-stevedore.sh** — downloads `StevedoreUpload` and uploads both
   archives to the `testing` repo. The resulting artifact IDs are appended to
   `out/dist/artifactids.txt`, which Yamato exposes as a job artifact.

No git tag is created — testing artifacts are identified by the fork HEAD
SHA in their Stevedore VERSION (12-char prefix).

**`publish_public`** — canonical release to customers:

1. **branch guard** (inline in `publish.yml`) — refuses to run unless HEAD
   is the tip of `unity/main`. The public Stevedore repo is immutable and
   customer-facing; emergency hotfixes must land on `unity/main` first.
2. **build-and-pack.sh** — same as testing.
3. **tag-and-push.sh** — computes a `unity-YYYY.MM.DD-<upstream-12char>[-N]`
   tag for HEAD and pushes it to the fork using `GH_PUSH_TOKEN`. Idempotent:
   if any `unity-*` tag already points at HEAD, the script exits cleanly.
   The counter `-N` increments per (date, upstream) pair: the first tag of a
   day for a given upstream is bare; same-day re-publishes on the same
   upstream get `-2`, `-3`.
4. **upload-to-stevedore.sh** — uploads to the `public` repo.

#### Tag vs. Stevedore VERSION — separate identifiers

Two formats, two audiences:

| | Stevedore VERSION | Git tag (public only) |
|---|---|---|
| Format | `<fork-HEAD-12char>` | `unity-YYYY.MM.DD-<upstream-12char>[-N]` |
| Example | `2500b3fb7bc5` | `unity-2026.06.09-ae5b334b23ec` |
| Audience | Stevedore / build tooling | Humans browsing GitHub tags |
| Constraint | Stevedore 40-char cap | Git tag rules (very permissive) |

The Stevedore VERSION follows the codebase convention for Unity forks of
upstream projects (see `External/CoreCLR`, `External/Yasm` in the Unity repo:
both use plain 12-char fork SHA). The git tag carries the human-readable
provenance — upstream baseline + ship date + iteration counter — and lives
only on GitHub.

To resolve between them:

```bash
# Stevedore artifact prefix -> tag
git tag --points-at 2500b3fb7bc5

# Tag -> Stevedore VERSION prefix
git rev-parse unity-2026.06.09-ae5b334b23ec | cut -c1-12

# Tag -> upstream baseline (for CVE triage / rebase context)
git merge-base unity-2026.06.09-ae5b334b23ec main
```

Required secret groups (configure once in the Yamato project Settings UI):

| Group | Variable | Used by | Purpose |
|---|---|---|---|
| `stevedore-upload-v2` | `STEVEDORE_UPLOAD_TOOL_MAC_X64_URL` | both | Where to download `StevedoreUpload`. Shared infrastructure group. |
| `crashpad-stevedore-key` | `STEVEDORE_UPLOAD_KEY` | both | Project upload key. Generate at <https://stevedore.unity3d.com/upload/keys> and register via `#devs-stevedore`. The same key must be authorized for `public` separately by a Stevedore admin. |
| `crashpad-github-push` | `GH_PUSH_TOKEN` | public only | GitHub token with `repo:write` on `Unity-Technologies/crashpad` — used only to push the version tag. |

To get the artifact IDs after a run: download the `stevedore` artifact from
the Yamato job page; `artifactids.txt` lists one line per archive in
`<repo>: <name>/<version>_<sha>.7z` form. Paste those lines into the relevant
Unity `manifest.stevedore`.

---

## Updating Unity to consume a new artifact

In the Unity repo, edit `External/crashpad/manifest.stevedore` and replace the
artifact ID with the new one. The lookup name (`crashpad-unity-mac-arm64`) stays
constant — only the `<version>_<sha>.7z` suffix changes:

```
testing: crashpad-unity-mac-arm64/<new-version>_<new-sha>.7z
```

For trunk-bound changes, the prefix must be `public:` (Stevedore enforces this).
Promotion `testing → public` is performed by a Stevedore admin after license
and guideline review.

---

## Unity modifications (Apache 2.0 disclosure)

The fork carries a small set of modifications vs. upstream Crashpad. Each
modified file should carry a `MODIFICATION HISTORY:` comment near the top
documenting what was changed, when, and why. Files currently modified:

| File | Modification |
|---|---|
| `handler/unity_post_minidump_hook.{cc,h}` | **New files.** Declare a `UnityCrashpadPostMinidumpHook` function-pointer global. Unity links its own non-null definition in `PlatformDependent/OSX/UnityMacCrashHandler/PostMinidumpHook.cpp`. The `.cc` here provides a `nullptr` default for standalone Crashpad builds. |
| `handler/mac/crash_report_exception_handler.cc` | Invokes the hook after a minidump is finalized so Unity can post-process the report. |
| `handler/BUILD.gn` | Adds the two new hook source files to the Mac handler target. |
| `client/crash_report_database.h` | Exposes `DatabasePath()` as `public` so the hook can pass the database path back to Unity. |

The `NOTICE` file shipped in the artifact is generated by the pack script and
surfaces the bundled third-party licenses (mini_chromium BSD-3, ICU/Unicode).
The full Crashpad `LICENSE` and `AUTHORS` are also shipped at the artifact
root.
