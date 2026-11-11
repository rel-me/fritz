cmake_minimum_required(VERSION 3.21)
project(FritzChromium LANGUAGES C CXX OBJCXX)

list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)

add_library(FritzChromium SHARED Chromium.mm)
set_target_properties(FritzChromium PROPERTIES INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR YES)
target_compile_options(FritzChromium PRIVATE -fobjc-arc)
target_compile_features(FritzChromium PRIVATE cxx_std_20)
target_include_directories(FritzChromium PRIVATE "${CEF_ROOT}")
target_link_libraries(FritzChromium PRIVATE libcef_dll_wrapper "-framework AppKit")

add_executable(FritzChromiumHelper Helper.cc)
target_compile_features(FritzChromiumHelper PRIVATE cxx_std_20)
target_include_directories(FritzChromiumHelper PRIVATE "${CEF_ROOT}")
target_link_libraries(FritzChromiumHelper PRIVATE libcef_dll_wrapper "-framework AppKit")
