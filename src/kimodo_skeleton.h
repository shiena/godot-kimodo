#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>

using namespace godot;

// Reference tables for the skeletons kimodo.cpp generates for, plus
// construction of a Skeleton3D that carries one of their rest poses.
//
// Every method takes the skeleton key last and defaults it to smplx22, which
// is the only one earlier versions of this addon knew and still the one most
// callers want.
//
// The first integration stage skips retargeting and feeds KimodoMotion
// rotations straight into a rest built here. Every rest rotation is identity,
// so the rest is translation only.
class KimodoSkeleton : public Object {
	GDCLASS(KimodoSkeleton, Object)

protected:
	static void _bind_methods();

public:
	// Every key this addon knows, in the order the dock should offer them.
	static PackedStringArray get_keys();
	// The key a clip of this many joints belongs to, or "" for a width none of
	// them uses.
	static String key_for_joint_count(int p_joints);
	// For a person to read: "SMPL-X", "SOMA", "Unitree G1".
	static String get_label(const String &p_key = "smplx22");

	static int get_joint_count(const String &p_key = "smplx22");
	static PackedInt32Array get_parents(const String &p_key = "smplx22");
	static PackedStringArray get_joint_names(const String &p_key = "smplx22");
	// SkeletonProfileHumanoid bone names, for BoneMap resolution when
	// retargeting. Empty where the profile has no slot for a joint.
	static PackedStringArray get_humanoid_bone_names(const String &p_key = "smplx22");
	static PackedVector3Array get_rest_offsets(const String &p_key = "smplx22");
	// Global rest positions, root at the origin, with every rotation identity.
	static PackedVector3Array get_rest_positions(const String &p_key = "smplx22");
	// Height of the joint extent in the rest pose, used to scale the root
	// position when retargeting. It excludes the sole and the skin thickness,
	// so it reads slightly shorter than the actual body height.
	static double get_rest_height(const String &p_key = "smplx22");

	// Root height above the lowest rest joint. These skeletons put their root
	// at the origin, while a humanoid Skeleton3D is expected to stand on
	// y = 0, so the skeletons built here are lifted by this much. The tables
	// stay as the model publishes them.
	static double get_ground_offset(const String &p_key = "smplx22");

	// A fresh Skeleton3D standing on y = 0, one bone per joint. The caller
	// owns it.
	static Skeleton3D *create_rest_skeleton(const String &p_key = "smplx22");

	// The same rest under SkeletonProfileHumanoid bone names, so it doubles as
	// a retarget target and as the preview when no model has been supplied.
	// Joints the profile has no slot for keep their own name, or the skeleton
	// would carry nameless bones.
	//
	// The rest is not taken from SkeletonProfile.get_reference_pose(): that is a
	// schematic layout for the BoneMap editor in which every limb bone points
	// straight up +Y, so both hands sit at the same height and the legs rise out
	// of the hips. It is not a pose anything can be retargeted onto.
	static Skeleton3D *create_humanoid_skeleton(const String &p_key = "smplx22");

	// Builds a preview mannequin by hanging a capsule off every bone. Left
	// limbs are warm, right limbs are cold and the spine is grey, so a
	// left/right flip is visible at a glance. Pass p_owner to make the nodes
	// show up in the editor scene tree.
	static void build_mannequin(Skeleton3D *p_skeleton, Node *p_owner, const String &p_key = "smplx22");
	static void clear_mannequin(Skeleton3D *p_skeleton);
};
