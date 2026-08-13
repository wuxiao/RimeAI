#include "RimeBridgeC.h"

#include <cstdio>
#include <cstring>

namespace {

void collect_candidate(const char* text,
                       const char*,
                       size_t,
                       void* context) {
  if (text && text[0]) {
    ++*static_cast<size_t*>(context);
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: rime-native-smoke SHARED_DIR USER_DIR\n");
    return 2;
  }
  char error[512] = {};
  RAIEngine* engine = rai_engine_create(
      argv[1], argv[2], "luna_pinyin_simp", error, sizeof(error));
  if (!engine) {
    std::fprintf(stderr, "create failed: %s\n", error);
    return 1;
  }
  const char* version = rai_engine_version(engine);
  if (!version || std::strcmp(version, "1.17.0") != 0) {
    std::fprintf(stderr, "unexpected librime version: %s\n",
                 version ? version : "missing");
    rai_engine_destroy(engine);
    return 1;
  }
  size_t candidate_count = 0;
  const int result = rai_engine_candidates(
      engine, "nihao", 5, collect_candidate, &candidate_count, error,
      sizeof(error));
  rai_engine_destroy(engine);
  if (result < 1 || candidate_count < 1) {
    std::fprintf(stderr, "candidate smoke failed: %s\n", error);
    return 1;
  }
  std::printf("librime=%s candidates=%zu\n", version, candidate_count);
  return 0;
}
