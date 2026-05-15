#import "Live2DWrapper.h"

// Cubism SDK headers
#include <CubismFramework.hpp>
#include <Math/CubismMatrix44.hpp>
#include <ICubismAllocator.hpp>

#include <cstdlib>
#include <cstdio>
#include <cstdarg>
#include <algorithm>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>
#include <time.h>

#include <Type/CubismBasicType.hpp>
#include <Type/csmVector.hpp>
#include <Model/CubismUserModel.hpp>
#include <ICubismModelSetting.hpp>
#include <CubismModelSettingJson.hpp>
#include <Motion/CubismMotion.hpp>
#include <Effect/CubismEyeBlink.hpp>
#include <Physics/CubismPhysics.hpp>
#include <CubismDefaultParameterId.hpp>
#include <Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp>
#include <Utils/CubismString.hpp>
#include <Id/CubismIdManager.hpp>

#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <stdio.h>

// Prefer stderr so logs show in the terminal used by `flutter run` / VS Code
// `"console": "terminal"`. NSLog goes to unified logging and is often hidden
// from the Dart Debug Console.
#define L2D_LOG(fmt, ...)                                                                          \
    do {                                                                                         \
        NSString *__l2d_msg = [NSString stringWithFormat:@"" fmt, ##__VA_ARGS__];               \
        const char *__l2d_c = __l2d_msg.UTF8String;                                                \
        fprintf(stderr, "[FlutterLive2D] %s\n", __l2d_c ? __l2d_c : "");                         \
        fflush(stderr);                                                                          \
    } while (0)

using namespace Csm;
using namespace Live2D::Cubism::Framework;
using namespace Live2D::Cubism::Framework::DefaultParameterId;

static const int PriorityNone   = 0;
static const int PriorityIdle   = 1;
static const int PriorityNormal = 2;
static const int PriorityForce  = 3;

static BOOL Live2DCurrentFramebufferHasColorAttachment(void) {
    GLint name = 0;
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER,
                                          GL_COLOR_ATTACHMENT0,
                                          GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,
                                          &name);
    if (name == 0) return NO;
    // A renderbuffer object may exist (name != 0) but have zero storage if
    // renderbufferStorage:fromDrawable: failed because the CAEAGLLayer was not
    // connected to a window yet. Treat zero-storage renderbuffers as missing so
    // CreateRenderer is never given a dummy FBO — which would silently render
    // nothing and produce a black screen until the next loadModel call.
    GLint width = 0;
    glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)name);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    return width > 0;
}

// ---------------------------------------------------------------------------
// Allocator (one global is fine — it has no state)
// ---------------------------------------------------------------------------
class IOSAllocator : public ICubismAllocator {
public:
    void* Allocate(const csmSizeType size) override { return malloc(size); }
    void  Deallocate(void* p)              override { free(p); }
    void* AllocateAligned(const csmSizeType size, const csmUint32 alignment) override {
        size_t offset = alignment - 1 + sizeof(void*);
        void*  alloc  = malloc(size + (csmUint32)offset);
        size_t addr   = (size_t)alloc + sizeof(void*);
        size_t shift  = addr % alignment;
        if (shift) addr += (alignment - shift);
        ((void**)addr)[-1] = alloc;
        return (void*)addr;
    }
    void DeallocateAligned(void* p) override { free(((void**)p)[-1]); }
};

// ---------------------------------------------------------------------------
// PAL (file I/O) — stateless helpers
// ---------------------------------------------------------------------------
//
// The Cubism Framework calls back into us through the file loader registered
// in CubismFramework::Option for **two** kinds of paths:
//
//   1. Absolute filesystem paths — model assets that the Dart side has
//      extracted from Flutter's assets into the application Documents/Caches
//      directory. These are read with plain fopen.
//
//   2. Relative paths like "FrameworkShaders/VertShaderSrc.vert" — the
//      framework's own ES2 shader sources. Those ship as files inside the
//      plugin's CocoaPods resource bundle (see flutter_live2d.podspec ➜
//      `s.resource_bundles`). We resolve them by basename against the
//      bundle's resource path.
//
// The signature MUST match `csmLoadFileFunction` exactly because we hand the
// function pointer to CubismFramework::Option::LoadFileFunction.
static NSBundle* PluginResourceBundle() {
    static NSBundle* sBundle = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle* plugin = [NSBundle bundleForClass:[Live2DWrapper class]];
        // Plugin built as a framework → resource bundle is nested inside it.
        NSURL* url = [plugin URLForResource:@"flutter_live2d" withExtension:@"bundle"];
        if (url) {
            sBundle = [NSBundle bundleWithURL:url];
        } else {
            // Fallback: static build, resources live directly in the plugin
            // bundle (or the main bundle).
            sBundle = plugin;
        }
    });
    return sBundle;
}

static csmByte* ReadFileFromDisk(const char* path, csmSizeInt* outSize) {
    FILE* fp = fopen(path, "rb");
    if (!fp) { *outSize = 0; return nullptr; }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    rewind(fp);
    csmByte* buf = new csmByte[sz];
    fread(buf, 1, sz, fp);
    fclose(fp);
    *outSize = (csmSizeInt)sz;
    return buf;
}

// Signature must match Csm::csmLoadFileFunction (`const std::string`, by value).
static csmByte* LoadFile_Cubism(const std::string filePath, csmSizeInt* outSize) {
    *outSize = 0;
    if (filePath.empty()) return nullptr;

    // (1) Absolute path → direct file I/O.
    if (filePath[0] == '/') {
        return ReadFileFromDisk(filePath.c_str(), outSize);
    }

    // (2) Relative path → look up in the plugin's resource bundle by basename.
    NSString* rel = [NSString stringWithUTF8String:filePath.c_str()];
    NSString* base = [rel lastPathComponent];
    NSString* name = [base stringByDeletingPathExtension];
    NSString* ext  = [base pathExtension];
    NSBundle* rb = PluginResourceBundle();
    NSString* resolved = [rb pathForResource:name ofType:ext];
    if (!resolved) return nullptr;

    return ReadFileFromDisk(resolved.UTF8String, outSize);
}

static void ReleaseBytes_Cubism(csmByte* buf) { delete[] buf; }

// Convenience wrapper used by IOSModel internally — most callers pass
// std::string and we don't want to make implicit copies inside hot paths.
static csmByte* LoadFileAsBytes(const std::string& path, csmSizeInt* outSize) {
    return LoadFile_Cubism(path, outSize);
}
static void ReleaseBytes(csmByte* buf) { ReleaseBytes_Cubism(buf); }

// Per-frame delta time. Read by IOSModel::Update; written from -onDrawFrame.
// Live2D frames are coalesced to wall clock so a single global is fine even
// Per-instance frame timing — declared here so IOSModel::Update can reference
// the forward declaration. The actual storage lives in Live2DWrapper ivars;
// see @implementation Live2DWrapper below.
static void LogFn(const csmChar* msg) { NSLog(@"[Live2D] %s", msg); }

// ---------------------------------------------------------------------------
// Texture info — owned per-wrapper because GL texture ids are per-context.
// ---------------------------------------------------------------------------
struct TextureInfo { GLuint id; int w; int h; std::string file; };

// ---------------------------------------------------------------------------
// Motion cache key — must match how we index files in warmMotionFileCache()
// and in StartMotion (group name + motion index within that group).
// ---------------------------------------------------------------------------
static std::string IOSMotionCacheKey(const csmChar* group, csmInt32 idx) {
    const char* g = (group && group[0]) ? group : "";
    return std::string(g) + "_" + std::to_string(static_cast<int>(idx));
}

// ---------------------------------------------------------------------------
// IOSModel — the actual Cubism model wrapper. Texture loading is delegated
// to a callback so the same model class can stay agnostic of where textures
// are cached.
// ---------------------------------------------------------------------------
class IOSModel : public CubismUserModel {
public:
    using TextureLoader = std::function<TextureInfo*(const std::string&)>;

    IOSModel(TextureLoader loader)
        : CubismUserModel()
        , _modelSetting(nullptr)
        , _userTime(0)
        , _textureLoader(std::move(loader))
    {
        _idAngleX     = CubismFramework::GetIdManager()->GetId(ParamAngleX);
        _idAngleY     = CubismFramework::GetIdManager()->GetId(ParamAngleY);
        _idAngleZ     = CubismFramework::GetIdManager()->GetId(ParamAngleZ);
        _idBodyAngleX = CubismFramework::GetIdManager()->GetId(ParamBodyAngleX);
    }
    ~IOSModel() {
        for (auto it = _motions.Begin(); it != _motions.End(); ++it)
            ACubismMotion::Delete(it->Second);
        for (auto it = _exprs.Begin();   it != _exprs.End();   ++it)
            ACubismMotion::Delete(it->Second);
        delete _modelSetting;
    }

    bool Load(const char* dir, const char* fileName) {
        _homeDir = dir;
        csmSizeInt sz;
        csmString path = csmString(dir) + fileName;
        csmByte* buf = LoadFileAsBytes(path.GetRawString(), &sz);
        if (!buf) return false;
        auto* setting = new CubismModelSettingJson(buf, sz);
        ReleaseBytes(buf);
        _modelSetting = setting;
        Setup();
        return true;
    }

    void SetMotionSpeed(csmFloat32 speed) {
        _motionSpeed = (speed > 0.0f) ? speed : 0.0f;
    }

    void Update(csmFloat32 dt) {
        _userTime += dt;
        _dragManager->Update(dt);
        const csmFloat32 dragX = _dragManager->GetX();
        const csmFloat32 dragY = _dragManager->GetY();

        // Scale dt for motion playback only; physics/eyeblink use unscaled dt.
        const csmFloat32 motionDt = dt * _motionSpeed;
        _model->LoadParameters();
        if (_motionManager->IsFinished()) StartMotion("Idle", 0, PriorityIdle);
        else _motionManager->UpdateMotion(_model, motionDt);
        _model->SaveParameters();

        _model->AddParameterValue(_idAngleX,     dragX * 30.0f);
        _model->AddParameterValue(_idAngleY,     dragY * 30.0f);
        _model->AddParameterValue(_idAngleZ,     dragX * dragY * -30.0f);
        _model->AddParameterValue(_idBodyAngleX, dragX * 10.0f);

        if (_eyeBlink)          _eyeBlink->UpdateParameters(_model, dt);
        if (_expressionManager) _expressionManager->UpdateMotion(_model, dt);
        if (_physics)           _physics->Evaluate(_model, dt);
        if (_pose)              _pose->UpdateParameters(_model, dt);
        _model->Update();
    }

    void Draw(CubismMatrix44& mvp) {
        if (!_model) return;
        mvp.MultiplyByMatrix(_modelMatrix);
        GetRenderer<Rendering::CubismRenderer_OpenGLES2>()->SetMvpMatrix(&mvp);
        GetRenderer<Rendering::CubismRenderer_OpenGLES2>()->DrawModel();
    }

    void StartMotion(const csmChar* group, csmInt32 idx, csmInt32 priority) {
        if (!_modelSetting) return;
        if (idx >= _modelSetting->GetMotionCount(group)) return;

        CubismMotion* m = nullptr;
        const std::string key = IOSMotionCacheKey(group, idx);
        const auto cached = _motionFileCache.find(key);
        if (cached != _motionFileCache.end() && !cached->second.empty()) {
            const std::vector<unsigned char>& bytes = cached->second;
            m = static_cast<CubismMotion*>(
                LoadMotion(const_cast<csmByte*>(bytes.data()),
                           static_cast<csmSizeInt>(bytes.size()),
                           nullptr));
        } else {
            csmString path = csmString(_homeDir.c_str()) + _modelSetting->GetMotionFileName(group, idx);
            csmSizeInt sz;
            csmByte* buf = LoadFileAsBytes(path.GetRawString(), &sz);
            if (!buf) return;
            m = static_cast<CubismMotion*>(LoadMotion(buf, sz, nullptr));
            ReleaseBytes(buf);
        }
        if (!m) return;

        csmFloat32 fi = _modelSetting->GetMotionFadeInTimeValue(group, idx);
        csmFloat32 fo = _modelSetting->GetMotionFadeOutTimeValue(group, idx);
        if (fi >= 0) m->SetFadeInTime(fi);
        if (fo >= 0) m->SetFadeOutTime(fo);
        // Loop the Idle motion so it never "finishes" and never triggers
        // another StartMotion call with its JSON re-parse. Other groups
        // (user-triggered motions) play once and hand back to Idle.
        const bool isIdle = (group && strcmp(group, "Idle") == 0);
        if (isIdle) {
            m->SetLoop(true);
            m->SetLoopFadeIn(false);
        }
        // `true` = queue entry deletes motion when playback ends (matches typical
        // Cubism samples). `false` leaked one ACubismMotion per tap and kept
        // disk+parse on the render thread — very visible on heavy models (Ren).
        _motionManager->StartMotionPriority(m, true, priority);
    }

    void SetExpr(csmInt32 idx) {
        if (!_modelSetting || idx < 0 || idx >= _modelSetting->GetExpressionCount()) return;
        const csmChar* name = _modelSetting->GetExpressionName(idx);
        if (_exprs.IsExist(name))
            _expressionManager->StartMotion(_exprs[name], false);
    }

    void SetParam(const csmChar* id, csmFloat32 val) {
        _model->SetParameterValue(CubismFramework::GetIdManager()->GetId(id), val);
    }

    bool IsLoaded() const { return _modelSetting != nullptr; }

    /// Upload textures to the GL renderer. Must be called AFTER
    /// CreateRenderer() because BindTexture lives on the renderer.
    void SetupTextures() {
        auto* renderer = GetRenderer<Rendering::CubismRenderer_OpenGLES2>();
        if (!renderer) return;
        for (csmInt32 i = 0; i < _modelSetting->GetTextureCount(); i++) {
            if (!*_modelSetting->GetTextureFileName(i)) continue;
            csmString p = csmString(_homeDir.c_str()) + _modelSetting->GetTextureFileName(i);
            TextureInfo* ti = _textureLoader(p.GetRawString());
            if (ti) renderer->BindTexture(i, ti->id);
        }
        renderer->IsPremultipliedAlpha(false);
    }

protected:
    csmByte* CreateBuffer(const csmChar* p, csmSizeInt* sz)
        { return LoadFileAsBytes(p, sz); }
    void DeleteBuffer(csmByte* buf, const csmChar* = "")
        { ReleaseBytes(buf); }

private:
    void Setup() {
        _updating = true; _initialized = false;
        { csmSizeInt sz; csmString p = csmString(_homeDir.c_str()) + _modelSetting->GetModelFileName();
          csmByte* b = CreateBuffer(p.GetRawString(), &sz); LoadModel(b, sz); DeleteBuffer(b); }
        for (csmInt32 i = 0; i < _modelSetting->GetExpressionCount(); i++) {
            const csmChar* n = _modelSetting->GetExpressionName(i);
            csmString p = csmString(_homeDir.c_str()) + _modelSetting->GetExpressionFileName(i);
            csmSizeInt sz; csmByte* b = CreateBuffer(p.GetRawString(), &sz);
            _exprs[n] = LoadExpression(b, sz, n); DeleteBuffer(b);
        }
        if (*_modelSetting->GetPhysicsFileName()) {
            csmString p = csmString(_homeDir.c_str()) + _modelSetting->GetPhysicsFileName();
            csmSizeInt sz; csmByte* b = CreateBuffer(p.GetRawString(), &sz);
            LoadPhysics(b, sz); DeleteBuffer(b);
            if (_physics) {
                // Initial stabilization: analytically settles each physics group
                // to its equilibrium position from the model's current parameters.
                _physics->Stabilization(_model);

                // Warm-up: simulate 60 frames (2 s at 30 fps) in zero real time.
                // Stabilization settles groups in isolation; groups that have
                // inputs from other groups' outputs (e.g. hair chains where
                // group N feeds group N+1) need several Evaluate passes to fully
                // converge. Without this, complex chains arrive at a visibly
                // wrong pose and snap to the correct one over the first few
                // rendered frames.
                const csmFloat32 warmDt = 1.0f / 30.0f;
                for (int i = 0; i < 60; i++) {
                    _physics->Evaluate(_model, warmDt);
                }
                // Re-stabilize after warm-up to lock in the converged pose.
                _physics->Stabilization(_model);
            }
        }
        if (*_modelSetting->GetPoseFileName()) {
            csmString p = csmString(_homeDir.c_str()) + _modelSetting->GetPoseFileName();
            csmSizeInt sz; csmByte* b = CreateBuffer(p.GetRawString(), &sz);
            LoadPose(b, sz); DeleteBuffer(b);
        }
        if (_modelSetting->GetEyeBlinkParameterCount() > 0)
            _eyeBlink = CubismEyeBlink::Create(_modelSetting);
        warmMotionFileCache();
        // Note: SetupTextures() is called externally AFTER CreateRenderer().
        _updating = false; _initialized = true;
    }

    /// Read every motion file once into RAM so StartMotion() avoids repeated
    /// disk I/O on the render thread (large .motion3.json e.g. Ren was
    /// stalling GL for a full frame each button tap).
    void warmMotionFileCache() {
        _motionFileCache.clear();
        if (!_modelSetting) return;
        for (csmInt32 gi = 0; gi < _modelSetting->GetMotionGroupCount(); gi++) {
            const csmChar* g = _modelSetting->GetMotionGroupName(gi);
            if (!g) g = "";
            const csmInt32 n = _modelSetting->GetMotionCount(g);
            for (csmInt32 i = 0; i < n; i++) {
                csmString path =
                    csmString(_homeDir.c_str()) + _modelSetting->GetMotionFileName(g, i);
                csmSizeInt sz = 0;
                csmByte* raw = LoadFileAsBytes(path.GetRawString(), &sz);
                if (!raw || sz <= 0) continue;
                std::string key = IOSMotionCacheKey(g, i);
                auto& slot = _motionFileCache[key];
                slot.assign(raw, raw + sz);
                ReleaseBytes(raw);
            }
        }
    }

    ICubismModelSetting*               _modelSetting;
    std::string                        _homeDir;
    csmFloat32                         _userTime;
    csmFloat32                         _motionSpeed = 1.0f;
    csmMap<csmString, ACubismMotion*>  _motions;
    csmMap<csmString, ACubismMotion*>  _exprs;
    const CubismId*                    _idAngleX;
    const CubismId*                    _idAngleY;
    const CubismId*                    _idAngleZ;
    const CubismId*                    _idBodyAngleX;
    TextureLoader                      _textureLoader;
    std::unordered_map<std::string, std::vector<unsigned char>> _motionFileCache;
};

// ---------------------------------------------------------------------------
// Framework lifecycle (refcounted across multiple wrapper instances)
// ---------------------------------------------------------------------------
static IOSAllocator           g_allocator;
static CubismFramework::Option g_opts;
static int                    g_frameworkRefCount = 0;

static void FrameworkRetain() {
    if (g_frameworkRefCount++ == 0) {
        g_opts.LogFunction         = LogFn;
        g_opts.LoggingLevel        = CubismFramework::Option::LogLevel_Verbose;
        // Required so Cubism's OpenGL ES2 renderer can pull its shader
        // sources off disk on first use; without this the framework logs
        // "[CSM][E]File loader is not set." and rendering silently fails.
        g_opts.LoadFileFunction    = &LoadFile_Cubism;
        g_opts.ReleaseBytesFunction = &ReleaseBytes_Cubism;
        CubismFramework::StartUp(&g_allocator, &g_opts);
        CubismFramework::Initialize();
        NSLog(@"[Live2D] Framework initialized");
    }
}

static void FrameworkRelease() {
    if (--g_frameworkRefCount <= 0) {
        g_frameworkRefCount = 0;
        CubismFramework::Dispose();
        NSLog(@"[Live2D] Framework disposed");
    }
}

// ---------------------------------------------------------------------------
// PNG → GL: downscale when atlas exceeds GL_MAX_TEXTURE_SIZE
// ---------------------------------------------------------------------------
//
// Some models (e.g. IceGirl) ship 8192² atlases. Many iOS GPUs cap at 4096
// for GL_TEXTURE_2D; oversize uploads fail and the model renders black.
// Box-filter down by half until both dimensions fit.

static bool DownscaleRgbaHalfBox(unsigned char*& px, int& w, int& h) {
    const int nw = std::max(1, (w + 1) / 2);
    const int nh = std::max(1, (h + 1) / 2);
    unsigned char* dst = (unsigned char*)malloc((size_t)nw * nh * 4);
    if (!dst) return false;
    for (int y = 0; y < nh; y++) {
        const int sy0 = std::min(y * 2, h - 1);
        const int sy1 = std::min(sy0 + 1, h - 1);
        for (int x = 0; x < nw; x++) {
            const int sx0 = std::min(x * 2, w - 1);
            const int sx1 = std::min(sx0 + 1, w - 1);
            unsigned acc[4] = {0, 0, 0, 0};
            int count = 0;
            for (int sy : {sy0, sy1}) {
                for (int sx : {sx0, sx1}) {
                    const unsigned char* p = px + (sy * w + sx) * 4;
                    for (int c = 0; c < 4; c++) acc[c] += p[c];
                    count++;
                }
            }
            unsigned char* out = dst + (y * nw + x) * 4;
            for (int c = 0; c < 4; c++) out[c] = (unsigned char)(acc[c] / (unsigned)count);
        }
    }
    stbi_image_free(px);
    px = dst;
    w = nw;
    h = nh;
    return true;
}

// ---------------------------------------------------------------------------
// ObjC wrapper implementation
// ---------------------------------------------------------------------------
@implementation Live2DWrapper {
    IOSModel*                  _model;
    int                        _width;
    int                        _height;
    CubismMatrix44             _proj;
    std::vector<TextureInfo*>  _textures;
    BOOL                       _retainedFramework;
    BOOL                       _pendingGLRenderer;
    BOOL                       _loggedInstallFboDefer;

    // Per-instance frame timing.
    // Using globals broke multi-view: both views called UpdateTime() ~60×/s,
    // making each individual dt ~8 ms instead of 16.67 ms (half speed).
    // Loading a second model also reset the timer, snapping the first model.
    double _lastFrame;
    double _deltaTime;
    double _smoothedDt;
}

- (void)resetFrameTimer {
    _lastFrame  = 0.0;
    _deltaTime  = 0.0;
    _smoothedDt = 1.0 / 60.0;
}

/// EMA-smoothed frame duration. Raw GCD dispatch latency varies ±2–3 ms/frame;
/// smoothing prevents micro-stutter on models with dense motion curves / physics.
- (void)updateTime {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec + ts.tv_nsec * 1e-9;
    if (_lastFrame == 0.0) {
        _smoothedDt = 1.0 / 60.0;
        _deltaTime  = 0.0;
    } else {
        double raw = now - _lastFrame;
        if (raw > 1.0 / 10.0) raw = 1.0 / 10.0;   // cap at 100 ms
        const double kAlpha = 0.1;
        _smoothedDt = kAlpha * raw + (1.0 - kAlpha) * _smoothedDt;
        _deltaTime  = _smoothedDt;
    }
    _lastFrame = now;
}

- (instancetype)init {
    if ((self = [super init])) {
        _model = nullptr;
        _width = 0;
        _height = 0;
        _retainedFramework = NO;
        _pendingGLRenderer = NO;
        _loggedInstallFboDefer = NO;
        [self resetFrameTimer];
        FrameworkRetain();
        _retainedFramework = YES;
    }
    return self;
}

- (void)dealloc {
    if (_model) {
        delete _model;
        _model = nullptr;
    }
    [self releaseAllTextures];
    if (_retainedFramework) {
        _retainedFramework = NO;
        FrameworkRelease();
    }
}

- (void)dispose {
    if (_model) {
        delete _model;
        _model = nullptr;
    }
    [self releaseAllTextures];
    if (_retainedFramework) {
        _retainedFramework = NO;
        FrameworkRelease();
    }
}

- (void)onSurfaceCreated {
    glClearColor(0, 0, 0, 0);
    [self releaseAllTextures];
    // The renderer is (re)created in -loadModel: once the view has been
    // sized; the GLKView lifecycle on iOS doesn't recreate the underlying
    // GL surface mid-life, so there's nothing to do here.
}

- (void)onSurfaceChangedWidth:(int)w height:(int)h {
    glViewport(0, 0, w, h);
    _width = w; _height = h;
    _proj.LoadIdentity();
    if (w > h) _proj.Scale((float)h / w, 1.0f);
    else        _proj.Scale(1.0f, (float)w / h);

    // First `loadModel` often runs before Flutter has laid out the view
    // (_width/_height were 0). Defer CreateRenderer until we have real
    // pixel dimensions — avoids a 1024² mask/FB mismatch that showed as
    // black until a second load.
    if (_pendingGLRenderer && _model && _model->IsLoaded() && w > 0 && h > 0) {
        [self installRendererAndTexturesWithWidth:w height:h];
    }

    if (_model && _model->IsLoaded() && w > 0 && h > 0) {
        if (_model->GetRenderer<Rendering::CubismRenderer_OpenGLES2>()) {
            if (w > h) _model->GetModelMatrix()->SetHeight(2.0f);
            else       _model->GetModelMatrix()->SetWidth(2.0f);
        }
    }
}

- (void)onDrawFrame {
    [self updateTime];
    if (_width > 0 && _height > 0) glViewport(0, 0, _width, _height);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    if (_model && _model->IsLoaded() &&
        _model->GetRenderer<Rendering::CubismRenderer_OpenGLES2>()) {
        _model->Update((csmFloat32)_deltaTime);
        CubismMatrix44 mvp = _proj;
        _model->Draw(mvp);
    }
}

/// Creates the Cubism GL renderer + uploads textures. Caller must have a
/// current GL context and a valid GLKView drawable (`bindDrawable`).
- (void)installRendererAndTexturesWithWidth:(int)w height:(int)h {
    if (!_model || !_model->IsLoaded() || w <= 0 || h <= 0) return;
    // CreateRenderer snapshots the current default FBO. If bindDrawable was
    // too early (common right after hot restart / platform view swap),
    // we would cache a missing color buffer and stay black until reload.
    if (!Live2DCurrentFramebufferHasColorAttachment()) {
        if (!_loggedInstallFboDefer) {
            _loggedInstallFboDefer = YES;
            L2D_LOG("installRenderer DEFERRED (no color attachment on default FBO) %dx%d — will retry when drawable is ready",
                    w, h);
        }
        _pendingGLRenderer = YES;
        return;
    }
    if (_model->GetRenderer<Rendering::CubismRenderer_OpenGLES2>()) {
        _model->DeleteRenderer();
    }
    _model->CreateRenderer((csmUint32)w, (csmUint32)h);
    if (auto* r = _model->GetRenderer<Rendering::CubismRenderer_OpenGLES2>()) {
        r->UseHighPrecisionMask(false);
    }
    _model->SetupTextures();
    if (w > h) _model->GetModelMatrix()->SetHeight(2.0f);
    else       _model->GetModelMatrix()->SetWidth(2.0f);
    _pendingGLRenderer = NO;
    _loggedInstallFboDefer = NO;
}

- (void)tryCompletePendingRendererInstall {
    if (!_pendingGLRenderer || !_model || !_model->IsLoaded()) return;
    if (_width <= 0 || _height <= 0) return;
    [self installRendererAndTexturesWithWidth:_width height:_height];
}

- (void)onFramebufferColorAttachmentMissing {
    if (!_model || !_model->IsLoaded()) return;
    if (!_model->GetRenderer<Rendering::CubismRenderer_OpenGLES2>()) return;
    _model->DeleteRenderer();
    if (_width > 0 && _height > 0) {
        _pendingGLRenderer = YES;
    }
}

- (BOOL)loadModelWithDir:(NSString *)modelDir fileName:(NSString *)fileName {
    if (_model) { delete _model; _model = nullptr; }
    [self releaseAllTextures];
    _pendingGLRenderer = NO;
    _loggedInstallFboDefer = NO;
    // Reset the global frame timer so the first onDrawFrame after this load
    // gets dt=0 instead of a potentially large stale delta (e.g. after a long
    // black-screen period). Without this, physics models with Fps=60 (Ren)
    // can snap/stutter on the first rendered frame.
    [self resetFrameTimer];

    __weak Live2DWrapper* weakSelf = self;
    _model = new IOSModel([weakSelf](const std::string& path) -> TextureInfo* {
        Live2DWrapper* strongSelf = weakSelf;
        if (!strongSelf) return nullptr;
        return [strongSelf createTextureWithPath:path];
    });

    bool ok = _model->Load(modelDir.UTF8String, fileName.UTF8String);
    if (ok) {
        if (_width > 0 && _height > 0) {
            [self installRendererAndTexturesWithWidth:_width height:_height];
        } else {
            _pendingGLRenderer = YES;
        }
    } else {
        delete _model;
        _model = nullptr;
    }
    return ok;
}

- (void)unloadModel {
    _pendingGLRenderer = NO;
    if (_model) {
        delete _model;
        _model = nullptr;
    }
    [self releaseAllTextures];
}

- (void)touchBeganAtX:(float)x y:(float)y {
    if (_model && _width > 0 && _height > 0) {
        _model->SetDragging(
            2.0f * x / _width - 1.0f,
            -(2.0f * y / _height - 1.0f));
    }
}
- (void)touchMovedAtX:(float)x y:(float)y {
    if (_model && _width > 0 && _height > 0) {
        _model->SetDragging(
            2.0f * x / _width - 1.0f,
            -(2.0f * y / _height - 1.0f));
    }
}
- (void)touchEndedAtX:(float)x y:(float)y {
    if (_model) _model->SetDragging(0, 0);
}

- (void)startMotionGroup:(NSString *)group index:(int)idx priority:(int)prio {
    if (_model && _model->IsLoaded())
        _model->StartMotion(group.UTF8String, idx, prio);
}

- (void)setExpressionAtIndex:(int)idx {
    if (_model && _model->IsLoaded()) _model->SetExpr(idx);
}

- (void)setParameterWithId:(NSString *)pid value:(float)val {
    if (_model && _model->IsLoaded()) _model->SetParam(pid.UTF8String, val);
}

- (void)setMotionSpeed:(float)speed {
    if (_model) _model->SetMotionSpeed(speed);
}

// ---------------------------------------------------------------------------
// Per-instance texture cache
// ---------------------------------------------------------------------------
- (TextureInfo*)createTextureWithPath:(const std::string&)path {
    for (size_t i = 0; i < _textures.size(); i++) {
        if (_textures[i]->file == path) return _textures[i];
    }
    csmSizeInt sz;
    unsigned char* raw = LoadFileAsBytes(path, &sz);
    if (!raw) return nullptr;
    int w, h, ch;
    unsigned char* px = stbi_load_from_memory(raw, (int)sz, &w, &h, &ch, STBI_rgb_alpha);
    ReleaseBytes(raw);
    if (!px) return nullptr;

    GLint maxTex = 4096;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTex);
    if (maxTex < 64) maxTex = 4096;
    int origW = w, origH = h;
    while (w > maxTex || h > maxTex) {
        if (!DownscaleRgbaHalfBox(px, w, h)) {
            stbi_image_free(px);
            NSLog(@"[Live2D] Out of memory downscaling texture: %s", path.c_str());
            return nullptr;
        }
    }
    if (w != origW || h != origH) {
        NSLog(@"[Live2D] Downscaled atlas to fit GL_MAX_TEXTURE_SIZE=%d: %s → %dx%d (was %dx%d)",
              (int)maxTex, path.c_str(), w, h, origW, origH);
    }

    // Clear any stale GL errors accumulated before this point so they aren't
    // falsely attributed to glTexImage2D below.
    { GLenum _e; while ((_e = glGetError()) != GL_NO_ERROR) { (void)_e; } }

    GLuint tid;
    glGenTextures(1, &tid);
    glBindTexture(GL_TEXTURE_2D, tid);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        NSLog(@"[Live2D] glTexImage2D failed (0x%x) for %s size %dx%d", err, path.c_str(), w, h);
        glBindTexture(GL_TEXTURE_2D, 0);
        glDeleteTextures(1, &tid);
        stbi_image_free(px);
        return nullptr;
    }
    glGenerateMipmap(GL_TEXTURE_2D);
    err = glGetError();
    if (err != GL_NO_ERROR) {
        NSLog(@"[Live2D] glGenerateMipmap failed (0x%x) for %s — using LINEAR only", err, path.c_str());
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    } else {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    }
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);
    stbi_image_free(px);

    TextureInfo* info = new TextureInfo{tid, w, h, path};
    _textures.push_back(info);
    return info;
}

- (void)releaseAllTextures {
    for (size_t i = 0; i < _textures.size(); i++) {
        glDeleteTextures(1, &_textures[i]->id);
        delete _textures[i];
    }
    _textures.clear();
}

@end
