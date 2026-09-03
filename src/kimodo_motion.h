#pragma once

#include "skeletons.h"

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

// Holds the two raw F32 buffers that kmd-generate writes:
//
//   local_rotations_xyzw.f32 : [T, J, 4] parent-local quaternions (x, y, z, w)
//   root_positions.f32       : [T, 3]     root world position, meters
//
// Neither file carries a header, so the frame count and the skeleton are
// derived from the two file sizes. J is 22, 30 or 34 depending on which model
// generated the clip, and the three sizes are distinct, which is what lets the
// skeleton be recognised rather than declared.
class KimodoMotion : public Resource {
	GDCLASS(KimodoMotion, Resource)

	PackedFloat32Array local_rotations;
	PackedFloat32Array root_positions;
	Dictionary recipe;
	int frame_count = 0;
	double fps = 30.0;
	const skeletons::Definition *skeleton = &skeletons::smplx22();

	void read_layout();

protected:
	static void _bind_methods();

public:
	// Takes the OUT_DIR that kmd-generate was given.
	Error load_directory(const String &p_dir);
	Error load_files(const String &p_rotations_path, const String &p_root_positions_path);
	void clear();

	int get_frame_count() const { return frame_count; }
	int get_joint_count() const { return skeleton->joint_count; }
	// The kimodo.skeleton key of the model that generated this clip.
	String get_skeleton_key() const { return String(skeleton->key); }
	String get_skeleton_label() const { return String(skeleton->label); }
	const skeletons::Definition &get_skeleton() const { return *skeleton; }
	double get_fps() const { return fps; }
	void set_fps(double p_fps);
	double get_duration() const;

	PackedFloat32Array get_local_rotations_raw() const { return local_rotations; }
	void set_local_rotations_raw(const PackedFloat32Array &p_value);
	PackedFloat32Array get_root_positions_raw() const { return root_positions; }
	void set_root_positions_raw(const PackedFloat32Array &p_value);

	// What produced this clip: the prompts, their lengths, the steps and seed,
	// and the model that ran. Carried rather than interpreted, because the two
	// files kmd-generate writes say nothing about the run that wrote them and
	// a clip that cannot name its own seed cannot be made again.
	Dictionary get_recipe() const { return recipe; }
	void set_recipe(const Dictionary &p_recipe);

	Quaternion get_local_rotation(int p_frame, int p_joint) const;
	Vector3 get_root_position(int p_frame) const;

	// Forward kinematics. get_global_rotation() is the D[j] of the retargeting
	// correction local_dst[j] = G[parent]^-1 * D[parent]^-1 * D[j] * G[j].
	Quaternion get_global_rotation(int p_frame, int p_joint) const;
	PackedVector3Array get_global_positions(int p_frame) const;

	// Direct bake for a Skeleton3D that carries this skeleton's rest verbatim.
	// No retargeting is applied. Only the root gets a position track.
	Ref<Animation> bake_animation(const NodePath &p_skeleton_path) const;

	KimodoMotion() = default;
	~KimodoMotion() override = default;
};
