package gh.com.waecplatform.waecdirect

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth:
// the AndroidX biometric prompt must be hosted in a fragment activity with an
// AppCompat-derived theme (see res/values[(-night)]/styles.xml).
class MainActivity : FlutterFragmentActivity()
