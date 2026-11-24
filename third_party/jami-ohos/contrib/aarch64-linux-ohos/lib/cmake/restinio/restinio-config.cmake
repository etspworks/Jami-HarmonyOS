
####### Expanded from @PACKAGE_INIT@ by configure_package_config_file() #######
####### Any changes to this file will be overwritten by the next CMake run ####
####### The input file was restinio-config.cmake.in                            ########

get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)

macro(set_and_check _var _file)
  set(${_var} "${_file}")
  if(NOT EXISTS "${_file}")
    message(FATAL_ERROR "File or directory ${_file} referenced by variable ${_var} does not exist !")
  endif()
endmacro()

macro(check_required_components _NAME)
  foreach(comp ${${_NAME}_FIND_COMPONENTS})
    if(NOT ${_NAME}_${comp}_FOUND)
      if(${_NAME}_FIND_REQUIRED_${comp})
        set(${_NAME}_FOUND FALSE)
      endif()
    endif()
  endforeach()
endmacro()

####################################################################################

set(RESTINIO_ASIO_SOURCE standalone)
set(RESTINIO_DEP_STANDALONE_ASIO system)
set(RESTINIO_DEP_BOOST_ASIO find)

set(RESTINIO_DEP_LLHTTP system)
set(RESTINIO_DEP_FMT system)
set(RESTINIO_DEP_EXPECTED_LITE system)

include(CMakeFindDependencyMacro)

if(RESTINIO_ASIO_SOURCE STREQUAL "standalone")
    if (RESTINIO_DEP_STANDALONE_ASIO STREQUAL "find")
        find_dependency(asio)
    endif ()
else ()
    if (RESTINIO_DEP_BOOST_ASIO STREQUAL "find")
        find_dependency(Boost)
    endif ()
endif ()

if (RESTINIO_DEP_LLHTTP STREQUAL "find")
    find_dependency(llhttp)
endif ()

if (RESTINIO_DEP_FMT STREQUAL "find")
    find_dependency(fmt)
endif ()

if (RESTINIO_DEP_EXPECTED_LITE STREQUAL "find")
    find_dependency(expected-lite)
endif ()

include(${CMAKE_CURRENT_LIST_DIR}/restinio-targets.cmake)
