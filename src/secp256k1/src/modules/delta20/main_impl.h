/*
 * delta20 — Batch Schnorr via ecmult_multi_var (Pippenger)
 *
 * AXIOMA: loop de preprocessamento = aritmetica escalar pura, zero EC.
 *   secp256k1_ge_set_xo_var ocorre DENTRO do callback, nao antes.
 *   cbdata armazena secp256k1_fe (32 B, x-only), nao secp256k1_ge (64 B).
 *
 * API hash desta versao do secp256k1: hash_ctx como primeiro argumento em
 *   secp256k1_sha256_{initialize_tagged,write,finalize}
 *   secp256k1_rfc6979_hmac_sha256_{initialize,generate}
 * C89: declaracoes no topo de cada bloco.
 */

#ifndef SECP256K1_MODULE_DELTA20_MAIN_H
#define SECP256K1_MODULE_DELTA20_MAIN_H

#include "../../../include/secp256k1_delta20_batch.h"

typedef struct {
    const secp256k1_scalar* a;
    const secp256k1_fe*     rx;
    const secp256k1_scalar* ae;
    const secp256k1_fe*     px;
} delta20_cbdata;

static int delta20_ecmult_cb(secp256k1_scalar* sc, secp256k1_ge* pt,
                              size_t idx, void* data)
{
    const delta20_cbdata* d = (const delta20_cbdata*)data;
    size_t k = idx >> 1;
    if (!(idx & 1)) { *sc = d->a[k];  return secp256k1_ge_set_xo_var(pt, &d->rx[k], 0); }
    else            { *sc = d->ae[k]; return secp256k1_ge_set_xo_var(pt, &d->px[k], 0); }
}

static void delta20_challenge(const secp256k1_context* ctx,
                               secp256k1_scalar* e,
                               const unsigned char* r32,
                               const unsigned char* p32,
                               const unsigned char* msg, size_t msglen)
{
    unsigned char buf[32];
    secp256k1_sha256 sha;

    secp256k1_sha256_initialize_tagged(&ctx->hash_ctx, &sha,
        (const unsigned char*)"BIP0340/challenge",
        sizeof("BIP0340/challenge") - 1);
    secp256k1_sha256_write(&ctx->hash_ctx, &sha, r32, 32);
    secp256k1_sha256_write(&ctx->hash_ctx, &sha, p32, 32);
    secp256k1_sha256_write(&ctx->hash_ctx, &sha, msg, msglen);
    secp256k1_sha256_finalize(&ctx->hash_ctx, &sha, buf);
    secp256k1_scalar_set_b32(e, buf, NULL);
}

int secp256k1_delta20_batch_verify(
    const secp256k1_context*    ctx,
    const unsigned char* const* sigs,
    const unsigned char* const* msgs,
    size_t                      msglen,
    const unsigned char* const* pubkeys,
    size_t                      m,
    const unsigned char*        blind_seed)
{
    int ret;
    size_t i;
    secp256k1_scalar* a;
    secp256k1_scalar* ae;
    secp256k1_fe*     rx;
    secp256k1_fe*     px;

    VERIFY_CHECK(ctx != NULL);
    ARG_CHECK(sigs != NULL); ARG_CHECK(msgs != NULL);
    ARG_CHECK(pubkeys != NULL); ARG_CHECK(blind_seed != NULL);
    ARG_CHECK(m > 0);

    ret = 0;
    a   = (secp256k1_scalar*)checked_malloc(&ctx->error_callback, m * sizeof(*a));
    ae  = (secp256k1_scalar*)checked_malloc(&ctx->error_callback, m * sizeof(*ae));
    rx  = (secp256k1_fe*)   checked_malloc(&ctx->error_callback, m * sizeof(*rx));
    px  = (secp256k1_fe*)   checked_malloc(&ctx->error_callback, m * sizeof(*px));

    if (!a || !ae || !rx || !px) goto cleanup;

    {
        secp256k1_rfc6979_hmac_sha256 rng;
        secp256k1_scalar inp_g_sc;

        secp256k1_rfc6979_hmac_sha256_initialize(&ctx->hash_ctx, &rng, blind_seed, 32);
        secp256k1_scalar_set_int(&inp_g_sc, 0);

        for (i = 0; i < m; i++) {
            secp256k1_scalar s, e, as;
            int overflow;
            unsigned char rand32[32];

            if (!secp256k1_fe_set_b32_limit(&rx[i], sigs[i]))    goto cleanup_rng;
            secp256k1_scalar_set_b32(&s, sigs[i] + 32, &overflow);
            if (overflow) goto cleanup_rng;
            if (!secp256k1_fe_set_b32_limit(&px[i], pubkeys[i])) goto cleanup_rng;

            delta20_challenge(ctx, &e, sigs[i], pubkeys[i], msgs[i], msglen);

            secp256k1_rfc6979_hmac_sha256_generate(&ctx->hash_ctx, &rng, rand32, 32);
            secp256k1_scalar_set_b32(&a[i], rand32, NULL);
            memset(rand32, 0, 32);

            secp256k1_scalar_mul(&ae[i], &a[i], &e);
            secp256k1_scalar_mul(&as, &a[i], &s);
            secp256k1_scalar_negate(&as, &as);
            secp256k1_scalar_add(&inp_g_sc, &inp_g_sc, &as);
            secp256k1_scalar_clear(&as);
        }

        memset(&rng, 0, sizeof(rng));

        {
            int bw;
            size_t sz;
            secp256k1_scratch* scratch;
            delta20_cbdata cb;
            secp256k1_gej result;
            int ok;

            bw      = secp256k1_pippenger_bucket_window(2 * m);
            sz      = secp256k1_pippenger_scratch_size(2 * m, bw)
                    + PIPPENGER_SCRATCH_OBJECTS * ALIGNMENT;
            scratch = secp256k1_scratch_create(&ctx->error_callback, sz);

            if (!scratch) { secp256k1_scalar_clear(&inp_g_sc); goto cleanup; }

            cb.a  = a;
            cb.rx = rx;
            cb.ae = ae;
            cb.px = px;

            ok = secp256k1_ecmult_multi_var(
                &ctx->error_callback, scratch, &result,
                &inp_g_sc, delta20_ecmult_cb, &cb, 2 * m);

            secp256k1_scratch_destroy(&ctx->error_callback, scratch);
            ret = ok && secp256k1_gej_is_infinity(&result);
        }

        secp256k1_scalar_clear(&inp_g_sc);
        goto cleanup;

cleanup_rng:
        memset(&rng, 0, sizeof(rng));
        secp256k1_scalar_clear(&inp_g_sc);
    }

cleanup:
    if (a)  { for (i = 0; i < m; i++) secp256k1_scalar_clear(&a[i]);  free(a); }
    if (ae) { for (i = 0; i < m; i++) secp256k1_scalar_clear(&ae[i]); free(ae); }
    free(rx);
    free(px);
    return ret;
}

#endif /* SECP256K1_MODULE_DELTA20_MAIN_H */
