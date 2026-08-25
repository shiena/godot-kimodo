#pragma once

#include <godot_cpp/variant/vector3.hpp>

// Static tables for the SMPL-X 22 joint skeleton.
//
// The joint order and the parent array match parent[] in
// kimodo.cpp/src/motion_decode.cpp.
//
// The rest offsets are not stored in the motion GGUF, so they are duplicated
// from kimodo.cpp/demo/index.html, which calibrated them against the upstream
// posed-joint fixture. Once the converter and the C API expose the rest pose,
// this table can go away.
namespace smplx22 {

constexpr int JOINT_COUNT = 22;

enum Side {
	SIDE_CENTER = 0,
	SIDE_LEFT = 1,
	SIDE_RIGHT = 2,
};

extern const int PARENT[JOINT_COUNT];
extern const char *const JOINT_NAME[JOINT_COUNT];
extern const char *const HUMANOID_NAME[JOINT_COUNT];
extern const int SIDE[JOINT_COUNT];

// Parent-local rest offsets in meters. Every rest rotation is identity.
extern const float REST_OFFSET[JOINT_COUNT][3];

// Preview-only half-width for the bone that ends at each joint, in meters.
// Derived from body part rather than bone length, because the spine segments
// are short enough that a length-derived width makes the torso thinner than
// the arms. Index 0 is unused: the pelvis has no incoming bone.
extern const float LIMB_RADIUS[JOINT_COUNT];

inline godot::Vector3 rest_offset(int p_joint) {
	return godot::Vector3(REST_OFFSET[p_joint][0], REST_OFFSET[p_joint][1], REST_OFFSET[p_joint][2]);
}

} // namespace smplx22
