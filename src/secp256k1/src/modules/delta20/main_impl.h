/*
 * δ²⁰ — Batch Schnorr via ecmult_multi_var (Pippenger)
 *
 * AXIOMA: loop de préprocessamento = aritmética escalar pura, zero EC.
 *   secp256k1_ge_set_xo_var (sqrt de campo, ~286 field ops) ocorre
 *   DENTRO do callback — chamado pelo Pippenger, não antes dele.
 *
 * cbdata armazena secp256k1_fe (32 B, x-only), não secp256k1_ge (64 B).
 */

#ifndef SECP256K1_MODULE_DELTA20_MAIN_H
#define SECP256K1_MODULE_DELTA20_MAIN_H

#include "../../../include/secp256k1_delta20_batch.h"

typedef struct {
    const secp256k1_scalar* a;   /* blinding scalars [m]    */
    const secp256k1_fe*     rx;  /* x-coords de R [m]       */
    const secp256k1_scalar* ae;  /* a[i]·e[i] [m]           */
    const secp256k1_fe*     px;  /* x-coords de P [m]       */
} delta20_cbdata;

/* Lift de ponto aqui — dentro do Pippenger, não no préprocessamento. */
static int delta20_ecmult_cb(secp256k1_scalar* sc, secp256k1_ge* pt,
                              size_t idx, void* data)
{
    const delta20_cbdata* d = (const delta20_cbdata*)data;
    const size_t k = idx >> 1;
    if (!(idx & 1)) { *sc = d->a[k];  return secp256k1_ge_set_xo_var(pt, &d->rx[k], 0); }
    else            { *sc = d->ae[k]; return secp256k1_ge_set_xo_var(pt, &d->px[k], 0); }
}

/* e = H_tagged("BIP0340/challenge", R_x || P_x || msg) */
static void delta20_challenge(secp256k1_scalar* e,
                               const unsigned char* r32,
                               const unsigned char* p32,
                               const unsigned char* msg, size_t msglen)
{
    unsigned char buf[32];
    secp256k1_sha256 sha;
    secp256k1_sha256_initialize_tagged(&sha,
        (const unsigned char*)"BIP0340/challenge",
        sizeof("BIP0340/challenge") - 1);
    secp256k1_sha256_write(&sha, r32, 32);
    secp256k1_sha256_write(&sha, p32, 32);
    secp256k1_sha256_write(&sha, msg, msglen);
    secp256k1_sha256_finalize(&sha, buf);
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
    VERIFY_CHECK(ctx != NULL);
    ARG_CHECK(sigs != NULL); ARG_CHECK(msgs != NULL);
    ARG_CHECK(pubkeys != NULL); ARG_CHECK(blind_seed != NULL);
    ARG_CHECK(m > 0);

    int ret = 0;
    size_t i;

    secp256k1_scalar* a  = (secp256k1_scalar*)checked_malloc(&ctx->error_callback, m * sizeof(*a));
    secp256k1_scalar* ae = (secp256k1_scalar*)checked_malloc(&ctx->error_callback, m * sizeof(*ae));
    secp256k1_fe*     rx = (secp256k1_fe*)   checked_malloc(&ctx->error_callback, m * sizeof(*rx));
    secp256k1_fe*     px = (secp256k1_fe*)   checked_malloc(&ctx->error_callback, m * sizeof(*px));

    if (!a || !ae || !rx || !px) goto cleanup;

    {
        secp256k1_rfc6979_hmac_sha256 rng;
        secp256k1_scalar inp_g_sc;
        secp256k1_rfc6979_hmac_sha256_initialize(&rng, blind_seed, 32);
        secp256k1_scalar_set_int(&inp_g_sc, 0);

        /*
         * LOOP: aritmética escalar e hash apenas.
         * Proibido: secp256k1_ge_set_xo_var / set_xquad / fe_sqrt.
         */
        for (i = 0; i < m; i++) {
            secp256k1_scalar s, e, as;
            int overflow;
            unsigned char rand32[32];

            if (!secp256k1_fe_set_b32_limit(&rx[i], sigs[i]))     goto cleanup_rng;
            secp256k1_scalar_set_b32(&s, sigs[i] + 32, &overflow);
            if (overflow) goto cleanup_rng;
            if (!secp256k1_fe_set_b32_limit(&px[i], pubkeys[i]))  goto cleanup_rng;

            delta20_challenge(&e, sigs[i], pubkeys[i], msgs[i], msglen);

            secp256k1_rfc6979_hmac_sha256_generate(&rng, rand32, 32);
            secp256k1_scalar_set_b32(&a[i], rand32, NULL);
            memset(rand32, 0, 32);

            secp256k1_scalar_mul(&ae[i], &a[i], &e);

            secp256k1_scalar_mul(&as, &a[i], &s);
            secp256k1_scalar_negate(&as, &as);
            secp256k1_scalar_add(&inp_g_sc, &inp_g_sc, &as);
            secp256k1_scalar_clear(&as);
        }

        memset(&rng, 0, sizeof(rng));  /* blind_seed residue */

        /* ── Única chamada EC ─────────────────────────────────────────── */
        {
            const int    bw  = secp256k1_pippenger_bucket_window(2 * m);
            const size_t sz  = secp256k1_pippenger_scratch_size(2 * m, bw)
                             + PIPPENGER_SCRATCH_OBJECTS * ALIGNMENT;
            secp256k1_scratch* scratch = secp256k1_scratch_create(&ctx->error_callback, sz);
            if (!scratch) { secp256k1_scalar_clear(&inp_g_sc); goto cleanup; }

            delta20_cbdata cb = { a, rx, ae, px };
            secp256k1_gej  result;
            const int ok = secp256k1_ecmult_multi_var(
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
