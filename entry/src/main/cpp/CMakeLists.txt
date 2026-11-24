# libjami.so — the NAPI binding of the Jami daemon (napi_jami.cpp) linked against the daemon
# and its contribs, cross-compiled for HarmonyOS by jami-daemon-ohos/compile-ohos.sh.
cmake_minimum_required(VERSION 3.5.0)
project(jami_napi CXX C)

set(CMAKE_CXX_STANDARD 20)

# Prebuilt daemon: the copy shipped inside the project (third_party/jami-ohos, holding only
# install-ohos/ and contrib/aarch64-linux-ohos/) wins, so a handed-over project folder builds on
# its own. Otherwise the daemon worktree next to round_0_v2 (…/_jami/jami-daemon-ohos).
get_filename_component(JAMI_OHOS_BUNDLED "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/jami-ohos" ABSOLUTE)
get_filename_component(JAMI_OHOS_SIBLING "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../jami-daemon-ohos" ABSOLUTE)
if(EXISTS "${JAMI_OHOS_BUNDLED}/install-ohos")
    set(JAMI_OHOS_DEFAULT "${JAMI_OHOS_BUNDLED}")
else()
    set(JAMI_OHOS_DEFAULT "${JAMI_OHOS_SIBLING}")
endif()
set(JAMI_OHOS_ROOT "${JAMI_OHOS_DEFAULT}" CACHE PATH "jami-daemon-ohos checkout")
set(JAMI_INSTALL "${JAMI_OHOS_ROOT}/install-ohos")
set(JAMI_CONTRIB "${JAMI_OHOS_ROOT}/contrib/aarch64-linux-ohos")

add_library(jami SHARED napi_jami.cpp)
target_include_directories(jami PRIVATE "${JAMI_INSTALL}/include" "${JAMI_CONTRIB}/include")

file(GLOB JAMI_STATIC_LIBS "${JAMI_INSTALL}/lib/*.a" "${JAMI_CONTRIB}/lib/*.a")
# Static archives depend on each other in no fixed order; let the linker resolve them as a group.
target_link_libraries(jami PRIVATE
    -Wl,--start-group ${JAMI_STATIC_LIBS} -Wl,--end-group
    libace_napi.z.so libhilog_ndk.z.so ohaudio native_window native_buffer image_receiver ohimage dl m)
