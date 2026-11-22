/**
 * JetBird SPAKE2 (RFC 9382) C API for iOS
 *
 * This header provides the FFI interface to the Rust SPAKE2 implementation.
 * Compatible with the Android native/lan_spake.h API.
 *
 * License: GPL-3.0-or-later
 * Ported from native/lan_spake.c by nueex
 */

#ifndef JETBIRD_SPAKE2_H
#define JETBIRD_SPAKE2_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// SPAKE2 role
typedef enum {
    JETBIRD_SPAKE2_ROLE_PHONE = 1,   ///< Client (phone) side
    JETBIRD_SPAKE2_ROLE_CONSOLE = 2  ///< Server (PS4) side
} jetbird_spake2_role_t;

/// Error codes
typedef enum {
    JETBIRD_SPAKE2_SUCCESS = 0,
    JETBIRD_SPAKE2_ERROR_INVALID_CODE = -1,
    JETBIRD_SPAKE2_ERROR_INVALID_SCALAR = -2,
    JETBIRD_SPAKE2_ERROR_CRYPTO_FAILURE = -3,
    JETBIRD_SPAKE2_ERROR_INVALID_INPUT = -4,
    JETBIRD_SPAKE2_ERROR_BUFFER_TOO_SMALL = -5,
} jetbird_spake2_error_t;

/// Opaque session handle
typedef struct jetbird_spake2_session_s *jetbird_spake2_handle_t;

/**
 * Create a new SPAKE2 session
 *
 * @param role     JETBIRD_SPAKE2_ROLE_PHONE (1) or JETBIRD_SPAKE2_ROLE_CONSOLE (2)
 * @param code     6-digit pairing code (0-999999)
 * @param scalar   32-byte random scalar (private key)
 * @param pin      16-byte PIN from QR code
 * @return         Opaque handle, or NULL on error
 */
jetbird_spake2_handle_t jetbird_spake2_create(
    int role,
    uint32_t code,
    const uint8_t *scalar,
    const uint8_t *pin
);

/**
 * Compute our public point to share (65 bytes, SEC1 uncompressed)
 *
 * @param handle   Session handle
 * @param out_point 65-byte output buffer
 * @return         JETBIRD_SPAKE2_SUCCESS on success, error code otherwise
 */
int jetbird_spake2_compute_share(
    jetbird_spake2_handle_t handle,
    uint8_t *out_point
);

/**
 * Process peer's public point and compute shared secret
 *
 * @param handle      Session handle
 * @param their_point 65-byte peer public point (SEC1 uncompressed)
 * @return            JETBIRD_SPAKE2_SUCCESS on success, error code otherwise
 */
int jetbird_spake2_process_their_point(
    jetbird_spake2_handle_t handle,
    const uint8_t *their_point
);

/**
 * Generate confirmation proofs (64 bytes: 32 + 32)
 *
 * @param handle     Session handle
 * @param out_proofs 64-byte output buffer
 * @return           JETBIRD_SPAKE2_SUCCESS on success, error code otherwise
 */
int jetbird_spake2_generate_proofs(
    jetbird_spake2_handle_t handle,
    uint8_t *out_proofs
);

/**
 * Verify received confirmation proofs
 *
 * @param handle Session handle
 * @param proofs 64-byte proofs to verify
 * @return       1 if valid, 0 if invalid
 */
int jetbird_spake2_verify_proofs(
    jetbird_spake2_handle_t handle,
    const uint8_t *proofs
);

/**
 * Get the derived session key (32 bytes)
 *
 * @param handle  Session handle
 * @param out_key 32-byte output buffer
 * @return        JETBIRD_SPAKE2_SUCCESS on success, error code otherwise
 */
int jetbird_spake2_session_key(
    jetbird_spake2_handle_t handle,
    uint8_t *out_key
);

/**
 * Destroy session and securely zeroize all memory
 *
 * @param handle Session handle (set to NULL after)
 */
void jetbird_spake2_destroy(
    jetbird_spake2_handle_t handle
);

/**
 * Validate a scalar is in [1, n-1] range
 *
 * @param scalar 32-byte scalar
 * @return       1 if valid, 0 if invalid
 */
int jetbird_spake2_validate_scalar(
    const uint8_t *scalar
);

/**
 * Generate a cryptographically random scalar (32 bytes)
 *
 * @param out_scalar 32-byte output buffer
 * @return           JETBIRD_SPAKE2_SUCCESS on success, error code otherwise
 */
int jetbird_spake2_random_scalar(
    uint8_t *out_scalar
);

#ifdef __cplusplus
}
#endif

#endif // JETBIRD_SPAKE2_H