# tx8-toolchain-aarch64.cmake -- cross toolchain for the TX8 (4x Cortex-A53, Ubuntu 22.04, glibc 2.35)
#
# Usage (WSL2 Ubuntu 22.04):
#   sudo apt install g++-11-aarch64-linux-gnu          # engineer installs; GCC 11 matches the board
#   export TX8_SYSROOT=$HOME/tx8-sysroot               # copied from the board, see build-and-deploy.md
#   cmake -S . -B build/cross -DCMAKE_TOOLCHAIN_FILE=cmake/tx8-toolchain-aarch64.cmake -DCMAKE_BUILD_TYPE=Release
#
# Optional overrides: -DTX8_SYSROOT=/path  -DTX8_CROSS_PREFIX=aarch64-linux-gnu-  -DTX8_GCC_SUFFIX=-11
# Do NOT point this at Arm GNU Toolchain 13.x-15.x: its glibc/libstdc++ do not match the board.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT DEFINED TX8_CROSS_PREFIX)
  set(TX8_CROSS_PREFIX "aarch64-linux-gnu-")
endif()
if(NOT DEFINED TX8_GCC_SUFFIX)
  set(TX8_GCC_SUFFIX "-11")
endif()

set(CMAKE_C_COMPILER   "${TX8_CROSS_PREFIX}gcc${TX8_GCC_SUFFIX}")
set(CMAKE_CXX_COMPILER "${TX8_CROSS_PREFIX}g++${TX8_GCC_SUFFIX}")

# Sysroot: cache variable > environment variable TX8_SYSROOT.
if(NOT DEFINED TX8_SYSROOT AND DEFINED ENV{TX8_SYSROOT})
  set(TX8_SYSROOT "$ENV{TX8_SYSROOT}")
endif()
# Toolchain files are re-read for try_compile projects; forward the variables.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES TX8_SYSROOT TX8_CROSS_PREFIX TX8_GCC_SUFFIX)

if(DEFINED TX8_SYSROOT AND NOT TX8_SYSROOT STREQUAL "")
  if(NOT EXISTS "${TX8_SYSROOT}/usr/include")
    message(FATAL_ERROR "TX8_SYSROOT='${TX8_SYSROOT}' has no usr/include. Pull it from the board first.")
  endif()
  set(CMAKE_SYSROOT "${TX8_SYSROOT}")
  set(CMAKE_FIND_ROOT_PATH "${TX8_SYSROOT}")

  # pkg-config must look only inside the sysroot.
  set(ENV{PKG_CONFIG_SYSROOT_DIR} "${TX8_SYSROOT}")
  set(ENV{PKG_CONFIG_LIBDIR}
      "${TX8_SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${TX8_SYSROOT}/usr/lib/pkgconfig:${TX8_SYSROOT}/usr/share/pkgconfig")
  set(ENV{PKG_CONFIG_PATH} "")
else()
  message(WARNING "TX8_SYSROOT not set: building against the cross compiler's own sysroot. "
                  "MemryX/TurboJPEG libraries will not be found; use a sysroot copied from the board.")
endif()

# Programs (code generators) run on the host; libraries/headers/packages come from the target.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# The baseline -mcpu and warnings are set per target by TX8Flags.cmake (tx8_apply_flags).
