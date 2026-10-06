#include "doctest.h"

#include "sinew.h"

#include <cmath>
#include <cstring>

TEST_CASE("C API: a capsule falls onto a box") {
	CHECK(std::strncmp(sinew_version(), "sinew", 5) == 0);
	sinew_world* w = sinew_world_create(sinew_vec3{ 0.0f, -9.81f, 0.0f }, 4);
	sinew_world_add_static_box(w, sinew_xform{ { 0.0f, -0.5f, 0.0f }, { 0, 0, 0, 1 } }, sinew_vec3{ 5.0f, 0.5f, 5.0f });
	uint64_t body = sinew_world_add_capsule(w, sinew_xform{ { 0.0f, 2.0f, 0.0f }, { 0, 0, 0, 1 } },
			sinew_vec3{ -0.2f, 0.0f, 0.0f }, sinew_vec3{ 0.2f, 0.0f, 0.0f }, 0.1f, 1000.0f);
	for (int i = 0; i < 180; ++i) {
		sinew_world_step(w, 1.0f / 60.0f);
	}
	CHECK(std::fabs(sinew_body_transform(w, body).p.y - 0.1f) < 0.01f);
	sinew_world_destroy(w);
}
