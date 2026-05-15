#include "Live2DAllocator.hpp"
#include <cstdlib>

using namespace Csm;

void* Live2DAllocator::Allocate(const csmSizeType size)
{
    return malloc(size);
}

void Live2DAllocator::Deallocate(void* memory)
{
    free(memory);
}

void* Live2DAllocator::AllocateAligned(const csmSizeType size, const csmUint32 alignment)
{
    size_t offset = alignment - 1 + sizeof(void*);
    void*  allocation = malloc(size + static_cast<csmUint32>(offset));

    size_t alignedAddress = reinterpret_cast<size_t>(allocation) + sizeof(void*);
    size_t shift = alignedAddress % alignment;
    if (shift) alignedAddress += (alignment - shift);

    void** preamble = reinterpret_cast<void**>(alignedAddress);
    preamble[-1] = allocation;
    return reinterpret_cast<void*>(alignedAddress);
}

void Live2DAllocator::DeallocateAligned(void* alignedMemory)
{
    void** preamble = static_cast<void**>(alignedMemory);
    free(preamble[-1]);
}
