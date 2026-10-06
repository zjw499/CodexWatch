#ifndef SCRIBE_VOICE_CAPTURE_RING_H
#define SCRIBE_VOICE_CAPTURE_RING_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

// One audio-thread producer and one worker-queue consumer. Storage is allocated
// before capture. Write performs only lock-free atomics, validation and memcpy.
typedef struct SPVoiceCaptureRing SPVoiceCaptureRing;
SPVoiceCaptureRing *SPVoiceCaptureRingCreate(uint32_t buffers, uint32_t channelsPerBuffer,
                                           uint32_t bytesPerFrame, uint32_t maximumFrames,
                                           uint32_t slots);
void SPVoiceCaptureRingDestroy(SPVoiceCaptureRing *ring);
void SPVoiceCaptureRingWrite(SPVoiceCaptureRing *ring, uint32_t frames, const AudioBufferList *input);
uint32_t SPVoiceCaptureRingRead(SPVoiceCaptureRing *ring, AudioBufferList *output);
uint64_t SPVoiceCaptureRingReceivedFrames(const SPVoiceCaptureRing *ring);
// 0: healthy, 1: full, 2: unexpected PCM layout or callback size.
uint32_t SPVoiceCaptureRingFault(const SPVoiceCaptureRing *ring);
void SPVoiceCaptureRingStop(SPVoiceCaptureRing *ring);
// Call only after the engine has stopped and the consumer queue is idle.
void SPVoiceCaptureRingClear(SPVoiceCaptureRing *ring);

#endif
