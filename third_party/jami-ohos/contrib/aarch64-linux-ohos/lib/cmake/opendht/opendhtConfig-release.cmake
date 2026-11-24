#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "opendht" for configuration "Release"
set_property(TARGET opendht APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(opendht PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "/Users/isra/Desktop/_jami/jami-daemon-ohos/contrib/aarch64-linux-ohos/lib/libopendht.a"
  )

list(APPEND _cmake_import_check_targets opendht )
list(APPEND _cmake_import_check_files_for_opendht "/Users/isra/Desktop/_jami/jami-daemon-ohos/contrib/aarch64-linux-ohos/lib/libopendht.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
