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

Weekly on Sunday 04:00 UTC, or manual:

1. **`build-imagebuilder.yml`** — `discover` job lists directories in [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) (named `{date}_r{revision}-{commit-hash}_{branch}`), picks the latest (or the one matching `force_branch`), extracts the short commit hash, and resolves it to a full SHA via the GitHub API. Checks if that SHA is already recorded in our GH release body; if so, skips. `build` job does a **depth-1 fetch of that specific commit** (not the branch HEAD — guarantees byte-for-byte compat with the release we're mirroring), pulls `config.buildinfo` from pesa's release dir as `.config`, appends `CONFIG_IB=y` + `CONFIG_IB_STANDALONE=y` + a few tweaks, runs `make world`. Also downloads the matching `.manifest` and writes it to `firmware-packages.txt` (artifact). `containerize` job builds the slim runtime image (the Containerfile bakes `firmware-packages.txt` into `DEFAULT_PACKAGES`, so `make image` with no `PACKAGES=` argument produces pesa-parity firmware), pushes to GHCR, publishes packages + metadata under `releases/{version}/` on the `releases` branch.
2. **`publish-branches.yml`** — runs after a successful build; rebuilds `branches.json` on the `releases` branch from existing GH releases so the ASU server can discover available builds.
3. **`healthchecks.yml`** — pings healthchecks.io. Requires the `HEALTHCHECK_BUILD_UUID` repo secret.
4. **`build-firmware.yml`** — supplemental firmware image builds (distinct from the ImageBuilder container).

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

Release-series branches (e.g. `next-r4.8.x.rss.mtk`) derive an ASU X.Y version via `sed 's/^next-r//' | cut -d. -f1,2` (→ `4.8`). Test branches (containing `-test`) skip this and use the branch name directly as the version — they're manual-only.

## Containerfile details

The `Containerfile` in this repo is **stage 2** (slim runtime). The build context is the repo root plus two CI-injected files: `*imagebuilder*.tar.*` (the compiled IB from the `build` job) and `firmware-packages.txt` (pesa's manifest for the same release, also from the `build` job). Both are downloaded as artifacts by the `containerize` job before `docker build` runs.

- Patches `apk-mbedtls → apk-openssl`, `libustream-mbedtls → libustream-openssl`, `wpad-basic-mbedtls → wpad-openssl` in three files. Pesa's config uses the openssl variants, but upstream OpenWrt's default-packages lists still reference mbedtls — without these patches, ImageBuilder output references packages that weren't actually compiled.
- **Appends `firmware-packages.txt` to `DEFAULT_PACKAGES`** in `include/default-packages.mk`, so `make image PROFILE=X` with no `PACKAGES=` argument produces a rootfs matching pesa's manifest (LuCI, kmods, the works). Since the manifest comes from the same release whose `config.buildinfo` drove the build, every package in the list is guaranteed to exist in the IB's package repo — `make image` can't fail on a missing name.
- Accepts `PACKAGES_BASE_URL` build-arg — if set, it rewrites `repositories.conf`/`repositories` so firmware built by ASU fetches post-flash packages from our signed feed on the `releases` branch instead of pesa's raw GitHub URLs.
- Replaces `setup.sh` with a no-op (ASU calls this for snapshot builds; upstream's version refreshes feeds, but our tree is fully pre-built).
- Runs as uid/gid 1000 `buildbot`. The upstream Ubuntu image's default `ubuntu` user (also uid 1000) is deleted first.

## `releases` branch layout

This branch is a **metadata-only** store consumed by ASU. No source code.

```
branches.json                                                       # ASU branch config
.versions.json                                                      # available versions
releases/{version}/.targets.json                                    # per-version targets
releases/{version}/packages/{arch}/feeds.conf                       # feed name list
releases/{version}/packages/{arch}/{feed}/index.json                # signed APK feed per name
releases/{version}/packages/{arch}/{feed}/*.apk
releases/{version}/targets/mediatek/filogic/profiles.json           # device profiles
releases/{version}/targets/mediatek/filogic/*.manifest              # build manifests
releases/{version}/targets/mediatek/filogic/*.buildinfo
releases/{version}/targets/mediatek/filogic/packages/index.json     # target kmods
releases/{version}/targets/mediatek/filogic/packages/*.apk
```

The `path` field in `branches.json` uses the template `releases/{version}` — ASU expands `{version}` at runtime with the full `-SNAPSHOT` suffix, then fetches packages from `{path}/packages/{arch}/` and target kmods from `{path}/targets/{target}/packages/`.

`feeds.conf` is opkg-format (whitespace-separated columns); ASU's `parse_feeds_conf` only reads the second column (the feed name), so the other fields are placeholders.

## Related repos

- [Ogglord/asu](https://github.com/Ogglord/asu) — ASU server (consumer).
- [pesa1234/openwrt](https://github.com/pesa1234/openwrt) — upstream source fork we build from.
- [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) — source of `.config` files and release directory markers we use to discover new branches.
