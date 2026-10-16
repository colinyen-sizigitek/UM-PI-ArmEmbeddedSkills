# TX8Flags.cmake -- compiler flags for TX8 (Cortex-A53, GCC 11), per DESIGN.md section 3.3.
#
#   list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
#   include(TX8Flags)
#   add_executable(myapp src/main.cpp src/postproc_neon.cpp)
#   tx8_apply_flags(myapp)                       # global baseline
#   tx8_hot_file(src/postproc_neon.cpp)          # -O3 + vectorizer report for hot files only
#
# Options:
#   TX8_ENABLE_CRYPTO  (OFF) -mcpu=cortex-a53+crypto; only if the code uses AES/SHA/PMULL.
#   TX8_A53_ERRATA     (OFF) -mfix-cortex-a53-835769/-843419; set after checking CPU revision
#                            on the board (see tx8-platform references/board-facts.md section 2).
#   TX8_SANITIZE       (OFF) ASan + UBSan for test builds. Never for release/deployment.
#   TX8_WERROR         (ON)  -Werror on project targets.

include_guard(GLOBAL)

option(TX8_ENABLE_CRYPTO "Enable Armv8 Crypto extension (+crypto)" OFF)
option(TX8_A53_ERRATA    "Enable Cortex-A53 erratum 835769/843419 workarounds (safe default ON)" ON)
option(TX8_SANITIZE      "Build with AddressSanitizer + UndefinedBehaviorSanitizer (tests only)" OFF)
option(TX8_WERROR        "Treat warnings as errors on project targets" ON)

if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  message(WARNING "TX8Flags: compiler is ${CMAKE_CXX_COMPILER_ID}; the TX8 baseline is GCC 11 "
                  "(LLVM's Cortex-A53 scheduling model is inaccurate).")
endif()

if(TX8_SANITIZE AND CMAKE_BUILD_TYPE STREQUAL "Release")
  message(WARNING "TX8_SANITIZE=ON with Release: sanitizer builds must not be deployed.")
endif()

if(TX8_ENABLE_CRYPTO)
  set(TX8_MCPU "-mcpu=cortex-a53+crypto")
else()
  set(TX8_MCPU "-mcpu=cortex-a53")
endif()

# Only add AArch64 flags when actually targeting aarch64 (lets host unit tests build on x86).
set(_tx8_is_arm64 OFF)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
  set(_tx8_is_arm64 ON)
endif()

function(tx8_apply_flags target)
  if(NOT TARGET ${target})
    message(FATAL_ERROR "tx8_apply_flags: '${target}' is not a target")
  endif()

  target_compile_features(${target} PRIVATE cxx_std_17)

  set(_opts -Wall -Wextra)
  if(TX8_WERROR)
    list(APPEND _opts -Werror)
  endif()

  if(_tx8_is_arm64)
    list(APPEND _opts ${TX8_MCPU} -mno-outline-atomics)
    if(TX8_A53_ERRATA)
      list(APPEND _opts -mfix-cortex-a53-835769 -mfix-cortex-a53-843419)
      target_link_options(${target} PRIVATE -mfix-cortex-a53-835769 -mfix-cortex-a53-843419)
    endif()
  endif()

  # Baseline optimisation: -O2 for Release/RelWithDebInfo (overrides CMake's default -O3 for Release).
  list(APPEND _opts $<$<CONFIG:Release>:-O2> $<$<CONFIG:RelWithDebInfo>:-O2>)
  target_compile_options(${target} PRIVATE ${_opts})

  if(TX8_SANITIZE)
    target_compile_options(${target} PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer -g -O1)
    target_link_options(${target} PRIVATE -fsanitize=address,undefined)
  endif()
endfunction()

# Mark hot translation units: -O3 and a missed-vectorization report (appears in build output).
# Source file properties are directory-scoped: call this in the same CMakeLists.txt that adds the files.
function(tx8_hot_file)
  foreach(_f IN LISTS ARGN)
    set_property(SOURCE ${_f} APPEND PROPERTY COMPILE_OPTIONS -O3 -fopt-info-vec-missed)
  endforeach()
endfunction()

# CMake's default Release flags contain "-O3 -DNDEBUG"; replace with "-DNDEBUG" so the
# per-target -O2 above is the effective level (hot files still get -O3, which comes later).
foreach(_cfg RELEASE RELWITHDEBINFO)
  foreach(_lang C CXX)
    string(REGEX REPLACE "(^| )-O[0-9s]( |$)" " " CMAKE_${_lang}_FLAGS_${_cfg} "${CMAKE_${_lang}_FLAGS_${_cfg}}")
  endforeach()
endforeach()
