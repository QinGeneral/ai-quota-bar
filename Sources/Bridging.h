#ifndef QUOTABAR_BRIDGING_H
#define QUOTABAR_BRIDGING_H

#include <stddef.h>
#include <stdint.h>

// Electron safeStorage on macOS: PBKDF2-HMAC-SHA1 + AES-128-CBC, v10 envelope.
int decrypt_electron_v10(const char *password,
                         const uint8_t *cipher, size_t cipher_len,
                         uint8_t *out, size_t out_cap, size_t *out_len);

int encrypt_electron_v10(const char *password,
                         const uint8_t *plain, size_t plain_len,
                         uint8_t *out, size_t out_cap, size_t *out_len);

#endif
