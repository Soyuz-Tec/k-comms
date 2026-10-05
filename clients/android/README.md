# Android foreground client

This app uses the existing member HTTP/Phoenix APIs and current LiveKit admissions. Active human conversation-only accounts retain admitted conversations and calls. Directory, direct/group creation, meeting scheduling and Phone require explicit current workspace scope; absent or unknown scope grants none of those workspace features. Owner-confirmed role/scope changes update the existing login, while scope withdrawal clears workspace projections, stops phone media and fences pending workspace results without logging out an otherwise valid conversation owner. It supports sign-in/MFA, directory/direct/private groups, bounded chat replay and explicit idempotent retry, call history/audio/video, meeting scheduling, and assigned-line telephony. Credentials and pending messages are encrypted with Android Keystore in no-backup storage; platform rules exclude all app data from cloud backup and device transfer. Failed encrypted writes retain the previous idempotent command snapshot. SDK and WebRTC logging are explicitly disabled before LiveKit initialization. Changing account/device, signing out, admission/session expiry or foreground exit stops local media. Configuration changes keep the foreground owner.

Native push and incoming-call background wake are visibly unavailable. Calls require this app on screen; an expired media admission requires a fresh join. A submitted DTMF receipt does not establish carrier delivery. These source flows are not physical-device, provider, distribution or background-wake qualification.

Corporate OIDC sign-in and administrator step-up proof are unavailable. The UI supports the server's password sign-in and typed authenticator/recovery-code MFA challenge only.

## Pinned tools and SDKs

| Component | Pin |
| --- | --- |
| Gradle wrapper | 8.11.1 |
| Android Gradle Plugin | 8.10.1 |
| Kotlin / Compose compiler plugin | 2.1.21 |
| Compile / target SDK | 35 / 35 |
| Minimum SDK | 26 |
| Android build tools | 35.0.0 |
| JDK for CI / bytecode | 17 / 17 |
| LiveKit Android | 2.29.0 |
| AndroidX CoreTelecom | 1.0.0 |

The default cloud Java 21 installation is a JRE without `javac`. Actual Gradle validation uses the checksum-verified Temurin JDK 17.0.20.1+1 installed below; CI pins a full JDK 17. Reuse the existing checkout. Do not create a worktree for environment setup. Phoenix tickets use only the `x-k-comms-socket-ticket` upgrade header; the WebSocket URL contains only its protocol version.

LiveKit API/toolchain evidence comes from the [official v2.29.0 tag](https://github.com/livekit/client-sdk-android/tree/v2.29.0), [release toolchain pins](https://github.com/livekit/client-sdk-android/blob/v2.29.0/deps.gradle), and [published module metadata](https://repo.maven.apache.org/maven2/io/livekit/livekit-android/2.29.0/livekit-android-2.29.0.module). Its [installation instructions](https://github.com/livekit/client-sdk-android/blob/v2.29.0/README.md#installation) require JitPack for the pinned AudioSwitch Git commit; this project restricts that repository to `com.github.davidliu`. CoreTelecom APIs were inspected from [Google's published 1.0.0 source archive](https://dl.google.com/dl/android/maven2/androidx/core/core-telecom/1.0.0/core-telecom-1.0.0-sources.jar). TLS and checksum verification remain enabled.

## Cloud bootstrap

The prepared SDK lives at `/workspace/.toolchains/android-sdk`; Gradle 8.11.1 is also extracted at `/workspace/.toolchains/gradle/gradle-8.11.1`. The checked-in wrapper downloads and verifies its own distribution if its cache is empty. Use writable workspace caches and the exact working directory:

```bash
cd /workspace/k-comms-native-clients/clients/android
export JAVA_HOME=/workspace/.toolchains/temurin-jdk17/jdk-17.0.20.1+1
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME=/workspace/.toolchains/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME=/workspace/.toolchains/android-user
export GRADLE_USER_HOME=/workspace/.cache/k-comms-gradle
```

The installed JDK is from the [official Temurin release](https://github.com/adoptium/temurin17-binaries/releases/tag/jdk-17.0.20.1%2B1). The Linux x64 JDK archive SHA256 is `3808d1d15e3ec6bd5b84057fb5d84c33d8a1536a258146bcea2e603fc726e08e`, verified against its official `.sha256.txt` asset before extraction. Full source URLs/hash/install path are recorded in `/tmp/kcomms-jdk17-bootstrap-receipt.json`.

This cloud instance requires Java proxy properties for its unauthenticated environment proxy, with loopback bypass for synthetic TLS tests; Java does not automatically use `HTTPS_PROXY`. TLS remains enabled, using the operator-installed OS Java CA trust store. The current instance uses:

```bash
export GRADLE_OPTS="-Dhttp.proxyHost=proxy -Dhttp.proxyPort=8080 -Dhttps.proxyHost=proxy -Dhttps.proxyPort=8080 -Dhttp.nonProxyHosts=localhost|127.*|[::1] -Dhttps.nonProxyHosts=localhost|127.*|[::1] -Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts -Duser.home=/workspace/.toolchains/android-user"
```

Use the actual environment proxy on other hosts; do not copy this host name to ordinary CI.

For a fresh machine, fetch command-line tools 19.0 from [the official Linux archive](https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip). Its Google [repository manifest](https://dl.google.com/android/repository/repository2-3.xml) publishes SHA1 `5fdcc763663eefb86a5b8879697aa6088b041e70`. Verify that checksum before extracting into `$ANDROID_HOME/cmdline-tools/19.0`; this directory must contain `bin/sdkmanager`, not a second nested `cmdline-tools` folder. Android SDK licenses must be accepted by the authorized operator/setup flow before installation. Then install the published targets:

```bash
"$ANDROID_HOME/cmdline-tools/19.0/bin/sdkmanager" --sdk_root="$ANDROID_HOME" --licenses
"$ANDROID_HOME/cmdline-tools/19.0/bin/sdkmanager" --sdk_root="$ANDROID_HOME" \
  'platforms;android-35' 'build-tools;35.0.0' 'platform-tools'
test -f "$ANDROID_HOME/platforms/android-35/android.jar"
test -x "$ANDROID_HOME/build-tools/35.0.0/aapt2"
```

Current-instance setup completed those operations with successful exit status. Logs are `/tmp/kcomms-android-sdk-licenses.log` and `/tmp/kcomms-android-sdk-install.log`; they do not establish app build/runtime readiness.

The wrapper/distribution hashes verified during setup are:

- [Gradle 8.11.1 distribution](https://services.gradle.org/distributions/gradle-8.11.1-bin.zip): SHA256 `f397b287023acdba1e9f6fc5ea72d22dd63669d59ed4a289a29b1a76eee151c6`, pinned as `distributionSha256Sum`.
- [Official wrapper JAR](https://raw.githubusercontent.com/gradle/gradle/v8.11.1/gradle/wrapper/gradle-wrapper.jar): SHA256 `2db75c40782f5e8ba1fc278a5574bab070adccb2d21ca5a6e5ed840888448046`, matching [Gradle's published wrapper checksum](https://services.gradle.org/distributions/gradle-8.11.1-wrapper.jar.sha256).

## Validation and local launch

Required integrated gates, with bounded parallelism:

```bash
./gradlew --no-daemon --max-workers=2 \
  -Dorg.gradle.jvmargs="-Xmx2048m -XX:ActiveProcessorCount=2 -Dfile.encoding=UTF-8 -Duser.home=/workspace/.toolchains/android-user" \
  -Pkotlin.compiler.execution.strategy=in-process \
  testDebugUnitTest assembleDebug assembleRelease lintDebug
```

Debug APK: `app/build/outputs/apk/debug/app-debug.apk`. Release output is unsigned; operator-owned signing/distribution is separate. To exercise Android Keystore tamper/refusal on an authorized synthetic emulator/device:

```bash
./gradlew --no-daemon --max-workers=2 connectedDebugAndroidTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.soyuz.kcomms/.MainActivity
```

Use synthetic accounts and the actual HTTPS workspace origin; the app accepts no cleartext origin, bearer URL or credential Intent. Grant microphone/camera only through its explicit runtime prompts. Validate foreground exit, denied/revoked permissions, identity replacement, stale admission, Telecom audio routing, provider failures, incoming assigned-line answer and exact DTMF completion/reconciliation on physical devices before claiming those paths qualified.

The prior-source cloud gate completed successfully on JDK 17 before the authorized scope/role correction: `testDebugUnitTest`, `assembleDebug`, `assembleRelease` and `lintDebug`. All 37 JVM cases passed, with no failures, errors or skips. Lint reported zero errors and 15 nonblocking warnings: pinned dependency updates, a false positive for `stopService(Intent(...))`, SDK folder qualification/style suggestions, and an optional monochrome launcher icon. Backup/transfer declarations and the adaptive icon are included in the compiled APKs.

Prior-source receipts: `/tmp/kcomms-android-gradle-attempt-05.log`, `.exit.json`, `-artifacts.json`, and `-source.json`. Build input snapshot SHA256: `9b1bf7cbe47cfff10e5338292face1d310d65b9d6b5b6389a789b3058696f3df`. The official SDK `apksigner verify --verbose` returned the expected unsigned/no-certificate failure for the release APK; its output is retained in `-unsigned-verify.log`. Earlier attempts and their failures are preserved separately.

The final changed source contains 48 authored JVM cases across 10 suites, including 11 new scope/role/current-owner regressions. The prior 37-case build/APK receipts qualify only the earlier source snapshot. After this source-only correction, Kotlin grammar and XML parsing passed; no local Gradle compile, test or lint runner was authorized. Remote native CI must qualify the final changed source. The Keystore instrumentation case, actual device permission/audio/camera/Telecom/provider journeys, signing/distribution and background native wake remain unrun or unqualified. Native push and background call admission remain unavailable.
