cmake_minimum_required(VERSION 3.22)
project(sinew VERSION 0.1.0 LANGUAGES C CXX)

# Sinew core: engine-agnostic C++17 on Box3D. Bindings (bindings/godot, later Unity /
# Unreal) link sinew_core; sinew_capi is the shared C library for engines that bind via C.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)   # the core goes into shared libraries

option(SINEW_TESTS "Build the Sinew tests" ${PROJECT_IS_TOP_LEVEL})
option(SINEW_CAPI_SHARED "Build the shared C API library" ${PROJECT_IS_TOP_LEVEL})

# Box3D (MIT, pinned submodule). Its own samples / tests are skipped when it isn't top level.
set(BOX3D_VALIDATE OFF CACHE BOOL "" FORCE)
add_subdirectory(extern/box3d EXCLUDE_FROM_ALL)

find_package(Git QUIET)
set(SINEW_BOX3D_COMMIT "unknown")
if(GIT_FOUND)
	execute_process(COMMAND ${GIT_EXECUTABLE} -C ${CMAKE_CURRENT_SOURCE_DIR}/extern/box3d rev-parse --short HEAD
		OUTPUT_VARIABLE SINEW_BOX3D_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
endif()

add_library(sinew_core STATIC
	src/physics_world.cpp
	src/version.cpp
	capi/sinew_capi.cpp
)
target_include_directories(sinew_core PUBLIC include capi)
target_link_libraries(sinew_core PRIVATE box3d)
target_compile_definitions(sinew_core PRIVATE SINEW_BOX3D_COMMIT="${SINEW_BOX3D_COMMIT}")

if(SINEW_CAPI_SHARED)
	add_library(sinew_capi SHARED capi/sinew_capi.cpp src/physics_world.cpp src/version.cpp)
	target_include_directories(sinew_capi PUBLIC include capi)
	target_link_libraries(sinew_capi PRIVATE box3d)
	target_compile_definitions(sinew_capi PRIVATE SINEW_CAPI_SHARED SINEW_BOX3D_COMMIT="${SINEW_BOX3D_COMMIT}")
	set_target_properties(sinew_capi PROPERTIES CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden)
endif()

if(SINEW_TESTS)
	enable_testing()
	add_executable(sinew_tests
		tests/test_main.cpp
		tests/test_physics.cpp
		tests/test_capi.cpp
	)
	target_include_directories(sinew_tests PRIVATE extern/doctest)
	target_link_libraries(sinew_tests PRIVATE sinew_core)
	add_test(NAME sinew_tests COMMAND sinew_tests)
endif()
