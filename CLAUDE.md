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

Pipeline runs weekly on Sunday 04:00 UTC or on manual dispatch. Two workflows chained via `workflow_run`:

1. **`build-imagebuilder.yml`** — `discover` job lists all directories in [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) (named `{date}_r{revision}-{commit-hash}_{branch}`), picks the absolute latest (or filters to `force_branch` if set), resolves to full SHA. Skips if already built (auto mode only). `build` job does a **depth-1 fetch of that specific commit**, pulls `config.buildinfo` as `.config`, appends `CONFIG_IB=y` + `CONFIG_IB_STANDALONE=y` + a few tweaks, runs `make world`. Uploads four artifacts (retention 14d): `build-tarballs` (imagebuilder + sdk), `packages-staging`, `firmware-packages`, `build-meta` (JSON with discover outputs).
2. **`containerize.yml`** ("Containerize & Publish") — auto-triggers on successful Build ImageBuilder via `workflow_run`; also manually runnable via `workflow_dispatch` with optional `build_run_id` and `branch_filter` inputs. Downloads artifacts, publishes packages + metadata under `{version}/` on the `releases` branch, builds the slim runtime container (Containerfile bakes `firmware-packages.txt` into `DEFAULT_PACKAGES`), pushes to GHCR, creates a GitHub release, then rebuilds `branches.json` / `.versions.json` / `.targets.json` on the `releases` branch.
3. **`build-firmware.yml`** — supplemental firmware image builds (distinct from the ImageBuilder container).

Secrets required: `PACKAGE_SIGNING_KEY` (RSA private key), `PACKAGE_SIGNING_KEY_PUB`.

## Version / naming contract

This is the critical invariant — the naming must match what the ASU server expects. Flow for a pesa branch `next-r4.8.0.rss.mtk-test6.18`:

| Stage | Value |
|---|---|
| Firmware `CONFIG_VERSION_NUMBER` | `4.8.0` |
| ASU branch key (in `branches.json`) | `4.8` |
| Container tag (ASU resolves to this) | `mediatek-filogic-v4.8.0` |
| Metadata path on `releases` branch | `releases/4.8.0/` |

ASU's `get_branch()` uses `rsplit(".", 1)[0]` for stable versions (no `-SNAPSHOT` suffix), giving `"4.8.0"` → `"4.8"`. `get_container_version_tag()` matches `^\d+\.\d+\.\d+` and prepends `v` to get the image tag. Don't touch the version string or container tag format without changing both sides.

Branches derive an ASU X.Y.Z version via `sed 's/^next-r//' | cut -d. -f1,2,3` (→ `4.8.0` for both `next-r4.8.0.rss.mtk` and `next-r4.8.0.rss.mtk-test6.18`). The branch key is X.Y only (`cut -d. -f1,2`). Test and non-test branches that share the same X.Y.Z collapse to the same version — latest published wins.

### OpenWrt version variables — `REVISION` vs `VERSION_CODE`

These look interchangeable and aren't. Both get written into the firmware rootfs, via different sed substitutions in `VERSION_SED_SCRIPT` (`include/version.mk`):

| Var | Source | Sed slot | Ends up in |
|---|---|---|---|
| `VERSION_CODE` | `CONFIG_VERSION_CODE`, falls back to `$(REVISION)` | `%C` / `%c` | `DISTRIB_DESCRIPTION`, APK feed URLs (`$(VERSION_CODE)` in pesa's `include/feeds.mk`) |
| `REVISION` | `scripts/getver.sh` — *only* | `%R` | `DISTRIB_REVISION` in `/etc/openwrt_release` |

`CONFIG_VERSION_CODE` does **not** drive `REVISION`, only the other way around (fallback). Pinning `CONFIG_VERSION_CODE` alone fixes feed URLs and `DISTRIB_DESCRIPTION` but leaves `DISTRIB_REVISION` with whatever `getver.sh` produced.

**Shallow-clone trap**: our `build` job does a depth-1 fetch of a specific commit (byte-for-byte parity with pesa's release). `getver.sh`'s git path counts commits via `git rev-list REBOOT..HEAD` where `REBOOT=ee53a240ac902dc83209008a2671e7fdcf55957a` (pesa's fork-specific REBOOT commit), and on a shallow clone that range is empty → output is `r0-<7-char-sha>`. `getver.sh` has an escape hatch: `try_version()` reads from a `TOPDIR/version` file and short-circuits before the git path, so we write the parsed `rREV-HASH` there before `make world` — see `build-imagebuilder.yml:267-287`. Do not remove the `version` file write without first removing the depth-1 fetch.

### distfeeds.list generation is make-time, not overlay-compatible

`include/feeds.mk`'s `FeedSourcesAppendAPK` + `VERSION_SED_SCRIPT` runs from `package/base-files/Makefile` during the rootfs install step of `make image` (at ASU worker time). It *overwrites* `/etc/apk/repositories.d/distfeeds.list` even if one was pre-seeded via the IB's `files/` overlay. Shipping a correct distfeeds.list means controlling the template (patched in `build-imagebuilder.yml` before `make world`) and `CONFIG_VERSION_REPO`, not writing a rootfs file.

### Build-time apk feeds vs runtime distfeeds

Two files, same template, different lifecycles:

- **`$(TOPDIR)/repositories`** — generated at `make world` (step 1) by `target/imagebuilder/Makefile:49`. Consumed at `make image` (ASU worker) time by the `APK` invocation in `target/imagebuilder/files/Makefile:100-104`. Governs build-time package resolution (what `make image PACKAGES=...` can pull in).
- **`/etc/apk/repositories.d/distfeeds.list`** (firmware runtime) — generated at `make image` time by `package/base-files/Makefile`. Same `FeedSourcesAppendAPK` template, expanded at a later stage. Governs on-device `apk update && apk install`.

Both files share `include/feeds.mk`'s template, so the feeds.mk sed has to land **before** `make world` to cleanly fix both surfaces.

### Why we keep `CONFIG_IB_STANDALONE=y` and patch around it

`CONFIG_IB_STANDALONE=y` gates three blocks in pesa's `target/imagebuilder/Makefile` + `files/Makefile`:

1. `Makefile:48-51` — generation of `$(TOPDIR)/repositories` (skipped when standalone).
2. `Makefile:71-81` — which `.apk` files get copied into the IB tarball's `packages/` dir: **all** built packages (standalone) vs just `base-files`, `libc`, `kernel` (non-standalone).
3. `files/Makefile:101` — whether `--repositories-file` is passed to apk at `make image` time.

Dropping `IB_STANDALONE=y` (enabling non-standalone) allows upstream-snapshot fallback via (3), but also strips 2/3 of pesa's packages from the IB tarball (via 2) and forces them to be pulled from upstream snapshots — **losing pesa's patches on `luci`, `wpad-openssl`, `dropbear`, etc.** The fork's purpose is to ship pesa's build, so this is unacceptable.

Instead, `build-imagebuilder.yml`'s "Allow apk upstream-snapshot fallback" step keeps `IB_STANDALONE=y` and surgically removes the guards on (1) and (3) via sed before `make world`:

- Drops `ifeq ($(CONFIG_IB_STANDALONE),)` + its matching `endif` in the APK branch of `Makefile` (scoped to the range `ifneq ($(CONFIG_USE_APK),) … else` so the OPKG branch and package-copy strategy stay untouched).
- Strips the `$(if $(CONFIG_IB_STANDALONE),,…)` wrapper from the APK command line in `files/Makefile`.

Result: IB tarball still ships every pesa-built package (via (2), still gated on standalone), `$(TOPDIR)/repositories` still gets generated, and apk at `make image` time sees both `--repository $(PACKAGE_DIR)/packages.adb` (local, pesa-patched packages win) and `--repositories-file $(TOPDIR)/repositories` (upstream snapshots for anything we didn't build — nano, git, …).

Verification: after the seds, `target/imagebuilder/Makefile` should retain exactly 2 `CONFIG_IB_STANDALONE` references (OPKG branch + package-copy branch); `files/Makefile` should have 0. The CI step asserts both.

## Containerfile details

The `Containerfile` in this repo is **stage 2** (slim runtime). The build context is the repo root plus two CI-injected files: `*imagebuilder*.tar.*` (the compiled IB from the `build` job) and `firmware-packages.txt` (pesa's manifest for the same release, also from the `build` job). Both are downloaded as artifacts by the `containerize` job before `docker build` runs.

- Patches `apk-mbedtls → apk-openssl`, `libustream-mbedtls → libustream-openssl`, `wpad-basic-mbedtls → wpad-openssl` in three files. Pesa's config uses the openssl variants, but upstream OpenWrt's default-packages lists still reference mbedtls — without these patches, ImageBuilder output references packages that weren't actually compiled.
- **Appends `firmware-packages.txt` to `DEFAULT_PACKAGES`** in `include/default-packages.mk`, so `make image PROFILE=X` with no `PACKAGES=` argument produces a rootfs matching pesa's manifest (LuCI, kmods, the works). Since the manifest comes from the same release whose `config.buildinfo` drove the build, every package in the list is guaranteed to exist in the IB's package repo — `make image` can't fail on a missing name.
- **Refuses IB tarballs that haven't had pesa's `$(DATE)_$(VERSION_CODE)_$(BRANCH)/` template segment stripped from `include/feeds.mk`**. The strip itself happens at step 1 in `build-imagebuilder.yml` before `make world`, because `$(TOPDIR)/repositories` (the apk repository list used at `make image` time) is generated during `make world` by `target/imagebuilder/Makefile` via the same `FeedSourcesAppendAPK` template. Stripping the template post-hoc in this Containerfile would only fix the firmware's runtime `distfeeds.list`, not the IB's build-time feed list. Combined with `CONFIG_VERSION_REPO=https://raw.githubusercontent.com/Ogglord/openwrt-imagebuilder-mt6000/releases/<X.Y>-SNAPSHOT`, both `repositories` and `distfeeds.list` resolve to `%U/targets/%S/packages/packages.adb` → the `releases`-branch layout.
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
