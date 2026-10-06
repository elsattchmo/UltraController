/* Sinew flat C API: the surface for engines that bind through C (Unity P/Invoke, Unreal,
 * scripting languages). Handles are opaque; every struct is plain data. */
#ifndef SINEW_H
#define SINEW_H

#include <stdint.h>

#if defined(_WIN32) && defined(SINEW_CAPI_SHARED)
#define SINEW_API __declspec(dllexport)
#elif defined(__GNUC__) && defined(SINEW_CAPI_SHARED)
#define SINEW_API __attribute__((visibility("default")))
#else
#define SINEW_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sinew_vec3 { float x, y, z; } sinew_vec3;
typedef struct sinew_quat { float x, y, z, w; } sinew_quat;
typedef struct sinew_xform { sinew_vec3 p; sinew_quat q; } sinew_xform;
typedef struct sinew_world sinew_world;

SINEW_API const char* sinew_version(void);

SINEW_API sinew_world* sinew_world_create(sinew_vec3 gravity, int substeps);
SINEW_API void sinew_world_destroy(sinew_world* world);
SINEW_API void sinew_world_step(sinew_world* world, float dt);
SINEW_API uint64_t sinew_world_add_static_box(sinew_world* world, sinew_xform xform, sinew_vec3 half_extents);
SINEW_API uint64_t sinew_world_add_capsule(sinew_world* world, sinew_xform xform, sinew_vec3 a, sinew_vec3 b,
		float radius, float density);
SINEW_API sinew_xform sinew_body_transform(const sinew_world* world, uint64_t body);

#ifdef __cplusplus
}
#endif

#endif
