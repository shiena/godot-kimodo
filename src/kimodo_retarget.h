#pragma once

#include "kimodo_motion.h"

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/bone_map.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

using namespace godot;

// Drives an arbitrary humanoid rig from a KimodoMotion.
//
// SMPL-X and the target rig hold different rest poses, so the rotations cannot
// be copied across. Every SMPL-X rest rotation is identity, which reduces the
// correction to
//
//     local_dst[j] = G[parent]^-1 * D[parent]^-1 * D[j] * G[j]
//
// for a target global rest rotation G and a SMPL-X global pose rotation D. This
// class works in global pose rotations instead and converts to local at the
// end, so that unmapped bones between two mapped ones -- twist bones, an extra
// spine joint -- stay at their rest and still compose correctly.
//
// Bones the mapping does not reach keep their rest pose and get no track: the
// fingers, the eyes and the jaw have no counterpart in SMPL-X 22.
class KimodoRetarget : public Object {
	GDCLASS(KimodoRetarget, Object)

protected:
	static void _bind_methods();

public:
	// Target bone index per SMPL-X joint, -1 where the mapping does not reach.
	// A null bone map falls back to matching SkeletonProfileHumanoid names
	// against the skeleton directly.
	static PackedInt32Array resolve_bones(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map);

	// What resolved and what did not, plus the rest heights behind the scale.
	static Dictionary describe_mapping(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map);

	// Ratio of the two rest heights, measured over the mapped joints only.
	// Without it, a character of a different build gets the wrong stride and
	// slides along the ground.
	static double get_scale(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map);

	static Ref<Animation> bake_animation(const Ref<KimodoMotion> &p_motion, Skeleton3D *p_skeleton,
										 const Ref<BoneMap> &p_bone_map, const NodePath &p_skeleton_path);

	// Preview geometry for a mapped rig, sized from the SMPL-X proportions and
	// scaled to the target.
	static void build_mannequin(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map, Node *p_owner);
};
