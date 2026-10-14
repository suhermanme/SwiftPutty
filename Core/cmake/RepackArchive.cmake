# Rebuild a static archive so that every member has a unique name.
#
#   cmake -DOBJECT_LIST=<file> -DBASE_DIR=<dir> -DSTAGING_DIR=<dir>
#         -DOUTPUT=<archive> [-DSOURCE_ROOT=<dir>] -P RepackArchive.cmake
#
# Archives store only object basenames, and upstream PuTTY has several
# same-named sources in different directories (ssh/sharing.c and
# unix/sharing.c, crypto/rsa.c and keygen/rsa.c, ...). With deterministic
# (zeroed) archive timestamps, dsymutil cannot tell such members apart
# and drops their debug information. Members are therefore named after
# their path relative to BASE_DIR. CMake places objects for sources
# outside the build tree under their absolute source path; SOURCE_ROOT is
# stripped from those so that names do not depend on the checkout path.

foreach(var OBJECT_LIST BASE_DIR STAGING_DIR OUTPUT)
  if(NOT ${var})
    message(FATAL_ERROR "${var} must be set")
  endif()
endforeach()

file(STRINGS "${OBJECT_LIST}" objects)
file(REMOVE_RECURSE "${STAGING_DIR}")
file(MAKE_DIRECTORY "${STAGING_DIR}")

set(staged)
foreach(object IN LISTS objects)
  file(RELATIVE_PATH rel "${BASE_DIR}" "${object}")
  if(SOURCE_ROOT)
    string(REGEX REPLACE "^/" "" source_root_rel "${SOURCE_ROOT}")
    string(REPLACE "${source_root_rel}/" "" rel "${rel}")
  endif()
  string(REPLACE "CMakeFiles/" "" rel "${rel}")
  string(REPLACE "/__/" "/" rel "${rel}")      # CMake encodes ../ as __
  string(REPLACE ".dir/" "/" rel "${rel}")
  string(REGEX REPLACE "[/\\.]+" "_" name "${rel}")
  string(REGEX REPLACE "_o$" ".o" name "${name}")
  if(EXISTS "${STAGING_DIR}/${name}")
    message(FATAL_ERROR "Archive member name collision: ${name}")
  endif()
  file(COPY_FILE "${object}" "${STAGING_DIR}/${name}")
  list(APPEND staged "${STAGING_DIR}/${name}")
endforeach()

file(REMOVE "${OUTPUT}")
execute_process(
  COMMAND libtool -static -D -no_warning_for_no_symbols -o "${OUTPUT}" ${staged}
  RESULT_VARIABLE result)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "libtool failed (${result})")
endif()
