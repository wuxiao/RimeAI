#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
corpora_root=${RIMEAI_CORPORA_ROOT:-"${project_root}/.rimeai/corpora"}
wikivoyage_file="${corpora_root}/zhwikivoyage-20260701-pages-articles.xml.bz2"
wikivoyage_url="https://dumps.wikimedia.org/zhwikivoyage/20260701/zhwikivoyage-20260701-pages-articles.xml.bz2"
wikivoyage_sha1="161380a9ec5e1a30b217667c18849b6610ca2544"
mdn_revision="9780b8cb15f9973e0bfbf5a5d60d3461b3d386ef"
mdn_archive="${corpora_root}/mdn-zh-cn-${mdn_revision[1,7]}.tar.gz"

mkdir -p "${corpora_root}"

if [[ ! -f ${wikivoyage_file} ]] ||
   [[ $(shasum -a 1 "${wikivoyage_file}" | awk '{print $1}') != ${wikivoyage_sha1} ]]; then
  temporary_file=$(mktemp "${corpora_root}/wikivoyage.XXXXXX")
  cleanup_download() {
    if [[ -f ${temporary_file} ]]; then
      command rm -f -- "${temporary_file}"
    fi
  }
  trap cleanup_download EXIT
  curl --fail --location --retry 3 --output "${temporary_file}" \
    "${wikivoyage_url}"
  actual_sha1=$(shasum -a 1 "${temporary_file}" | awk '{print $1}')
  if [[ ${actual_sha1} != ${wikivoyage_sha1} ]]; then
    print -u2 "error: Wikivoyage dump SHA-1 mismatch"
    exit 2
  fi
  mv "${temporary_file}" "${wikivoyage_file}"
  trap - EXIT
fi

if [[ ! -f ${mdn_archive} ]]; then
  checkout_root=$(mktemp -d /tmp/rimeai-mdn-checkout.XXXXXX)
  archive_stage=$(mktemp /tmp/rimeai-mdn-content.XXXXXX.tar.gz)
  cleanup_mdn() {
    case ${checkout_root} in
      /tmp/rimeai-mdn-checkout.*)
        command rm -rf -- "${checkout_root}"
        ;;
    esac
    case ${archive_stage} in
      /tmp/rimeai-mdn-content.*.tar.gz)
        command rm -f -- "${archive_stage}"
        ;;
    esac
  }
  trap cleanup_mdn EXIT
  git clone --quiet --filter=blob:none --no-checkout \
    https://github.com/mdn/translated-content.git "${checkout_root}"
  git -C "${checkout_root}" sparse-checkout init --cone
  git -C "${checkout_root}" sparse-checkout set files/zh-cn
  git -C "${checkout_root}" checkout --quiet --detach "${mdn_revision}"
  COPYFILE_DISABLE=1 tar -czf "${archive_stage}" \
    -C "${checkout_root}/files/zh-cn" .
  tar -tzf "${archive_stage}" >/dev/null
  command cp "${archive_stage}" "${mdn_archive}"
  command rm -f -- "${archive_stage}"
  command rm -rf -- "${checkout_root}"
  trap - EXIT
fi

print -r -- "wikivoyage=${wikivoyage_file}"
print -r -- "mdn=${mdn_archive}"
