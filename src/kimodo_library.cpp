#include "kimodo_library.h"

#include <godot_cpp/classes/animation_library.hpp>
#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

Error ensure_directory(const String &p_path) {
	const String directory = p_path.get_base_dir();
	if (directory.is_empty() || DirAccess::dir_exists_absolute(directory)) {
		return OK;
	}
	return DirAccess::make_dir_recursive_absolute(directory);
}

} // namespace

void KimodoLibrary::_bind_methods() {
	ClassDB::bind_static_method("KimodoLibrary", D_METHOD("save_animation", "animation", "path"),
								&KimodoLibrary::save_animation);
	ClassDB::bind_static_method("KimodoLibrary", D_METHOD("save_to_library", "animation", "library_path", "name"),
								&KimodoLibrary::save_to_library);
	ClassDB::bind_static_method("KimodoLibrary", D_METHOD("attach_library", "player", "library_path", "library_name"),
								&KimodoLibrary::attach_library);
}

Error KimodoLibrary::save_animation(const Ref<Animation> &p_animation, const String &p_path) {
	ERR_FAIL_COND_V_MSG(p_animation.is_null(), ERR_INVALID_PARAMETER, "KimodoLibrary: no animation to save.");
	ERR_FAIL_COND_V_MSG(p_path.is_empty(), ERR_INVALID_PARAMETER, "KimodoLibrary: no destination path.");

	const Error error = ensure_directory(p_path);
	ERR_FAIL_COND_V_MSG(error != OK, error, vformat("KimodoLibrary: cannot create %s.", p_path.get_base_dir()));

	return ResourceSaver::get_singleton()->save(p_animation, p_path);
}

Error KimodoLibrary::save_to_library(const Ref<Animation> &p_animation, const String &p_library_path,
									 const StringName &p_name) {
	ERR_FAIL_COND_V_MSG(p_animation.is_null(), ERR_INVALID_PARAMETER, "KimodoLibrary: no animation to save.");
	ERR_FAIL_COND_V_MSG(p_library_path.is_empty(), ERR_INVALID_PARAMETER, "KimodoLibrary: no library path.");
	ERR_FAIL_COND_V_MSG(String(p_name).is_empty(), ERR_INVALID_PARAMETER, "KimodoLibrary: no animation name.");

	Ref<AnimationLibrary> library;
	if (ResourceLoader::get_singleton()->exists(p_library_path)) {
		// Ignore the resource cache: an editor that already has this library
		// open would otherwise hand back its copy and the save would fight it.
		library = ResourceLoader::get_singleton()->load(p_library_path, "AnimationLibrary",
														ResourceLoader::CACHE_MODE_REPLACE);
		ERR_FAIL_COND_V_MSG(library.is_null(), ERR_CANT_OPEN,
							vformat("KimodoLibrary: %s is not an AnimationLibrary.", p_library_path));
	} else {
		library.instantiate();
	}

	if (library->has_animation(p_name)) {
		library->remove_animation(p_name);
	}
	const Error added = library->add_animation(p_name, p_animation);
	ERR_FAIL_COND_V_MSG(added != OK, added, vformat("KimodoLibrary: cannot add %s to the library.", p_name));

	const Error error = ensure_directory(p_library_path);
	ERR_FAIL_COND_V_MSG(error != OK, error,
						vformat("KimodoLibrary: cannot create %s.", p_library_path.get_base_dir()));

	return ResourceSaver::get_singleton()->save(library, p_library_path);
}

Error KimodoLibrary::attach_library(AnimationPlayer *p_player, const String &p_library_path,
									const StringName &p_library_name) {
	ERR_FAIL_NULL_V_MSG(p_player, ERR_INVALID_PARAMETER, "KimodoLibrary: no player given.");

	Ref<AnimationLibrary> library =
			ResourceLoader::get_singleton()->load(p_library_path, "AnimationLibrary", ResourceLoader::CACHE_MODE_REUSE);
	ERR_FAIL_COND_V_MSG(library.is_null(), ERR_CANT_OPEN,
						vformat("KimodoLibrary: cannot load %s.", p_library_path));

	if (p_player->has_animation_library(p_library_name)) {
		p_player->remove_animation_library(p_library_name);
	}
	return p_player->add_animation_library(p_library_name, library);
}
