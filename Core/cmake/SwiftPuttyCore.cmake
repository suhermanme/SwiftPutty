# SwiftPutty core library, built inside upstream PuTTY's own CMake build.
#
# This file is injected with
#     -DCMAKE_PROJECT_putty_INCLUDE=<this file> -DSWIFTPUTTY_ROOT=<repo root>
# (CMake's documented code-injection hook), so upstream's CMakeLists.txt
# stays unmodified. It defers the actual target definitions until the end
# of upstream's top-level CMakeLists.txt, when all upstream targets and
# directory-level compile settings exist. See docs/DECISIONS.md D-010.

if(SWIFTPUTTY_CORE_INJECTED)
  return()
endif()
set(SWIFTPUTTY_CORE_INJECTED TRUE)

if(NOT SWIFTPUTTY_ROOT)
  message(FATAL_ERROR "SWIFTPUTTY_ROOT must be set")
endif()

# Must run at directory level before targets are processed; it has no
# effect from a deferred call.
enable_testing()

# The macOS SDK marks sprintf() deprecated. Upstream's uses are bounded
# and deliberate, and at -O1 and above _FORTIFY_SOURCE routes them through
# __sprintf_chk anyway, so the warning only appears in -O0 builds. Silence
# that one category for upstream code; the bridge re-enables it below.
add_compile_options(-Wno-deprecated-declarations)

function(swiftputty_define_core)
  set(P ${CMAKE_SOURCE_DIR})
  set(B ${SWIFTPUTTY_ROOT}/Core)

  # The backend list, as upstream's be_list() would generate for a
  # PuTTY-like GUI tool with every backend available on Unix.
  add_library(swiftputty-be-list OBJECT ${P}/be_list.c)
  target_compile_definitions(swiftputty-be-list PRIVATE
    SSH=1 SERIAL=1 OTHERBACKENDS=1 APPNAME=SwiftPutty)

  # Upstream's Unix storage is used unmodified for host keys, host CAs and
  # the random seed (its location is redirected with PUTTYDIR). Its
  # *session* functions are renamed out of the way, because the bridge
  # provides in-memory session settings (Core/src/spb_storage.c).
  add_library(swiftputty-unix-storage OBJECT ${P}/unix/storage.c)
  target_compile_definitions(swiftputty-unix-storage PRIVATE
    settings_w=upstream_settings_w
    settings_r=upstream_settings_r
    settings_e=upstream_settings_e
    open_settings_w=upstream_open_settings_w
    write_setting_s=upstream_write_setting_s
    write_setting_i=upstream_write_setting_i
    write_setting_filename=upstream_write_setting_filename
    write_setting_fontspec=upstream_write_setting_fontspec
    close_settings_w=upstream_close_settings_w
    open_settings_r=upstream_open_settings_r
    read_setting_s=upstream_read_setting_s
    read_setting_i=upstream_read_setting_i
    read_setting_filename=upstream_read_setting_filename
    read_setting_fontspec=upstream_read_setting_fontspec
    close_settings_r=upstream_close_settings_r
    del_settings=upstream_del_settings
    enum_settings_start=upstream_enum_settings_start
    enum_settings_next=upstream_enum_settings_next
    enum_settings_finish=upstream_enum_settings_finish)

  # Objects from upstream libraries used whole. Besides each library's
  # own sources, upstream attaches object libraries to them (logging,
  # sshcommon, all-backends, and the CPU-specific crypto implementations
  # that crypto/CMakeLists.txt compiles with special flags only when the
  # compiler supports them), so collect those too, deduplicated.
  set(upstream_objects)
  foreach(lib sshclient otherbackends network crypto utils charset)
    list(APPEND upstream_objects $<TARGET_OBJECTS:${lib}>)
    get_target_property(lib_sources ${lib} SOURCES)
    foreach(src IN LISTS lib_sources)
      if(src MATCHES "^\\$<TARGET_OBJECTS:")
        list(APPEND upstream_objects ${src})
      endif()
    endforeach()
  endforeach()
  list(REMOVE_DUPLICATES upstream_objects)

  # Exclude ssh/ca-config.c: it only describes upstream's portable "Host
  # CA" configuration dialog (ctrl_*/dlg_* API), which SwiftPutty replaces
  # with native UI over the host_ca_* storage API.
  set(filtered_objects)
  foreach(objs IN LISTS upstream_objects)
    list(APPEND filtered_objects "$<FILTER:${objs},EXCLUDE,/ca-config\\.c\\.o$>")
  endforeach()
  set(upstream_objects ${filtered_objects})

  add_library(swiftputty-core STATIC
    # SwiftPutty bridge
    ${B}/src/spb_core.c
    ${B}/src/spb_eventloop.c
    ${B}/src/spb_platform.c
    ${B}/src/spb_seat.c
    ${B}/src/spb_session.c
    ${B}/src/spb_settings.c
    ${B}/src/spb_storage.c

    # Event-loop primitives (upstream's 'eventloop' library minus
    # unix/cliloop.c, whose loop and uxsel hooks the bridge replaces)
    ${P}/callback.c
    ${P}/timing.c
    ${P}/unix/uxsel.c

    # Conf <-> saved-settings mapping (upstream's 'settings' library minus
    # unix/storage.c and the command-line parser)
    ${P}/settings.c

    # Terminal and line discipline (upstream's 'guiterminal' library minus
    # the portable dialog description config.c/dialog.c, which SwiftPutty
    # replaces with native UI)
    ${P}/terminal/terminal.c
    ${P}/terminal/bidi.c
    ${P}/terminal/lineedit.c
    ${P}/ldisc.c

    # Unix platform pieces that GUI frontends link individually
    ${P}/unix/unicode.c
    ${P}/unix/no-gtk.c
    ${P}/unix/printing.c

    $<TARGET_OBJECTS:swiftputty-be-list>
    $<TARGET_OBJECTS:swiftputty-unix-storage>
    ${upstream_objects})
  target_include_directories(swiftputty-core PUBLIC ${B}/include)
  target_include_directories(swiftputty-core PRIVATE ${B}/src)
  add_dependencies(swiftputty-core generated_licence_h cmake_commit_c)
  set_target_properties(swiftputty-core PROPERTIES OUTPUT_NAME SwiftPuttyCore)

  # Repack the archive with unique member names (see RepackArchive.cmake).
  set(all_objects
    $<TARGET_OBJECTS:swiftputty-core>
    $<TARGET_OBJECTS:swiftputty-be-list>
    $<TARGET_OBJECTS:swiftputty-unix-storage>
    ${upstream_objects})
  set(object_list ${CMAKE_BINARY_DIR}/swiftputty-core-objects.txt)
  file(GENERATE OUTPUT ${object_list}
    CONTENT "$<JOIN:$<REMOVE_DUPLICATES:${all_objects}>,\n>\n")
  add_custom_command(TARGET swiftputty-core POST_BUILD
    COMMAND ${CMAKE_COMMAND}
      -DOBJECT_LIST=${object_list}
      -DBASE_DIR=${CMAKE_BINARY_DIR}
      -DSTAGING_DIR=${CMAKE_BINARY_DIR}/swiftputty-core-objects
      -DOUTPUT=$<TARGET_FILE:swiftputty-core>
      -DSOURCE_ROOT=${SWIFTPUTTY_ROOT}
      -P ${B}/cmake/RepackArchive.cmake
    VERBATIM)

  # Bridge code is held to a stricter warning standard than upstream.
  set_source_files_properties(
    ${B}/src/spb_core.c ${B}/src/spb_eventloop.c ${B}/src/spb_platform.c
    ${B}/src/spb_seat.c ${B}/src/spb_session.c
    ${B}/src/spb_settings.c ${B}/src/spb_storage.c
    TARGET_DIRECTORY swiftputty-core
    PROPERTIES COMPILE_OPTIONS
      "-Wall;-Wextra;-Werror;-Wno-unused-parameter;-Wdeprecated-declarations")

  # C-level bridge tests
  add_executable(spb_bridge_test ${B}/tests/spb_bridge_test.c)
  # Upstream applies link_libraries(-lm -ldl) to its whole directory; the
  # core library already carries those, so link it alone to avoid
  # duplicate-library linker warnings.
  set_property(TARGET spb_bridge_test PROPERTY LINK_LIBRARIES swiftputty-core)
  target_compile_options(spb_bridge_test PRIVATE
    -Wall -Wextra -Werror -Wno-unused-parameter -Wdeprecated-declarations)
  add_test(NAME spb_bridge_test COMMAND spb_bridge_test)

  # Core thread, session executor and Raw sessions against a local
  # server (M02).
  add_executable(spb_session_test ${B}/tests/spb_session_test.c)
  set_property(TARGET spb_session_test PROPERTY LINK_LIBRARIES
    swiftputty-core)
  target_compile_options(spb_session_test PRIVATE
    -Wall -Wextra -Werror -Wno-unused-parameter -Wdeprecated-declarations)
  add_test(NAME spb_session_test COMMAND spb_session_test)

  # Link every archive member, not just the ones a program happens to
  # reference, so that any unresolved symbol in the core fails the build.
  add_executable(spb_link_closure_test ${B}/tests/spb_link_closure_test.c)
  target_include_directories(spb_link_closure_test PRIVATE ${B}/include)
  set_property(TARGET spb_link_closure_test PROPERTY LINK_LIBRARIES
    "-Wl,-force_load,$<TARGET_FILE:swiftputty-core>")
  add_dependencies(spb_link_closure_test swiftputty-core)
  add_test(NAME spb_link_closure_test COMMAND spb_link_closure_test)
endfunction()

cmake_language(DEFER DIRECTORY ${CMAKE_SOURCE_DIR}
  CALL swiftputty_define_core)
