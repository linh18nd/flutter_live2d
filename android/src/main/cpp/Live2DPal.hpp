#pragma once

#include <string>
#include <CubismFramework.hpp>
#include <Type/CubismBasicType.hpp>

struct AAssetManager;

class Live2DPal
{
public:
    static void SetAssetManager(AAssetManager* mgr);

    // Signature matches csmLoadFileFunction: value (not reference) required for function pointer
    static Csm::csmByte* LoadFileAsBytes(const std::string filePath, Csm::csmSizeInt* outSize);
    static void          ReleaseBytes(Csm::csmByte* bytes);

    static Csm::csmFloat32 GetDeltaTime();
    static void            UpdateTime();

    static void PrintLogLn(const Csm::csmChar* format, ...);

private:
    static double        s_currentFrame;
    static double        s_lastFrame;
    static double        s_deltaTime;
    static AAssetManager* s_assetManager;

    static double GetSystemTime();
};
