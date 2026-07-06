import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing credentials live outside the repo (../waylo-keys/) and are
// referenced via a gitignored keystore.properties — never hardcode secrets here.
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties()
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.waylo"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.waylo"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (hasKeystoreProperties) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        // Pre-existing UI lint debt (unrelated to release signing) — baseline it
        // rather than fix it here so `./gradlew build` isn't blocked by it, while
        // still failing on any *new* lint errors this or future work introduces.
        baseline = file("lint-baseline.xml")
    }
}

dependencies {
    // AndroidX core
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.cardview:cardview:1.0.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.viewpager2:viewpager2:1.0.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    implementation("androidx.fragment:fragment-ktx:1.6.2")

    // ML Kit on-device text recognition (OCR fallback - Layer 2)
    implementation("com.google.android.gms:play-services-mlkit-text-recognition:19.0.0")

    // Retrofit for backend calls
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")

    // OkHttp (explicit 4.x for the Kotlin request/media-type extensions used by GeminiClient)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Kotlin Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")

    // Unit + instrumentation testing
    testImplementation("junit:junit:4.13.2")
    // Real org.json impl for JVM unit tests — the Android stub jar's JSONObject
    // throws on construction ("not mocked"), which PlanParser's catch-all would
    // otherwise silently swallow into a false-passing null result.
    testImplementation("org.json:json:20231013")
    // For mocking AccessibilityNodeInfo in the ElementFinder lookahead/partial-
    // match JVM tests (mirrors ElementFinderTest's existing androidTest usage;
    // Mockito 5's inline mock maker handles final Android framework classes
    // fine without needing the instrumented runtime).
    testImplementation("org.mockito:mockito-core:5.5.0")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:runner:1.5.2")
    androidTestImplementation("androidx.test:core:1.5.0")
    androidTestImplementation("org.mockito:mockito-core:5.5.0")
    androidTestImplementation("org.mockito:mockito-android:5.5.0")
}
