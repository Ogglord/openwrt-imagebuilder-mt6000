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

1. A weekly GitHub Action checks [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) for new release branches
2. For each new branch, it downloads pesa's recommended `.config` from MT6000_cust_build, appends `CONFIG_IB=y` to enable ImageBuilder output, and builds from the corresponding `pesa1234/openwrt` branch
3. Branches containing `test6.18` use `config_file/test6.18/.config`, all others use `config_file/.config`
4. The resulting container is pushed to `ghcr.io` with tags matching the branch name
5. A second workflow (`publish-branches.yml`) generates metadata files on the `releases` branch so the ASU server can discover available builds

## Version and naming conventions

The naming follows upstream OpenWrt/ASU conventions so that the standard ASU `get_branch()` logic resolves everything correctly. Here's how a pesa branch flows through the system:

### 1. Pesa branch discovered

The CI discovers a branch like `next-r4.8.0.rss.mtk-test6.18` from [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build).

### 2. Firmware version string

The build sets `CONFIG_VERSION_NUMBER` to **`{branch}-SNAPSHOT`**:

```
next-r4.8.0.rss.mtk-test6.18-SNAPSHOT
```

This is what the router reports as its version. The `-SNAPSHOT` suffix tells ASU this is a rolling/development build, and the pesa branch label remains visible to users.

### 3. Container image tags

Two tags are pushed per build:

```
ghcr.io/ogglord/openwrt-imagebuilder:mediatek-filogic-{branch}
ghcr.io/ogglord/openwrt-imagebuilder:mediatek-filogic-openwrt-{branch}
```

The `openwrt-` prefixed tag is the one ASU resolves to. When ASU receives a build request for version `next-r4.8.0.rss.mtk-test6.18-SNAPSHOT`, it calls `get_container_version_tag()` which strips `-SNAPSHOT` and prepends `openwrt-`:

```
next-r4.8.0.rss.mtk-test6.18-SNAPSHOT
  → strip -SNAPSHOT  → next-r4.8.0.rss.mtk-test6.18
  → prepend openwrt- → openwrt-next-r4.8.0.rss.mtk-test6.18
  → full image tag   → mediatek-filogic-openwrt-next-r4.8.0.rss.mtk-test6.18
```

### 4. ASU branch resolution

ASU's `get_branch()` has special handling for `-SNAPSHOT` versions -- it splits on the last hyphen to derive the branch name:

```
next-r4.8.0.rss.mtk-test6.18-SNAPSHOT
  → rsplit("-", 1)[0] → next-r4.8.0.rss.mtk-test6.18
```

This branch name must exist as a key in the ASU branch config. The config is loaded dynamically from `branches.json` on the `releases` branch via the fork's `branches_url` setting.

### 5. Metadata on the `releases` branch

The `releases` branch contains only metadata files -- no source code or packages:

```
branches.json                                          # branch config for ASU
.versions.json                                         # list of available versions
releases/{version}/.targets.json                       # target list per version
releases/{version}/targets/mediatek/filogic/profiles.json  # device profiles per version
```

`branches.json` uses the pesa branch name as the key:

```json
{
  "next-r4.8.0.rss.mtk-test6.18": {
    "enabled": true,
    "snapshot": true,
    "path": "releases/{version}",
    "targets": {"mediatek/filogic": "next-r4.8.0.rss.mtk-test6.18-SNAPSHOT"}
  }
}
```

The `path` template `releases/{version}` is expanded by ASU at runtime using the full version string (including `-SNAPSHOT`), so profiles.json is fetched from `releases/next-r4.8.0.rss.mtk-test6.18-SNAPSHOT/targets/mediatek/filogic/profiles.json`.

### End-to-end summary

| Stage | Value | Where |
|-------|-------|-------|
| Pesa branch | `next-r4.8.0.rss.mtk-test6.18` | pesa1234/openwrt |
| Firmware version | `next-r4.8.0.rss.mtk-test6.18-SNAPSHOT` | Router's `/etc/openwrt_release` |
| ASU branch key | `next-r4.8.0.rss.mtk-test6.18` | `branches.json` on releases branch |
| Container tag | `mediatek-filogic-openwrt-next-r4.8.0.rss.mtk-test6.18` | ghcr.io |
| Metadata path | `releases/next-r4.8.0.rss.mtk-test6.18-SNAPSHOT/` | releases branch |

## Manual build

Trigger a build for a specific branch via the Actions tab using "Run workflow" and specifying the branch name.

## Setup

Add the following repository secret:
- `HEALTHCHECK_BUILD_UUID`: Indicates if the github actions build fails or succeeds
