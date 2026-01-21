#ifndef RT_BINDLESS_GLSL
#define RT_BINDLESS_GLSL

#include "bindless.h"

#define BINDLESS_ACCEL_STRUCTURES 5
layout(binding = BINDLESS_ACCEL_STRUCTURES, set = 0) uniform accelerationStructureEXT accel_table[];

#endif // RT_BINDLESS_GLSL
