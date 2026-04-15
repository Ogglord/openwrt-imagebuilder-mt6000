# Package Repository Publishing Plan

## Problem

Devices running our custom firmware cannot install packages post-flash using the
pesa1234 package feeds. The packages in `pesa1234/MT6000_cust_build` are signed with
pesa1234's private key, but our firmware embeds the key generated at our build time —
so APK rejects those packages as untrusted.

The fix is to:
1. Build and sign packages with our own stable RSA keypair
2. Publish a package repository that devices can consume via APK
3. Embed our public key in the firmware image so APK trusts it on-device
4. Update the imagebuilder container to point to our repo instead of pesa1234's

---

## What We Learned About the APK Format

pesa1234's package repo structure (confirmed by inspecting
`2026-04-12_r34722-2fff68cf9a_next-r4.8.0.rss.mtk-test6.18`):

```
packages/
└── aarch64_cortex-a53/
    ├── sha256sums            ← integrity checksums for the whole arch tree
    ├── base/
    │   ├── *.apk             ← individual packages (~100+ files)
    │   ├── packages.adb      ← binary APK database with embedded signature
    │   └── index.json        ← JSON manifest used by ASU tooling (not by APK itself)
    ├── luci/                 ← same structure (~56 packages)
    ├── packages/             ← same structure (~74 packages)
    └── routing/              ← same structure (minimal, e.g. batctl-default)
```

Key facts:
- Packages are `.apk` format (Alpine-derived), **not** `.ipk`
- The APK package manager fetches `packages.adb` (binary), **not** `Packages`/`Packages.gz`
- **No separate `.sig` files** — the signature is embedded inside `packages.adb`
- `index.json` maps `{ "packages": { "pkgname": "version" } }` — used by ASU, not APK
- Public keys live in `/etc/apk/keys/` on the device (not `/etc/opkg/keys/`)
- No `repositories.conf` — APK reads `/etc/apk/repositories` on the device
- **No post-build re-signing needed**: if we inject our RSA key before `make`, OpenWrt's
  build system signs all `.apk` files and `packages.adb` indexes with our key automatically.
  The output in `bin/packages/` is ready to publish as-is.

---

## Signing Key

**Same key for every build.** The public key is baked into firmware once. Rotating
keys would break trust on every already-flashed device. Only rotate if compromised.

### One-Time Key Generation (do this locally, never in CI)

```bash
# Requires openssl
openssl genrsa -out pesabuilder-signing.rsa 2048
openssl rsa -in pesabuilder-signing.rsa -pubout -out pesabuilder-signing.rsa.pub

# Verify
openssl rsa -in pesabuilder-signing.rsa -check -noout
```

### Store in GitHub

Go to repo Settings → Secrets and variables → Actions:

| Secret name              | Value                                           |
|--------------------------|-------------------------------------------------|
| `PACKAGE_SIGNING_KEY`    | Full content of `pesabuilder-signing.rsa`       |
| `PACKAGE_SIGNING_KEY_PUB`| Full content of `pesabuilder-signing.rsa.pub`   |

Also commit the public key to the repo (it is not sensitive):
```
keys/pesabuilder-signing.rsa.pub
```

---

## Package Hosting Strategy

**Use the `releases` branch** (already exists, used for `branches.json`).

Packages are pushed to `packages/{tag}/{arch}/{feed}/` on the `releases` branch and
served via `raw.githubusercontent.com`. This gives opkg-compatible URL structure:

```
https://raw.githubusercontent.com/ogglord/openwrt-imagebuilder-mt6000/releases/
  packages/
    mediatek-filogic-next-r4.8.0.rss.mtk-test6.18/
      aarch64_cortex-a53/
        base/
          *.apk
          packages.adb
          index.json
        luci/  ...
        packages/  ...
        routing/  ...
        sha256sums
```

The APK feed URL for the device becomes:
```
https://raw.githubusercontent.com/ogglord/openwrt-imagebuilder-mt6000/releases/packages/mediatek-filogic-{branch}/aarch64_cortex-a53/{feed}
```

**GitHub Releases** also receives a `packages-{tag}.tar.gz` tarball as a release asset
for discoverability and manual download.

**Repository size management**: The `releases` branch accumulates binary `.apk` files.
To keep it manageable, the publish step prunes package directories older than the 3
most recent tags. Estimated size per build: 150–300 MB. With 2 active branches and
pruning, steady-state is ~1 GB.

---

## Implementation: `build-imagebuilder.yml`

### Step 1 — New step: "Inject APK signing key"

Insert **after** "Download and apply config" and **before** "Pre-fetch linux-firmware".

```yaml
- name: Inject APK signing key
  working-directory: ${{ runner.temp }}/openwrt
  env:
    PACKAGE_SIGNING_KEY: ${{ secrets.PACKAGE_SIGNING_KEY }}
    PACKAGE_SIGNING_KEY_PUB: ${{ secrets.PACKAGE_SIGNING_KEY_PUB }}
  run: |
    set -euo pipefail

    # Write RSA private key for build-time package signing
    printf '%s\n' "${PACKAGE_SIGNING_KEY}" > key-build.rsa
    chmod 600 key-build.rsa

    # Write public key
    printf '%s\n' "${PACKAGE_SIGNING_KEY_PUB}" > key-build.rsa.pub

    # Embed public key in firmware rootfs so APK trusts our packages on-device
    # APK looks for trusted keys in /etc/apk/keys/ by filename
    mkdir -p files/etc/apk/keys
    cp key-build.rsa.pub files/etc/apk/keys/pesabuilder-signing.rsa.pub

    echo "Signing key injected, public key embedded in firmware at files/etc/apk/keys/"
```

> **Note**: Verify where OpenWrt's APK build system expects the RSA signing key. It may
> need a specific filename or location in the source tree. Check
> `scripts/apk-sign.sh` or similar in the pesa1234/openwrt source.
> The usign key (key-build / key-build.pub at the source root) may still be needed
> for imagebuilder signing even in APK builds — investigate before removing it.

### Step 2 — Modify: "Extract imagebuilder tarball"

**Remove** the `rm -rf ${{ runner.temp }}/openwrt` line from this step.
It moves to a dedicated cleanup step after package collection (packages are still needed).

### Step 3 — New step: "Collect and stage packages"

Insert **after** "Extract imagebuilder tarball".

Since we inject our signing key before `make`, the build output in `bin/packages/`
is already signed with our key. No re-signing needed — just copy the tree as-is.

```yaml
- name: Collect and stage packages
  run: |
    set -euo pipefail
    OPENWRT="${{ runner.temp }}/openwrt"
    ARCH="aarch64_cortex-a53"
    STAGING="${{ runner.temp }}/pkg-staging/${ARCH}"

    mkdir -p "${STAGING}"

    # Copy feed packages as-is (already signed with our key by `make`)
    for FEED_DIR in "${OPENWRT}/bin/packages/${ARCH}"/*/; do
      FEED=$(basename "${FEED_DIR}")
      DEST="${STAGING}/${FEED}"
      mkdir -p "${DEST}"
      cp "${FEED_DIR}"*.apk "${DEST}/" 2>/dev/null || true
      cp "${FEED_DIR}"packages.adb "${DEST}/" 2>/dev/null || true
      cp "${FEED_DIR}"index.json "${DEST}/" 2>/dev/null || true
    done

    # Collect target packages (kmods)
    TARGET_PKGS="${OPENWRT}/bin/targets/mediatek/filogic/packages"
    if [ -d "${TARGET_PKGS}" ]; then
      DEST="${STAGING}/kmods"
      mkdir -p "${DEST}"
      cp "${TARGET_PKGS}"/*.apk "${DEST}/" 2>/dev/null || true
      cp "${TARGET_PKGS}"/packages.adb "${DEST}/" 2>/dev/null || true
      cp "${TARGET_PKGS}"/index.json "${DEST}/" 2>/dev/null || true
    fi

    # Generate sha256sums across the whole arch tree
    (cd "${{ runner.temp }}/pkg-staging/${ARCH}" && \
      find . -name '*.apk' -o -name 'packages.adb' -o -name 'index.json' | \
      sort | xargs sha256sum > sha256sums)

    echo "Total packages: $(find "${STAGING}" -name '*.apk' | wc -l)"

    # Bundle for artifact handoff to containerize job
    tar -czf "$GITHUB_WORKSPACE/packages-staging.tar.gz" \
      -C "${{ runner.temp }}/pkg-staging" .

- name: Upload packages artifact
  uses: actions/upload-artifact@v4
  with:
    name: packages-staging
    path: packages-staging.tar.gz
    retention-days: 1

- name: Cleanup openwrt build dir
  run: rm -rf ${{ runner.temp }}/openwrt
```

---

## Implementation: `containerize` job

### Step 4 — New step: "Download packages artifact"

Add **before** "Set up Docker Buildx":

```yaml
- name: Download packages artifact
  uses: actions/download-artifact@v4
  with:
    name: packages-staging
```

### Step 5 — New step: "Publish packages to releases branch"

Add **after** "Download packages artifact":

```yaml
- name: Publish packages to releases branch
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    set -euo pipefail
    TAG="mediatek-filogic-${{ needs.discover.outputs.branch }}"

    # Extract staged packages
    mkdir -p /tmp/pkg-staging
    tar -xzf packages-staging.tar.gz -C /tmp/pkg-staging

    # Shallow clone of releases branch
    git clone --depth=1 --branch=releases \
      "https://x-access-token:${GH_TOKEN}@github.com/${{ github.repository }}.git" \
      /tmp/releases-branch

    # Replace packages for this tag (idempotent on re-run)
    rm -rf "/tmp/releases-branch/packages/${TAG}"
    mkdir -p "/tmp/releases-branch/packages/${TAG}"
    cp -a /tmp/pkg-staging/. "/tmp/releases-branch/packages/${TAG}/"

    # Prune: keep only the 3 most recent package tag directories
    cd /tmp/releases-branch/packages
    ls -t | tail -n +4 | xargs -r rm -rf

    cd /tmp/releases-branch
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add packages/
    git diff --cached --quiet && echo "No package changes" && exit 0
    git commit -m "ci: publish packages for ${TAG}"

    # Retry push in case of concurrent runs
    for i in 1 2 3; do
      git push origin releases && break
      echo "Push failed (attempt $i), retrying..."
      sleep 10
      git pull --rebase origin releases
    done
```

### Step 6 — Modify: "Build and push" step

Add `build-args` to pass the package base URL into the Containerfile:

```yaml
- name: Build and push (${{ needs.discover.outputs.branch }})
  uses: docker/build-push-action@v6
  with:
    context: .
    file: ./Containerfile
    push: true
    build-args: |
      PACKAGES_BASE_URL=https://raw.githubusercontent.com/${{ github.repository }}/releases/packages/mediatek-filogic-${{ needs.discover.outputs.branch }}/aarch64_cortex-a53
    tags: |
      ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:mediatek-filogic-${{ needs.discover.outputs.branch }}
      ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:mediatek-filogic-openwrt-${{ needs.discover.outputs.branch }}
```

### Step 7 — Modify: "Create release" step

Upload the packages tarball as a release asset:

```yaml
- name: Create release to record built commit
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    TAG="mediatek-filogic-${{ needs.discover.outputs.branch }}"
    gh release delete "${TAG}" --cleanup-tag -y --repo "${{ github.repository }}" 2>/dev/null || true
    gh release create "${TAG}" \
      --repo "${{ github.repository }}" \
      --title "ImageBuilder: ${{ needs.discover.outputs.branch }}" \
      --notes "**Branch:** ${{ needs.discover.outputs.branch }}
    **Commit:** ${{ needs.discover.outputs.commit_sha }}
    **Image:** \`${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${TAG}\`
    **Packages:** \`https://raw.githubusercontent.com/${{ github.repository }}/releases/packages/${TAG}/\`" \
      packages-staging.tar.gz
```

---

## Implementation: `Containerfile`

Add an `ARG` and `RUN` block to patch the APK repositories file inside the imagebuilder,
so that firmware built by ASU uses our package feed:

```dockerfile
# After the existing RUN block that patches mbedtls → openssl:

ARG PACKAGES_BASE_URL=""
RUN if [ -n "${PACKAGES_BASE_URL}" ]; then \
      # Patch /builder/etc/apk/repositories to point to our signed package feed.
      # The {feedname} placeholder is substituted by the imagebuilder at build time.
      REPOS_FILE="/builder/etc/apk/repositories"; \
      if [ -f "${REPOS_FILE}" ]; then \
        sed -i "s|https://raw.githubusercontent.com/pesa1234/MT6000_cust_build[^ ]*/packages/[^ ]*|${PACKAGES_BASE_URL}/{feedname}|g" \
          "${REPOS_FILE}" && \
        echo "Patched ${REPOS_FILE}"; \
        cat "${REPOS_FILE}"; \
      else \
        echo "WARNING: ${REPOS_FILE} not found — check imagebuilder tarball structure"; \
        find /builder -name "repositories" | head -20; \
      fi; \
    fi
```

> **TODO**: Confirm the actual path to the APK repositories config inside the
> imagebuilder tarball. Possibilities:
> - `/builder/etc/apk/repositories`
> - `/builder/repositories`
> - somewhere under `/builder/target/`
>
> To find it: extract the imagebuilder tarball locally and run:
> `find . -name "repositories" | head -20`
> or look at `/builder/.config` for `CONFIG_APK_*` entries.

---

## Implementation: `publish-branches.yml`

In the "Build branch entry JSON" step, change `path_packages` from pesa1234's path
to our `releases` branch URL:

```yaml
- name: Build branch entry JSON
  run: |
    BRANCH_KEY="${{ matrix.branch_key }}"
    BUILD_PATH="${{ steps.resolve.outputs.build_path }}"
    TAG="mediatek-filogic-${BRANCH_KEY}"
    PACKAGES_BASE="https://raw.githubusercontent.com/${{ github.repository }}/releases/packages/${TAG}/aarch64_cortex-a53"
    NAME=$(echo "$BRANCH_KEY" | sed 's/^next-//' | sed 's/\.rss\.mtk//')

    jq -n \
      --arg key "$BRANCH_KEY" \
      --arg name "$NAME" \
      --arg path "$BUILD_PATH" \
      --arg pkgs_base "${PACKAGES_BASE}" \
      '{
        ($key): {
          name: $name,
          enabled: true,
          path: $path,
          path_packages: ($pkgs_base + "/{feedname}"),
          updates: "dev",
          package_changes: [],
          targets: {"mediatek/filogic": $key}
        },
        "SNAPSHOT": {
          name: $name,
          enabled: true,
          path: $path,
          path_packages: ($pkgs_base + "/{feedname}"),
          updates: "dev",
          package_changes: [],
          targets: {"mediatek/filogic": $key}
        }
      }' > entry.json
```

---

## Open Questions / TODOs Before Implementing

1. **Where does OpenWrt's APK build system expect the RSA signing key?**
   Search the pesa1234/openwrt source for `key-build.rsa`, `apk sign`, or similar
   to find where the key is loaded during `make`. It may need to be placed at a specific
   path or referenced via a `.config` option.

2. **APK repositories file location inside the imagebuilder.**
   Extract a recent imagebuilder tarball and find where APK feed URLs are stored:
   ```bash
   tar -xf openwrt-imagebuilder-*.tar.zst
   find . -name "repositories" -o -name "*.conf" | xargs grep -l "raw.githubusercontent" 2>/dev/null
   ```

3. **Does the imagebuilder still need a usign `key-build` / `key-build.pub` pair?**
   The imagebuilder itself (used by ASU to build firmware images) may still sign
   its output with usign even if the package manager is APK. Investigate whether
   both key types are needed in the build step.

---

## Workflow Sequence After Changes

```
build job:
  1. Clone, feeds update, patch Makefile          [existing]
  2. Download and apply config                    [existing]
  3. Inject APK signing key + embed pubkey        [NEW]
  4. Pre-fetch linux-firmware                     [existing]
  5. Download package sources                     [existing]
  6. Build OpenWrt (make)                         [existing]
  7. Extract imagebuilder tarball                 [existing, rm -rf removed]
  8. Collect packages (already signed by make)    [NEW]
  9. Upload packages-staging artifact             [NEW]
  10. Cleanup openwrt dir (rm -rf)               [MOVED from step 7]

containerize job:
  1. Checkout + download imagebuilder artifact    [existing]
  2. Download packages-staging artifact           [NEW]
  3. Publish packages to releases branch          [NEW]
  4. Setup Docker Buildx + GHCR login             [existing]
  5. Build and push image (with PACKAGES_BASE_URL)[MODIFIED]
  6. Create GitHub release + attach tarball       [MODIFIED]

publish-branches.yml:
  - path_packages now points to our releases branch [MODIFIED]
```

---

## End State

- Devices trust our signing key (embedded at `/etc/apk/keys/pesabuilder-signing.rsa.pub`)
- `apk update && apk add <package>` works post-flash using our feed
- ASU-built firmware images also point to our feed via the patched imagebuilder
- Packages tarball attached to every GitHub Release for manual download
- `releases` branch hosts the live APK feed under `packages/`
- `branches.json` `path_packages` points to our feed, not pesa1234's
