#include "mannequin.h"

#include <godot_cpp/classes/bone_attachment3d.hpp>
#include <godot_cpp/classes/box_mesh.hpp>
#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>

using namespace godot;

namespace {

// Marks the nodes build() created, so a rebuild can find and drop them.
const char *MANNEQUIN_META = "kimodo_mannequin";

// Basis that points +Y along p_direction. Capsule and box meshes are built
// around the +Y axis.
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

float style_radius(const mannequin::Style &p_style, int p_bone) {
	return p_bone < p_style.radius.size() ? p_style.radius[p_bone] : 0.0f;
}

int style_side(const mannequin::Style &p_style, int p_bone) {
	return p_bone < p_style.side.size() ? p_style.side[p_bone] : mannequin::SIDE_CENTER;
}

} // namespace

void mannequin::clear(Skeleton3D *p_skeleton) {
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

void mannequin::build(Skeleton3D *p_skeleton, const Style &p_style, Node *p_owner) {
	ERR_FAIL_NULL(p_skeleton);
	clear(p_skeleton);

	Ref<StandardMaterial3D> material[3];
	material[SIDE_CENTER] = make_material(Color(0.72f, 0.72f, 0.76f));
	material[SIDE_LEFT] = make_material(Color(0.90f, 0.36f, 0.30f));
	material[SIDE_RIGHT] = make_material(Color(0.30f, 0.55f, 0.92f));
	const Ref<StandardMaterial3D> face_material = make_material(Color(0.95f, 0.80f, 0.25f));

	const int bone_count = p_skeleton->get_bone_count();
	for (int bone = 0; bone < bone_count; ++bone) {
		const PackedInt32Array children = p_skeleton->get_bone_children(bone);
		const bool is_head = bone == p_style.head_bone;
		const bool wants_tip = children.is_empty() && p_style.tip_radius > 0.0f;

		int drawable_children = 0;
		for (int i = 0; i < children.size(); ++i) {
			if (style_radius(p_style, children[i]) > 0.0f) {
				++drawable_children;
			}
		}
		if (drawable_children == 0 && !is_head && !wants_tip) {
			continue;
		}

		BoneAttachment3D *attachment = memnew(BoneAttachment3D);
		attachment->set_name(String("Part_") + p_skeleton->get_bone_name(bone));
		adopt(p_skeleton, attachment, p_owner);
		attachment->set_bone_idx(bone);

		for (int i = 0; i < children.size(); ++i) {
			const int child = children[i];
			const real_t radius = style_radius(p_style, child);
			if (radius <= 0.0f) {
				continue;
			}
			const Vector3 offset = p_skeleton->get_bone_rest(child).origin;
			const real_t bone_length = offset.length();
			if (bone_length < 0.001f) {
				continue;
			}

			// A capsule shorter than its own diameter degenerates into a bead, so
			// the stubby bones -- the pelvis block, the spine and the collars --
			// get a box instead and tile into a torso.
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
				  make_part(mesh, transform, material[style_side(p_style, child)],
							String("Limb_") + p_skeleton->get_bone_name(child)),
				  p_owner);
		}

		if (!is_head && !wants_tip) {
			continue;
		}

		const real_t radius = is_head ? 0.088f * p_style.scale : p_style.tip_radius;
		Ref<SphereMesh> sphere;
		sphere.instantiate();
		sphere->set_radius(radius);
		sphere->set_height(radius * 2.5f);
		sphere->set_radial_segments(12);
		sphere->set_rings(6);
		adopt(attachment,
			  make_part(sphere, Transform3D(Basis(), Vector3(0.0f, is_head ? radius : 0.0f, 0.0f)),
						material[style_side(p_style, bone)], "Tip"),
			  p_owner);

		if (is_head) {
			// Facing marker. SMPL-X reads as +Z forward while a Godot Node3D points
			// down -Z, so this makes a 180 degree mismatch visible.
			Ref<BoxMesh> nose;
			nose.instantiate();
			nose->set_size(Vector3(0.030f, 0.030f, 0.070f) * p_style.scale);
			adopt(attachment,
				  make_part(nose,
							Transform3D(Basis(), Vector3(0.0f, radius * 0.85f, radius * 1.02f)),
							face_material, "Nose"),
				  p_owner);
		}
	}
}
