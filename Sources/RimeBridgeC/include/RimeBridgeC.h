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

RAI_PUBLIC int rai_engine_candidates(RAIEngine* engine,
                                     const char* pinyin,
                                     size_t limit,
                                     RAICandidateCallback callback,
                                     void* callback_context,
                                     char* error,
                                     size_t error_size);

RAI_PUBLIC int rai_engine_commit_candidate(RAIEngine* engine,
                                           const char* pinyin,
                                           size_t candidate_index,
                                           char* committed_text,
                                           size_t committed_text_size,
                                           char* error,
                                           size_t error_size);

#ifdef __cplusplus
}
#endif

#undef RAI_PUBLIC

#endif
