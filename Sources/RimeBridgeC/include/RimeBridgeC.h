#ifndef RIME_AI_RIME_BRIDGE_C_H_
#define RIME_AI_RIME_BRIDGE_C_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RAIEngine RAIEngine;

typedef void (*RAICandidateCallback)(const char* text,
                                     const char* comment,
                                     size_t index,
                                     void* context);

RAIEngine* rai_engine_create(const char* shared_data_dir,
                             const char* user_data_dir,
                             const char* schema_id,
                             char* error,
                             size_t error_size);

RAIEngine* rai_engine_create_prebuilt(const char* shared_data_dir,
                                      const char* user_data_dir,
                                      const char* schema_id,
                                      char* error,
                                      size_t error_size);

void rai_engine_destroy(RAIEngine* engine);

const char* rai_engine_version(RAIEngine* engine);

int rai_engine_candidates(RAIEngine* engine,
                          const char* pinyin,
                          size_t limit,
                          RAICandidateCallback callback,
                          void* callback_context,
                          char* error,
                          size_t error_size);

int rai_engine_commit_candidate(RAIEngine* engine,
                                const char* pinyin,
                                size_t candidate_index,
                                char* committed_text,
                                size_t committed_text_size,
                                char* error,
                                size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
