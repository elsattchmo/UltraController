#include "doctest.h"

#include "sinew/math.hpp"

using namespace sinew;

TEST_CASE("basis_y is a rotation with +Y along y and +Z toward the hint") {
	const Vec3 dirs[] = { { 0, 1, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0.3f, -0.9f, 0.2f }, { 0, 0.1f, 1 } };
	for (Vec3 d : dirs) {
		Quat q = basis_y(d, Vec3{ 0, 0, 1 });
		Vec3 y = rotate(q, Vec3{ 0, 1, 0 });
		CHECK(length(y - normalized(d)) < 1e-4f);
		CHECK(std::fabs(dot(q, q) - 1.0f) < 1e-4f);
		Vec3 z = rotate(q, Vec3{ 0, 0, 1 });
		CHECK(std::fabs(dot(z, y)) < 1e-4f);
	}
}

TEST_CASE("from_to, rotation vectors and transforms") {
	Quat q = from_to(Vec3{ 0, 0, 1 }, Vec3{ 1, 0, 0 });
	CHECK(length(rotate(q, Vec3{ 0, 0, 1 }) - Vec3{ 1, 0, 0 }) < 1e-5f);
	Vec3 rv = to_rotation_vector(axis_angle(Vec3{ 0, 1, 0 }, 0.7f));
	CHECK(length(rv - Vec3{ 0, 0.7f, 0 }) < 1e-5f);
	Transform t{ Vec3{ 1, 2, 3 }, axis_angle(Vec3{ 1, 1, 0 }, 1.1f) };
	Transform i = inverse(t) * t;
	CHECK(length(i.p) < 1e-5f);
	CHECK(angle_between(i.q, Quat{}) < 1e-3f);
	CHECK(angle_between(axis_angle(Vec3{ 0, 0, 1 }, 0.5f), Quat{}) == doctest::Approx(0.5f).epsilon(1e-3));
}
