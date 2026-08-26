#!/usr/bin/env python
import os
import sys

from methods import build_kimodo_native, kimodo_native_blockers, print_error, print_warning


libname = "kimodo"
addonname = "kimodo"
projectdir = "project"

localEnv = Environment(tools=["default"], PLATFORM="")

customs = ["custom.py"]
customs = [os.path.abspath(path) for path in customs]

opts = Variables(customs, ARGUMENTS)
opts.Update(localEnv)

Help(opts.GenerateHelpText(localEnv))

env = localEnv.Clone()

if not (os.path.isdir("godot-cpp") and os.listdir("godot-cpp")):
    print_error("""godot-cpp is not available within this folder, as Git submodules haven't been initialized.
Run the following command to download godot-cpp:

    git submodule update --init --recursive""")
    sys.exit(1)

env = SConscript("godot-cpp/SConstruct", {"env": env, "customs": customs})

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

if env["target"] in ["editor", "template_debug"]:
    try:
        doc_data = env.GodotCPPDocData("src/gen/doc_data.gen.cpp", source=Glob("doc_classes/*.xml"))
        sources.append(doc_data)
    except AttributeError:
        print("Not including class reference as we're targeting a pre-4.3 baseline.")

# .dev doesn't inhibit compatibility, so we don't need to key it.
# .universal just means "compatible with all relevant arches" so we don't need to key it.
suffix = env['suffix'].replace(".dev", "").replace(".universal", "")

lib_filename = "{}{}{}{}".format(env.subst('$SHLIBPREFIX'), libname, suffix, env.subst('$SHLIBSUFFIX'))

library = env.SharedLibrary(
    "bin/{}/{}".format(env['platform'], lib_filename),
    source=sources,
)

# Installed inside the addon rather than beside the project, so that
# addons/kimodo is the whole of what a release ships and what someone copies
# into a project of their own.
copy = env.Install("{}/addons/{}/bin/{}/".format(projectdir, addonname, env["platform"]), library)

default_args = [library, copy]

# kmd-generate comes from kimodo.cpp's CMake build. It is put inside the addon
# so the dock finds it without anyone typing a path, and it is skipped rather
# than fatal when the toolchain for it is not installed: the addon is useful
# without it for anything that reads a motion kmd-generate already wrote.
Help("kimodo_native=yes|no: build kmd-generate from kimodo.cpp and bundle it (default yes)")
if ARGUMENTS.get("kimodo_native", "yes") not in ("no", "false", "0"):
    blockers = kimodo_native_blockers(env)
    if blockers:
        print_warning("Not building kmd-generate. Missing: " + "; ".join(blockers))
    else:
        native = env.Command(
            "{}/addons/{}/bin/{}/kmd-generate{}".format(
                projectdir, addonname, env["platform"], env["PROGSUFFIX"]),
            [],
            build_kimodo_native,
        )
        # CMake keeps its own dependency graph, and it is the one that knows
        # about GGML's sources and shaders.
        env.AlwaysBuild(native)
        default_args.append(native)

Default(*default_args)
