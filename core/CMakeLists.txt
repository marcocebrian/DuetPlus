cmake_minimum_required(VERSION 3.18)
project(duet C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---- libopus (portable float C, no SIMD/RTCD: plenty fast for decoding) ----
set(OPUS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/opus)
file(STRINGS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/opus_files.txt OPUS_REL)
set(OPUS_SRC "")
foreach(f ${OPUS_REL})
  list(APPEND OPUS_SRC ${OPUS_DIR}/${f})
endforeach()
add_library(opus STATIC ${OPUS_SRC})
target_include_directories(opus PUBLIC ${OPUS_DIR}/include
  PRIVATE ${OPUS_DIR} ${OPUS_DIR}/celt ${OPUS_DIR}/silk ${OPUS_DIR}/silk/float)
target_compile_definitions(opus PRIVATE OPUS_BUILD USE_ALLOCA HAVE_LRINTF HAVE_LRINT
  "OPUS_VERSION=\"1.5.2\"")
target_compile_options(opus PRIVATE -O2 -w)

# ---- duet core ----
set(DUET_SRC src/clock.cpp src/track.cpp src/engine.cpp src/api.cpp src/transcode.cpp)
if(ANDROID)
  list(APPEND DUET_SRC src/backend_aaudio.cpp)
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  list(APPEND DUET_SRC src/backend_ios.mm)
else()
  list(APPEND DUET_SRC src/backend_null.cpp)
endif()

if(DUET_STATIC)
  add_library(duet STATIC ${DUET_SRC})
else()
  add_library(duet SHARED ${DUET_SRC})
endif()
target_include_directories(duet PUBLIC include)
target_compile_options(duet PRIVATE -O2)
target_link_libraries(duet PRIVATE opus)

if(ANDROID)
  target_link_libraries(duet PRIVATE aaudio log mediandk)
  target_link_options(duet PRIVATE "-Wl,-z,max-page-size=16384")
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set_source_files_properties(src/backend_ios.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_link_libraries(duet PRIVATE "-framework AudioToolbox" "-framework AVFoundation")
else()
  find_package(Threads REQUIRED)
  target_link_libraries(duet PRIVATE Threads::Threads m)
endif()

# Desktop test harness (macOS/Linux): algorithm tests without audio hardware.
if(DUET_TESTS)
  add_executable(duet_test tests/test_main.cpp)
  target_link_libraries(duet_test PRIVATE duet)
endif()
