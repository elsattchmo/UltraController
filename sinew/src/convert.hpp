// Sinew <-> Box3D value conversions (internal).
#pragma once

#include "sinew/types.hpp"

#include "box3d/box3d.h"

namespace sinew {

inline b3Vec3 to_b3(Vec3 v) { return b3Vec3{ v.x, v.y, v.z }; }
inline b3Quat to_b3(Quat q) { return b3Quat{ { q.x, q.y, q.z }, q.w }; }
inline b3Transform to_b3(const Transform& t) { return b3Transform{ to_b3(t.p), to_b3(t.q) }; }

inline Vec3 from_b3(b3Vec3 v) { return Vec3{ v.x, v.y, v.z }; }
inline Quat from_b3(b3Quat q) { return Quat{ q.v.x, q.v.y, q.v.z, q.s }; }

inline b3BodyId body_id(BodyHandle h) { return b3LoadBodyId(h); }
inline b3JointId joint_id(JointHandle h) { return b3LoadJointId(h); }

} // namespace sinew
