#include "RimeBridgeC.h"

#include <algorithm>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

struct CandidateCollector {
  std::vector<std::string> values;
};

void collect_candidate(const char* text,
                       const char*,
                       size_t,
                       void* context) {
  if (!text || !context) {
    return;
  }
  auto* collector = static_cast<CandidateCollector*>(context);
  const std::string value(text);
  if (std::find(collector->values.begin(), collector->values.end(), value) ==
      collector->values.end()) {
    collector->values.push_back(value);
  }
}

std::string error_message(const char* error) {
  return error && error[0] ? error : "no error text";
}

size_t candidate_index(RAIEngine* engine,
                       const std::string& input,
                       const std::string& expected) {
  CandidateCollector collector;
  char error[512] = {0};
  const int count = rai_engine_candidates(
      engine, input.c_str(), 20, collect_candidate, &collector, error,
      sizeof(error));
  if (count < 0) {
    std::cerr << "candidate lookup failed: " << error_message(error) << "\n";
    std::exit(20);
  }
  const auto found = std::find(
      collector.values.begin(), collector.values.end(), expected);
  if (found == collector.values.end()) {
    std::cerr << "fixture candidate missing: " << expected << "\n";
    std::exit(21);
  }
  return static_cast<size_t>(found - collector.values.begin());
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    return 2;
  }
  char error[512] = {0};
  RAIEngine* engine = rai_engine_create_prebuilt(
      argv[1], argv[2], "luna_pinyin_simp", error, sizeof(error));
  if (!engine) {
    std::cerr << "engine creation failed: " << error_message(error) << "\n";
    return 3;
  }

  const std::string input = "mingtiantianqi";
  const std::string selected_candidate = "明天";
  const size_t index = candidate_index(engine, input, selected_candidate);
  char selected[4096] = {0};
  char remaining[4096] = {0};
  const int result = rai_engine_select_candidate(
      engine, input.c_str(), index, selected_candidate.c_str(), selected,
      sizeof(selected), remaining, sizeof(remaining), error, sizeof(error));

  const bool partial_passed = result == RAI_CANDIDATE_SELECTION_PARTIAL &&
      std::string(selected) == selected_candidate &&
      std::string(remaining) == "tianqi";
  if (!partial_passed) {
    std::cerr << "partial selection did not preserve the unconfirmed tail: "
              << "result=" << result << " selected=" << selected
              << " remaining=" << remaining
              << " error=" << error_message(error) << "\n";
  }

  const std::string corrected_tail = "天启";
  const size_t tail_index = candidate_index(engine, remaining, corrected_tail);
  selected[0] = '\0';
  remaining[0] = '\0';
  error[0] = '\0';
  const int tail_result = rai_engine_select_candidate(
      engine, "tianqi", tail_index, corrected_tail.c_str(), selected,
      sizeof(selected), remaining, sizeof(remaining), error, sizeof(error));
  const bool tail_passed = tail_result == RAI_CANDIDATE_SELECTION_COMPLETE &&
      std::string(selected) == corrected_tail && remaining[0] == '\0';
  if (!tail_passed) {
    std::cerr << "remaining composition could not be corrected: result="
              << tail_result << " selected=" << selected
              << " remaining=" << remaining
              << " error=" << error_message(error) << "\n";
  }
  const std::string complete_input = "nihao";
  const std::string complete_candidate = "你好";
  const size_t complete_index = candidate_index(
      engine, complete_input, complete_candidate);
  selected[0] = '\0';
  remaining[0] = '\0';
  error[0] = '\0';
  const int complete_result = rai_engine_select_candidate(
      engine, complete_input.c_str(), complete_index,
      complete_candidate.c_str(), selected, sizeof(selected), remaining,
      sizeof(remaining), error, sizeof(error));
  const bool complete_passed =
      complete_result == RAI_CANDIDATE_SELECTION_COMPLETE &&
      std::string(selected) == complete_candidate && remaining[0] == '\0';
  if (!complete_passed) {
    std::cerr << "whole-composition selection regressed: result="
              << complete_result << " selected=" << selected
              << " remaining=" << remaining
              << " error=" << error_message(error) << "\n";
  }

  const std::string apostrophe_input = "xi'anrenmin";
  const std::string apostrophe_candidate = "西安";
  const size_t apostrophe_index = candidate_index(
      engine, apostrophe_input, apostrophe_candidate);
  selected[0] = '\0';
  remaining[0] = '\0';
  error[0] = '\0';
  const int apostrophe_result = rai_engine_select_candidate(
      engine, apostrophe_input.c_str(), apostrophe_index,
      apostrophe_candidate.c_str(), selected, sizeof(selected), remaining,
      sizeof(remaining), error, sizeof(error));
  const bool apostrophe_passed =
      apostrophe_result == RAI_CANDIDATE_SELECTION_PARTIAL &&
      std::string(selected) == apostrophe_candidate &&
      std::string(remaining) == "renmin";
  if (!apostrophe_passed) {
    std::cerr << "apostrophe boundary was not consumed exactly: result="
              << apostrophe_result << " selected=" << selected
              << " remaining=" << remaining
              << " error=" << error_message(error) << "\n";
  }

  const size_t mismatch_index = candidate_index(
      engine, input, selected_candidate);
  std::strcpy(selected, "sentinel");
  std::strcpy(remaining, "sentinel");
  error[0] = '\0';
  const int mismatch_result = rai_engine_select_candidate(
      engine, input.c_str(), mismatch_index, "错误候选", selected,
      sizeof(selected), remaining, sizeof(remaining), error, sizeof(error));
  const bool mismatch_passed = mismatch_result < 0 && selected[0] == '\0' &&
      remaining[0] == '\0' && error[0] != '\0';
  if (!mismatch_passed) {
    std::cerr << "candidate identity drift did not fail closed\n";
  }

  const size_t small_buffer_index = candidate_index(
      engine, input, selected_candidate);
  char tiny_selected[2] = {'x', '\0'};
  remaining[0] = '\0';
  error[0] = '\0';
  const int small_buffer_result = rai_engine_select_candidate(
      engine, input.c_str(), small_buffer_index, selected_candidate.c_str(),
      tiny_selected, sizeof(tiny_selected), remaining, sizeof(remaining),
      error, sizeof(error));
  const bool small_buffer_passed = small_buffer_result < 0 &&
      tiny_selected[0] == '\0' && remaining[0] == '\0' && error[0] != '\0';
  if (!small_buffer_passed) {
    std::cerr << "undersized selection buffer did not fail closed\n";
  }

  const size_t legacy_partial_index = candidate_index(
      engine, input, selected_candidate);
  char legacy_committed[4096] = {'x', '\0'};
  error[0] = '\0';
  const int legacy_partial_result = rai_engine_commit_candidate(
      engine, input.c_str(), legacy_partial_index, legacy_committed,
      sizeof(legacy_committed), error, sizeof(error));
  const bool legacy_partial_passed = legacy_partial_result < 0 &&
      legacy_committed[0] == '\0' && error[0] != '\0';
  if (!legacy_partial_passed) {
    std::cerr << "legacy API still forced an unconfirmed tail\n";
  }

  CandidateCollector oversized_collector;
  error[0] = '\0';
  const int oversized_limit_result = rai_engine_candidates(
      engine, "nihao", 51, collect_candidate, &oversized_collector, error,
      sizeof(error));
  const bool oversized_limit_passed = oversized_limit_result < 0 &&
      oversized_collector.values.empty() && error[0] != '\0';
  if (!oversized_limit_passed) {
    std::cerr << "oversized candidate limit did not fail closed\n";
  }
  rai_engine_destroy(engine);
  return partial_passed && tail_passed && complete_passed &&
          apostrophe_passed && mismatch_passed && small_buffer_passed &&
          legacy_partial_passed && oversized_limit_passed
      ? 0
      : 1;
}
