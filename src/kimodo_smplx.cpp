#include "kimodo_smplx.h"

#include "mannequin.h"
#include "smplx22.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

constexpr int JOINTS = smplx22::JOINT_COUNT;

Skeleton3D *build_rest_skeleton(const char *p_node_name, const char *const *p_bone_names) {
	Skeleton3D *skeleton = memnew(Skeleton3D);
	skeleton->set_name(p_node_name);

	// Only the pelvis moves: lifting it carries the rest of the chain with it.
	const Vector3 stand(0.0f, static_cast<real_t>(KimodoSmplx::get_ground_offset()), 0.0f);
	for (int joint = 0; joint < JOINTS; ++joint) {
		skeleton->add_bone(String(p_bone_names[joint]));
		if (smplx22::PARENT[joint] >= 0) {
			skeleton->set_bone_parent(joint, smplx22::PARENT[joint]);
		}
		// Every SMPL-X rest rotation is identity, so translation alone is enough.
		skeleton->set_bone_rest(joint,
								Transform3D(Basis(), smplx22::rest_offset(joint) + (joint == 0 ? stand : Vector3())));
	}
	skeleton->reset_bone_poses();
	return skeleton;
}

} // namespace

void KimodoSmplx::_bind_methods() {
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_joint_count"), &KimodoSmplx::get_joint_count);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_parents"), &KimodoSmplx::get_parents);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_joint_names"), &KimodoSmplx::get_joint_names);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_humanoid_bone_names"),
								&KimodoSmplx::get_humanoid_bone_names);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_rest_offsets"), &KimodoSmplx::get_rest_offsets);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_rest_positions"), &KimodoSmplx::get_rest_positions);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_rest_height"), &KimodoSmplx::get_rest_height);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("get_ground_offset"), &KimodoSmplx::get_ground_offset);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("create_rest_skeleton"), &KimodoSmplx::create_rest_skeleton);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("create_humanoid_skeleton"),
								&KimodoSmplx::create_humanoid_skeleton);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("build_mannequin", "skeleton", "owner"),
								&KimodoSmplx::build_mannequin);
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("clear_mannequin", "skeleton"), &KimodoSmplx::clear_mannequin);
}

int KimodoSmplx::get_joint_count() {
	return JOINTS;
}

PackedInt32Array KimodoSmplx::get_parents() {
	PackedInt32Array out;
	out.resize(JOINTS);
	for (int joint = 0; joint < JOINTS; ++joint) {
		out[joint] = smplx22::PARENT[joint];
	}
	return out;
}

PackedStringArray KimodoSmplx::get_joint_names() {
	PackedStringArray out;
	out.resize(JOINTS);
	for (int joint = 0; joint < JOINTS; ++joint) {
		out[joint] = String(smplx22::JOINT_NAME[joint]);
	}
	return out;
}

PackedStringArray KimodoSmplx::get_humanoid_bone_names() {
	PackedStringArray out;
	out.resize(JOINTS);
	for (int joint = 0; joint < JOINTS; ++joint) {
		out[joint] = String(smplx22::HUMANOID_NAME[joint]);
	}
	return out;
}

PackedVector3Array KimodoSmplx::get_rest_offsets() {
	PackedVector3Array out;
	out.resize(JOINTS);
	for (int joint = 0; joint < JOINTS; ++joint) {
		out[joint] = smplx22::rest_offset(joint);
	}
	return out;
}

PackedVector3Array KimodoSmplx::get_rest_positions() {
	PackedVector3Array out;
	out.resize(JOINTS);
	for (int joint = 0; joint < JOINTS; ++joint) {
		const int parent = smplx22::PARENT[joint];
		out[joint] = parent < 0 ? smplx22::rest_offset(joint) : out[parent] + smplx22::rest_offset(joint);
	}
	return out;
}

double KimodoSmplx::get_rest_height() {
	const PackedVector3Array rest = get_rest_positions();
	real_t lowest = rest[0].y;
	real_t highest = rest[0].y;
	for (int joint = 1; joint < JOINTS; ++joint) {
		lowest = Math::min(lowest, rest[joint].y);
		highest = Math::max(highest, rest[joint].y);
	}
	return highest - lowest;
}

double KimodoSmplx::get_ground_offset() {
	const PackedVector3Array rest = get_rest_positions();
	real_t lowest = rest[0].y;
	for (int joint = 1; joint < JOINTS; ++joint) {
		lowest = Math::min(lowest, rest[joint].y);
	}
	// The toe joint rather than the sole: there is no sole in the data. A real
	// clip plants that joint about 15 mm above the ground, so this stands the
	// rest within that of where the model itself puts it.
	return -lowest;
}

Skeleton3D *KimodoSmplx::create_rest_skeleton() {
	return build_rest_skeleton("SmplxSkeleton", smplx22::JOINT_NAME);
}

Skeleton3D *KimodoSmplx::create_humanoid_skeleton() {
	return build_rest_skeleton("HumanoidSkeleton", smplx22::HUMANOID_NAME);
}

void KimodoSmplx::clear_mannequin(Skeleton3D *p_skeleton) {
	mannequin::clear(p_skeleton);
}

void KimodoSmplx::build_mannequin(Skeleton3D *p_skeleton, Node *p_owner) {
	ERR_FAIL_NULL(p_skeleton);
	ERR_FAIL_COND_MSG(p_skeleton->get_bone_count() < JOINTS,
					  vformat("KimodoSmplx: the skeleton has only %d bones; a SMPL-X 22 rest skeleton is required.",
							  p_skeleton->get_bone_count()));

	// Bone index equals joint index on a skeleton from create_rest_skeleton().
	mannequin::Style style;
	style.radius.resize(JOINTS);
	style.side.resize(JOINTS);
	for (int joint = 0; joint < JOINTS; ++joint) {
		style.radius[joint] = smplx22::LIMB_RADIUS[joint];
		style.side[joint] = smplx22::SIDE[joint];
	}
	style.head_bone = 15;
	mannequin::build(p_skeleton, style, p_owner);
}
