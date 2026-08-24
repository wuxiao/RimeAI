#include "RimeBridgeC.h"

#include <rime_api.h>

#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <unordered_set>

struct RAIEngine {
  RimeApi* api = nullptr;
  RimeSessionId session_id = 0;
  std::string shared_data_dir;
  std::string user_data_dir;
  std::string schema_id;
  std::string version;
  bool initialized = false;
};

namespace {

void set_error(char* error, size_t error_size, const char* message) {
  if (!error || error_size == 0) {
    return;
  }
  std::snprintf(error, error_size, "%s", message);
}

void clear_error(char* error, size_t error_size) {
  if (error && error_size > 0) {
    error[0] = '\0';
  }
}

void clear_output(char* output, size_t output_size) {
  if (output && output_size > 0) {
    output[0] = '\0';
  }
}

bool copy_output(const std::string& value,
                 char* output,
                 size_t output_size,
                 const char* buffer_error,
                 char* error,
                 size_t error_size) {
  if (!output || output_size == 0 || value.size() + 1 > output_size) {
    set_error(error, error_size, buffer_error);
    return false;
  }
  std::memcpy(output, value.c_str(), value.size() + 1);
  return true;
}

bool is_utf8_continuation(unsigned char value) {
  return (value & 0xc0) == 0x80;
}

bool is_ascii_whitespace(unsigned char value) {
  return value == 0x09 || value == 0x0a || value == 0x0b || value == 0x0c ||
      value == 0x0d || value == 0x20;
}

bool selection_remaining_input(const char* original_input,
                               const char* preedit,
                               int selection_start,
                               std::string* remaining_input) {
  if (!original_input || !original_input[0] || !preedit ||
      !remaining_input || selection_start < 0) {
    return false;
  }
  const size_t preedit_size = std::strlen(preedit);
  const size_t boundary = static_cast<size_t>(selection_start);
  if (boundary >= preedit_size ||
      is_utf8_continuation(static_cast<unsigned char>(preedit[boundary]))) {
    return false;
  }

  std::string normalized_tail;
  normalized_tail.reserve(preedit_size - boundary);
  for (size_t index = boundary; index < preedit_size; ++index) {
    const unsigned char value = static_cast<unsigned char>(preedit[index]);
    if (!is_ascii_whitespace(value)) {
      normalized_tail.push_back(static_cast<char>(value));
    }
  }

  const std::string raw_input(original_input);
  if (normalized_tail.empty() || normalized_tail.size() >= raw_input.size()) {
    return false;
  }
  const size_t suffix_start = raw_input.size() - normalized_tail.size();
  if (raw_input.compare(suffix_start, normalized_tail.size(), normalized_tail) !=
      0) {
    return false;
  }
  *remaining_input = normalized_tail;
  return true;
}

bool displayed_candidate_native_index(RAIEngine* engine,
                                      size_t displayed_index,
                                      const char* expected_text,
                                      size_t* native_index,
                                      char* error,
                                      size_t error_size) {
  RimeCandidateListIterator iterator = {0};
  if (!engine->api->candidate_list_begin(engine->session_id, &iterator)) {
    set_error(error, error_size, "librime returned no candidate list");
    return false;
  }

  bool found = false;
  std::string found_text;
  try {
    std::unordered_set<std::string> seen;
    size_t current_native_index = 0;
    size_t current_displayed_index = 0;
    while (engine->api->candidate_list_next(&iterator)) {
      const char* text = iterator.candidate.text;
      if (text && text[0] && seen.insert(text).second) {
        if (current_displayed_index == displayed_index) {
          found = true;
          found_text = text;
          *native_index = current_native_index;
          break;
        }
        ++current_displayed_index;
      }
      ++current_native_index;
    }
  } catch (...) {
    engine->api->candidate_list_end(&iterator);
    throw;
  }
  engine->api->candidate_list_end(&iterator);

  if (!found) {
    set_error(error, error_size, "Displayed candidate index is unavailable");
    return false;
  }
  if (expected_text && expected_text[0] && found_text != expected_text) {
    set_error(error, error_size, "Displayed candidate changed before selection");
    return false;
  }
  return true;
}

}  // namespace

RAIEngine* create_engine(const char* shared_data_dir,
                         const char* user_data_dir,
                         const char* schema_id,
                         bool run_maintenance,
                         char* error,
                         size_t error_size) {
  clear_error(error, error_size);
  if (!shared_data_dir || !shared_data_dir[0] || !user_data_dir ||
      !user_data_dir[0] || !schema_id || !schema_id[0]) {
    set_error(error, error_size, "Rime paths and schema must be non-empty");
    return nullptr;
  }

  RAIEngine* engine = new (std::nothrow) RAIEngine();
  if (!engine) {
    set_error(error, error_size, "Cannot allocate Rime engine");
    return nullptr;
  }
  engine->shared_data_dir = shared_data_dir;
  engine->user_data_dir = user_data_dir;
  engine->schema_id = schema_id;
  engine->api = rime_get_api();
  if (!engine->api) {
    set_error(error, error_size, "Cannot acquire librime API");
    delete engine;
    return nullptr;
  }

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = engine->shared_data_dir.c_str();
  traits.user_data_dir = engine->user_data_dir.c_str();
  traits.distribution_name = "RimeAI";
  traits.distribution_code_name = "rimeai";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.rimeai";
  traits.min_log_level = 2;
  traits.log_dir = "";

  engine->api->setup(&traits);
  engine->api->set_notification_handler(nullptr, nullptr);
  engine->api->initialize(nullptr);
  engine->initialized = true;

  if (run_maintenance && engine->api->start_maintenance(True)) {
    engine->api->join_maintenance_thread();
  }
  engine->session_id = engine->api->create_session();
  if (!engine->session_id) {
    set_error(error, error_size, "Cannot create librime session");
    rai_engine_destroy(engine);
    return nullptr;
  }
  if (!engine->api->select_schema(engine->session_id, engine->schema_id.c_str())) {
    set_error(error, error_size, "Cannot select requested Rime schema");
    rai_engine_destroy(engine);
    return nullptr;
  }
  const char* version = engine->api->get_version();
  engine->version = version ? version : "unknown";
  return engine;
}

RAIEngine* rai_engine_create(const char* shared_data_dir,
                             const char* user_data_dir,
                             const char* schema_id,
                             char* error,
                             size_t error_size) {
  return create_engine(shared_data_dir, user_data_dir, schema_id, true, error,
                       error_size);
}

RAIEngine* rai_engine_create_prebuilt(const char* shared_data_dir,
                                      const char* user_data_dir,
                                      const char* schema_id,
                                      char* error,
                                      size_t error_size) {
  return create_engine(shared_data_dir, user_data_dir, schema_id, false, error,
                       error_size);
}

void rai_engine_destroy(RAIEngine* engine) {
  if (!engine) {
    return;
  }
  if (engine->api && engine->session_id) {
    engine->api->destroy_session(engine->session_id);
    engine->session_id = 0;
  }
  if (engine->api && engine->initialized) {
    engine->api->finalize();
    engine->initialized = false;
  }
  delete engine;
}

const char* rai_engine_version(RAIEngine* engine) {
  return engine ? engine->version.c_str() : nullptr;
}

int rai_engine_set_option(RAIEngine* engine,
                          const char* option,
                          int enabled,
                          char* error,
                          size_t error_size) {
  clear_error(error, error_size);
  if (!engine || !engine->api || !engine->session_id) {
    set_error(error, error_size, "Rime engine is not running");
    return -1;
  }
  if (!option || !option[0]) {
    set_error(error, error_size, "Rime option name is invalid");
    return -1;
  }
  engine->api->set_option(
      engine->session_id, option, enabled ? True : False);
  return 0;
}

int rai_engine_get_option(RAIEngine* engine,
                          const char* option,
                          int* enabled,
                          char* error,
                          size_t error_size) {
  clear_error(error, error_size);
  if (!engine || !engine->api || !engine->session_id) {
    set_error(error, error_size, "Rime engine is not running");
    return -1;
  }
  if (!option || !option[0] || !enabled) {
    set_error(error, error_size, "Rime option query is invalid");
    return -1;
  }
  *enabled = engine->api->get_option(engine->session_id, option) ? 1 : 0;
  return 0;
}

int rai_engine_candidates(RAIEngine* engine,
                          const char* pinyin,
                          size_t limit,
                          RAICandidateCallback callback,
                          void* callback_context,
                          char* error,
                          size_t error_size) {
  clear_error(error, error_size);
  if (!engine || !engine->api || !engine->session_id) {
    set_error(error, error_size, "Rime engine is not running");
    return -1;
  }
  if (!pinyin || !pinyin[0] || limit == 0 || limit > 50 || !callback) {
    set_error(error, error_size, "Candidate request is invalid");
    return -1;
  }

  RimeCandidateListIterator iterator = {0};
  bool iterator_active = false;
  try {
    engine->api->clear_composition(engine->session_id);
    Bool accepted = False;
    if (RIME_API_AVAILABLE(engine->api, set_input)) {
      accepted = engine->api->set_input(engine->session_id, pinyin);
    } else {
      accepted = engine->api->simulate_key_sequence(engine->session_id, pinyin);
    }
    if (!accepted) {
      set_error(error, error_size, "librime rejected candidate input");
      return -1;
    }

    if (!engine->api->candidate_list_begin(engine->session_id, &iterator)) {
      set_error(error, error_size, "librime returned no candidate list");
      return -1;
    }
    iterator_active = true;

    size_t count = 0;
    std::unordered_set<std::string> seen;
    while (count < limit && engine->api->candidate_list_next(&iterator)) {
      if (iterator.candidate.text && iterator.candidate.text[0] &&
          seen.insert(iterator.candidate.text).second) {
        callback(iterator.candidate.text, iterator.candidate.comment, count,
                 callback_context);
        ++count;
      }
    }
    engine->api->candidate_list_end(&iterator);
    iterator_active = false;
    if (count == 0) {
      set_error(error, error_size, "librime returned no candidates");
      return -1;
    }
    return static_cast<int>(count);
  } catch (...) {
    if (iterator_active) {
      engine->api->candidate_list_end(&iterator);
    }
    set_error(error, error_size, "Candidate lookup failed");
    return -1;
  }
}

int rai_engine_commit_candidate(RAIEngine* engine,
                                const char* pinyin,
                                size_t candidate_index,
                                char* committed_text,
                                size_t committed_text_size,
                                char* error,
                                size_t error_size) {
  clear_error(error, error_size);
  if (committed_text && committed_text_size > 0) {
    committed_text[0] = '\0';
  }
  if (!engine || !engine->api || !engine->session_id) {
    set_error(error, error_size, "Rime engine is not running");
    return -1;
  }
  if (!pinyin || !pinyin[0] || !committed_text ||
      committed_text_size == 0 || candidate_index >= 50) {
    set_error(error, error_size, "Candidate commit request is invalid");
    return -1;
  }

  try {
    engine->api->clear_composition(engine->session_id);
    Bool accepted = False;
    if (RIME_API_AVAILABLE(engine->api, set_input)) {
      accepted = engine->api->set_input(engine->session_id, pinyin);
    } else {
      accepted = engine->api->simulate_key_sequence(engine->session_id, pinyin);
    }
    size_t native_index = 0;
    if (!accepted ||
        !displayed_candidate_native_index(
            engine, candidate_index, nullptr, &native_index, error, error_size) ||
        !engine->api->select_candidate(engine->session_id, native_index)) {
      if (error && error[0]) {
        return -1;
      }
      set_error(error, error_size, "librime rejected candidate selection");
      return -1;
    }

    RIME_STRUCT(RimeCommit, commit);
    if (!engine->api->get_commit(engine->session_id, &commit)) {
      set_error(
          error, error_size,
          "Candidate selected only a prefix; continuation is required");
      return -1;
    }
    if (!commit.text || !commit.text[0]) {
      engine->api->free_commit(&commit);
      set_error(error, error_size, "librime returned empty committed text");
      return -1;
    }
    const size_t required_size = std::strlen(commit.text) + 1;
    if (required_size > committed_text_size) {
      engine->api->free_commit(&commit);
      set_error(error, error_size, "Committed text buffer is too small");
      return -1;
    }
    std::memcpy(committed_text, commit.text, required_size);
    engine->api->free_commit(&commit);
    return static_cast<int>(required_size - 1);
  } catch (...) {
    clear_output(committed_text, committed_text_size);
    set_error(error, error_size, "Candidate commit failed");
    return -1;
  }
}

int rai_engine_select_candidate(RAIEngine* engine,
                                const char* pinyin,
                                size_t candidate_index,
                                const char* expected_text,
                                char* selected_text,
                                size_t selected_text_size,
                                char* remaining_input,
                                size_t remaining_input_size,
                                char* error,
                                size_t error_size) {
  clear_error(error, error_size);
  clear_output(selected_text, selected_text_size);
  clear_output(remaining_input, remaining_input_size);
  if (!engine || !engine->api || !engine->session_id) {
    set_error(error, error_size, "Rime engine is not running");
    return -1;
  }
  if (!pinyin || !pinyin[0] || !expected_text || !expected_text[0] ||
      !selected_text || selected_text_size == 0 || !remaining_input ||
      remaining_input_size == 0 || candidate_index >= 50) {
    set_error(error, error_size, "Candidate selection request is invalid");
    return -1;
  }

  try {
    engine->api->clear_composition(engine->session_id);
    Bool accepted = False;
    if (RIME_API_AVAILABLE(engine->api, set_input)) {
      accepted = engine->api->set_input(engine->session_id, pinyin);
    } else {
      accepted = engine->api->simulate_key_sequence(engine->session_id, pinyin);
    }
    if (!accepted) {
      set_error(error, error_size, "librime rejected candidate input");
      return -1;
    }

    size_t native_index = 0;
    if (!displayed_candidate_native_index(
            engine, candidate_index, expected_text, &native_index, error,
            error_size) ||
        !engine->api->select_candidate(engine->session_id, native_index)) {
      if (!error || !error[0]) {
        set_error(error, error_size, "librime rejected candidate selection");
      }
      return -1;
    }

    RIME_STRUCT(RimeCommit, commit);
    if (engine->api->get_commit(engine->session_id, &commit)) {
      std::string committed;
      try {
        committed = commit.text ? commit.text : "";
      } catch (...) {
        engine->api->free_commit(&commit);
        throw;
      }
      engine->api->free_commit(&commit);
      if (committed.empty()) {
        set_error(error, error_size, "librime returned empty committed text");
        return -1;
      }
      if (!copy_output(
              committed, selected_text, selected_text_size,
              "Selected text buffer is too small", error, error_size)) {
        clear_output(selected_text, selected_text_size);
        return -1;
      }
      return RAI_CANDIDATE_SELECTION_COMPLETE;
    }

    RIME_STRUCT(RimeStatus, status);
    if (!engine->api->get_status(engine->session_id, &status)) {
      set_error(error, error_size, "Cannot inspect candidate selection state");
      return -1;
    }
    const bool is_composing = status.is_composing;
    engine->api->free_status(&status);
    if (!is_composing) {
      set_error(error, error_size, "Candidate selection has no commit or tail");
      return -1;
    }

    const char* raw_input = engine->api->get_input(engine->session_id);
    if (!raw_input || std::strcmp(raw_input, pinyin) != 0) {
      set_error(error, error_size, "Candidate selection input identity changed");
      return -1;
    }

    RIME_STRUCT(RimeContext, context);
    if (!engine->api->get_context(engine->session_id, &context)) {
      set_error(error, error_size, "Cannot inspect candidate selection context");
      return -1;
    }
    std::string remainder;
    bool valid_remainder = false;
    try {
      valid_remainder = selection_remaining_input(
          raw_input, context.composition.preedit,
          context.composition.sel_start, &remainder);
    } catch (...) {
      engine->api->free_context(&context);
      throw;
    }
    engine->api->free_context(&context);
    if (!valid_remainder) {
      set_error(error, error_size, "Candidate selection tail is not authoritative");
      return -1;
    }

    const std::string selected(expected_text);
    if (selected.size() + 1 > selected_text_size ||
        remainder.size() + 1 > remaining_input_size) {
      set_error(error, error_size, "Candidate selection output buffer is too small");
      return -1;
    }
    std::memcpy(selected_text, selected.c_str(), selected.size() + 1);
    std::memcpy(
        remaining_input, remainder.c_str(), remainder.size() + 1);
    return RAI_CANDIDATE_SELECTION_PARTIAL;
  } catch (...) {
    clear_output(selected_text, selected_text_size);
    clear_output(remaining_input, remaining_input_size);
    set_error(error, error_size, "Candidate selection failed");
    return -1;
  }
}

#if defined(RIMEAI_BRIDGE_TESTING)
extern "C" int rai_test_selection_remaining_input(
    const char* original_input,
    const char* preedit,
    int selection_start,
    char* remaining_input,
    size_t remaining_input_size) {
  clear_output(remaining_input, remaining_input_size);
  try {
    std::string remainder;
    if (!selection_remaining_input(
            original_input, preedit, selection_start, &remainder) ||
        remainder.size() + 1 > remaining_input_size) {
      return 0;
    }
    std::memcpy(
        remaining_input, remainder.c_str(), remainder.size() + 1);
    return 1;
  } catch (...) {
    return 0;
  }
}

#endif
