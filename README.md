# OpenWrt ImageBuilder — GL.iNet Flint 2 (MT6000)

Builds an OpenWrt ImageBuilder container from [pesa1234/openwrt](https://github.com/pesa1234/openwrt), targeting exclusively `Flint2 (MT6000)`. The container is consumed by https://sysupgrade.ogglord.com to assemble custom firmware on demand.

**What this produces:** a container (`ghcr.io/ogglord/openwrt-imagebuilder`) where `make image PROFILE=glinet_gl-mt6000` reproduces pesa's full firmware (LuCI, kmods, openssl variants) similar to what is publised on [pesa1234/MT6000_cust_build](https://github.com/pesa1234/MT6000_cust_build).

## How to use it

Install owut

```bash
cat /etc/config/attendedsysupgrade
config server 'server'
        option url 'https://sysupgrade.ogglord.com'
```

use `owut` like normal. `owut` is a bit picky about package version deviations. A recommended firmare upgrade procedure is

```bash
owut versions
owut check -V 4.8.0
owut download -V 4.8.0
owut verify
owut install
```

## Naming conventions

Given branch `next-r4.8.0.rss.mtk`:

| Thing | Value |
|---|---|
| Firmware version string | `4.8.0` |
| Sysupgrade branch key | `4.8` |
| Container tags | `mediatek-filogic-next-r4.8.0.rss.mtk`, `mediatek-filogic-v4.8.0` |
| Metadata path on `releases` branch | `4.8.0/` |


## Patches applied to openwrt source

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
