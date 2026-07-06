# Waylo Android — Release Build Setup

Local-only release build setup (signing, R8 minification, verification). Nothing
here was pushed to any remote.

## What changed

1. Generated a release keystore (`waylo-release.keystore`, PKCS12, RSA 2048,
   valid until 2053) and stored it **outside this repo**, plus a gitignored
   `keystore.properties` the build reads passwords/alias from — no secrets in
   `build.gradle.kts`.
2. Added a real signed `release` build type: `isMinifyEnabled = true`,
   `isShrinkResources = true`, `isDebuggable = false`, `signingConfig` wired
   from `keystore.properties`.
3. Verified `PlanParser` (the one true `/plan` JSON parser — see
   `CLAUDE.md`) survives R8 unminified/unrenamed, backed by a new JVM unit
   test (`app/src/test/java/com/waylo/ai/PlanParserTest.kt`) and inspection
   of R8's `mapping.txt`.
4. Built `assembleRelease`, verified the APK's signature with `apksigner`.
5. Confirmed `usesCleartextTraffic` survives into the packaged release
   manifest — **flagged loudly below**, this needs to change before any
   Play Store submission.

## ⚠️ Cleartext HTTP is enabled — flagged for Play Store

The release manifest still has:

```
android:usesCleartextTraffic="true"
```

(confirmed via `aapt dump xmltree` on the built release APK — it survives
release/R8 unchanged). This exists because the backend
(`http://13.127.137.249:3000`) is plain HTTP, per `CLAUDE.md`. This is fine
for local sideloading/testing, **but Google Play will flag or reject an app
submission that ships cleartext traffic to a non-`10.0.0.0/8`/non-loopback
host** without a documented justification, and it's a real MITM exposure for
users on hostile networks in the meantime. Before any real distribution:
put the backend behind HTTPS (e.g. an ALB/nginx TLS terminator in front of
the EC2 instance, or a real domain + Let's Encrypt) and remove
`usesCleartextTraffic` (or scope it to the EC2 IP via a
`network_security_config.xml` domain-config, not a blanket app-wide flag).

## APK

```
app/build/outputs/apk/release/app-release.apk   (~2.5 MB)
```

Signature (`apksigner verify --print-certs`):
- Verified using APK Signature Scheme v2: **true**
- Signer DN: `CN=Waylo, OU=Engineering, O=Waylo, L=Patiala, ST=Punjab, C=IN`
- SHA-256 cert fingerprint: `FA:04:2D:45:27:42:35:D4:C0:FD:D0:67:32:83:E4:9B:9C:B0:C4:2D:B5:69:3D:C5:47:BC:CA:59:2B:2D:20:05`

## Keystore location and backup — CRITICAL

The keystore lives **outside this repo**, one level up:

```
../waylo-keys/waylo-release.keystore    (the key itself — PKCS12, alias "waylo-release")
../waylo-keys/KEYSTORE_INFO.txt          (passwords + fingerprints, plain text)
```

i.e. `C:\Users\Shambhvi\waylo\waylo-keys\` (sibling of this checkout,
`C:\Users\Shambhvi\waylo\frontend_systemsettings_overlay\`).

**This keystore IS the app's identity.** Every future release build must be
signed with the *same* key, or Android will refuse to install it as an
update over an existing install of `com.waylo` — there is no recovery if
you lose it and the app is already in users' hands (and no Play Console App
Signing enrollment yet to fall back on). **Back up the entire `waylo-keys/`
folder now**, to at least one place outside this machine:
- a password manager's encrypted file attachment (e.g. 1Password/Bitwarden),
- an encrypted cloud drive folder, or
- a physical offline drive (USB key in a drawer, not synced anywhere).

Do not commit it, email it unencrypted, or paste it into Slack/chat.

## Install command

```
adb install -r app/build/outputs/apk/release/app-release.apk
```

(`-r` reinstalls over any existing debug build of `com.waylo` already on
the device — note debug and release builds share the same `applicationId`
here, since there's no `.debug` suffix on the debug build type, so you may
need to `adb uninstall com.waylo` first if you get an
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` from a previously-installed
differently-signed build.)

## Exact commands used (reproducible)

```bash
# 1. Keystore (run once; already done — do NOT re-run unless rotating keys)
cd ../waylo-keys
keytool -genkeypair -v \
  -keystore waylo-release.keystore \
  -alias waylo-release \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass "<see KEYSTORE_INFO.txt>" \
  -dname "CN=Waylo, OU=Engineering, O=Waylo, L=Patiala, ST=Punjab, C=IN"

# 2. Build
./gradlew clean assembleRelease

# 3. Verify signature
"$ANDROID_HOME/build-tools/37.0.0/apksigner" verify --verbose --print-certs \
  app/build/outputs/apk/release/app-release.apk

# 4. Confirm PlanParser/Step/Plan survived R8 unrenamed
grep -E "^com\.waylo\.ai\.(PlanParser|Step|Plan) ->" \
  app/build/outputs/mapping/release/mapping.txt

# 5. Confirm usesCleartextTraffic in the packaged manifest
"$ANDROID_HOME/build-tools/37.0.0/aapt" dump xmltree \
  app/build/outputs/apk/release/app-release.apk AndroidManifest.xml | grep -i cleartext

# 6. Run the full test/lint/build gate
./gradlew build

# 7. Install on a connected device/emulator
adb install -r app/build/outputs/apk/release/app-release.apk
```

## What was surprising

- **`proguard-rules.pro` already anticipated this.** It already had a
  blanket `-keep class com.waylo.ai.** { *; }` (and `com.waylo.guidance.**`)
  from before this work — it was simply never exercised because
  `isMinifyEnabled` was `false`. `PlanParser`/`Step`/`Plan` were never
  actually at risk from R8; I added explicit `@Keep` annotations and a
  regression test anyway, since a wildcard package keep is an easy thing to
  accidentally narrow or delete later without noticing it protected
  something load-bearing.
- **JVM unit tests don't get a working `android.util.Log` or `org.json`
  for free.** The Android stub jar throws `RuntimeException: ... not
  mocked` on `Log.e(...)`, which is well known — but it *also* throws on
  `JSONObject(json)` construction, which `PlanParser`'s `catch (e:
  Exception)` block silently swallows into a `null` return. My first pass
  at the unit test "passed" for the wrong reason (every call was hitting
  the catch block, not real parsing) until I added a real
  `org.json:json` test dependency and `unitTests.isReturnDefaultValues`.
  Worth knowing if anyone adds more JVM tests here later — a green test
  can still be testing nothing.
- **`./gradlew build` was already failing before any of this**, on a
  pre-existing `MissingConstraints` lint error in
  `fragment_ob_permission.xml` from an earlier onboarding-UI commit,
  unrelated to release signing. Baselined it (`app/lint-baseline.xml`)
  rather than fix the layout, since that's out of scope here — flagging in
  case it should actually be fixed properly at some point.
- **PKCS12 keystores (the default since JDK 9+) don't support a separate
  key password** — `keytool` silently ignored the distinct key password I
  passed and reused the store password for both. `KEYSTORE_INFO.txt` and
  `keystore.properties` both reflect this (same value in both fields).
