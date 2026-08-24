#ifndef RIMEAI_SHERPA_ONNX_SAFE_C_H_
#define RIMEAI_SHERPA_ONNX_SAFE_C_H_

#include <stdint.h>
#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>

#ifdef __cplusplus
extern "C" {
#define RIMEAI_SHERPA_ONNX_NOEXCEPT noexcept
#else
#define RIMEAI_SHERPA_ONNX_NOEXCEPT
#endif

typedef enum RimeAISherpaOnnxStatus {
  RimeAISherpaOnnxStatusSuccess = 0,
  RimeAISherpaOnnxStatusLibraryFailure = 1,
  RimeAISherpaOnnxStatusInvalidArgument = 2,
  RimeAISherpaOnnxStatusAllocationFailure = 3,
  RimeAISherpaOnnxStatusStandardException = 4,
  RimeAISherpaOnnxStatusUnknownException = 5,
} RimeAISherpaOnnxStatus;

RimeAISherpaOnnxStatus RimeAISherpaOnnxGetVersionStr(
    const char **version) RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxGetGitSha1(
    const char **revision) RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxGetOnnxruntimeVersionStr(
    const char **version) RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus
RimeAISherpaOnnxCreateOnlineRecognizer(
    const SherpaOnnxOnlineRecognizerConfig *config,
    const SherpaOnnxOnlineRecognizer **recognizer)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxDestroyOnlineRecognizer(
    const SherpaOnnxOnlineRecognizer *recognizer)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxCreateOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream **stream)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus
RimeAISherpaOnnxCreateOnlineStreamWithHotwords(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const char *hotwords,
    const SherpaOnnxOnlineStream **stream)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxDestroyOnlineStream(
    const SherpaOnnxOnlineStream *stream)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxOnlineStreamAcceptWaveform(
    const SherpaOnnxOnlineStream *stream,
    int32_t sample_rate,
    const float *samples,
    int32_t sample_count) RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxIsOnlineStreamReady(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream,
    int32_t *is_ready) RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxDecodeOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus
RimeAISherpaOnnxGetOnlineStreamResult(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream,
    const SherpaOnnxOnlineRecognizerResult **result)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus
RimeAISherpaOnnxDestroyOnlineRecognizerResult(
    const SherpaOnnxOnlineRecognizerResult *result)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxOnlineStreamReset(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxOnlineStreamInputFinished(
    const SherpaOnnxOnlineStream *stream)
    RIMEAI_SHERPA_ONNX_NOEXCEPT;

RimeAISherpaOnnxStatus RimeAISherpaOnnxOnlineStreamIsEndpoint(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream,
    int32_t *is_endpoint) RIMEAI_SHERPA_ONNX_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef RIMEAI_SHERPA_ONNX_NOEXCEPT

#endif  // RIMEAI_SHERPA_ONNX_SAFE_C_H_
