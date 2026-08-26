#include "kimodo_skeleton.h"

#include "mannequin.h"
#include "skeletons.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

const skeletons::Definition *lookup(const String &p_key) {
	return skeletons::by_key(p_key.utf8().get_data());
}

Skeleton3D *build_rest_skeleton(const skeletons::Definition &p_definition, const String &p_node_name,
								bool p_humanoid_names) {
	Skeleton3D *skeleton = memnew(Skeleton3D);
	skeleton->set_name(p_node_name);

	// Only the root moves: lifting it carries the rest of the chain with it.
	const Vector3 stand(0.0f, static_cast<real_t>(skeletons::ground_offset(p_definition)), 0.0f);
	for (int joint = 0; joint < p_definition.joint_count; ++joint) {
		const char *humanoid = p_definition.humanoid_name[joint];
		const bool named = p_humanoid_names && humanoid[0] != 0;
		skeleton->add_bone(String(named ? humanoid : p_definition.joint_name[joint]));
		if (p_definition.parent[joint] >= 0) {
			skeleton->set_bone_parent(joint, p_definition.parent[joint]);
		}
		// Every rest rotation is identity, so translation alone is enough.
		skeleton->set_bone_rest(
				joint, Transform3D(Basis(), p_definition.offset(joint) + (joint == 0 ? stand : Vector3())));
	}
	skeleton->reset_bone_poses();
	return skeleton;
}

} // namespace

void KimodoSkeleton::_bind_methods() {
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_keys"), &KimodoSkeleton::get_keys);
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("key_for_joint_count", "joints"),
								&KimodoSkeleton::key_for_joint_count);
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_label", "key"), &KimodoSkeleton::get_label,
								DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_joint_count", "key"),
								&KimodoSkeleton::get_joint_count, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_parents", "key"), &KimodoSkeleton::get_parents,
								DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_joint_names", "key"),
								&KimodoSkeleton::get_joint_names, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_humanoid_bone_names", "key"),
								&KimodoSkeleton::get_humanoid_bone_names, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_rest_offsets", "key"),
								&KimodoSkeleton::get_rest_offsets, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_rest_positions", "key"),
								&KimodoSkeleton::get_rest_positions, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_rest_height", "key"),
								&KimodoSkeleton::get_rest_height, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("get_ground_offset", "key"),
								&KimodoSkeleton::get_ground_offset, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("create_rest_skeleton", "key"),
								&KimodoSkeleton::create_rest_skeleton, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("create_humanoid_skeleton", "key"),
								&KimodoSkeleton::create_humanoid_skeleton, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("build_mannequin", "skeleton", "owner", "key"),
								&KimodoSkeleton::build_mannequin, DEFVAL("smplx22"));
	ClassDB::bind_static_method("KimodoSkeleton", D_METHOD("clear_mannequin", "skeleton"),
								&KimodoSkeleton::clear_mannequin);
}

PackedStringArray KimodoSkeleton::get_keys() {
	PackedStringArray out;
	for (int index = 0; index < skeletons::count(); ++index) {
		out.append(String(skeletons::at(index)->key));
	}
	return out;
}

String KimodoSkeleton::key_for_joint_count(int p_joints) {
	const skeletons::Definition *definition = skeletons::by_joint_count(p_joints);
	return definition == nullptr ? String() : String(definition->key);
}

String KimodoSkeleton::get_label(const String &p_key) {
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, String(), vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	return String(definition->label);
}

int KimodoSkeleton::get_joint_count(const String &p_key) {
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, 0, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	return definition->joint_count;
}

PackedInt32Array KimodoSkeleton::get_parents(const String &p_key) {
	PackedInt32Array out;
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, out, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	out.resize(definition->joint_count);
	for (int joint = 0; joint < definition->joint_count; ++joint) {
		out[joint] = definition->parent[joint];
	}
	return out;
}

PackedStringArray KimodoSkeleton::get_joint_names(const String &p_key) {
	PackedStringArray out;
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, out, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	out.resize(definition->joint_count);
	for (int joint = 0; joint < definition->joint_count; ++joint) {
		out[joint] = String(definition->joint_name[joint]);
	}
	return out;
}

PackedStringArray KimodoSkeleton::get_humanoid_bone_names(const String &p_key) {
	PackedStringArray out;
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, out, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	out.resize(definition->joint_count);
	for (int joint = 0; joint < definition->joint_count; ++joint) {
		out[joint] = String(definition->humanoid_name[joint]);
	}
	return out;
}

PackedVector3Array KimodoSkeleton::get_rest_offsets(const String &p_key) {
	PackedVector3Array out;
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, out, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	out.resize(definition->joint_count);
	for (int joint = 0; joint < definition->joint_count; ++joint) {
		out[joint] = definition->offset(joint);
	}
	return out;
}

PackedVector3Array KimodoSkeleton::get_rest_positions(const String &p_key) {
	PackedVector3Array out;
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, out, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	Vector3 rest[skeletons::MAX_JOINTS];
	skeletons::rest_positions(*definition, rest);
	out.resize(definition->joint_count);
	for (int joint = 0; joint < definition->joint_count; ++joint) {
		out[joint] = rest[joint];
	}
	return out;
}

double KimodoSkeleton::get_rest_height(const String &p_key) {
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, 0.0, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	return skeletons::rest_height(*definition);
}

double KimodoSkeleton::get_ground_offset(const String &p_key) {
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, 0.0, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	// The toe joint rather than the sole: there is no sole in the data. A real
	// clip plants that joint about 15 mm above the ground, so this stands the
	// rest within that of where the model itself puts it.
	return skeletons::ground_offset(*definition);
}

Skeleton3D *KimodoSkeleton::create_rest_skeleton(const String &p_key) {
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, nullptr, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	return build_rest_skeleton(*definition, "KimodoRestSkeleton", false);
}

Skeleton3D *KimodoSkeleton::create_humanoid_skeleton(const String &p_key) {
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_V_MSG(definition, nullptr, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	return build_rest_skeleton(*definition, "HumanoidSkeleton", true);
}

void KimodoSkeleton::clear_mannequin(Skeleton3D *p_skeleton) {
	mannequin::clear(p_skeleton);
}

void KimodoSkeleton::build_mannequin(Skeleton3D *p_skeleton, Node *p_owner, const String &p_key) {
	ERR_FAIL_NULL(p_skeleton);
	const skeletons::Definition *definition = lookup(p_key);
	ERR_FAIL_NULL_MSG(definition, vformat("KimodoSkeleton: no skeleton called %s.", p_key));
	ERR_FAIL_COND_MSG(p_skeleton->get_bone_count() < definition->joint_count,
					  vformat("KimodoSkeleton: the skeleton has only %d bones; a %s rest skeleton has %d.",
							  p_skeleton->get_bone_count(), definition->label, definition->joint_count));

	// Bone index equals joint index on a skeleton from create_rest_skeleton().
	mannequin::Style style;
	style.radius.resize(definition->joint_count);
	style.side.resize(definition->joint_count);
	for (int joint = 0; joint < definition->joint_count; ++joint) {
		style.radius[joint] = definition->limb_radius[joint];
		style.side[joint] = definition->side[joint];
	}
	style.head_bone = definition->head_joint;
	mannequin::build(p_skeleton, style, p_owner);
}
