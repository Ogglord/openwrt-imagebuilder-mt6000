# OpenWrt ImageBuilder Container for MT6000

Builds an OpenWrt ImageBuilder container from [pesa1234/openwrt](https://github.com/pesa1234/openwrt) for the GL.iNet Flint 2 (MT6000).

> **Related repos:**
>
> | Repo | Purpose |
> |------|---------|
> | [Ogglord/asu](https://github.com/Ogglord/asu) | ASU application (fork of openwrt/asu) -- the FastAPI server and worker |
> | [Ogglord/asu-deploy](https://github.com/Ogglord/asu-deploy) | Deployment config (compose, config, deploy script) |
> | [Ogglord/openwrt-imagebuilder-mt6000](https://github.com/Ogglord/openwrt-imagebuilder-mt6000) | This repo -- CI workflows that build ImageBuilder containers from pesa1234's branches |

## How it works

1. A weekly GitHub Action enumerates release directories in [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) (named `YYYY-MM-DD_r{rev}-{short-sha}_{branch}`) and picks the latest.
2. The short SHA from the directory name is resolved to a full commit SHA against `pesa1234/openwrt` and compared against a stored marker (the body of the GH Release for that branch) to detect new commits.
3. For each new commit the workflow does a depth-1 fetch of **that exact commit** (not the branch HEAD) and pulls `config.buildinfo` from the matching release directory as its `.config`. `CONFIG_IB=y` + `CONFIG_IB_STANDALONE=y` are appended to produce an ImageBuilder-capable tree; `CONFIG_VERSION_NUMBER` is rewritten to `{X.Y}-SNAPSHOT` where `{X.Y}` is derived from the pesa branch name.
4. After `make world` finishes, the `.manifest` from pesa's release directory is downloaded and written to `firmware-packages.txt`. The `Containerfile` appends that list to `DEFAULT_PACKAGES` in the ImageBuilder tarball, so `make image` with no `PACKAGES=` argument produces a rootfs that matches pesa's firmware (LuCI + kmods + full default set).
5. The slim runtime container is pushed to `ghcr.io` tagged per-branch **and** per-ASU-version. A second workflow (`publish-branches.yml`) regenerates `branches.json` / `.versions.json` / `.targets.json` on the `releases` branch from the resulting GH Releases so ASU can discover available builds.

Config drift between our IB and pesa's firmware is structurally impossible: our `.config`, our package repository, and the manifest we use for `DEFAULT_PACKAGES` all come from the same pesa release directory.

## Version and naming conventions

The CI uses pesa's branch name for discovery, and a derived X.Y version for everything ASU-facing. Here's how a pesa branch flows through the system:

### 1. Pesa branch discovered

The CI discovers a release dir like `2026-04-12_r34722-2fff68cf9a_next-r4.8.0.rss.mtk` from [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build), which encodes the pesa branch `next-r4.8.0.rss.mtk`.

### 2. ASU version derivation

The pesa branch is reduced to an ASU X.Y version by stripping `next-r` and taking the first two version components:

```
next-r4.8.0.rss.mtk → 4.8
next-r4.7.4.rss.mtk → 4.7
```

Test branches (those containing `-test`) map to `SKIP` and are built container-only, without ASU integration.

### 3. Firmware version string

`CONFIG_VERSION_NUMBER` is set to **`{X.Y}-SNAPSHOT`**:

```
4.8-SNAPSHOT
```

This is what the router reports as its version. The `-SNAPSHOT` suffix tells ASU this is a rolling/development build.

### 4. Container image tags

Two tags are pushed per build:

```
ghcr.io/ogglord/openwrt-imagebuilder:mediatek-filogic-next-r4.8.0.rss.mtk   # pesa branch
ghcr.io/ogglord/openwrt-imagebuilder:mediatek-filogic-openwrt-4.8           # ASU resolves here
```

The `openwrt-{X.Y}` tag is the one ASU resolves to. When ASU receives a build request for version `4.8-SNAPSHOT`, `get_container_version_tag()` strips `-SNAPSHOT` and prepends `openwrt-`:

```
4.8-SNAPSHOT
  → strip -SNAPSHOT  → 4.8
  → prepend openwrt- → openwrt-4.8
  → full image tag   → mediatek-filogic-openwrt-4.8
```

### 5. ASU branch resolution

ASU's `get_branch()` has special handling for `-SNAPSHOT` versions — it splits on the last hyphen to derive the branch name:

```
4.8-SNAPSHOT
  → rsplit("-", 1)[0] → 4.8
```

`4.8` must exist as a key in the ASU branch config. `branches.json` is served from the `releases` branch and loaded by our fork's `branches_url` setting.

### 6. Metadata on the `releases` branch

Everything ASU needs lives at the branch root, keyed by the `-SNAPSHOT` version. No source code, no unsigned packages:

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

`branches.json` uses the derived X.Y key:

```json
{
  "4.8": {
    "name": "r4.8.0.rss.mtk",
    "enabled": true,
    "snapshot": true,
    "path": "{version}",
    "path_packages": "DEPRECATED",
    "package_changes": [],
    "targets": {"mediatek/filogic": "aarch64_cortex-a53"}
  }
}
```

The `path` template `{version}` is expanded by ASU at runtime with the full `-SNAPSHOT` suffix; data is fetched from the branch root (e.g. `4.8-SNAPSHOT/targets/mediatek/filogic/profiles.json`). The branch itself is named `releases`, so the raw GitHub URL already contains one `/releases/` — nesting another `releases/` directory inside would stutter in every URL.

### End-to-end summary

| Stage | Value | Where |
|-------|-------|-------|
| Pesa branch | `next-r4.8.0.rss.mtk` | pesa1234/openwrt |
| Release commit pinned to | (short-sha from release dir, resolved to full SHA) | pesa1234/openwrt |
| Firmware version | `4.8-SNAPSHOT` | Router's `/etc/openwrt_release` |
| ASU branch key | `4.8` | `branches.json` on releases branch |
| Pesa-branch container tag | `mediatek-filogic-next-r4.8.0.rss.mtk` | ghcr.io |
| ASU-resolved container tag | `mediatek-filogic-openwrt-4.8` | ghcr.io |
| Metadata path | `4.8-SNAPSHOT/` (at branch root) | releases branch |

## Manual build

Trigger via the Actions tab → "Build ImageBuilder Containers" → "Run workflow". Inputs:

- `force_branch` — e.g. `next-r4.8.0.rss.mtk`. Bypasses the "commit already built" skip and requires a release directory for that branch to exist in `pesa1234/MT6000_cust_build` (the config and manifest come from there).
- `runner` — `ubuntu-latest` (GH-hosted, ~60 min) or a self-hosted runner label.

## Local build

For quick iteration without waiting on CI:

```bash
./build-local.sh [branch]     # full IB build, default next-r4.8.0.rss.mtk-test6.18
./debug-package.sh <pkg>      # rebuild one package with V=s, cached layers up to defconfig
```

`build-local.sh` pipes failure tails through `claude` for diagnosis; logs land in `./logs/`.

## Setup

Required repository secrets:

- `HEALTHCHECK_BUILD_UUID` — healthcheck.io ping UUID (build start/success/failure notifications).
- `PACKAGE_SIGNING_KEY` — RSA private key used to sign APK packages at build time.
- `PACKAGE_SIGNING_KEY_PUB` — matching public key; embedded in firmware at `/etc/apk/keys/` so on-device APK installs trust our signed feed.
