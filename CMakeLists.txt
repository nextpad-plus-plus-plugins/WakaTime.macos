cmake_minimum_required(VERSION 3.20)
project(WakaTime VERSION 5.1.2 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Host plugin interface + Scintilla (read-only; NO host changes)
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")
set(SCINTILLA_INCLUDE  "${NPP_MACOS_DIR}/scintilla/include")

add_library(WakaTime SHARED src/WakaTime.mm)
target_include_directories(WakaTime PRIVATE ${NPP_PLUGIN_INCLUDE} ${SCINTILLA_INCLUDE})
target_link_libraries(WakaTime PRIVATE "-framework Cocoa")
target_compile_options(WakaTime PRIVATE
    -Wall -Wno-unused-parameter -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(WakaTime PROPERTIES PREFIX "" SUFFIX ".dylib")
target_link_options(WakaTime PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

# Install (real plugins dir). Toolbar PNGs live at the plugin root (host looks
# there first). WakaTime reads its config from the shared ~/.wakatime.cfg, so it
# bundles no resource data.
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/WakaTime")
install(TARGETS WakaTime DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES "${CMAKE_SOURCE_DIR}/toolbar.png" "${CMAKE_SOURCE_DIR}/toolbar_dark.png"
        DESTINATION "${PLUGIN_INSTALL_DIR}")
