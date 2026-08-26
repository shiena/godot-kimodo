#pragma once

#include <godot_cpp/variant/vector3.hpp>

// Static tables for the skeletons kimodo.cpp generates for.
//
// Joint order, parents and parent-local rest offsets are copied from
// kimodo.cpp/src/skeleton.hpp, which took them from NVIDIA Kimodo's
// definitions.py and the reference joint assets. The rest offsets are not
// carried in the motion GGUF, so they have to be duplicated; once the
// converter exposes the rest pose these tables can shrink to what is left.
//
// The remaining three columns are this addon's own. Humanoid names decide what
// retargeting can reach, sides colour the preview mannequin, and limb radii
// give it thickness. None of them exist upstream, because kimodo.cpp neither
// retargets nor draws.
namespace skeletons {

enum Side {
	SIDE_CENTER = 0,
	SIDE_LEFT = 1,
	SIDE_RIGHT = 2,
};

// Big enough for the widest skeleton here, so a rest pose can be computed on
// the stack without a heap allocation on every call.
constexpr int MAX_JOINTS = 34;

struct Definition {
	// Matches the kimodo.skeleton key in the motion GGUF.
	const char *key;
	// For a person to read.
	const char *label;
	int joint_count;

	const int *parent;
	const char *const *joint_name;
	// SkeletonProfileHumanoid bone names, used by the retargeting stage. An
	// empty string is a joint the profile has no slot for, which is not the
	// same as a rig that happens to lack the bone.
	const char *const *humanoid_name;
	const int *side;
	// Parent-local rest offsets in metres. Every rest rotation is identity.
	const float (*rest_offset)[3];
	// Preview-only half-width for the bone that ends at each joint, in metres.
	// Derived from body part rather than bone length, because the spine
	// segments are short enough that a length-derived width makes the torso
	// thinner than the arms. Index 0 is unused: the root has no incoming bone.
	const float *limb_radius;
	// Joint that carries the head sphere and the facing marker, or -1 when the
	// skeleton has no head. G1 stops at the waist.
	int head_joint;

	godot::Vector3 offset(int p_joint) const {
		return godot::Vector3(rest_offset[p_joint][0], rest_offset[p_joint][1], rest_offset[p_joint][2]);
	}
};

// The one every earlier release could read, and what an unlabelled motion is
// assumed to be.
const Definition &smplx22();

// A generated clip carries no skeleton name, only floats, so it is identified
// by its width. The three sizes are distinct, which is what makes this safe.
// Returns nullptr for a count none of them uses.
const Definition *by_joint_count(int p_joints);
const Definition *by_key(const char *p_key);

int count();
const Definition *at(int p_index);

// Global rest positions with the root at the origin, written into a buffer of
// at least joint_count entries. Every rest rotation is identity, so this is
// the offsets accumulated down the parent chain and nothing more.
void rest_positions(const Definition &p_definition, godot::Vector3 *r_out);

// Height of the joint extent in the rest pose. It excludes the sole and the
// skin, so it reads slightly shorter than a body would measure.
double rest_height(const Definition &p_definition);

// Root height above the lowest rest joint. These skeletons put their root at
// the origin while a Skeleton3D is expected to stand on y = 0.
double ground_offset(const Definition &p_definition);

} // namespace skeletons
