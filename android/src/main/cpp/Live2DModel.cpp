#include "Live2DModel.hpp"
#include "Live2DPal.hpp"
#include <android/log.h>

#include <CubismModelSettingJson.hpp>
#include <Motion/CubismMotion.hpp>
#include <Effect/CubismEyeBlink.hpp>
#include <Physics/CubismPhysics.hpp>
#include <CubismDefaultParameterId.hpp>
#include <Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp>
#include <Utils/CubismString.hpp>
#include <Id/CubismIdManager.hpp>
#include <Motion/CubismMotionQueueEntry.hpp>

using namespace Live2D::Cubism::Framework;
using namespace Live2D::Cubism::Framework::DefaultParameterId;

static const int PriorityNone   = 0;
static const int PriorityIdle   = 1;
static const int PriorityNormal = 2;
static const int PriorityForce  = 3;

Live2DModel::Live2DModel(Live2DTextureManager* textureManager)
    : CubismUserModel()
    , _modelSetting(nullptr)
    , _userTimeSeconds(0.0f)
    , _textureManager(textureManager)
{
    _idParamAngleX    = CubismFramework::GetIdManager()->GetId(ParamAngleX);
    _idParamAngleY    = CubismFramework::GetIdManager()->GetId(ParamAngleY);
    _idParamAngleZ    = CubismFramework::GetIdManager()->GetId(ParamAngleZ);
    _idParamBodyAngleX = CubismFramework::GetIdManager()->GetId(ParamBodyAngleX);
    _idParamEyeBallX  = CubismFramework::GetIdManager()->GetId(ParamEyeBallX);
    _idParamEyeBallY  = CubismFramework::GetIdManager()->GetId(ParamEyeBallY);
}

Live2DModel::~Live2DModel()
{
    ReleaseMotions();
    ReleaseExpressions();
    delete _modelSetting;
}

Csm::csmByte* Live2DModel::CreateBuffer(const Csm::csmChar* path, Csm::csmSizeInt* size)
{
    return Live2DPal::LoadFileAsBytes(path, size);
}

void Live2DModel::DeleteBuffer(Csm::csmByte* buffer, const Csm::csmChar* /*path*/)
{
    Live2DPal::ReleaseBytes(buffer);
}

void Live2DModel::LoadAssets(const Csm::csmChar* modelDir, const Csm::csmChar* modelFileName)
{
    _modelHomeDir = modelDir;

    csmSizeInt size;
    const csmString path = csmString(modelDir) + modelFileName;
    csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (!buffer) return;

    auto* setting = new CubismModelSettingJson(buffer, size);
    DeleteBuffer(buffer, path.GetRawString());

    _modelSetting = setting;
    SetupModel();
}

void Live2DModel::SetupModel()
{
    _updating = true;
    _initialized = false;

    // Load MOC
    {
        csmSizeInt size;
        const csmString path = csmString(_modelHomeDir.c_str()) + _modelSetting->GetModelFileName();
        csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
        LoadModel(buffer, size);
        DeleteBuffer(buffer, path.GetRawString());
    }

    // Expression
    for (csmInt32 i = 0; i < _modelSetting->GetExpressionCount(); i++)
    {
        const csmChar* name = _modelSetting->GetExpressionName(i);
        csmString path = csmString(_modelHomeDir.c_str()) + _modelSetting->GetExpressionFileName(i);
        csmSizeInt size;
        csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
        auto* motion = LoadExpression(buffer, size, name);
        _expressions[name] = motion;
        DeleteBuffer(buffer, path.GetRawString());
    }

    // Physics
    if (strcmp(_modelSetting->GetPhysicsFileName(), "") != 0)
    {
        csmString path = csmString(_modelHomeDir.c_str()) + _modelSetting->GetPhysicsFileName();
        csmSizeInt size;
        csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
        LoadPhysics(buffer, size);
        DeleteBuffer(buffer, path.GetRawString());
    }

    // Pose
    if (strcmp(_modelSetting->GetPoseFileName(), "") != 0)
    {
        csmString path = csmString(_modelHomeDir.c_str()) + _modelSetting->GetPoseFileName();
        csmSizeInt size;
        csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
        LoadPose(buffer, size);
        DeleteBuffer(buffer, path.GetRawString());
    }

    // Eye blink
    if (_modelSetting->GetEyeBlinkParameterCount() > 0)
    {
        _eyeBlink = CubismEyeBlink::Create(_modelSetting);
    }

    // Lip-sync parameter IDs (cached for external use)
    for (csmInt32 i = 0; i < _modelSetting->GetLipSyncParameterCount(); i++)
        _lipSyncIds.PushBack(_modelSetting->GetLipSyncParameterId(i));

    // UserData
    if (strcmp(_modelSetting->GetUserDataFile(), "") != 0)
    {
        csmString path = csmString(_modelHomeDir.c_str()) + _modelSetting->GetUserDataFile();
        csmSizeInt size;
        csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
        LoadUserData(buffer, size);
        DeleteBuffer(buffer, path.GetRawString());
    }

    // Preload default motions
    for (csmInt32 i = 0; i < _modelSetting->GetMotionGroupCount(); i++)
        PreloadMotionGroup(_modelSetting->GetMotionGroupName(i));

    _updating = false;
    _initialized = true;
    // Note: SetupTextures() must be called externally AFTER CreateRenderer()
}

void Live2DModel::SetupTextures()
{
    for (csmInt32 i = 0; i < _modelSetting->GetTextureCount(); i++)
    {
        if (!strcmp(_modelSetting->GetTextureFileName(i), "")) continue;

        csmString texturePath =
            csmString(_modelHomeDir.c_str()) + _modelSetting->GetTextureFileName(i);

        auto* info = _textureManager->CreateTextureFromPngFile(texturePath.GetRawString());
        if (info)
        {
            GetRenderer<Rendering::CubismRenderer_OpenGLES2>()->BindTexture(i, info->id);
        }
    }

#ifdef PREMULTIPLIED_ALPHA_ENABLE
    GetRenderer<Rendering::CubismRenderer_OpenGLES2>()->IsPremultipliedAlpha(true);
#else
    GetRenderer<Rendering::CubismRenderer_OpenGLES2>()->IsPremultipliedAlpha(false);
#endif
}

void Live2DModel::PreloadMotionGroup(const Csm::csmChar* group)
{
    for (csmInt32 i = 0; i < _modelSetting->GetMotionCount(group); i++)
    {
        csmString path = csmString(_modelHomeDir.c_str()) + _modelSetting->GetMotionFileName(group, i);
        csmSizeInt size;
        csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
        auto* motion = static_cast<CubismMotion*>(LoadMotion(buffer, size, nullptr));
        DeleteBuffer(buffer, path.GetRawString());

        csmFloat32 fadeTime = _modelSetting->GetMotionFadeInTimeValue(group, i);
        if (fadeTime >= 0.0f) motion->SetFadeInTime(fadeTime);
        fadeTime = _modelSetting->GetMotionFadeOutTimeValue(group, i);
        if (fadeTime >= 0.0f) motion->SetFadeOutTime(fadeTime);

        char idx[16];
        snprintf(idx, sizeof(idx), "%d", i);
        csmString name = csmString(group) + "_" + idx;
        _motions[name.GetRawString()] = motion;
    }
}

void Live2DModel::ReleaseMotions()
{
    for (csmMap<csmString, ACubismMotion*>::const_iterator i = _motions.Begin();
         i != _motions.End(); ++i)
        ACubismMotion::Delete(i->Second);
    _motions.Clear();
}

void Live2DModel::ReleaseExpressions()
{
    for (csmMap<csmString, ACubismMotion*>::const_iterator i = _expressions.Begin();
         i != _expressions.End(); ++i)
        ACubismMotion::Delete(i->Second);
    _expressions.Clear();
}

void Live2DModel::Update()
{
    const csmFloat32 deltaTime = Live2DPal::GetDeltaTime();
    _userTimeSeconds += deltaTime;

    _dragManager->Update(deltaTime);
    const csmFloat32 dragX = _dragManager->GetX();
    const csmFloat32 dragY = _dragManager->GetY();

    _model->LoadParameters();
    if (_motionManager->IsFinished())
    {
        StartMotion("Idle", 0, PriorityIdle);
    }
    else
    {
        _motionManager->UpdateMotion(_model, deltaTime * _motionSpeed);
    }
    _model->SaveParameters();

    // Apply drag (face look-at)
    _model->AddParameterValue(_idParamAngleX,    dragX * 30.0f);
    _model->AddParameterValue(_idParamAngleY,    dragY * 30.0f);
    _model->AddParameterValue(_idParamAngleZ,    dragX * dragY * (-30.0f));
    _model->AddParameterValue(_idParamBodyAngleX, dragX * 10.0f);
    _model->AddParameterValue(_idParamEyeBallX,  dragX);
    _model->AddParameterValue(_idParamEyeBallY,  dragY);

    // Eye blink
    if (_eyeBlink)
        _eyeBlink->UpdateParameters(_model, deltaTime);

    // Expression
    if (_expressionManager)
        _expressionManager->UpdateMotion(_model, deltaTime);

    // Physics
    if (_physics)
        _physics->Evaluate(_model, deltaTime);

    // Pose
    if (_pose)
        _pose->UpdateParameters(_model, deltaTime);

    _model->Update();
}

void Live2DModel::Draw(const Csm::CubismMatrix44& matrix)
{
    if (!_model) return;

    // Always build MVP from a fresh copy so the caller's matrix is not mutated
    CubismMatrix44 mvp = matrix;
    mvp.MultiplyByMatrix(_modelMatrix);

    auto* renderer = GetRenderer<Rendering::CubismRenderer_OpenGLES2>();
    if (!renderer) return;

    renderer->SetMvpMatrix(&mvp);
    renderer->DrawModel();
}

void Live2DModel::StartMotion(const Csm::csmChar* group, Csm::csmInt32 index, Csm::csmInt32 priority)
{
    if (!_modelSetting) return;
    if (!group) return;
    if (_modelSetting->GetMotionCount(group) <= 0) return;
    if (index < 0 || index >= _modelSetting->GetMotionCount(group)) return;

    const csmChar* motionFile = _modelSetting->GetMotionFileName(group, index);
    if (!motionFile || motionFile[0] == '\0') return;

    csmString path = csmString(_modelHomeDir.c_str()) + motionFile;
    csmSizeInt size;
    csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (!buffer || size <= 0) return;

    auto* motion = static_cast<CubismMotion*>(LoadMotion(buffer, size, nullptr));
    DeleteBuffer(buffer, path.GetRawString());
    if (!motion) return;

    csmFloat32 fadeIn  = _modelSetting->GetMotionFadeInTimeValue(group, index);
    csmFloat32 fadeOut = _modelSetting->GetMotionFadeOutTimeValue(group, index);
    if (fadeIn  >= 0.0f) motion->SetFadeInTime(fadeIn);
    if (fadeOut >= 0.0f) motion->SetFadeOutTime(fadeOut);

    _motionManager->StartMotionPriority(motion, false, priority);
}

void Live2DModel::SetExpression(Csm::csmInt32 index)
{
    if (!_modelSetting || index < 0 || index >= _modelSetting->GetExpressionCount()) return;

    const csmChar* name = _modelSetting->GetExpressionName(index);
    if (_expressions.IsExist(name))
        _expressionManager->StartMotion(_expressions[name], false);
}

void Live2DModel::ResizeMaskBuffer(int width, int height)
{
    auto* r = GetRenderer<Rendering::CubismRenderer_OpenGLES2>();
    if (r) r->SetDrawableClippingMaskBufferSize(
        static_cast<Csm::csmFloat32>(width),
        static_cast<Csm::csmFloat32>(height));
}

void Live2DModel::SetParameterValue(const Csm::csmChar* parameterId, Csm::csmFloat32 value)
{
    const CubismId* id = CubismFramework::GetIdManager()->GetId(parameterId);
    _model->SetParameterValue(id, value);
}

void Live2DModel::SetMotionSpeed(Csm::csmFloat32 speed)
{
    _motionSpeed = speed > 0.0f ? speed : 0.0f;
}
