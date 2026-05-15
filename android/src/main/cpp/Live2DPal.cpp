#include "Live2DPal.hpp"
#include <android/asset_manager.h>
#include <cstdio>
#include <cstdlib>
#include <time.h>

using namespace Csm;

double        Live2DPal::s_currentFrame = 0.0;
double        Live2DPal::s_lastFrame    = 0.0;
double        Live2DPal::s_deltaTime    = 0.0;
AAssetManager* Live2DPal::s_assetManager = nullptr;

void Live2DPal::SetAssetManager(AAssetManager* mgr)
{
    s_assetManager = mgr;
}

csmByte* Live2DPal::LoadFileAsBytes(const std::string filePath, csmSizeInt* outSize)
{
    // Absolute path → regular file I/O (model assets extracted to documents dir)
    if (!filePath.empty() && filePath[0] == '/')
    {
        FILE* fp = fopen(filePath.c_str(), "rb");
        if (!fp)
        {
            *outSize = 0;
            return nullptr;
        }
        fseek(fp, 0, SEEK_END);
        long size = ftell(fp);
        rewind(fp);
        csmByte* buffer = new csmByte[size];
        fread(buffer, 1, size, fp);
        fclose(fp);
        *outSize = static_cast<csmSizeInt>(size);
        return buffer;
    }

    // Relative path → load from APK assets (shader files etc.)
    if (s_assetManager)
    {
        // First try with FrameworkShaders/ prefix (SDK uses bare filenames for ES2 shaders)
        std::string assetPath = std::string("FrameworkShaders/") + filePath;
        AAsset* asset = AAssetManager_open(s_assetManager, assetPath.c_str(), AASSET_MODE_BUFFER);

        // Then try the path as-is (e.g., "FrameworkShaders/..." paths already have prefix)
        if (!asset)
        {
            asset = AAssetManager_open(s_assetManager, filePath.c_str(), AASSET_MODE_BUFFER);
        }

        if (asset)
        {
            off_t size = AAsset_getLength(asset);
            csmByte* buffer = new csmByte[size];
            AAsset_read(asset, buffer, static_cast<size_t>(size));
            AAsset_close(asset);
            *outSize = static_cast<csmSizeInt>(size);
            return buffer;
        }

    }

    *outSize = 0;
    return nullptr;
}

void Live2DPal::ReleaseBytes(csmByte* bytes)
{
    delete[] bytes;
}

csmFloat32 Live2DPal::GetDeltaTime()
{
    return static_cast<csmFloat32>(s_deltaTime);
}

void Live2DPal::UpdateTime()
{
    s_currentFrame = GetSystemTime();
    s_deltaTime    = s_currentFrame - s_lastFrame;
    s_lastFrame    = s_currentFrame;
}

void Live2DPal::PrintLogLn(const csmChar* format, ...)
{
    (void)format;
}

double Live2DPal::GetSystemTime()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}
