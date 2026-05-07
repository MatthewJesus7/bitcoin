#ifndef SECP256K1_DELTA20_BATCH_H
#define SECP256K1_DELTA20_BATCH_H

#include "secp256k1.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Verifica m assinaturas Schnorr BIP-340 em batch.
 *
 * Uma única multi-escalar (Pippenger):
 *   (Σ aᵢ·sᵢ)·G + Σ aᵢ·Rᵢ + Σ (aᵢ·eᵢ)·Pᵢ = 0
 *
 * sigs[i]    = 64 bytes  (R_x || s), BIP-340
 * msgs[i]    = msglen bytes, sighash
 * pubkeys[i] = 32 bytes, x-only pubkey BIP-340
 * blind_seed = 32 bytes, GetRandBytes do Core — NÃO pode ser NULL
 *
 * Retorna 1 se todas válidas, 0 caso contrário.
 */
SECP256K1_API int secp256k1_delta20_batch_verify(
    const secp256k1_context*    ctx,
    const unsigned char* const* sigs,
    const unsigned char* const* msgs,
    size_t                      msglen,
    const unsigned char* const* pubkeys,
    size_t                      m,
    const unsigned char*        blind_seed
) SECP256K1_ARG_NONNULL(1)
  SECP256K1_ARG_NONNULL(2)
  SECP256K1_ARG_NONNULL(3)
  SECP256K1_ARG_NONNULL(5)
  SECP256K1_ARG_NONNULL(7);

#ifdef __cplusplus
}
#endif

#endif /* SECP256K1_DELTA20_BATCH_H */
