# OpenWrt ImageBuilder Container for MT6000

Builds an OpenWrt ImageBuilder container from [pesa1234/openwrt](https://github.com/pesa1234/openwrt) for the GL.iNet Flint 2 (MT6000).

## How it works

1. A weekly GitHub Action checks [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) for new release branches
2. For each new branch, it downloads pesa's recommended `.config` from MT6000_cust_build, appends `CONFIG_IB=y` to enable ImageBuilder output, and builds from the corresponding `pesa1234/openwrt` branch
3. Branches containing `test6.18` use `config_file/test6.18/.config`, all others use `config_file/.config`
4. The resulting container is pushed to `ghcr.io` with a tag matching the branch name

## Container tags

Tags follow the pattern: `mediatek-filogic-{branch-name}`

Example:
```
ghcr.io/<owner>/openwrt-imagebuilder:mediatek-filogic-next-r4.8.0.rss.mtk-test6.18
```

## Manual build

Trigger a build for a specific branch via the Actions tab using "Run workflow" and specifying the branch name.

## Setup

Add the following repository secret:
- `HEALTHCHECK_BUILD_UUID`: Your healthcheck.io ping UUID for build monitoring
