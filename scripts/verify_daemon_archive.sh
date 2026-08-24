#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 RELEASE_ARCHIVE.tar.gz"
  exit 2
fi

archive_file=${1:A}
if [[ ! -f "${archive_file}" || -L "${archive_file}" ]]; then
  print -u2 "error: expected a regular gzip-compressed release archive"
  exit 2
fi

temporary_root=$(mktemp -d /tmp/rimeai-archive-verify.XXXXXX)
cleanup() {
  case "${temporary_root}" in
    /tmp/rimeai-archive-verify.*) find "${temporary_root}" -depth -delete ;;
    *) print -u2 "error: refusing to clean unexpected path: ${temporary_root}" ;;
  esac
}
trap cleanup EXIT

archive_entries=("${(@f)$(tar -tzf "${archive_file}")}")
if (( ${#archive_entries} == 0 )); then
  print -u2 "error: release archive is empty"
  exit 1
fi
for archive_entry in "${archive_entries[@]}"; do
  if [[ "${archive_entry}" == /* \
    || "${archive_entry}" == *$'\n'* \
    || "/${archive_entry}/" == *'/../'* ]]; then
    print -u2 "error: unsafe path in release archive: ${archive_entry}"
    exit 1
  fi
done

COPYFILE_DISABLE=1 tar -xzf "${archive_file}" -C "${temporary_root}"
top_level_entries=("${temporary_root}"/*(DN))
if (( ${#top_level_entries} != 1 )) \
  || [[ ! -d "${top_level_entries[1]}" || -L "${top_level_entries[1]}" ]]; then
  print -u2 "error: release archive must contain exactly one directory"
  exit 1
fi
"${0:A:h}/verify_daemon_release.sh" "${top_level_entries[1]}"
print -r -- "archive_sha256=$(shasum -a 256 "${archive_file}" | awk '{ print $1 }')"
