#pragma once

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

using namespace godot;

// Writing a baked Animation out and keeping it in an AnimationLibrary.
//
// A baked clip is an ordinary Animation resource, so it works with AnimationTree
// and state machines once it is saved. What is worth centralising is the part
// that is easy to get wrong: replacing a clip of the same name in place instead
// of accumulating duplicates, and creating the library the first time.
class KimodoLibrary : public Object {
	GDCLASS(KimodoLibrary, Object)

protected:
	static void _bind_methods();

public:
	// Writes one clip on its own. Missing directories are created.
	static Error save_animation(const Ref<Animation> &p_animation, const String &p_path);

	// Adds p_name to the AnimationLibrary at p_library_path, replacing any clip
	// already under that name, and saves the library. The library is created if
	// it does not exist yet.
	static Error save_to_library(const Ref<Animation> &p_animation, const String &p_library_path,
								 const StringName &p_name);

	// Loads a saved library and hands it to a player, replacing whatever was
	// registered under p_library_name.
	static Error attach_library(AnimationPlayer *p_player, const String &p_library_path,
								const StringName &p_library_name);
};
