# Releasing the Android app

A release is a git tag. Pushing `v0.1.0` makes
[`.github/workflows/release.yml`](../.github/workflows/release.yml) build the
app, sign it with the upload key, and publish a GitHub release carrying the APK
and the changelog for that version.

## Cutting a release

1. **Write the changelog.** Move the entries under `## [Unreleased]` in
   [`CHANGELOG.md`](../CHANGELOG.md) into a new `## [x.y.z] - YYYY-MM-DD`
   section, and add the link references at the bottom. The workflow reads this
   section and publishes it as the release notes, so it refuses to build a
   version that has no section — a release nobody can read the changes of is
   only half published.

2. **Match the version in `android_app/pubspec.yaml`** so local builds agree
   with the tag. The workflow overrides both halves from the tag anyway, but a
   pubspec that says something else is a trap for the next person.

3. **Tag and push.**

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. **Watch it.** `gh run watch` or the Actions tab. It analyzes, tests, builds,
   verifies the signature, then publishes.

To rehearse without publishing, run the workflow by hand from the Actions tab
("Run workflow" → version). It builds and signs identically and leaves the
results as workflow artifacts, publishing nothing.

## What comes out

| Asset | What it is |
| --- | --- |
| `BatteryHolder-<version>.apk` | Installed directly on a phone. The release notes link straight to it. |
| `BatteryHolder-<version>.aab` | The Play Console upload. Not installable by hand. |
| `SHA256SUMS.txt` | Checksums for both. |

`versionCode` is derived from the version as `major×10000 + minor×100 + patch`
(0.1.0 → 100). It rises with every release and never depends on a run counter
that resets when a workflow is renamed — which matters because Play remembers
every code it has ever seen and will not take one twice.

## The upload key

Google Play identifies the app by the key it is signed with, for as long as the
app exists. Lose it and there is no way to update the published app; leak it and
someone else can publish as us. It therefore lives **outside this repository**,
and `.gitignore` refuses `*.jks`, `*.keystore` and `key.properties` at both the
root and inside `android_app/`.

```
C:\Users\HoangAnh\Documents\BatteryHolder-keys\
  batteryholder-upload.jks    the key
  key.properties              its passwords and alias — the master copy
```

`android_app/android/key.properties` is a copy of that file, pointing at the
same absolute path. Gradle reads it and signs release builds with the upload
key; without it, a release build falls back to the debug key so a fresh clone
still builds something installable on a bench phone.

| Property | Value |
| --- | --- |
| Alias | `upload` |
| Algorithm | RSA 2048, SHA384withRSA |
| Valid until | 2056-08-16 |

Back the folder up somewhere that is not this laptop. Play requires a key valid
past 2033, and this one is good for thirty years — the realistic way to lose the
app is a dead disk, not an expired certificate.

## CI secrets

The workflow rebuilds the same `key.properties` from three repository secrets
(Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `KEYSTORE_BASE64` | `batteryholder-upload.jks`, base64-encoded |
| `KEYSTORE_PASSWORD` | `storePassword` from `key.properties` |
| `KEY_PASSWORD` | `keyPassword` from `key.properties` |

The alias is `KEY_ALIAS` in the workflow's own `env`, not a secret. Actions
masks every secret value wherever it appears in a log, so an alias of `upload`
would black out that word in every ordinary sentence that used it — including
the release notes echoed into the build log.

To set them again from the key folder:

```sh
KEYDIR="/c/Users/HoangAnh/Documents/BatteryHolder-keys"
base64 -w0 "$KEYDIR/batteryholder-upload.jks" | gh secret set KEYSTORE_BASE64
grep '^storePassword=' "$KEYDIR/key.properties" | cut -d= -f2- | tr -d '\r\n' | gh secret set KEYSTORE_PASSWORD
grep '^keyPassword=' "$KEYDIR/key.properties" | cut -d= -f2- | tr -d '\r\n' | gh secret set KEY_PASSWORD
```

The build fails loudly if `KEYSTORE_BASE64` is missing, and again if the APK
comes out signed by `CN=Android Debug` — a debug-signed release installs happily
and can then never be updated from Play, which is the kind of mistake that is
only visible much too late.

## Publishing to Play

The workflow stops at the GitHub release; uploading to the Play Console is
manual. Take the `.aab` from the release assets and upload it there. The key it
is signed with is the one Play will expect from every future upload.

## Note on the debug-signed builds already installed

Bench phones running a build from before this workflow existed have a
debug-signed APK on them. Android refuses to replace a package with one signed
by a different key, so `adb install -r` fails with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Uninstall first:

```sh
adb -s <device> uninstall store.lyhoanganh.battery_holder
```

This costs the beacon log and the per-board alert settings on that phone. It is
a one-time cost — every build from here on is signed with the same upload key.
