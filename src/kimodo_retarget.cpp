#include "kimodo_retarget.h"

#include "kimodo_smplx.h"
#include "mannequin.h"
#include "smplx22.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>

using namespace godot;

namespace {

constexpr int JOINTS = smplx22::JOINT_COUNT;

// Bone indices ordered so that a parent always precedes its children. Godot
// does not promise that plain index order has that property.
std::vector<int> hierarchy_order(Skeleton3D *p_skeleton) {
	const int bone_count = p_skeleton->get_bone_count();
	std::vector<int> order;
	order.reserve(bone_count);

	std::vector<int> pending;
	const PackedInt32Array roots = p_skeleton->get_parentless_bones();
	for (int i = roots.size() - 1; i >= 0; --i) {
		pending.push_back(roots[i]);
	}
	while (!pending.empty()) {
		const int bone = pending.back();
		pending.pop_back();
		order.push_back(bone);
		const PackedInt32Array children = p_skeleton->get_bone_children(bone);
		for (int i = children.size() - 1; i >= 0; --i) {
			pending.push_back(children[i]);
		}
	}
	return order;
}

// Vertical extent of the joints both skeletons agree on. Comparing only the
// mapped joints keeps a rig without toes from being measured against a source
// that has them.
bool mapped_extent(Skeleton3D *p_skeleton, const PackedInt32Array &p_bones, double &r_source, double &r_target) {
	const PackedVector3Array source_rest = KimodoSmplx::get_rest_positions();
	real_t source_low = 0.0f;
	real_t source_high = 0.0f;
	real_t target_low = 0.0f;
	real_t target_high = 0.0f;
	bool any = false;

	for (int joint = 0; joint < JOINTS; ++joint) {
		if (p_bones[joint] < 0) {
			continue;
		}
		const real_t source_y = source_rest[joint].y;
		const real_t target_y = p_skeleton->get_bone_global_rest(p_bones[joint]).origin.y;
		if (!any) {
			source_low = source_high = source_y;
			target_low = target_high = target_y;
			any = true;
			continue;
		}
		source_low = Math::min(source_low, source_y);
		source_high = Math::max(source_high, source_y);
		target_low = Math::min(target_low, target_y);
		target_high = Math::max(target_high, target_y);
	}

	r_source = source_high - source_low;
	r_target = target_high - target_low;
	return any;
}

} // namespace

void KimodoRetarget::_bind_methods() {
	ClassDB::bind_static_method("KimodoRetarget", D_METHOD("resolve_bones", "skeleton", "bone_map"),
								&KimodoRetarget::resolve_bones);
	ClassDB::bind_static_method("KimodoRetarget", D_METHOD("describe_mapping", "skeleton", "bone_map"),
								&KimodoRetarget::describe_mapping);
	ClassDB::bind_static_method("KimodoRetarget", D_METHOD("get_scale", "skeleton", "bone_map"),
								&KimodoRetarget::get_scale);
	ClassDB::bind_static_method("KimodoRetarget",
								D_METHOD("bake_animation", "motion", "skeleton", "bone_map", "skeleton_path"),
								&KimodoRetarget::bake_animation);
	ClassDB::bind_static_method("KimodoRetarget", D_METHOD("build_mannequin", "skeleton", "bone_map", "owner"),
								&KimodoRetarget::build_mannequin);
}

PackedInt32Array KimodoRetarget::resolve_bones(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map) {
	PackedInt32Array out;
	ERR_FAIL_NULL_V(p_skeleton, out);
	out.resize(JOINTS);

	for (int joint = 0; joint < JOINTS; ++joint) {
		const StringName profile_bone(smplx22::HUMANOID_NAME[joint]);
		const String bone_name = p_bone_map.is_valid()
				? String(p_bone_map->get_skeleton_bone_name(profile_bone))
				: String(profile_bone);
		out[joint] = bone_name.is_empty() ? -1 : p_skeleton->find_bone(bone_name);
	}
	return out;
}

Dictionary KimodoRetarget::describe_mapping(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map) {
	Dictionary out;
	ERR_FAIL_NULL_V(p_skeleton, out);

	const PackedInt32Array bones = resolve_bones(p_skeleton, p_bone_map);
	PackedStringArray mapped;
	PackedStringArray missing;
	for (int joint = 0; joint < JOINTS; ++joint) {
		if (bones[joint] < 0) {
			missing.append(String(smplx22::HUMANOID_NAME[joint]));
		} else {
			mapped.append(vformat("%s -> %s", smplx22::HUMANOID_NAME[joint],
								  p_skeleton->get_bone_name(bones[joint])));
		}
	}

	double source_height = 0.0;
	double target_height = 0.0;
	mapped_extent(p_skeleton, bones, source_height, target_height);

	out["bones"] = bones;
	out["mapped"] = mapped;
	out["missing"] = missing;
	out["source_height"] = source_height;
	out["target_height"] = target_height;
	out["scale"] = get_scale(p_skeleton, p_bone_map);
	return out;
}

double KimodoRetarget::get_scale(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map) {
	ERR_FAIL_NULL_V(p_skeleton, 1.0);

	const PackedInt32Array bones = resolve_bones(p_skeleton, p_bone_map);
	double source_height = 0.0;
	double target_height = 0.0;
	if (!mapped_extent(p_skeleton, bones, source_height, target_height)) {
		return 1.0;
	}
	if (source_height <= CMP_EPSILON || target_height <= CMP_EPSILON) {
		return 1.0;
	}
	return target_height / source_height;
}

Ref<Animation> KimodoRetarget::bake_animation(const Ref<KimodoMotion> &p_motion, Skeleton3D *p_skeleton,
											  const Ref<BoneMap> &p_bone_map, const NodePath &p_skeleton_path) {
	ERR_FAIL_COND_V_MSG(p_motion.is_null(), Ref<Animation>(), "KimodoRetarget: no motion given.");
	ERR_FAIL_NULL_V_MSG(p_skeleton, Ref<Animation>(), "KimodoRetarget: no skeleton given.");

	const int frames = p_motion->get_frame_count();
	ERR_FAIL_COND_V_MSG(frames <= 0, Ref<Animation>(), "KimodoRetarget: the motion has no frames.");

	const PackedInt32Array bones = resolve_bones(p_skeleton, p_bone_map);
	ERR_FAIL_COND_V_MSG(bones[0] < 0, Ref<Animation>(),
						"KimodoRetarget: Hips did not resolve; without it there is nothing to anchor the motion to.");

	const int bone_count = p_skeleton->get_bone_count();
	std::vector<int> joint_of_bone(bone_count, -1);
	for (int joint = 0; joint < JOINTS; ++joint) {
		if (bones[joint] >= 0) {
			joint_of_bone[bones[joint]] = joint;
		}
	}

	std::vector<Quaternion> rest_global(bone_count);
	std::vector<Quaternion> rest_local(bone_count);
	for (int bone = 0; bone < bone_count; ++bone) {
		rest_global[bone] = p_skeleton->get_bone_global_rest(bone).basis.get_rotation_quaternion();
		rest_local[bone] = p_skeleton->get_bone_rest(bone).basis.get_rotation_quaternion();
	}
	const std::vector<int> order = hierarchy_order(p_skeleton);

	const double fps = p_motion->get_fps();
	Ref<Animation> animation;
	animation.instantiate();
	animation->set_step(1.0 / fps);
	animation->set_length(p_motion->get_duration());
	animation->set_loop_mode(Animation::LOOP_NONE);

	const String base = String(p_skeleton_path);
	std::vector<int> track_of_joint(JOINTS, -1);
	for (int joint = 0; joint < JOINTS; ++joint) {
		if (bones[joint] < 0) {
			continue;
		}
		const int track = animation->add_track(Animation::TYPE_ROTATION_3D);
		animation->track_set_path(track, NodePath(vformat("%s:%s", base, p_skeleton->get_bone_name(bones[joint]))));
		animation->track_set_interpolation_type(track, Animation::INTERPOLATION_LINEAR);
		track_of_joint[joint] = track;
	}

	// Only the pelvis carries translation. Writing it anywhere else would
	// stretch the rig to the proportions of the motion source.
	const int position_track = animation->add_track(Animation::TYPE_POSITION_3D);
	animation->track_set_path(position_track, NodePath(vformat("%s:%s", base, p_skeleton->get_bone_name(bones[0]))));
	animation->track_set_interpolation_type(position_track, Animation::INTERPOLATION_LINEAR);

	// Everything above the pelvis in the target hierarchy is unmapped and stays
	// at rest, so its rest transform is also its pose transform.
	const int hips_parent = p_skeleton->get_bone_parent(bones[0]);
	const Transform3D hips_parent_inverse =
			hips_parent < 0 ? Transform3D() : p_skeleton->get_bone_global_rest(hips_parent).affine_inverse();
	const double scale = get_scale(p_skeleton, p_bone_map);

	std::vector<Quaternion> motion_global(JOINTS);
	std::vector<Quaternion> pose_global(bone_count);
	for (int frame = 0; frame < frames; ++frame) {
		const double time = frame / fps;

		for (int joint = 0; joint < JOINTS; ++joint) {
			const Quaternion local = p_motion->get_local_rotation(frame, joint);
			const int parent = smplx22::PARENT[joint];
			motion_global[joint] = parent < 0 ? local : motion_global[parent] * local;
		}

		for (size_t i = 0; i < order.size(); ++i) {
			const int bone = order[i];
			const int joint = joint_of_bone[bone];
			const int parent = p_skeleton->get_bone_parent(bone);
			if (joint >= 0) {
				pose_global[bone] = motion_global[joint] * rest_global[bone];
			} else {
				pose_global[bone] = parent < 0 ? rest_local[bone] : pose_global[parent] * rest_local[bone];
			}
		}

		for (int joint = 0; joint < JOINTS; ++joint) {
			if (track_of_joint[joint] < 0) {
				continue;
			}
			const int bone = bones[joint];
			const int parent = p_skeleton->get_bone_parent(bone);
			const Quaternion local =
					(parent < 0 ? Quaternion() : pose_global[parent].inverse()) * pose_global[bone];
			animation->rotation_track_insert_key(track_of_joint[joint], time, local.normalized());
		}

		animation->position_track_insert_key(position_track, time,
											 hips_parent_inverse.xform(p_motion->get_root_position(frame) * scale));
	}

	return animation;
}

void KimodoRetarget::build_mannequin(Skeleton3D *p_skeleton, const Ref<BoneMap> &p_bone_map, Node *p_owner) {
	ERR_FAIL_NULL(p_skeleton);

	const PackedInt32Array bones = resolve_bones(p_skeleton, p_bone_map);
	const double scale = get_scale(p_skeleton, p_bone_map);

	mannequin::Style style;
	style.radius.resize(p_skeleton->get_bone_count());
	style.side.resize(p_skeleton->get_bone_count());
	style.radius.fill(0.0f);
	style.side.fill(mannequin::SIDE_CENTER);
	for (int joint = 0; joint < JOINTS; ++joint) {
		if (bones[joint] < 0) {
			continue;
		}
		style.radius[bones[joint]] = smplx22::LIMB_RADIUS[joint] * scale;
		style.side[bones[joint]] = smplx22::SIDE[joint];
	}
	style.head_bone = bones[15];
	style.tip_radius = 0.036f * scale;
	style.scale = scale;
	mannequin::build(p_skeleton, style, p_owner);
}
