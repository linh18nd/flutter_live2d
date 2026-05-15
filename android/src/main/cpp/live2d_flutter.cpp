/**
 * JNI bridge between Flutter (Kotlin) and the Live2D Cubism SDK.
 *
 * Per-view design: every Live2DPlatformView on the Kotlin side calls
 * nativeCreateView() once to get an opaque jlong handle to a Live2DView
 * instance allocated on the heap here. All subsequent calls take that handle
 * so multiple views can coexist without sharing global mutable state.
 *
 * Kotlin class: com.linh18nd.flutter_live2d.Live2DBridge
 */

#include <jni.h>
#include <GLES2/gl2.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <CubismFramework.hpp>
#include <Math/CubismMatrix44.hpp>
#include <Math/CubismViewMatrix.hpp>
#include <Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp>

#include "Live2DAllocator.hpp"
#include "Live2DPal.hpp"
#include "Live2DTextureManager.hpp"
#include "Live2DModel.hpp"

using namespace Csm;

// ---------------------------------------------------------------------------
// Per-view state. Lives behind an opaque jlong handle on the Kotlin side.
// ---------------------------------------------------------------------------
struct Live2DView
{
    Live2DTextureManager* textureManager = nullptr;
    Live2DModel*          model           = nullptr;
    int                   width           = 0;
    int                   height          = 0;
    bool                  surfaceNeedsInit = false;
    CubismMatrix44        projection;
};

static inline Live2DView* AsView(jlong handle)
{
    return reinterpret_cast<Live2DView*>(static_cast<intptr_t>(handle));
}

// ---------------------------------------------------------------------------
// Framework lifecycle (refcounted across views)
// ---------------------------------------------------------------------------
static Live2DAllocator         g_allocator;
static CubismFramework::Option g_options;
static int                     g_frameworkRefCount = 0;

static void LogFunction(const char* /*message*/) {}

static void FrameworkRetain()
{
    if (g_frameworkRefCount++ == 0)
    {
        g_options.LogFunction          = LogFunction;
        g_options.LoggingLevel         = CubismFramework::Option::LogLevel_Verbose;
        g_options.LoadFileFunction     = Live2DPal::LoadFileAsBytes;
        g_options.ReleaseBytesFunction = Live2DPal::ReleaseBytes;

        CubismFramework::StartUp(&g_allocator, &g_options);
        CubismFramework::Initialize();
    }
}

static void FrameworkRelease()
{
    if (--g_frameworkRefCount <= 0)
    {
        g_frameworkRefCount = 0;
        CubismFramework::Dispose();
    }
}

static void ConfigureRendererForStability(Live2DModel* model)
{
    if (!model) return;
    auto* renderer =
        model->GetRenderer<Live2D::Cubism::Framework::Rendering::CubismRenderer_OpenGLES2>();
    if (!renderer) return;

    // High-precision mask becomes unstable under repeated surface lifecycle /
    // resize in this Flutter PlatformView setup. Force normal mask path.
    renderer->UseHighPrecisionMask(false);
}

static bool ReloadModelInternal(Live2DView* view, const char* dir, const char* file)
{
    if (!view || !dir || !file) return false;
    if (view->width <= 0 || view->height <= 0) return false;
    if (!view->textureManager) view->textureManager = new Live2DTextureManager();

    delete view->model;
    view->model = new Live2DModel(view->textureManager);
    view->model->LoadAssets(dir, file);
    if (!view->model->IsLoaded())
    {
        delete view->model;
        view->model = nullptr;
        return false;
    }

    view->model->CreateRenderer(view->width, view->height);
    ConfigureRendererForStability(view->model);
    view->model->SetupTextures();
    if (view->width > view->height)
        view->model->GetModelMatrix()->SetHeight(2.0f);
    else
        view->model->GetModelMatrix()->SetWidth(2.0f);

    return true;
}

extern "C" {

// ---------------------------------------------------------------------------
// JNI: global setup
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetAssetManager(JNIEnv* env, jclass,
    jobject assetManager)
{
    AAssetManager* mgr = AAssetManager_fromJava(env, assetManager);
    Live2DPal::SetAssetManager(mgr);
}

// ---------------------------------------------------------------------------
// JNI: per-view lifecycle
// ---------------------------------------------------------------------------

JNIEXPORT jlong JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeCreateView(JNIEnv*, jclass)
{
    FrameworkRetain();
    Live2DView* view = new Live2DView();
    return static_cast<jlong>(reinterpret_cast<intptr_t>(view));
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeDestroyView(JNIEnv*, jclass, jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    delete view->model;
    if (view->textureManager) view->textureManager->ReleaseTextures();
    delete view->textureManager;
    delete view;

    FrameworkRelease();
}

// ---------------------------------------------------------------------------
// JNI: GL surface callbacks
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnSurfaceCreated(JNIEnv*, jclass,
    jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    view->surfaceNeedsInit = true;

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // GL textures and renderer are tied to the old context which is now gone.
    // Drop them so they get recreated on the next loadModel.
    delete view->model;
    view->model = nullptr;
    if (view->textureManager) view->textureManager->ReleaseTextures();
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnSurfaceDestroyed(JNIEnv*, jclass,
    jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    delete view->model;
    view->model = nullptr;
    if (view->textureManager) view->textureManager->ReleaseTextures();

    view->surfaceNeedsInit = false;
    view->width = 0;
    view->height = 0;
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnSurfaceChanged(JNIEnv*, jclass,
    jlong handle, jint width, jint height)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    view->width = width;
    view->height = height;
    glViewport(0, 0, view->width, view->height);

    view->projection.LoadIdentity();
    if (view->width > view->height)
    {
        float ratio = static_cast<float>(view->height) / static_cast<float>(view->width);
        view->projection.Scale(ratio, 1.0f);
    }
    else
    {
        float ratio = static_cast<float>(view->width) / static_cast<float>(view->height);
        view->projection.Scale(1.0f, ratio);
    }

    if (view->surfaceNeedsInit)
    {
        view->surfaceNeedsInit = false;
        return;
    }

    if (view->model && view->model->IsLoaded())
    {
        if (view->width > view->height)
            view->model->GetModelMatrix()->SetHeight(2.0f);
        else
            view->model->GetModelMatrix()->SetWidth(2.0f);
    }
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnDrawFrame(JNIEnv*, jclass, jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    Live2DPal::UpdateTime();

    glViewport(0, 0, view->width, view->height);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    if (view->model && view->model->IsLoaded())
    {
        view->model->Update();
        CubismMatrix44 mvp = view->projection;
        view->model->Draw(mvp);
    }
}

// ---------------------------------------------------------------------------
// JNI: model
// ---------------------------------------------------------------------------

JNIEXPORT jboolean JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeLoadModel(JNIEnv* env, jclass,
    jlong handle, jstring modelDir, jstring modelFileName)
{
    Live2DView* view = AsView(handle);
    if (!view) return JNI_FALSE;

    const char* dir  = env->GetStringUTFChars(modelDir,      nullptr);
    const char* file = env->GetStringUTFChars(modelFileName, nullptr);

    bool ok = false;
    if (view->width > 0 && view->height > 0)
    {
        ok = ReloadModelInternal(view, dir, file);
    }

    env->ReleaseStringUTFChars(modelDir,      dir);
    env->ReleaseStringUTFChars(modelFileName, file);

    return (ok && view->model && view->model->IsLoaded()) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeUnloadModel(JNIEnv*, jclass, jlong handle)
{
    Live2DView* view = AsView(handle);
    if (!view) return;

    delete view->model;
    view->model = nullptr;
    if (view->textureManager) view->textureManager->ReleaseTextures();
}

// ---------------------------------------------------------------------------
// JNI: touch events
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnTouchBegan(JNIEnv*, jclass, jlong handle,
    jfloat x, jfloat y)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || view->width <= 0 || view->height <= 0) return;
    view->model->SetDragging(
        (2.0f * x / view->width  - 1.0f),
        -(2.0f * y / view->height - 1.0f));
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnTouchMoved(JNIEnv*, jclass, jlong handle,
    jfloat x, jfloat y)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || view->width <= 0 || view->height <= 0) return;
    view->model->SetDragging(
        (2.0f * x / view->width  - 1.0f),
        -(2.0f * y / view->height - 1.0f));
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeOnTouchEnded(JNIEnv*, jclass, jlong handle,
    jfloat, jfloat)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model) return;
    view->model->SetDragging(0.0f, 0.0f);
}

// ---------------------------------------------------------------------------
// JNI: motion / expression / parameter
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeStartMotion(JNIEnv* env, jclass, jlong handle,
    jstring group, jint index, jint priority)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || !view->model->IsLoaded()) return;
    const char* g = env->GetStringUTFChars(group, nullptr);
    view->model->StartMotion(g, index, priority);
    env->ReleaseStringUTFChars(group, g);
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetExpression(JNIEnv*, jclass, jlong handle,
    jint index)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || !view->model->IsLoaded()) return;
    view->model->SetExpression(index);
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetParameter(JNIEnv* env, jclass, jlong handle,
    jstring parameterId, jfloat value)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model || !view->model->IsLoaded()) return;
    const char* id = env->GetStringUTFChars(parameterId, nullptr);
    view->model->SetParameterValue(id, value);
    env->ReleaseStringUTFChars(parameterId, id);
}

JNIEXPORT void JNICALL
Java_com_linh18nd_flutter_1live2d_Live2DBridge_nativeSetMotionSpeed(JNIEnv*, jclass, jlong handle,
    jfloat speed)
{
    Live2DView* view = AsView(handle);
    if (!view || !view->model) return;
    view->model->SetMotionSpeed(speed);
}

} // extern "C"
