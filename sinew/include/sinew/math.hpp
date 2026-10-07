// Minimal vector / quaternion math for Sinew's public types (header-only, no dependencies).
#pragma once

#include "sinew/types.hpp"

#include <cmath>

namespace sinew {

constexpr float PI = 3.14159265358979f;
constexpr float DEG = PI / 180.0f;

inline Vec3 operator+(Vec3 a, Vec3 b) { return { a.x + b.x, a.y + b.y, a.z + b.z }; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return { a.x - b.x, a.y - b.y, a.z - b.z }; }
inline Vec3 operator-(Vec3 a) { return { -a.x, -a.y, -a.z }; }
inline Vec3 operator*(Vec3 a, float s) { return { a.x * s, a.y * s, a.z * s }; }
inline Vec3 operator*(float s, Vec3 a) { return a * s; }
inline Vec3& operator+=(Vec3& a, Vec3 b) { a = a + b; return a; }
inline Vec3& operator-=(Vec3& a, Vec3 b) { a = a - b; return a; }
inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(Vec3 a, Vec3 b) { return { a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x }; }
inline float length(Vec3 a) { return std::sqrt(dot(a, a)); }
inline Vec3 normalized(Vec3 a) {
	float l = length(a);
	return l > 1e-9f ? a * (1.0f / l) : Vec3{ 0.0f, 0.0f, 0.0f };
}
inline Vec3 lerp(Vec3 a, Vec3 b, float t) { return a + (b - a) * t; }

inline Quat operator*(Quat a, Quat b) {
	return { a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z };
}
inline Quat conj(Quat q) { return { -q.x, -q.y, -q.z, q.w }; }
inline float dot(Quat a, Quat b) { return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w; }
inline Quat normalized(Quat q) {
	float l = std::sqrt(dot(q, q));
	return l > 1e-9f ? Quat{ q.x / l, q.y / l, q.z / l, q.w / l } : Quat{};
}
inline Vec3 rotate(Quat q, Vec3 v) {
	Vec3 u{ q.x, q.y, q.z };
	Vec3 t = 2.0f * cross(u, v);
	return v + q.w * t + cross(u, t);
}
inline Quat axis_angle(Vec3 axis, float angle) {
	Vec3 a = normalized(axis) * std::sin(0.5f * angle);
	return { a.x, a.y, a.z, std::cos(0.5f * angle) };
}
/// Rotation vector (axis * angle, shortest way) of q.
inline Vec3 to_rotation_vector(Quat q) {
	if (q.w < 0.0f) {
		q = { -q.x, -q.y, -q.z, -q.w };
	}
	Vec3 v{ q.x, q.y, q.z };
	float s = length(v);
	if (s < 1e-7f) {
		return v * 2.0f;
	}
	float angle = 2.0f * std::atan2(s, q.w);
	return v * (angle / s);
}
/// Shortest rotation taking unit vector a onto unit vector b.
inline Quat from_to(Vec3 a, Vec3 b) {
	a = normalized(a);
	b = normalized(b);
	float d = dot(a, b);
	if (d < -0.999999f) {
		Vec3 axis = cross(Vec3{ 1.0f, 0.0f, 0.0f }, a);
		if (length(axis) < 1e-4f) {
			axis = cross(Vec3{ 0.0f, 1.0f, 0.0f }, a);
		}
		return axis_angle(axis, PI);
	}
	Vec3 c = cross(a, b);
	return normalized(Quat{ c.x, c.y, c.z, 1.0f + d });
}
inline Quat slerp(Quat a, Quat b, float t) {
	float d = dot(a, b);
	if (d < 0.0f) {
		b = { -b.x, -b.y, -b.z, -b.w };
		d = -d;
	}
	if (d > 0.9995f) {
		return normalized(Quat{ a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t });
	}
	float th = std::acos(d);
	float s = std::sin(th);
	float wa = std::sin((1.0f - t) * th) / s, wb = std::sin(t * th) / s;
	return { a.x * wa + b.x * wb, a.y * wa + b.y * wb, a.z * wa + b.z * wb, a.w * wa + b.w * wb };
}
/// Angle between two rotations, radians [0, pi].
inline float angle_between(Quat a, Quat b) {
	float d = std::fabs(dot(normalized(a), normalized(b)));
	return 2.0f * std::acos(d > 1.0f ? 1.0f : d);
}

/// A basis (rotation) whose +Y is `y` and whose +Z is as close to `z_hint` as possible.
inline Quat basis_y(Vec3 y, Vec3 z_hint) {
	y = normalized(y);
	Vec3 z = z_hint - y * dot(z_hint, y);
	if (length(z) < 1e-4f) {
		z = Vec3{ 0.0f, 1.0f, 0.0f } - y * y.y;
		if (length(z) < 1e-4f) {
			z = Vec3{ 1.0f, 0.0f, 0.0f } - y * y.x;
		}
	}
	z = normalized(z);
	Vec3 x = cross(y, z);
	// rotation matrix [x y z] -> quaternion
	float m00 = x.x, m11 = y.y, m22 = z.z;
	float tr = m00 + m11 + m22;
	Quat q;
	if (tr > 0.0f) {
		float s = std::sqrt(tr + 1.0f) * 2.0f;
		q = { (y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, 0.25f * s };
	} else if (m00 > m11 && m00 > m22) {
		float s = std::sqrt(1.0f + m00 - m11 - m22) * 2.0f;
		q = { 0.25f * s, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s };
	} else if (m11 > m22) {
		float s = std::sqrt(1.0f + m11 - m00 - m22) * 2.0f;
		q = { (y.x + x.y) / s, 0.25f * s, (z.y + y.z) / s, (z.x - x.z) / s };
	} else {
		float s = std::sqrt(1.0f + m22 - m00 - m11) * 2.0f;
		q = { (z.x + x.z) / s, (z.y + y.z) / s, 0.25f * s, (x.y - y.x) / s };
	}
	return normalized(q);
}

inline Transform operator*(const Transform& a, const Transform& b) {
	return { a.p + rotate(a.q, b.p), a.q * b.q };
}
inline Transform inverse(const Transform& t) {
	Quat qi = conj(t.q);
	return { rotate(qi, -t.p), qi };
}
inline Vec3 xform(const Transform& t, Vec3 p) { return t.p + rotate(t.q, p); }

} // namespace sinew
