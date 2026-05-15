#include "Live2DTextureManager.hpp"
#include "Live2DPal.hpp"

#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include <GLES2/gl2.h>

Live2DTextureManager::Live2DTextureManager() {}

Live2DTextureManager::~Live2DTextureManager()
{
    ReleaseTextures();
}

Live2DTextureManager::TextureInfo* Live2DTextureManager::CreateTextureFromPngFile(const std::string& filePath)
{
    // Return cached texture if already loaded
    for (Csm::csmUint32 i = 0; i < _textures.GetSize(); i++)
    {
        if (_textures[i]->fileName == filePath)
            return _textures[i];
    }

    Csm::csmSizeInt size = 0;
    unsigned char*  raw  = Live2DPal::LoadFileAsBytes(filePath, &size);
    if (!raw) return nullptr;

    int width, height, channels;
    unsigned char* pixels = stbi_load_from_memory(
        raw, static_cast<int>(size),
        &width, &height, &channels, STBI_rgb_alpha);

    Live2DPal::ReleaseBytes(raw);
    if (!pixels) return nullptr;

    GLuint texId;
    glGenTextures(1, &texId);
    glBindTexture(GL_TEXTURE_2D, texId);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glGenerateMipmap(GL_TEXTURE_2D);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);

    stbi_image_free(pixels);

    TextureInfo* info = new TextureInfo();
    info->id       = texId;
    info->width    = width;
    info->height   = height;
    info->fileName = filePath;
    _textures.PushBack(info);

    return info;
}

void Live2DTextureManager::ReleaseTextures()
{
    for (Csm::csmUint32 i = 0; i < _textures.GetSize(); i++)
    {
        glDeleteTextures(1, &(_textures[i]->id));
        delete _textures[i];
    }
    _textures.Clear();
}

void Live2DTextureManager::ReleaseTexture(GLuint textureId)
{
    for (Csm::csmUint32 i = 0; i < _textures.GetSize(); i++)
    {
        if (_textures[i]->id == textureId)
        {
            glDeleteTextures(1, &(_textures[i]->id));
            delete _textures[i];
            _textures.Remove(i);
            return;
        }
    }
}
