#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

using namespace godot;

// Reference tables for the SMPL-X 22 skeleton, plus construction of a
// Skeleton3D that carries its rest pose.
//
// The first integration stage skips retargeting and feeds KimodoMotion
// rotations straight into this rest. Every SMPL-X rest rotation is identity,
// so the rest is translation only.
class KimodoSmplx : public Object {
	GDCLASS(KimodoSmplx, Object)

protected:
	static void _bind_methods();

public:
	static int get_joint_count();
	static PackedInt32Array get_parents();
	static PackedStringArray get_joint_names();
	// SkeletonProfileHumanoid bone names, for BoneMap resolution when
	// retargeting.
	static PackedStringArray get_humanoid_bone_names();
	static PackedVector3Array get_rest_offsets();
	// Global rest positions, pelvis at the origin, with every rotation identity.
	static PackedVector3Array get_rest_positions();
	// Height of the joint extent in the rest pose, used to scale the pelvis
	// position when retargeting. It excludes the sole and the skin thickness,
	// so it reads slightly shorter than the actual body height.
	static double get_rest_height();

	// Returns a fresh 22-bone Skeleton3D. The caller owns it.
	static Skeleton3D *create_rest_skeleton();

	// The same rest under SkeletonProfileHumanoid bone names, so it doubles as
	// a retarget target and as the preview when no model has been supplied.
	//
	// The rest is not taken from SkeletonProfile.get_reference_pose(): that is a
	// schematic layout for the BoneMap editor in which every limb bone points
	// straight up +Y, so both hands sit at the same height and the legs rise out
	// of the hips. It is not a pose anything can be retargeted onto.
	static Skeleton3D *create_humanoid_skeleton();

	// Builds a preview mannequin by hanging a capsule off every bone. Left
	// limbs are warm, right limbs are cold and the spine is grey, so a
	// left/right flip is visible at a glance. Pass p_owner to make the nodes
	// show up in the editor scene tree.
	static void build_mannequin(Skeleton3D *p_skeleton, Node *p_owner);
	static void clear_mannequin(Skeleton3D *p_skeleton);
};
