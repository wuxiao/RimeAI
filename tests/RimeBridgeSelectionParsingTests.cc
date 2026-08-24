#include <cstddef>
#include <cstring>
#include <iostream>
#include <string>

extern "C" int rai_test_selection_remaining_input(
    const char* original_input,
    const char* preedit,
    int selection_start,
    char* remaining_input,
    size_t remaining_input_size);

namespace {

bool expect_valid(const char* original,
                  const char* preedit,
                  int boundary,
                  const char* expected) {
  char remaining[256] = {0};
  const int result = rai_test_selection_remaining_input(
      original, preedit, boundary, remaining, sizeof(remaining));
  if (result == 1 && std::string(remaining) == expected) {
    return true;
  }
  std::cerr << "valid remainder rejected: original=" << original
            << " preedit=" << preedit << " boundary=" << boundary
            << " remaining=" << remaining << "\n";
  return false;
}

bool expect_invalid(const char* original,
                    const char* preedit,
                    int boundary,
                    size_t output_size = 256) {
  char remaining[256] = {'x', '\0'};
  const int result = rai_test_selection_remaining_input(
      original, preedit, boundary, remaining, output_size);
  if (result == 0 && remaining[0] == '\0') {
    return true;
  }
  std::cerr << "invalid remainder accepted: original=" << original
            << " preedit=" << preedit << " boundary=" << boundary
            << " remaining=" << remaining << "\n";
  return false;
}

}  // namespace

int main() {
  bool passed = true;
  passed &= expect_valid("mingtiantianqi", "明天tian qi", 6, "tianqi");
  passed &= expect_valid("xi'anrenmin", "西安ren min", 6, "renmin");
  passed &= expect_invalid("mingtiantianqi", "明天tian qi", 1);
  passed &= expect_invalid("mingtiantianqi", "明天qian qi", 6);
  passed &= expect_invalid("tianqi", "tian qi", 0);
  passed &= expect_invalid("mingtiantianqi", "明天tian qi", 6, 2);
  return passed ? 0 : 1;
}
