#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

// Preview geometry hung off a Skeleton3D: one part per bone, spanning from its
// parent, so a motion can be watched on a rig that carries no mesh.
//
// Part width comes from a caller-supplied table rather than from bone length,
// because the spine bones are short enough that a length-derived width would
// make the torso thinner than the arms.
namespace mannequin {

enum Side {
	SIDE_CENTER = 0,
	SIDE_LEFT = 1,
	SIDE_RIGHT = 2,
};

struct Style {
	// Both indexed by skeleton bone. radius[b] is the half-width of the part
	// that ends at bone b; zero, or an index past the end, draws nothing.
	godot::PackedFloat32Array radius;
	godot::PackedInt32Array side;
	// Bone that carries the head sphere and the facing marker, or -1 for none.
	int head_bone = -1;
	// Radius of the sphere on bones that have no children. Zero omits them.
	float tip_radius = 0.036f;
	// Scales the head sphere and the facing marker along with the rest.
	float scale = 1.0f;
};

void build(godot::Skeleton3D *p_skeleton, const Style &p_style, godot::Node *p_owner);
void clear(godot::Skeleton3D *p_skeleton);

} // namespace mannequin
