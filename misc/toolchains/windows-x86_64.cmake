# Building kimodo.cpp for Windows from a Linux host, with mingw-w64.
#
# Only the toolchain lives here. Where the Vulkan headers, the loader import
# library and glslc are is passed on the command line through KIMODO_CMAKE_ARGS,
# because that depends on how the SDK was obtained rather than on the compiler.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(KIMODO_MINGW_PREFIX x86_64-w64-mingw32)
set(CMAKE_C_COMPILER   ${KIMODO_MINGW_PREFIX}-gcc)
set(CMAKE_CXX_COMPILER ${KIMODO_MINGW_PREFIX}-g++)
set(CMAKE_RC_COMPILER  ${KIMODO_MINGW_PREFIX}-windres)
set(CMAKE_AR           ${KIMODO_MINGW_PREFIX}-ar)
set(CMAKE_RANLIB       ${KIMODO_MINGW_PREFIX}-ranlib)
set(CMAKE_DLLTOOL      ${KIMODO_MINGW_PREFIX}-dlltool)

set(CMAKE_FIND_ROOT_PATH /usr/${KIMODO_MINGW_PREFIX})
# Programs stay the host's. glslc emits SPIR-V and so does not care what it is
# compiling for, and ggml builds its shader generator for the host by itself
# once CMAKE_CROSSCOMPILING is set.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
# SPIRV-Headers is header-only and arrives through CMAKE_PREFIX_PATH, which is
# outside the root above.
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# Nothing on the far side ships a GCC runtime, and the machine that loads these
# has no reason to have one, so it goes inside them.
set(KIMODO_STATIC_RUNTIME "-static-libgcc -static-libstdc++ -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${KIMODO_STATIC_RUNTIME}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${KIMODO_STATIC_RUNTIME}")
