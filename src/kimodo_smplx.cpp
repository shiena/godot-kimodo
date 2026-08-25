#include "kimodo_smplx.h"

#include "smplx22.h"

#include <godot_cpp/classes/bone_attachment3d.hpp>
#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

constexpr int JOINTS = smplx22::JOINT_COUNT;

// Marks the nodes build_mannequin() created, so a rebuild can find and drop
// them.
const char *MANNEQUIN_META = "kimodo_mannequin";

// Basis that points +Y along p_direction. Capsule and cylinder meshes are
// built around the +Y axis.
Basis basis_pointing(const Vector3 &p_direction) {
	const Vector3 up(0.0f, 1.0f, 0.0f);
	const Vector3 direction = p_direction.normalized();
	const real_t alignment = up.dot(direction);
	if (alignment > 1.0f - (real_t)CMP_EPSILON) {
		return Basis();
	}
	if (alignment < -1.0f + (real_t)CMP_EPSILON) {
		return Basis(Vector3(1.0f, 0.0f, 0.0f), (real_t)Math_PI);
	}
	return Basis(up.cross(direction).normalized(), Math::acos(alignment));
}

Ref<StandardMaterial3D> make_material(const Color &p_albedo) {
	Ref<StandardMaterial3D> material;
	material.instantiate();
	material->set_albedo(p_albedo);
	material->set_roughness(0.7f);
	material->set_metallic(0.0f);
	return material;
}

void adopt(Node *p_parent, Node *p_child, Node *p_owner) {
	p_parent->add_child(p_child);
	p_child->set_meta(MANNEQUIN_META, true);
	if (p_owner != nullptr) {
		p_child->set_owner(p_owner);
	}
}

MeshInstance3D *make_part(const Ref<Mesh> &p_mesh, const Transform3D &p_transform,
						  const Ref<StandardMaterial3D> &p_material, const String &p_name) {
	MeshInstance3D *part = memnew(MeshInstance3D);
	part->set_name(p_name);
	part->set_mesh(p_mesh);
	part->set_transform(p_transform);
	part->set_material_override(p_material);
	return part;
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
	ClassDB::bind_static_method("KimodoSmplx", D_METHOD("create_rest_skeleton"), &KimodoSmplx::create_rest_skeleton);
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

Skeleton3D *KimodoSmplx::create_rest_skeleton() {
	Skeleton3D *skeleton = memnew(Skeleton3D);
	skeleton->set_name("SmplxSkeleton");

	for (int joint = 0; joint < JOINTS; ++joint) {
		skeleton->add_bone(String(smplx22::JOINT_NAME[joint]));
		if (smplx22::PARENT[joint] >= 0) {
			skeleton->set_bone_parent(joint, smplx22::PARENT[joint]);
		}
		// Every SMPL-X rest rotation is identity, so translation alone is enough.
		skeleton->set_bone_rest(joint, Transform3D(Basis(), smplx22::rest_offset(joint)));
	}
	skeleton->reset_bone_poses();
	return skeleton;
}

void KimodoSmplx::clear_mannequin(Skeleton3D *p_skeleton) {
	ERR_FAIL_NULL(p_skeleton);
	TypedArray<Node> children = p_skeleton->get_children();
	for (int i = 0; i < children.size(); ++i) {
		Node *child = Object::cast_to<Node>(children[i]);
		if (child != nullptr && child->has_meta(MANNEQUIN_META)) {
			p_skeleton->remove_child(child);
			child->queue_free();
		}
	}
}

void KimodoSmplx::build_mannequin(Skeleton3D *p_skeleton, Node *p_owner) {
	ERR_FAIL_NULL(p_skeleton);
	ERR_FAIL_COND_MSG(p_skeleton->get_bone_count() < JOINTS,
					  vformat("KimodoSmplx: the skeleton has only %d bones; a SMPL-X 22 rest skeleton is required.",
							  p_skeleton->get_bone_count()));

	clear_mannequin(p_skeleton);

	Ref<StandardMaterial3D> material[3];
	material[smplx22::SIDE_CENTER] = make_material(Color(0.72f, 0.72f, 0.76f));
	material[smplx22::SIDE_LEFT] = make_material(Color(0.90f, 0.36f, 0.30f));
	material[smplx22::SIDE_RIGHT] = make_material(Color(0.30f, 0.55f, 0.92f));
	const Ref<StandardMaterial3D> face_material = make_material(Color(0.95f, 0.80f, 0.25f));

	for (int joint = 0; joint < JOINTS; ++joint) {
		// Joints without children get a sphere instead: the head, the wrists and
		// the toes.
		int child_count = 0;
		for (int other = 0; other < JOINTS; ++other) {
			if (smplx22::PARENT[other] == joint) {
				++child_count;
			}
		}

		BoneAttachment3D *attachment = memnew(BoneAttachment3D);
		attachment->set_name(String("Part_") + String(smplx22::JOINT_NAME[joint]));
		adopt(p_skeleton, attachment, p_owner);
		attachment->set_bone_idx(joint);

		for (int child = 0; child < JOINTS; ++child) {
			if (smplx22::PARENT[child] != joint) {
				continue;
			}
			const Vector3 offset = smplx22::rest_offset(child);
			const real_t bone_length = offset.length();
			if (bone_length < 0.01f) {
				continue;
			}
			// A capsule shorter than its own diameter degenerates into a bead, so
			// the stubby bones -- the pelvis block, the spine and the collars --
			// get a box instead and tile into a torso.
			const real_t radius = smplx22::LIMB_RADIUS[child];
			Ref<Mesh> mesh;
			if (bone_length < radius * 2.0f) {
				Ref<BoxMesh> box;
				box.instantiate();
				box->set_size(Vector3(radius * 2.0f, bone_length, radius * 1.5f));
				mesh = box;
			} else {
				Ref<CapsuleMesh> capsule;
				capsule.instantiate();
				capsule->set_radius(radius);
				capsule->set_height(bone_length);
				capsule->set_radial_segments(10);
				capsule->set_rings(3);
				mesh = capsule;
			}

			// The part spans parent to child in the parent bone local space.
			const Transform3D transform(basis_pointing(offset), offset * 0.5f);
			adopt(attachment,
				  make_part(mesh, transform, material[smplx22::SIDE[child]],
							String("Limb_") + String(smplx22::JOINT_NAME[child])),
				  p_owner);
		}

		if (child_count > 0 && joint != 15) {
			continue;
		}

		const bool is_head = joint == 15;
		Ref<SphereMesh> sphere;
		sphere.instantiate();
		sphere->set_radius(is_head ? 0.088f : 0.036f);
		sphere->set_height(is_head ? 0.220f : 0.072f);
		sphere->set_radial_segments(12);
		sphere->set_rings(6);
		adopt(attachment,
			  make_part(sphere, Transform3D(Basis(), Vector3(0.0f, is_head ? 0.085f : 0.0f, 0.0f)),
						material[smplx22::SIDE[joint]], "Tip"),
			  p_owner);

		if (is_head) {
			// Facing marker. SMPL-X reads as +Z forward while a Godot Node3D points
			// down -Z, so this makes a 180 degree mismatch visible.
			Ref<BoxMesh> nose;
			nose.instantiate();
			nose->set_size(Vector3(0.030f, 0.030f, 0.070f));
			adopt(attachment,
				  make_part(nose, Transform3D(Basis(), Vector3(0.0f, 0.075f, 0.090f)), face_material, "Nose"),
				  p_owner);
		}
	}
}
