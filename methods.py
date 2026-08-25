import os
import shutil
import subprocess
import sys
from enum import Enum

# Colors are disabled in non-TTY environments such as pipes. This means
# that if output is redirected to a file, it won't contain color codes.
# Colors are always enabled on continuous integration.
_colorize = bool(sys.stdout.isatty() or os.environ.get("CI"))


class ANSI(Enum):
    """
    Enum class for adding ansi colorcodes directly into strings.
    Automatically converts values to strings representing their
    internal value, or an empty string in a non-colorized scope.
    """

    RESET = "\x1b[0m"

    BOLD = "\x1b[1m"
    ITALIC = "\x1b[3m"
    UNDERLINE = "\x1b[4m"
    STRIKETHROUGH = "\x1b[9m"
    REGULAR = "\x1b[22;23;24;29m"

    BLACK = "\x1b[30m"
    RED = "\x1b[31m"
    GREEN = "\x1b[32m"
    YELLOW = "\x1b[33m"
    BLUE = "\x1b[34m"
    MAGENTA = "\x1b[35m"
    CYAN = "\x1b[36m"
    WHITE = "\x1b[37m"

    PURPLE = "\x1b[38;5;93m"
    PINK = "\x1b[38;5;206m"
    ORANGE = "\x1b[38;5;214m"
    GRAY = "\x1b[38;5;244m"

    def __str__(self) -> str:
        global _colorize
        return str(self.value) if _colorize else ""


def print_warning(*values: object) -> None:
    """Prints a warning message with formatting."""
    print(f"{ANSI.YELLOW}{ANSI.BOLD}WARNING:{ANSI.REGULAR}", *values, ANSI.RESET, file=sys.stderr)


def print_error(*values: object) -> None:
    """Prints an error message with formatting."""
    print(f"{ANSI.RED}{ANSI.BOLD}ERROR:{ANSI.REGULAR}", *values, ANSI.RESET, file=sys.stderr)


KIMODO_SOURCE_DIR = "kimodo.cpp"
KIMODO_BUILD_DIR = os.path.join(KIMODO_SOURCE_DIR, "build", "godot")


def kimodo_native_blockers() -> list:
    """What is missing before kimodo.cpp's CMake build can run, if anything.

    These are all "the toolchain is not installed" conditions rather than
    failures, so the caller skips the native build instead of breaking the
    GDExtension build for someone who only wants the addon.
    """
    missing = []
    if not os.path.isfile(os.path.join(KIMODO_SOURCE_DIR, "CMakeLists.txt")):
        missing.append("the kimodo.cpp submodule (git submodule update --init kimodo.cpp)")
    elif not os.path.isfile(os.path.join(KIMODO_SOURCE_DIR, "ggml", "CMakeLists.txt")):
        missing.append("kimodo.cpp's ggml submodule (git submodule update --init --recursive kimodo.cpp)")
    if shutil.which("cmake") is None:
        missing.append("cmake 3.25 or newer")
    if shutil.which("glslc") is None and not os.environ.get("VULKAN_SDK"):
        missing.append("the Vulkan SDK, which supplies glslc for the GGML Vulkan shaders")
    return missing


def _cmake_environment(env) -> dict:
    """The shell environment CMake gets.

    SCons has already located MSVC and put its INCLUDE, LIB and PATH into
    env["ENV"]. Handing that to CMake is what lets the Ninja generator find a
    compiler without a developer command prompt. The compiler paths go in front
    of the caller's PATH rather than replacing it, or cmake and glslc would
    disappear from it.
    """
    scons_env = {key: str(value) for key, value in env["ENV"].items()}
    scons_path = scons_env.pop("PATH", "")

    process_env = dict(os.environ)
    process_env.update(scons_env)
    if scons_path:
        process_env["PATH"] = os.pathsep.join([scons_path, os.environ.get("PATH", "")])
    return process_env


def build_kimodo_native(target, source, env):
    """Configure and build kmd-generate straight into the addon.

    Reproducing this in SCons would mean reproducing GGML and the compilation
    of its Vulkan shaders as well, so SCons drives CMake and takes the result.
    """
    destination = os.path.abspath(os.path.dirname(str(target[0])))
    os.makedirs(destination, exist_ok=True)
    process_env = _cmake_environment(env)

    if not os.path.isfile(os.path.join(KIMODO_BUILD_DIR, "CMakeCache.txt")):
        configure = [
            "cmake",
            "-S", KIMODO_SOURCE_DIR,
            "-B", KIMODO_BUILD_DIR,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DKIMODO_BUILD_TESTS=OFF",
            # The executable and the shared libraries it loads have to end up
            # beside each other. Windows counts a DLL as a runtime artifact
            # while ELF counts a .so as a library one, so both are set.
            "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=" + destination,
            "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=" + destination,
        ]
        print("Configuring kimodo.cpp in {} ...".format(KIMODO_BUILD_DIR))
        if subprocess.call(configure, env=process_env) != 0:
            print_error("kimodo.cpp failed to configure. Pass kimodo_native=no to build the addon without it.")
            return 1

    # Only this target: the fixture and parity executables link ggml-vulkan
    # unconditionally, and none of them is needed to generate a motion.
    build = ["cmake", "--build", KIMODO_BUILD_DIR, "--target", "kmd-generate"]
    print("Building kmd-generate ...")
    if subprocess.call(build, env=process_env) != 0:
        print_error("kmd-generate failed to build. Pass kimodo_native=no to build the addon without it.")
        return 1
    return 0
