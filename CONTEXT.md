# openwrt-imagebuilder-mt6000

## Purpose

This repository builds an OpenWrt **ImageBuilder** container from the [pesa1234/openwrt](https://github.com/pesa1234/openwrt) custom firmware fork, targeting exclusively the **GL.iNet Flint 2 (MT6000)** router (target: `mediatek/filogic`, profile: `glinet_gl-mt6000`).

The ImageBuilder container is consumed by a separate ASU (Attended Sysupgrade) server that uses it to assemble custom firmware images on demand.

## How it works

1. A weekly GitHub Actions workflow checks [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) for release directories
2. Release directories follow the naming pattern `{date}_{commit-hash}_{branch-name}` (e.g. `2026-04-12_r34722-2fff68cf9a_next-r4.8.0.rss.mtk-test6.18`)
3. The `{branch-name}` portion maps 1:1 to a branch in `pesa1234/openwrt`
4. For each new branch not yet built, the workflow compiles the full OpenWrt toolchain + ImageBuilder using pesa's recommended `.config` (fetched from MT6000_cust_build), with `CONFIG_IB=y` appended
5. Branches containing `test6.18` use `config_file/test6.18/.config`; all others use `config_file/.config`
6. The resulting container is pushed to `ghcr.io/<owner>/openwrt-imagebuilder` tagged as `mediatek-filogic-{branch-name}`

## Key design decisions

- **Pesa's `.config` is used as-is** with only `CONFIG_IB=y` and `CONFIG_IB_STANDALONE=y` appended. This ensures the ImageBuilder output matches pesa's firmware (kernel config, toolchain flags, package feeds, custom patches).
- **`FORCE_UNSAFE_CONFIGURE=1`** is set because the container build runs as root and some host tools (e.g. `tar`) reject root builds otherwise. This is standard practice for container-based OpenWrt builds.
- **Multi-stage build**: stage 1 compiles everything (~tens of GB), stage 2 extracts only the ImageBuilder tarball into a slim Debian image.
- **Weekly schedule** with auto-discovery -- only builds when MT6000_cust_build has new branches. Manual trigger also supported.
- **healthcheck.io** integration pings on build start, success, and failure.

## Container tag convention

```
ghcr.io/<owner>/openwrt-imagebuilder:mediatek-filogic-{branch-name}
```

The ASU server's `BRANCHES` config maps each branch to this tag via the `targets` field.

## Companion repository

The ASU server that consumes these containers lives in [`asu-server`](../asu-server/).
