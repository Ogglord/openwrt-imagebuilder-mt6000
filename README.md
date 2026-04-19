# OpenWrt ImageBuilder — GL.iNet Flint 2 (MT6000)

Builds an OpenWrt ImageBuilder container from [pesa1234/openwrt](https://github.com/pesa1234/openwrt), targeting exclusively `mediatek/filogic` / `glinet_gl-mt6000`. The container is consumed by [Ogglord/asu](https://github.com/Ogglord/asu) to assemble custom firmware on demand.

**What this produces:** a slim OCI container (`ghcr.io/ogglord/openwrt-imagebuilder`) where `make image PROFILE=glinet_gl-mt6000` reproduces pesa's full firmware (LuCI, kmods, openssl variants) without specifying any `PACKAGES=`.

## How it works

1. Weekly CI enumerates release dirs in [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) (`YYYY-MM-DD_r{rev}-{sha}_{branch}`), picks the latest, resolves the short SHA to a full commit on `pesa1234/openwrt`.
2. Skips if that commit was already built (GH Release body tracks it).
3. Does a depth-1 fetch of that exact commit, pulls `config.buildinfo` as `.config`, appends `CONFIG_IB=y CONFIG_IB_STANDALONE=y`, applies patches, runs `make world`.
4. Downloads pesa's `.manifest` → `firmware-packages.txt`. The Containerfile appends it to `DEFAULT_PACKAGES` in the tarball — no `PACKAGES=` argument needed at `make image` time.
5. Pushes container to GHCR, creates a GH Release, regenerates `branches.json` on the `releases` branch.

## Naming conventions

Given pesa branch `next-r4.8.0.rss.mtk`:

| Thing | Value |
|---|---|
| Firmware version string | `4.8-SNAPSHOT` |
| ASU branch key | `4.8` |
| Pesa-branch container tag | `mediatek-filogic-next-r4.8.0.rss.mtk` |
| ASU-resolved container tag | `mediatek-filogic-openwrt-4.8` |
| Metadata path on `releases` branch | `4.8-SNAPSHOT/` |

**Derivation:**
```
next-r4.8.0.rss.mtk
  → strip next-r, take first 2 parts   → 4.8          (ASU branch key)
  → append -SNAPSHOT                   → 4.8-SNAPSHOT  (firmware version)
  → strip -SNAPSHOT, prepend openwrt-  → openwrt-4.8   (container tag suffix)
```

ASU receives `4.8-SNAPSHOT` from the router, derives `openwrt-4.8`, pulls `ghcr.io/ogglord/openwrt-imagebuilder:mediatek-filogic-openwrt-4.8`.

Test branches (containing `-test`) are built but not published to ASU.

## Patches applied before `make world`

| Patch | What it does |
|---|---|
| `001-openssl-packages` | Replaces `wpad-basic-mbedtls`, `libustream-mbedtls`, `apk-mbedtls` with openssl variants — pesa builds these, upstream defaults don't |
| `002-feeds-strip-release-dir` | Strips pesa's `$(DATE)_$(VERSION_CODE)_$(BRANCH)/` path segment from `include/feeds.mk` so feed URLs resolve to our `releases` branch layout |
| `003-ib-standalone-apk-fallback` | Removes `CONFIG_IB_STANDALONE` guards on `repositories` generation and `--repositories-file` flag — keeps pesa's packages in the tarball while enabling upstream-snapshot fallback for extras (nano, git, …) |

## Local build

```bash
./build-local.sh [branch]       # full IB build, default next-r4.8.0.rss.mtk-test6.18
./debug-package.sh <pkg-path>   # single package with V=s, cached layers to defconfig
```

Logs in `./logs/`. Build failures are auto-diagnosed via `claude`.

## Required secrets

| Secret | Purpose |
|---|---|
| `HEALTHCHECK_BUILD_UUID` | healthchecks.io ping on build start/success/failure |
| `PACKAGE_SIGNING_KEY` | RSA private key for APK package signing |
| `PACKAGE_SIGNING_KEY_PUB` | Matching public key — embedded in firmware at `/etc/apk/keys/` |

## Related repos

| Repo | Purpose |
|---|---|
| [Ogglord/asu](https://github.com/Ogglord/asu) | ASU server that uses these containers |
| [Ogglord/asu-deploy](https://github.com/Ogglord/asu-deploy) | Deployment config (compose, deploy scripts) |
| [pesa1234/openwrt](https://github.com/pesa1234/openwrt) | Source fork we build from |
| [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build) | Release dirs with `.config` and `.manifest` |
