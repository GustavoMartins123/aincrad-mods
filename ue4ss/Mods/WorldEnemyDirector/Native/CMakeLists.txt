cmake_minimum_required(VERSION 3.22)

project(WorldEnemyDirectorNative LANGUAGES CXX)

add_library(WorldEnemyDirectorNative SHARED src/main.cpp)
target_compile_features(WorldEnemyDirectorNative PRIVATE cxx_std_20)
target_compile_definitions(WorldEnemyDirectorNative PRIVATE
    NOMINMAX
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
)

if(MSVC)
    target_compile_options(WorldEnemyDirectorNative PRIVATE /W4 /permissive- /EHsc /utf-8)
    set_property(TARGET WorldEnemyDirectorNative PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()

set_target_properties(WorldEnemyDirectorNative PROPERTIES
    OUTPUT_NAME "main"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../dlls"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/../dlls"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_CURRENT_SOURCE_DIR}/../dlls"
)
