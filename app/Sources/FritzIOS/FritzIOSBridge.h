#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void fritz_ios_request(
    const uint8_t *input, size_t input_len,
    const uint8_t *key, size_t key_len,
    void *context,
    void (*on_event)(void *, const uint8_t *, size_t),
    bool (*is_cancelled)(void *)
);
