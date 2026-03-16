# The Auth Bug From Hell: Post-Mortem & Fix Guide

## The Symphony of Errors
For 4 months, a persistent authentication bug forced users to log in on *every single app launch*. The core issue was not a simple code logic failure, but a perfect storm of package renaming, native Android security architecture, and Google's automatic cloud backup system.

When the application package name was changed from `com.example.truebalanceclient` to `com.levelyouup.truebalanceathome`, the following chain reaction occurred:

1. **The Mismatch**: The Android app ran under the new package name, but the underlying configuration files still referenced the old one. This created an identity crisis when Firebase attempted to generate secure storage keys.
2. **The Silent Keystore Crash**: Firebase Auth fetches a session token and encrypts it using Android's native Keystore / `SharedPreferences`. Because of the package ID mismatch, the hardware Keystore refused to encrypt the token. Firebase silently fell back to `Persistence.NONE` (in-memory only), meaning the token died the second the app was closed.
3. **The Final Boss (Auto-Backup)**: When the configuration *was* finally corrected, the bug persisted anyway. **Why?** Because Android's OS automatically backs up App Data to the user's personal Google Drive. When the app was re-downloaded or updated via Google Play, Android "helpfully" restored the old, corrupted, mismatched encrypted session file onto the phone. Firebase tried to decrypt this old file, failed, assumed the data was corrupt, and instantly wiped the current login session.

---

## How to Fix It (The Implementation Guide)

When fast-forwarding to the latest code branch, you must implement these exact four phases to ensure the bug remains dead.

### Phase 1: Unify All Package Identifiers
Your app's ID must be identical across Android, iOS, macOS, and Firebase.
1. **Android:** Ensure `android/app/build.gradle.kts` has exactly:
   `applicationId = "com.levelyouup.truebalanceathome"`.
2. **iOS & macOS:** Run these commands in the terminal to force the Apple platforms to match perfectly:
   ```bash
   dart pub global activate rename
   dart pub global run rename setAppName --targets ios,macos --value "True Balance At Home"
   dart pub global run rename setBundleId --targets ios,macos --value "com.levelyouup.truebalanceathome"
   ```

### Phase 2: Perfect the Firebase Link
The code must have the API keys tied specifically to the new package name.
1. **Firebase Console:** Ensure your `com.levelyouup.truebalanceathome` Android app has your local/release **SHA-1 fingerprints** added to it.
2. **Re-sync Configurations:** In the terminal, force FlutterFire to completely rewrite the files:
   ```bash
   dart pub global run flutterfire_cli:flutterfire configure -y --project true-balance-8dac7
   ```
   *(This permanently syncs `lib/firebase_options.dart` and `android/app/google-services.json` to the new package name).*

### Phase 3: The Android Auto-Backup Fix (The "Silver Bullet")
To stop Google Cloud from permanently re-injecting the corrupted local storage states onto users' phones during Google Play downloads, you must explicitly forbid it.

Open `android/app/src/main/AndroidManifest.xml` and add `allowBackup="false"` and `fullBackupContent="false"` to the `<application>` tag:

```xml
<application
    android:label="truebalanceclient"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:allowBackup="false"              <!-- ADD THIS -->
    android:fullBackupContent="false">       <!-- ADD THIS -->
```

### Phase 4: The Device Wipe Rule (Mandatory Testing Protocol)
Code cannot delete a corrupted Android Keystore file mathematically locked onto a physical phone's hard drive. 

Whenever testing this fix on a phone that previously exhibited the login loop:
1. **You MUST physically uninstall the app** completely from the Android device. Do not just hit "Update" in Google Play. Deleting the app is the *only* way to destroy the locked storage file.
2. Download the newly compiled App Bundle from Google Play.
3. Log in once. Android will generate a healthy, uncorrupted encryption key, and the session will now correctly survive every app restart.