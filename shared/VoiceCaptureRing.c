#include "VoiceCaptureRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct SPVoiceCaptureRing {
    uint32_t buffers, channelsPerBuffer, bytesPerFrame, maximumFrames, slots;
    size_t bufferBytes, storageBytes;
    unsigned char *storage;
    uint32_t *frameCounts;
    atomic_uint writePosition, readPosition, fault;
    atomic_uint_fast64_t receivedFrames;
    atomic_bool active;
};

SPVoiceCaptureRing *SPVoiceCaptureRingCreate(uint32_t buffers, uint32_t channelsPerBuffer,
                                           uint32_t bytesPerFrame, uint32_t maximumFrames,
                                           uint32_t slots) {
    if (!buffers || buffers > 8 || !channelsPerBuffer || channelsPerBuffer > 8 ||
        !bytesPerFrame || bytesPerFrame > 64 || !maximumFrames || maximumFrames > 8192 ||
        slots < 2 || slots > 32) return NULL;
    SPVoiceCaptureRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->buffers = buffers; ring->channelsPerBuffer = channelsPerBuffer;
    ring->bytesPerFrame = bytesPerFrame; ring->maximumFrames = maximumFrames; ring->slots = slots;
    ring->bufferBytes = (size_t)bytesPerFrame * maximumFrames;
    ring->storageBytes = ring->bufferBytes * buffers * slots;
    ring->storage = calloc(1, ring->storageBytes);
    ring->frameCounts = calloc(slots, sizeof(uint32_t));
    atomic_init(&ring->writePosition, 0); atomic_init(&ring->readPosition, 0);
    atomic_init(&ring->fault, 0); atomic_init(&ring->receivedFrames, 0);
    atomic_init(&ring->active, true);
    if (!ring->storage || !ring->frameCounts ||
        !atomic_is_lock_free(&ring->writePosition) || !atomic_is_lock_free(&ring->readPosition) ||
        !atomic_is_lock_free(&ring->fault) || !atomic_is_lock_free(&ring->receivedFrames) ||
        !atomic_is_lock_free(&ring->active)) {
        SPVoiceCaptureRingDestroy(ring); return NULL;
    }
    return ring;
}

static void fail(SPVoiceCaptureRing *ring, uint32_t code) {
    atomic_store_explicit(&ring->fault, code, memory_order_release);
    atomic_store_explicit(&ring->active, false, memory_order_release);
}

void SPVoiceCaptureRingWrite(SPVoiceCaptureRing *ring, uint32_t frames, const AudioBufferList *input) {
    if (!atomic_load_explicit(&ring->active, memory_order_acquire) || !frames) return;
    atomic_fetch_add_explicit(&ring->receivedFrames, frames, memory_order_relaxed);
    if (!input || frames > ring->maximumFrames || input->mNumberBuffers != ring->buffers) {
        fail(ring, 2); return;
    }
    const uint32_t bytes = frames * ring->bytesPerFrame;
    for (uint32_t channel = 0; channel < ring->buffers; ++channel) {
        const AudioBuffer *buffer = &input->mBuffers[channel];
        if (!buffer->mData || buffer->mDataByteSize < bytes || buffer->mNumberChannels != ring->channelsPerBuffer) {
            fail(ring, 2); return;
        }
    }
    const unsigned write = atomic_load_explicit(&ring->writePosition, memory_order_relaxed);
    const unsigned read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    if ((unsigned)(write - read) >= ring->slots) { fail(ring, 1); return; }
    const unsigned slot = write % ring->slots;
    for (uint32_t channel = 0; channel < ring->buffers; ++channel) {
        memcpy(ring->storage + ((size_t)slot * ring->buffers + channel) * ring->bufferBytes,
               input->mBuffers[channel].mData, bytes);
    }
    ring->frameCounts[slot] = frames;
    atomic_store_explicit(&ring->writePosition, write + 1, memory_order_release);
}

uint32_t SPVoiceCaptureRingRead(SPVoiceCaptureRing *ring, AudioBufferList *output) {
    if (!atomic_load_explicit(&ring->active, memory_order_acquire)) return 0;
    const unsigned read = atomic_load_explicit(&ring->readPosition, memory_order_relaxed);
    if (read == atomic_load_explicit(&ring->writePosition, memory_order_acquire)) return 0;
    const unsigned slot = read % ring->slots;
    const uint32_t frames = ring->frameCounts[slot];
    const uint32_t bytes = frames * ring->bytesPerFrame;
    if (!output || output->mNumberBuffers != ring->buffers) { fail(ring, 2); return 0; }
    for (uint32_t channel = 0; channel < ring->buffers; ++channel) {
        if (!output->mBuffers[channel].mData || output->mBuffers[channel].mDataByteSize < bytes ||
            output->mBuffers[channel].mNumberChannels != ring->channelsPerBuffer) {
            fail(ring, 2); return 0;
        }
    }
    for (uint32_t channel = 0; channel < ring->buffers; ++channel) {
        unsigned char *source = ring->storage + ((size_t)slot * ring->buffers + channel) * ring->bufferBytes;
        memcpy(output->mBuffers[channel].mData, source, bytes);
        memset(source, 0, bytes);
        output->mBuffers[channel].mDataByteSize = bytes;
    }
    ring->frameCounts[slot] = 0;
    atomic_store_explicit(&ring->readPosition, read + 1, memory_order_release);
    return frames;
}

uint64_t SPVoiceCaptureRingReceivedFrames(const SPVoiceCaptureRing *ring) {
    return atomic_load_explicit(&ring->receivedFrames, memory_order_relaxed);
}
uint32_t SPVoiceCaptureRingFault(const SPVoiceCaptureRing *ring) {
    return atomic_load_explicit(&ring->fault, memory_order_acquire);
}
void SPVoiceCaptureRingStop(SPVoiceCaptureRing *ring) {
    atomic_store_explicit(&ring->active, false, memory_order_release);
}
void SPVoiceCaptureRingClear(SPVoiceCaptureRing *ring) {
    // Volatile writes keep teardown clearing observable even immediately before free.
    if (ring->storage) {
        volatile unsigned char *bytes = ring->storage;
        for (size_t index = 0; index < ring->storageBytes; ++index) bytes[index] = 0;
    }
    if (ring->frameCounts) memset(ring->frameCounts, 0, (size_t)ring->slots * sizeof(uint32_t));
}
void SPVoiceCaptureRingDestroy(SPVoiceCaptureRing *ring) {
    if (!ring) return;
    if (ring->storage) { SPVoiceCaptureRingClear(ring); free(ring->storage); }
    free(ring->frameCounts); free(ring);
}
