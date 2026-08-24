#ifndef RIME_AI_RIME_BRIDGE_C_H_
#define RIME_AI_RIME_BRIDGE_C_H_

#include <stddef.h>

#if defined(__GNUC__)
#define RAI_PUBLIC __attribute__((visibility("default")))
#else
#define RAI_PUBLIC
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RAIEngine RAIEngine;

typedef void (*RAICandidateCallback)(const char* text,
                                     const char* comment,
                                     size_t index,
                                     void* context);

RAI_PUBLIC RAIEngine* rai_engine_create(const char* shared_data_dir,
                                        const char* user_data_dir,
                                        const char* schema_id,
                                        char* error,
                                        size_t error_size);

RAI_PUBLIC RAIEngine* rai_engine_create_prebuilt(const char* shared_data_dir,
                                                 const char* user_data_dir,
                                                 const char* schema_id,
                                                 char* error,
                                                 size_t error_size);

RAI_PUBLIC void rai_engine_destroy(RAIEngine* engine);

RAI_PUBLIC const char* rai_engine_version(RAIEngine* engine);

RAI_PUBLIC int rai_engine_set_option(RAIEngine* engine,
                                     const char* option,
                                     int enabled,
                                     char* error,
                                     size_t error_size);

RAI_PUBLIC int rai_engine_get_option(RAIEngine* engine,
                                     const char* option,
                                     int* enabled,
                                     char* error,
                                     size_t error_size);

RAI_PUBLIC int rai_engine_candidates(RAIEngine* engine,
                                     const char* pinyin,
                                     size_t limit,
                                     RAICandidateCallback callback,
                                     void* callback_context,
                                     char* error,
                                     size_t error_size);

/*
 * Deprecated whole-composition-only API. A candidate that consumes only an
 * input prefix fails instead of forcing the unselected tail to commit. New
 * interactive callers must use rai_engine_select_candidate().
 */
RAI_PUBLIC int rai_engine_commit_candidate(RAIEngine* engine,
                                           const char* pinyin,
                                           size_t candidate_index,
                                           char* committed_text,
                                           size_t committed_text_size,
                                           char* error,
                                           size_t error_size);

/*
 * Selects the displayed candidate without forcing any unselected input to
 * commit. The return value is RAI_CANDIDATE_SELECTION_COMPLETE when librime
 * committed the whole composition, RAI_CANDIDATE_SELECTION_PARTIAL when only
 * the selected prefix is authoritative, or -1 on failure. On a partial
 * result, remaining_input is the exact unselected raw-input suffix reported
 * by librime's composition boundary. expected_text binds the displayed,
 * de-duplicated candidate index to the native candidate selected here.
 */
enum {
  RAI_CANDIDATE_SELECTION_COMPLETE = 0,
  RAI_CANDIDATE_SELECTION_PARTIAL = 1,
};

RAI_PUBLIC int rai_engine_select_candidate(
    RAIEngine* engine,
    const char* pinyin,
    size_t candidate_index,
    const char* expected_text,
    char* selected_text,
    size_t selected_text_size,
    char* remaining_input,
    size_t remaining_input_size,
    char* error,
    size_t error_size);

#ifdef __cplusplus
}
#endif

#undef RAI_PUBLIC

#endif
