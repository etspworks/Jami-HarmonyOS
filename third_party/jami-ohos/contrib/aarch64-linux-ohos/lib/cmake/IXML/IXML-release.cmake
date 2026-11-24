#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "IXML::Static" for configuration "Release"
set_property(TARGET IXML::Static APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(IXML::Static PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "/Users/isra/Desktop/_jami/jami-daemon-ohos/contrib/aarch64-linux-ohos/lib/libixml.a"
  )

list(APPEND _cmake_import_check_targets IXML::Static )
list(APPEND _cmake_import_check_files_for_IXML::Static "/Users/isra/Desktop/_jami/jami-daemon-ohos/contrib/aarch64-linux-ohos/lib/libixml.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
