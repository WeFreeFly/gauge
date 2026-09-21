// SPDX-License-Identifier: Apache-2.0
//  Apple SMC access shim.
//
//  The SMC user-client expects an exact 80-byte request struct. Swift lays the
//  same field list out as 76 bytes (it packs into SMCKeyInfoData's tail padding),
//  so every call is rejected. Keeping the struct in C guarantees the ABI.

#ifndef GAUGE_SMC_SHIM_H
#define GAUGE_SMC_SHIM_H

#include <stdint.h>
#include <stdbool.h>

#define GAUGE_SMC_MAX_BYTES 32

typedef struct {
    uint32_t type;                        // four-char code, e.g. 'flt ', 'ui16'
    uint32_t size;                        // valid bytes in `bytes`
    uint8_t  bytes[GAUGE_SMC_MAX_BYTES];
} gauge_smc_value;

/// Opens the AppleSMC user client. Safe to call repeatedly; returns true when a
/// connection is available.
bool gauge_smc_open(void);

/// Closes the connection opened by `gauge_smc_open`.
void gauge_smc_close(void);

/// Reads a four-character SMC key (e.g. "F0Ac"). Returns false when the key is
/// absent on this machine, which is the normal answer for most keys.
bool gauge_smc_read(const char *key, gauge_smc_value *out);

/// Number of keys this SMC exposes, or 0 on failure.
uint32_t gauge_smc_key_count(void);

/// Writes the four-character name of the key at `index` into `out` (5 bytes:
/// four characters plus NUL). Used to enumerate the key space.
bool gauge_smc_key_at_index(uint32_t index, char *out);

/// Writes a value back to the SMC. Only used for fan control, which requires
/// the caller to already hold the right entitlements/privileges; returns false
/// when the SMC refuses.
bool gauge_smc_write(const char *key, const uint8_t *bytes, uint32_t size);

#endif
