#pragma once

#include <string>
#include <CubismFramework.hpp>
#include <Model/CubismUserModel.hpp>
#include <ICubismModelSetting.hpp>
#include <Type/csmVector.hpp>
#include <Math/CubismMatrix44.hpp>
#include "Live2DTextureManager.hpp"

class Live2DModel : public Csm::CubismUserModel
{
public:
    explicit Live2DModel(Live2DTextureManager* textureManager);
    virtual ~Live2DModel();

    void LoadAssets(const Csm::csmChar* modelDir, const Csm::csmChar* modelFileName);
    void Update();
    void Draw(const Csm::CubismMatrix44& matrix);

    void StartMotion(const Csm::csmChar* group, Csm::csmInt32 index, Csm::csmInt32 priority);
    void SetExpression(Csm::csmInt32 index);
    void SetParameterValue(const Csm::csmChar* parameterId, Csm::csmFloat32 value);

    /// Sets the motion playback speed multiplier (default 1.0).
    /// Physics, eye-blink and expressions are NOT affected.
    void SetMotionSpeed(Csm::csmFloat32 speed);

    // Must be called AFTER CreateRenderer()
    void SetupTextures();

    // Resize only the clipping mask FBO when the viewport changes.
    // Cheaper than CreateRenderer() because shaders are preserved.
    void ResizeMaskBuffer(int width, int height);


    bool IsLoaded() const { return _modelSetting != nullptr; }

protected:
    Csm::csmByte* CreateBuffer(const Csm::csmChar* path, Csm::csmSizeInt* size);
    void          DeleteBuffer(Csm::csmByte* buffer, const Csm::csmChar* path = "");

private:
    void SetupModel();
    void PreloadMotionGroup(const Csm::csmChar* group);
    void ReleaseMotions();
    void ReleaseExpressions();

    Csm::ICubismModelSetting*  _modelSetting;
    std::string                _modelHomeDir;
    Csm::csmFloat32            _userTimeSeconds;
    Csm::csmFloat32            _motionSpeed = 1.0f;
    Live2DTextureManager*      _textureManager;

    Csm::csmVector<Csm::CubismIdHandle> _lipSyncIds;
    Csm::csmMap<Csm::csmString, Csm::ACubismMotion*> _motions;
    Csm::csmMap<Csm::csmString, Csm::ACubismMotion*> _expressions;

    const Csm::CubismId* _idParamAngleX;
    const Csm::CubismId* _idParamAngleY;
    const Csm::CubismId* _idParamAngleZ;
    const Csm::CubismId* _idParamBodyAngleX;
    const Csm::CubismId* _idParamEyeBallX;
    const Csm::CubismId* _idParamEyeBallY;
};
