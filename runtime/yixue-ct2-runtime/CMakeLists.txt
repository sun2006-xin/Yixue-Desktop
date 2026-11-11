cmake_minimum_required(VERSION 3.20)

project(yixue_ct2_runtime VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
  add_compile_options(/utf-8 /W4 /permissive-)
endif()

find_package(CTranslate2 CONFIG REQUIRED)

if(NOT DEFINED SENTENCEPIECE_SOURCE)
  message(FATAL_ERROR "SENTENCEPIECE_SOURCE must point to the pinned SentencePiece source")
endif()

set(SPM_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(SPM_ENABLE_TCMALLOC OFF CACHE BOOL "" FORCE)
set(SPM_BUILD_TEST OFF CACHE BOOL "" FORCE)
add_subdirectory(
  "${SENTENCEPIECE_SOURCE}"
  "${CMAKE_CURRENT_BINARY_DIR}/sentencepiece"
  EXCLUDE_FROM_ALL)

add_library(yixue_ct2_runtime SHARED
  src/yixue_ct2_runtime.cpp)

add_executable(yixue_ct2_worker
  src/worker_main.cpp)

target_compile_definitions(yixue_ct2_runtime PRIVATE YIXUE_CT2_RUNTIME_BUILD)
target_include_directories(yixue_ct2_runtime
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${SENTENCEPIECE_SOURCE}"
    "${SENTENCEPIECE_SOURCE}/src"
    "${SENTENCEPIECE_SOURCE}/third_party/abseil-cpp")
target_link_libraries(yixue_ct2_runtime
  PRIVATE CTranslate2::ctranslate2 sentencepiece-static)

target_link_libraries(yixue_ct2_worker
  PRIVATE yixue_ct2_runtime CTranslate2::ctranslate2)

set_target_properties(yixue_ct2_runtime PROPERTIES
  OUTPUT_NAME "yixue_ct2_runtime")

install(TARGETS yixue_ct2_runtime yixue_ct2_worker
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION bin
  ARCHIVE DESTINATION lib)
get_target_property(CTRANSLATE2_RUNTIME CTranslate2::ctranslate2 IMPORTED_LOCATION_RELEASE)
if(CTRANSLATE2_RUNTIME)
  install(FILES "${CTRANSLATE2_RUNTIME}" DESTINATION bin)
endif()
install(FILES include/yixue_ct2_runtime.h DESTINATION include)
