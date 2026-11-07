#include "Bridging.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <string.h>

static int derive_key(const char *password, uint8_t key[16]) {
    if (password == NULL) return -1;
    CCCryptorStatus status = CCKeyDerivationPBKDF(
        kCCPBKDF2,
        password,
        strlen(password),
        (const uint8_t *)"saltysalt",
        9,
        kCCPRFHmacAlgSHA1,
        1003,
        key,
        16);
    return status == kCCSuccess ? 0 : -1;
}

int decrypt_electron_v10(const char *password,
                         const uint8_t *cipher, size_t cipher_len,
                         uint8_t *out, size_t out_cap, size_t *out_len) {
    uint8_t key[16];
    uint8_t iv[16];
    size_t moved = 0;
    if (derive_key(password, key) != 0) return 1;
    memset(iv, ' ', sizeof(iv));
    CCCryptorStatus status = CCCrypt(
        kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        key, sizeof(key), iv,
        cipher, cipher_len,
        out, out_cap, &moved);
    memset(key, 0, sizeof(key));
    if (status != kCCSuccess) return 2;
    *out_len = moved;
    return 0;
}

int encrypt_electron_v10(const char *password,
                         const uint8_t *plain, size_t plain_len,
                         uint8_t *out, size_t out_cap, size_t *out_len) {
    uint8_t key[16];
    uint8_t iv[16];
    size_t moved = 0;
    if (derive_key(password, key) != 0) return 1;
    memset(iv, ' ', sizeof(iv));
    CCCryptorStatus status = CCCrypt(
        kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        key, sizeof(key), iv,
        plain, plain_len,
        out, out_cap, &moved);
    memset(key, 0, sizeof(key));
    if (status != kCCSuccess) return 2;
    *out_len = moved;
    return 0;
}
