#ifndef VINDU_BORDER_ENGINE_H
#define VINDU_BORDER_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

typedef struct VBEEngine VBEEngine;

typedef struct {
    double red;
    double green;
    double blue;
    double alpha;
} VBEColor;

VBEEngine * _Nullable VBEEngineCreate(void);
void VBEEngineSetTarget(VBEEngine *engine,
                        uint32_t windowID,
                        const VBEColor *colors,
                        size_t colorCount,
                        double angleDegrees,
                        double width,
                        double fallbackRadius);
void VBEEngineHide(VBEEngine *engine);
bool VBEEngineIsAvailable(const VBEEngine * _Nullable engine);
void VBEEngineDestroy(VBEEngine *engine);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#endif
