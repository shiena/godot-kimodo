#include "kimodo_motion.h"

#include "skeletons.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

// Reads a headerless raw F32 buffer in full.
PackedFloat32Array read_raw_f32(const String &p_path, Error &r_error) {
	Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::READ);
	if (file.is_null()) {
		r_error = FileAccess::get_open_error();
		ERR_PRINT(vformat("KimodoMotion: cannot open %s.", p_path));
		return PackedFloat32Array();
	}
	const int64_t length = static_cast<int64_t>(file->get_length());
	if (length <= 0 || (length % 4) != 0) {
		r_error = ERR_FILE_CORRUPT;
		ERR_PRINT(vformat("KimodoMotion: size %d of %s is not a valid F32 buffer.", length, p_path));
		return PackedFloat32Array();
	}
	r_error = OK;
	return file->get_buffer(length).to_float32_array();
}

} // namespace

void KimodoMotion::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_directory", "dir"), &KimodoMotion::load_directory);
	ClassDB::bind_method(D_METHOD("load_files", "rotations_path", "root_positions_path"), &KimodoMotion::load_files);
	ClassDB::bind_method(D_METHOD("clear"), &KimodoMotion::clear);

	ClassDB::bind_method(D_METHOD("get_frame_count"), &KimodoMotion::get_frame_count);
	ClassDB::bind_method(D_METHOD("get_joint_count"), &KimodoMotion::get_joint_count);
	ClassDB::bind_method(D_METHOD("get_skeleton_key"), &KimodoMotion::get_skeleton_key);
	ClassDB::bind_method(D_METHOD("get_skeleton_label"), &KimodoMotion::get_skeleton_label);
	ClassDB::bind_method(D_METHOD("get_fps"), &KimodoMotion::get_fps);
	ClassDB::bind_method(D_METHOD("set_fps", "fps"), &KimodoMotion::set_fps);
	ClassDB::bind_method(D_METHOD("get_duration"), &KimodoMotion::get_duration);

	ClassDB::bind_method(D_METHOD("get_local_rotations_raw"), &KimodoMotion::get_local_rotations_raw);
	ClassDB::bind_method(D_METHOD("set_local_rotations_raw", "value"), &KimodoMotion::set_local_rotations_raw);
	ClassDB::bind_method(D_METHOD("get_root_positions_raw"), &KimodoMotion::get_root_positions_raw);
	ClassDB::bind_method(D_METHOD("set_root_positions_raw", "value"), &KimodoMotion::set_root_positions_raw);
	ClassDB::bind_method(D_METHOD("get_recipe"), &KimodoMotion::get_recipe);
	ClassDB::bind_method(D_METHOD("set_recipe", "recipe"), &KimodoMotion::set_recipe);

	ClassDB::bind_method(D_METHOD("get_local_rotation", "frame", "joint"), &KimodoMotion::get_local_rotation);
	ClassDB::bind_method(D_METHOD("get_root_position", "frame"), &KimodoMotion::get_root_position);
	ClassDB::bind_method(D_METHOD("get_global_rotation", "frame", "joint"), &KimodoMotion::get_global_rotation);
	ClassDB::bind_method(D_METHOD("get_global_positions", "frame"), &KimodoMotion::get_global_positions);

	ClassDB::bind_method(D_METHOD("bake_animation", "skeleton_path"), &KimodoMotion::bake_animation);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fps", PROPERTY_HINT_RANGE, "1,240,1"), "set_fps", "get_fps");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "local_rotations_raw", PROPERTY_HINT_NONE, "",
							  PROPERTY_USAGE_NO_EDITOR),
				 "set_local_rotations_raw", "get_local_rotations_raw");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "root_positions_raw", PROPERTY_HINT_NONE, "",
							  PROPERTY_USAGE_NO_EDITOR),
				 "set_root_positions_raw", "get_root_positions_raw");
	// Editable, unlike the two buffers. It is the half of a clip a person reads
	// rather than plays, and correcting a mistyped prompt should not mean
	// generating the motion again.
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "recipe"), "set_recipe", "get_recipe");
}

Error KimodoMotion::load_directory(const String &p_dir) {
	const String dir = p_dir.trim_suffix("/");
	return load_files(dir + String("/local_rotations_xyzw.f32"), dir + String("/root_positions.f32"));
}

Error KimodoMotion::load_files(const String &p_rotations_path, const String &p_root_positions_path) {
	Error error = OK;

	const PackedFloat32Array rotations = read_raw_f32(p_rotations_path, error);
	if (error != OK) {
		return error;
	}
	const PackedFloat32Array positions = read_raw_f32(p_root_positions_path, error);
	if (error != OK) {
		return error;
	}

	ERR_FAIL_COND_V_MSG(positions.size() % 3 != 0, ERR_INVALID_DATA,
						vformat("KimodoMotion: root position element count %d does not divide into [T, 3].",
								positions.size()));
	const int frames = positions.size() / 3;
	ERR_FAIL_COND_V_MSG(frames <= 0, ERR_INVALID_DATA, "KimodoMotion: the motion has zero frames.");

	// The root translation is three floats a frame whatever the skeleton, so it
	// fixes the frame count and the rotations then say how many joints a run
	// produced. That is worth naming: kimodo.cpp generates for whichever
	// skeleton the motion GGUF declares, and since it gained SOMA and G1 the
	// answer is no longer always 22.
	ERR_FAIL_COND_V_MSG(rotations.size() % (frames * 4) != 0, ERR_INVALID_DATA,
						vformat("KimodoMotion: %d rotation floats is not a whole number of quaternions across %d frames.",
								rotations.size(), frames));
	const int joints = rotations.size() / (frames * 4);
	const skeletons::Definition *definition = skeletons::by_joint_count(joints);
	ERR_FAIL_COND_V_MSG(definition == nullptr, ERR_INVALID_DATA,
						vformat("KimodoMotion: %d joints a frame belongs to no skeleton this addon knows.", joints));

	local_rotations = rotations;
	root_positions = positions;
	frame_count = frames;
	skeleton = definition;
	emit_changed();
	return OK;
}

void KimodoMotion::clear() {
	local_rotations.clear();
	root_positions.clear();
	recipe.clear();
	frame_count = 0;
	emit_changed();
}

void KimodoMotion::set_recipe(const Dictionary &p_recipe) {
	recipe = p_recipe;
	emit_changed();
}

void KimodoMotion::set_fps(double p_fps) {
	ERR_FAIL_COND_MSG(p_fps <= 0.0, "KimodoMotion: fps must be positive.");
	fps = p_fps;
	emit_changed();
}

double KimodoMotion::get_duration() const {
	return frame_count > 1 ? (frame_count - 1) / fps : 0.0;
}

void KimodoMotion::set_local_rotations_raw(const PackedFloat32Array &p_value) {
	local_rotations = p_value;
	read_layout();
	emit_changed();
}

void KimodoMotion::set_root_positions_raw(const PackedFloat32Array &p_value) {
	root_positions = p_value;
	read_layout();
	emit_changed();
}

// The two buffers describe their own shape between them: the root translation
// is three floats a frame whatever the skeleton, and the rotations are then
// four floats a joint over those frames. Nothing else has to be stored, and a
// resource saved before this addon knew more than one skeleton still loads.
//
// Both setters call this because deserialisation assigns them one at a time,
// and the shape is only knowable once the second one lands.
void KimodoMotion::read_layout() {
	frame_count = 0;
	if (root_positions.size() % 3 != 0 || root_positions.is_empty()) {
		return;
	}
	const int frames = root_positions.size() / 3;
	if (local_rotations.size() % (frames * 4) != 0) {
		return;
	}
	const skeletons::Definition *definition = skeletons::by_joint_count(local_rotations.size() / (frames * 4));
	if (definition == nullptr) {
		return;
	}
	frame_count = frames;
	skeleton = definition;
}

Quaternion KimodoMotion::get_local_rotation(int p_frame, int p_joint) const {
	ERR_FAIL_INDEX_V(p_frame, frame_count, Quaternion());
	ERR_FAIL_INDEX_V(p_joint, skeleton->joint_count, Quaternion());

	const int base = (p_frame * skeleton->joint_count + p_joint) * 4;
	const Quaternion q(local_rotations[base], local_rotations[base + 1], local_rotations[base + 2],
					   local_rotations[base + 3]);

	// The raw F32 values are meant to be unit quaternions but drift slightly
	// through rounding. Godot slerp and Basis construction assume normalized
	// input, so fix them up here.
	const real_t length_squared = q.length_squared();
	if (length_squared < CMP_EPSILON) {
		return Quaternion();
	}
	return q / Math::sqrt(length_squared);
}

Vector3 KimodoMotion::get_root_position(int p_frame) const {
	ERR_FAIL_INDEX_V(p_frame, frame_count, Vector3());
	const int base = p_frame * 3;
	return Vector3(root_positions[base], root_positions[base + 1], root_positions[base + 2]);
}

Quaternion KimodoMotion::get_global_rotation(int p_frame, int p_joint) const {
	ERR_FAIL_INDEX_V(p_frame, frame_count, Quaternion());
	ERR_FAIL_INDEX_V(p_joint, skeleton->joint_count, Quaternion());

	Quaternion global = get_local_rotation(p_frame, p_joint);
	for (int parent = skeleton->parent[p_joint]; parent >= 0; parent = skeleton->parent[parent]) {
		global = get_local_rotation(p_frame, parent) * global;
	}
	return global;
}

PackedVector3Array KimodoMotion::get_global_positions(int p_frame) const {
	PackedVector3Array out;
	ERR_FAIL_INDEX_V(p_frame, frame_count, out);
	const int joints = skeleton->joint_count;
	out.resize(joints);

	LocalVector<Quaternion> global;
	LocalVector<Vector3> position;
	global.resize(joints);
	position.resize(joints);
	for (int joint = 0; joint < joints; ++joint) {
		const Quaternion local = get_local_rotation(p_frame, joint);
		const int parent = skeleton->parent[joint];
		if (parent < 0) {
			global[joint] = local;
			position[joint] = get_root_position(p_frame);
		} else {
			global[joint] = global[parent] * local;
			position[joint] = position[parent] + global[parent].xform(skeleton->offset(joint));
		}
		out[joint] = position[joint];
	}
	return out;
}

Ref<Animation> KimodoMotion::bake_animation(const NodePath &p_skeleton_path) const {
	ERR_FAIL_COND_V_MSG(frame_count <= 0, Ref<Animation>(), "KimodoMotion: no frames loaded.");

	Ref<Animation> animation;
	animation.instantiate();
	animation->set_step(1.0 / fps);
	animation->set_length(get_duration());
	animation->set_loop_mode(Animation::LOOP_NONE);

	const String base = String(p_skeleton_path);

	const int joints = skeleton->joint_count;
	LocalVector<int> rotation_track;
	rotation_track.resize(joints);
	for (int joint = 0; joint < joints; ++joint) {
		const int track = animation->add_track(Animation::TYPE_ROTATION_3D);
		animation->track_set_path(track, NodePath(vformat("%s:%s", base, skeleton->joint_name[joint])));
		animation->track_set_interpolation_type(track, Animation::INTERPOLATION_LINEAR);
		rotation_track[joint] = track;
	}

	// Only the pelvis gets a position track. Writing one for any other bone
	// stretches the rig to the proportions of the motion source.
	const int position_track = animation->add_track(Animation::TYPE_POSITION_3D);
	animation->track_set_path(position_track, NodePath(vformat("%s:%s", base, skeleton->joint_name[0])));
	animation->track_set_interpolation_type(position_track, Animation::INTERPOLATION_LINEAR);

	for (int frame = 0; frame < frame_count; ++frame) {
		const double time = frame / fps;
		for (int joint = 0; joint < joints; ++joint) {
			animation->rotation_track_insert_key(rotation_track[joint], time, get_local_rotation(frame, joint));
		}
		animation->position_track_insert_key(position_track, time, get_root_position(frame));
	}

	return animation;
}
