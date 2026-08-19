#include "RimeBridgeC.h"

#include <rime_api.h>

#include <cstdio>
#include <cstring>
#include <new>
#include <string>

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
  if (!pinyin || !pinyin[0] || limit == 0 || !callback) {
    set_error(error, error_size, "Candidate request is invalid");
    return -1;
  }

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

  RimeCandidateListIterator iterator = {0};
  if (!engine->api->candidate_list_begin(engine->session_id, &iterator)) {
    set_error(error, error_size, "librime returned no candidate list");
    return -1;
  }

  size_t count = 0;
  while (count < limit && engine->api->candidate_list_next(&iterator)) {
    if (iterator.candidate.text && iterator.candidate.text[0]) {
      callback(iterator.candidate.text, iterator.candidate.comment, count,
               callback_context);
      ++count;
    }
  }
  engine->api->candidate_list_end(&iterator);
  if (count == 0) {
    set_error(error, error_size, "librime returned no candidates");
    return -1;
  }
  return static_cast<int>(count);
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
      committed_text_size == 0) {
    set_error(error, error_size, "Candidate commit request is invalid");
    return -1;
  }

  engine->api->clear_composition(engine->session_id);
  Bool accepted = False;
  if (RIME_API_AVAILABLE(engine->api, set_input)) {
    accepted = engine->api->set_input(engine->session_id, pinyin);
  } else {
    accepted = engine->api->simulate_key_sequence(engine->session_id, pinyin);
  }
  if (!accepted ||
      !engine->api->select_candidate(engine->session_id, candidate_index)) {
    set_error(error, error_size, "librime rejected candidate selection");
    return -1;
  }

  RIME_STRUCT(RimeCommit, commit);
  if (!engine->api->get_commit(engine->session_id, &commit)) {
    if (!engine->api->commit_composition(engine->session_id) ||
        !engine->api->get_commit(engine->session_id, &commit)) {
      set_error(error, error_size, "librime returned no committed text");
      return -1;
    }
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
}
