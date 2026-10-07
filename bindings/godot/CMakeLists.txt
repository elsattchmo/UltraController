cmake_minimum_required(VERSION 3.22)
project(sinew_godot LANGUAGES C CXX)

# Sinew's Godot binding: a GDExtension (godot-cpp 4.5 API, loads in Godot 4.5+ incl. 4.7)
# that links the engine-agnostic core. Output goes straight into addons/sinew/bin/.
#   cmake -S bindings/godot -B build/godot -DGODOTCPP_TARGET=template_debug
#   cmake --build build/godot --config Release

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# One MSVC runtime for everything linked into the DLL: the static one, as Box3D and godot-cpp
# (GODOTCPP_USE_STATIC_CPP) use. godot-cpp sets it on its own target only - the binding's own
# objects came out /MD and the link failed (LNK2038 'MT_StaticRelease' vs 'MD_DynamicRelease').
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# godot-cpp first.
add_subdirectory(godot-cpp)
set(SINEW_TESTS OFF CACHE BOOL "" FORCE)
set(SINEW_CAPI_SHARED OFF CACHE BOOL "" FORCE)
add_subdirectory(../../sinew sinew)

add_library(sinew_godot SHARED
	src/register_types.cpp
	src/sinew_physics.cpp
)
target_link_libraries(sinew_godot PRIVATE godot-cpp sinew_core)

get_target_property(GODOTCPP_SUFFIX godot-cpp GODOTCPP_SUFFIX)
set(OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../addons/sinew/bin/")
set_target_properties(sinew_godot PROPERTIES
	CXX_VISIBILITY_PRESET hidden
	PREFIX "lib"
	OUTPUT_NAME "sinew${GODOTCPP_SUFFIX}"
	LIBRARY_OUTPUT_DIRECTORY "$<1:${OUTPUT_DIR}>"
	RUNTIME_OUTPUT_DIRECTORY "$<1:${OUTPUT_DIR}>"
	PDB_OUTPUT_DIRECTORY "$<1:${CMAKE_CURRENT_BINARY_DIR}/pdb>"
)
