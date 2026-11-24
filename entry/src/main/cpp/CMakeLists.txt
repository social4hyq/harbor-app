cmake_minimum_required(VERSION 3.5)
project(harbor_bridge)

add_library(harbor_bridge SHARED harbor_bridge.c)

target_include_directories(harbor_bridge PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  $ENV{OHOS_NATIVE_SYSROOT}/usr/include/napi
  $ENV{OHOS_NATIVE_SYSROOT}/usr/include
)

set_target_properties(harbor_bridge PROPERTIES
  LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}
)
