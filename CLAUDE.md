# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CI-driven build system that produces OpenWrt **ImageBuilder** containers from the [pesa1234/openwrt](https://github.com/pesa1234/openwrt) fork, targeting exclusively the GL.iNet Flint 2 (MT6000) — `mediatek/filogic`, profile `glinet_gl-mt6000`. The containers are consumed by the companion [Ogglord/asu](https://github.com/Ogglord/asu) server to assemble custom firmware on demand.

This repo has no application source — the `Containerfile` wraps a pre-built ImageBuilder tarball that comes out of the GitHub Actions workflow. All heavy lifting is in `.github/workflows/`.

## Common tasks

```bash
./build-local.sh [branch]                           # full local build (default branch: next-r4.8.0.rss.mtk-test6.18)
./debug-package.sh [package-path] [branch]          # build a single package with V=s, stops at defconfig
```

`build-local.sh` pipes failure tails through `claude` to auto-diagnose — expect an assistant invocation if the build breaks. Logs go to `./logs/`.

`debug-package.sh` uses a separate inline Containerfile that stops right after `make defconfig`, so `podman` reuses layers across runs — iterate fast on a single package without re-cloning pesa's tree.

## CI pipeline (`.github/workflows/`)

Pipeline runs weekly on Sunday 04:00 UTC or on manual dispatch. Split across
four workflows chained via `workflow_run`:

1. **`build-imagebuilder.yml`** — `discover` job lists directories in [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) (named `{date}_r{revision}-{commit-hash}_{branch}`), picks the latest (or the one matching `force_branch`), extracts the short commit hash, and resolves it to a full SHA via the GitHub API. Checks if that SHA is already recorded in our GH release body; if so, skips. `build` job does a **depth-1 fetch of that specific commit** (not the branch HEAD — guarantees byte-for-byte compat with the release we're mirroring), pulls `config.buildinfo` from pesa's release dir as `.config`, appends `CONFIG_IB=y` + `CONFIG_IB_STANDALONE=y` + a few tweaks, runs `make world`. Also downloads the matching `.manifest` and writes it to `firmware-packages.txt`. Uploads five artifacts (retention 14d): `imagebuilder-tarball`, `packages-staging`, `firmware-packages`, `profiles-json`, `build-meta` (JSON with discover outputs).
2. **`containerize.yml`** — auto-triggers on successful Build ImageBuilder via `workflow_run`; also manually runnable via `workflow_dispatch` with an optional `build_run_id` input (blank = latest successful build). Downloads the above artifacts from the specified run, publishes packages + metadata under `{version}/` on the `releases` branch, builds the slim runtime container (Containerfile bakes `firmware-packages.txt` into `DEFAULT_PACKAGES` so `make image` produces pesa-parity firmware without `PACKAGES=`), pushes to GHCR, and creates a GitHub release recording the built commit. Split out so the ~2min container step can be re-run without re-doing the ~40min `make world`.
3. **`publish-branches.yml`** — triggered by Containerize completion; rebuilds `branches.json` on the `releases` branch from existing GH releases so the ASU server can discover available builds.
4. **`healthchecks.yml`** — pings healthchecks.io on Containerize completion (success/fail). Build-only failures are already reported by the in-workflow ping step inside `build-imagebuilder.yml`. Requires the `HEALTHCHECK_BUILD_UUID` repo secret.
5. **`build-firmware.yml`** — supplemental firmware image builds (distinct from the ImageBuilder container).

Secrets required: `HEALTHCHECK_BUILD_UUID`, `PACKAGE_SIGNING_KEY` (RSA private key), `PACKAGE_SIGNING_KEY_PUB`.

## Version / naming contract

This is the critical invariant — the naming must match what the ASU server expects. Flow for a pesa branch `next-r4.8.0.rss.mtk-test6.18`:

| Stage | Value |
|---|---|
| Firmware `CONFIG_VERSION_NUMBER` | `next-r4.8.0.rss.mtk-test6.18-SNAPSHOT` |
| ASU branch key (in `branches.json`) | `next-r4.8.0.rss.mtk-test6.18` |
| Container tag (ASU resolves to this) | `mediatek-filogic-openwrt-next-r4.8.0.rss.mtk-test6.18` |
| Metadata path on `releases` branch | `releases/next-r4.8.0.rss.mtk-test6.18-SNAPSHOT/` |

ASU's `get_branch()` does `rsplit("-", 1)[0]` on the version to get the branch key, and `get_container_version_tag()` strips `-SNAPSHOT` and prepends `openwrt-` to get the image tag. Don't touch the version string or container tag format without changing both sides.

Branches derive an ASU X.Y version via `sed 's/^next-r//' | cut -d. -f1,2` (→ `4.8` for `next-r4.8.0.rss.mtk` and `next-r4.8.0.rss.mtk-test6.18` alike). Test and non-test branches that collapse to the same `<X.Y>` publish to the same `-SNAPSHOT` tag/path — latest build wins.

## Containerfile details

The `Containerfile` in this repo is **stage 2** (slim runtime). The build context is the repo root plus two CI-injected files: `*imagebuilder*.tar.*` (the compiled IB from the `build` job) and `firmware-packages.txt` (pesa's manifest for the same release, also from the `build` job). Both are downloaded as artifacts by the `containerize` job before `docker build` runs.

- Patches `apk-mbedtls → apk-openssl`, `libustream-mbedtls → libustream-openssl`, `wpad-basic-mbedtls → wpad-openssl` in three files. Pesa's config uses the openssl variants, but upstream OpenWrt's default-packages lists still reference mbedtls — without these patches, ImageBuilder output references packages that weren't actually compiled.
- **Appends `firmware-packages.txt` to `DEFAULT_PACKAGES`** in `include/default-packages.mk`, so `make image PROFILE=X` with no `PACKAGES=` argument produces a rootfs matching pesa's manifest (LuCI, kmods, the works). Since the manifest comes from the same release whose `config.buildinfo` drove the build, every package in the list is guaranteed to exist in the IB's package repo — `make image` can't fail on a missing name.
- **Strips pesa's `$(DATE)_$(VERSION_CODE)_$(BRANCH)/` segment from `include/feeds.mk`'s `FeedSourcesAppendAPK` template**. Pesa's `next-r*` branches patch that template to emit `%U/$(DATE)_$(VERSION_CODE)_$(BRANCH)/targets/%S/packages/packages.adb` so the rendered URL points at `MT6000_cust_build/<release_dir>/targets/…`. That segment leaks into any downstream build that links against pesa's tree — including ours, where `$(BRANCH)` resolves to literal `HEAD` due to detached-HEAD checkout. We drop it so firmware `/etc/apk/repositories.d/distfeeds.list` resolves to `%U/targets/%S/packages/packages.adb`, which combined with `CONFIG_VERSION_REPO=https://raw.githubusercontent.com/Ogglord/openwrt-imagebuilder-mt6000/releases/<X.Y>-SNAPSHOT` lands exactly on the `releases`-branch layout. The Containerfile aborts if the expected template segment is not found, so silent drift from upstream is caught.
- Replaces `setup.sh` with a no-op (ASU calls this for snapshot builds; upstream's version refreshes feeds, but our tree is fully pre-built).
- Runs as uid/gid 1000 `buildbot`. The upstream Ubuntu image's default `ubuntu` user (also uid 1000) is deleted first.

## `releases` branch layout

This branch is a **metadata-only** store consumed by ASU. No source code.

```
branches.json                                           # ASU branch config
.versions.json                                          # available versions
{version}/.targets.json                                 # per-version targets
{version}/packages/{arch}/feeds.conf                    # feed name list
{version}/packages/{arch}/{feed}/index.json             # signed APK feed per name
{version}/packages/{arch}/{feed}/*.apk
{version}/targets/mediatek/filogic/profiles.json        # device profiles
{version}/targets/mediatek/filogic/*.manifest           # build manifests
{version}/targets/mediatek/filogic/*.buildinfo
{version}/targets/mediatek/filogic/packages/index.json  # target kmods
{version}/targets/mediatek/filogic/packages/*.apk
```

The `path` field in `branches.json` is `"{version}"` — ASU expands it at runtime with the full `-SNAPSHOT` suffix, then fetches packages from `{path}/packages/{arch}/` and target kmods from `{path}/targets/{target}/packages/`. The branch is itself named `releases`, so the raw GitHub URL already contains one `/releases/` (the branch); keeping the content at the branch root avoids a stutter like `.../releases/releases/4.8-SNAPSHOT/...` in every URL.

`feeds.conf` is opkg-format (whitespace-separated columns); ASU's `parse_feeds_conf` only reads the second column (the feed name), so the other fields are placeholders.

## Related repos

- [Ogglord/asu](https://github.com/Ogglord/asu) — ASU server (consumer).
- [pesa1234/openwrt](https://github.com/pesa1234/openwrt) — upstream source fork we build from.
- [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) — source of `.config` files and release directory markers we use to discover new branches.
