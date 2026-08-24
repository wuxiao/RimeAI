#include "RimeAISherpaOnnxSafeC.h"

#include <exception>
#include <new>
#include <utility>

#if !defined(__cpp_exceptions)
#error "RimeAISherpaOnnxSafeC requires C++ exception unwinding"
#endif

namespace {

RimeAISherpaOnnxStatus CurrentExceptionStatus() noexcept {
  try {
    throw;
  } catch (const std::bad_alloc &) {
    return RimeAISherpaOnnxStatusAllocationFailure;
  } catch (const std::exception &) {
    return RimeAISherpaOnnxStatusStandardException;
  } catch (...) {
    return RimeAISherpaOnnxStatusUnknownException;
  }
}

template <typename Function, typename Output>
RimeAISherpaOnnxStatus CallPointer(Function &&function,
                                   Output *output) noexcept {
  if (output == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  *output = nullptr;
  try {
    auto value = function();
    if (value == nullptr) {
      return RimeAISherpaOnnxStatusLibraryFailure;
    }
    *output = value;
    return RimeAISherpaOnnxStatusSuccess;
  } catch (...) {
    return CurrentExceptionStatus();
  }
}

template <typename Function>
RimeAISherpaOnnxStatus CallVoid(Function &&function) noexcept {
  try {
    function();
    return RimeAISherpaOnnxStatusSuccess;
  } catch (...) {
    return CurrentExceptionStatus();
  }
}

template <typename Function>
RimeAISherpaOnnxStatus CallInt32(Function &&function,
                                 int32_t *output) noexcept {
  if (output == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  *output = 0;
  try {
    *output = function();
    return RimeAISherpaOnnxStatusSuccess;
  } catch (...) {
    return CurrentExceptionStatus();
  }
}

}  // namespace

extern "C" RimeAISherpaOnnxStatus RimeAISherpaOnnxGetVersionStr(
    const char **version) noexcept {
  return CallPointer([] { return SherpaOnnxGetVersionStr(); }, version);
}

extern "C" RimeAISherpaOnnxStatus RimeAISherpaOnnxGetGitSha1(
    const char **revision) noexcept {
  return CallPointer([] { return SherpaOnnxGetGitSha1(); }, revision);
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxGetOnnxruntimeVersionStr(const char **version) noexcept {
  return CallPointer(
      [] { return SherpaOnnxGetOnnxruntimeVersionStr(); }, version);
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxCreateOnlineRecognizer(
    const SherpaOnnxOnlineRecognizerConfig *config,
    const SherpaOnnxOnlineRecognizer **recognizer) noexcept {
  if (recognizer != nullptr) {
    *recognizer = nullptr;
  }
  if (config == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallPointer(
      [config] { return SherpaOnnxCreateOnlineRecognizer(config); },
      recognizer);
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxDestroyOnlineRecognizer(
    const SherpaOnnxOnlineRecognizer *recognizer) noexcept {
  if (recognizer == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallVoid(
      [recognizer] { SherpaOnnxDestroyOnlineRecognizer(recognizer); });
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxCreateOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream **stream) noexcept {
  if (stream != nullptr) {
    *stream = nullptr;
  }
  if (recognizer == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallPointer(
      [recognizer] { return SherpaOnnxCreateOnlineStream(recognizer); },
      stream);
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxCreateOnlineStreamWithHotwords(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const char *hotwords,
    const SherpaOnnxOnlineStream **stream) noexcept {
  if (stream != nullptr) {
    *stream = nullptr;
  }
  if (recognizer == nullptr || hotwords == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallPointer(
      [recognizer, hotwords] {
        return SherpaOnnxCreateOnlineStreamWithHotwords(recognizer, hotwords);
      },
      stream);
}

extern "C" RimeAISherpaOnnxStatus RimeAISherpaOnnxDestroyOnlineStream(
    const SherpaOnnxOnlineStream *stream) noexcept {
  if (stream == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallVoid([stream] { SherpaOnnxDestroyOnlineStream(stream); });
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxOnlineStreamAcceptWaveform(
    const SherpaOnnxOnlineStream *stream,
    int32_t sample_rate,
    const float *samples,
    int32_t sample_count) noexcept {
  if (stream == nullptr || samples == nullptr || sample_count < 0) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallVoid([stream, sample_rate, samples, sample_count] {
    SherpaOnnxOnlineStreamAcceptWaveform(
        stream, sample_rate, samples, sample_count);
  });
}

extern "C" RimeAISherpaOnnxStatus RimeAISherpaOnnxIsOnlineStreamReady(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream,
    int32_t *is_ready) noexcept {
  if (recognizer == nullptr || stream == nullptr) {
    if (is_ready != nullptr) {
      *is_ready = 0;
    }
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallInt32(
      [recognizer, stream] {
        return SherpaOnnxIsOnlineStreamReady(recognizer, stream);
      },
      is_ready);
}

extern "C" RimeAISherpaOnnxStatus RimeAISherpaOnnxDecodeOnlineStream(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream) noexcept {
  if (recognizer == nullptr || stream == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallVoid([recognizer, stream] {
    SherpaOnnxDecodeOnlineStream(recognizer, stream);
  });
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxGetOnlineStreamResult(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream,
    const SherpaOnnxOnlineRecognizerResult **result) noexcept {
  if (result != nullptr) {
    *result = nullptr;
  }
  if (recognizer == nullptr || stream == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallPointer(
      [recognizer, stream] {
        return SherpaOnnxGetOnlineStreamResult(recognizer, stream);
      },
      result);
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxDestroyOnlineRecognizerResult(
    const SherpaOnnxOnlineRecognizerResult *result) noexcept {
  if (result == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallVoid(
      [result] { SherpaOnnxDestroyOnlineRecognizerResult(result); });
}

extern "C" RimeAISherpaOnnxStatus RimeAISherpaOnnxOnlineStreamReset(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream) noexcept {
  if (recognizer == nullptr || stream == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallVoid([recognizer, stream] {
    SherpaOnnxOnlineStreamReset(recognizer, stream);
  });
}

extern "C" RimeAISherpaOnnxStatus
RimeAISherpaOnnxOnlineStreamInputFinished(
    const SherpaOnnxOnlineStream *stream) noexcept {
  if (stream == nullptr) {
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallVoid(
      [stream] { SherpaOnnxOnlineStreamInputFinished(stream); });
}

extern "C" RimeAISherpaOnnxStatus RimeAISherpaOnnxOnlineStreamIsEndpoint(
    const SherpaOnnxOnlineRecognizer *recognizer,
    const SherpaOnnxOnlineStream *stream,
    int32_t *is_endpoint) noexcept {
  if (recognizer == nullptr || stream == nullptr) {
    if (is_endpoint != nullptr) {
      *is_endpoint = 0;
    }
    return RimeAISherpaOnnxStatusInvalidArgument;
  }
  return CallInt32(
      [recognizer, stream] {
        return SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream);
      },
      is_endpoint);
}
