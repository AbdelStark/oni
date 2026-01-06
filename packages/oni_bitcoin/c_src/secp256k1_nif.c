// secp256k1_nif.c - NIF wrapper for libsecp256k1 Bitcoin cryptography
//
// This NIF provides:
// - ECDSA signature verification (secp256k1)
// - Schnorr signature verification (BIP-340)
// - Public key parsing and serialization
//
// Build requirements: libsecp256k1 with schnorrsig module enabled

#include <erl_nif.h>
#include <string.h>
#include <secp256k1.h>
#include <secp256k1_schnorrsig.h>
#include <secp256k1_extrakeys.h>

// Thread-local context for secp256k1 operations
static ErlNifResourceType *CONTEXT_RESOURCE = NULL;
static secp256k1_context *global_ctx = NULL;

// Initialize the secp256k1 context
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)env;
    (void)priv_data;
    (void)load_info;

    // Create a context for both signing and verification
    global_ctx = secp256k1_context_create(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY);
    if (global_ctx == NULL) {
        return -1;
    }

    return 0;
}

// Cleanup the context on unload
static void unload(ErlNifEnv *env, void *priv_data) {
    (void)env;
    (void)priv_data;

    if (global_ctx != NULL) {
        secp256k1_context_destroy(global_ctx);
        global_ctx = NULL;
    }
}

// Upgrade callback
static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info) {
    (void)env;
    (void)old_priv_data;
    (void)load_info;
    *priv_data = NULL;
    return 0;
}

// Helper to create atom terms
static ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *name) {
    ERL_NIF_TERM atom;
    if (enif_make_existing_atom(env, name, &atom, ERL_NIF_LATIN1)) {
        return atom;
    }
    return enif_make_atom(env, name);
}

// Helper result tuples
static ERL_NIF_TERM make_ok(ErlNifEnv *env, ERL_NIF_TERM result) {
    return enif_make_tuple2(env, make_atom(env, "ok"), result);
}

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, make_atom(env, "error"), make_atom(env, reason));
}

// ============================================================================
// ECDSA Signature Verification
// ============================================================================

// ecdsa_verify(MsgHash :: binary(), Signature :: binary(), PubKey :: binary()) ->
//     {ok, true | false} | {error, Reason}
static ERL_NIF_TERM ecdsa_verify_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary msg_hash, signature, pubkey;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    // Get the message hash (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[0], &msg_hash) || msg_hash.size != 32) {
        return make_error(env, "invalid_message_hash");
    }

    // Get the DER-encoded signature
    if (!enif_inspect_binary(env, argv[1], &signature)) {
        return make_error(env, "invalid_signature");
    }

    // Get the public key (33 or 65 bytes)
    if (!enif_inspect_binary(env, argv[2], &pubkey)) {
        return make_error(env, "invalid_pubkey");
    }

    if (pubkey.size != 33 && pubkey.size != 65) {
        return make_error(env, "invalid_pubkey_length");
    }

    // Parse the public key
    secp256k1_pubkey pk;
    if (!secp256k1_ec_pubkey_parse(global_ctx, &pk, pubkey.data, pubkey.size)) {
        return make_error(env, "pubkey_parse_failed");
    }

    // Parse the DER signature
    secp256k1_ecdsa_signature sig;
    if (!secp256k1_ecdsa_signature_parse_der(global_ctx, &sig, signature.data, signature.size)) {
        return make_error(env, "signature_parse_failed");
    }

    // Normalize the signature to lower-S form (required by BIP-0066)
    secp256k1_ecdsa_signature_normalize(global_ctx, &sig, &sig);

    // Verify the signature
    int result = secp256k1_ecdsa_verify(global_ctx, &sig, msg_hash.data, &pk);

    return make_ok(env, result ? make_atom(env, "true") : make_atom(env, "false"));
}

// ============================================================================
// Schnorr Signature Verification (BIP-340)
// ============================================================================

// schnorr_verify(MsgHash :: binary(), Signature :: binary(), XOnlyPubKey :: binary()) ->
//     {ok, true | false} | {error, Reason}
static ERL_NIF_TERM schnorr_verify_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary msg_hash, signature, xonly_pubkey;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    // Get the message hash (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[0], &msg_hash) || msg_hash.size != 32) {
        return make_error(env, "invalid_message_hash");
    }

    // Get the Schnorr signature (must be 64 bytes)
    if (!enif_inspect_binary(env, argv[1], &signature) || signature.size != 64) {
        return make_error(env, "invalid_signature");
    }

    // Get the x-only public key (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[2], &xonly_pubkey) || xonly_pubkey.size != 32) {
        return make_error(env, "invalid_xonly_pubkey");
    }

    // Parse the x-only public key
    secp256k1_xonly_pubkey pk;
    if (!secp256k1_xonly_pubkey_parse(global_ctx, &pk, xonly_pubkey.data)) {
        return make_error(env, "xonly_pubkey_parse_failed");
    }

    // Verify the Schnorr signature
    int result = secp256k1_schnorrsig_verify(global_ctx, signature.data, msg_hash.data, 32, &pk);

    return make_ok(env, result ? make_atom(env, "true") : make_atom(env, "false"));
}

// ============================================================================
// Public Key Operations
// ============================================================================

// parse_pubkey(PubKeyBytes :: binary()) -> {ok, ParsedPubKey} | {error, Reason}
static ERL_NIF_TERM parse_pubkey_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary pubkey_bytes;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[0], &pubkey_bytes)) {
        return make_error(env, "invalid_binary");
    }

    if (pubkey_bytes.size != 33 && pubkey_bytes.size != 65) {
        return make_error(env, "invalid_pubkey_length");
    }

    secp256k1_pubkey pk;
    if (!secp256k1_ec_pubkey_parse(global_ctx, &pk, pubkey_bytes.data, pubkey_bytes.size)) {
        return make_error(env, "parse_failed");
    }

    // Re-serialize in compressed form (33 bytes)
    unsigned char output[33];
    size_t output_len = 33;
    secp256k1_ec_pubkey_serialize(global_ctx, output, &output_len, &pk, SECP256K1_EC_COMPRESSED);

    ERL_NIF_TERM result;
    unsigned char *result_data = enif_make_new_binary(env, output_len, &result);
    memcpy(result_data, output, output_len);

    return make_ok(env, result);
}

// pubkey_to_xonly(PubKeyBytes :: binary()) -> {ok, XOnlyPubKey} | {error, Reason}
static ERL_NIF_TERM pubkey_to_xonly_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary pubkey_bytes;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[0], &pubkey_bytes)) {
        return make_error(env, "invalid_binary");
    }

    if (pubkey_bytes.size != 33 && pubkey_bytes.size != 65) {
        return make_error(env, "invalid_pubkey_length");
    }

    secp256k1_pubkey pk;
    if (!secp256k1_ec_pubkey_parse(global_ctx, &pk, pubkey_bytes.data, pubkey_bytes.size)) {
        return make_error(env, "parse_failed");
    }

    // Convert to x-only
    secp256k1_xonly_pubkey xonly;
    int parity;
    if (!secp256k1_xonly_pubkey_from_pubkey(global_ctx, &xonly, &parity, &pk)) {
        return make_error(env, "xonly_conversion_failed");
    }

    // Serialize the x-only pubkey (32 bytes)
    unsigned char output[32];
    secp256k1_xonly_pubkey_serialize(global_ctx, output, &xonly);

    ERL_NIF_TERM result;
    unsigned char *result_data = enif_make_new_binary(env, 32, &result);
    memcpy(result_data, output, 32);

    // Return {ok, {XOnlyPubKey, Parity}}
    return make_ok(env, enif_make_tuple2(env, result, enif_make_int(env, parity)));
}

// ============================================================================
// Taproot Tweaking
// ============================================================================

// tweak_pubkey(InternalPubKey :: binary(), TweakHash :: binary()) ->
//     {ok, {OutputPubKey, Parity}} | {error, Reason}
static ERL_NIF_TERM tweak_pubkey_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary internal_key, tweak_hash;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    // Get the internal public key (32 bytes x-only)
    if (!enif_inspect_binary(env, argv[0], &internal_key) || internal_key.size != 32) {
        return make_error(env, "invalid_internal_key");
    }

    // Get the tweak hash (32 bytes)
    if (!enif_inspect_binary(env, argv[1], &tweak_hash) || tweak_hash.size != 32) {
        return make_error(env, "invalid_tweak_hash");
    }

    // Parse the x-only internal key
    secp256k1_xonly_pubkey internal_xonly;
    if (!secp256k1_xonly_pubkey_parse(global_ctx, &internal_xonly, internal_key.data)) {
        return make_error(env, "internal_key_parse_failed");
    }

    // Tweak the pubkey (BIP-341 key path spending)
    secp256k1_pubkey output_pubkey;
    if (!secp256k1_xonly_pubkey_tweak_add(global_ctx, &output_pubkey, &internal_xonly, tweak_hash.data)) {
        return make_error(env, "tweak_failed");
    }

    // Convert output to x-only
    secp256k1_xonly_pubkey output_xonly;
    int parity;
    if (!secp256k1_xonly_pubkey_from_pubkey(global_ctx, &output_xonly, &parity, &output_pubkey)) {
        return make_error(env, "output_conversion_failed");
    }

    // Serialize
    unsigned char output[32];
    secp256k1_xonly_pubkey_serialize(global_ctx, output, &output_xonly);

    ERL_NIF_TERM result;
    unsigned char *result_data = enif_make_new_binary(env, 32, &result);
    memcpy(result_data, output, 32);

    return make_ok(env, enif_make_tuple2(env, result, enif_make_int(env, parity)));
}

// ============================================================================
// Private Key to Public Key
// ============================================================================

// private_to_public(PrivateKey :: binary()) -> {ok, PubKey} | {error, Reason}
static ERL_NIF_TERM private_to_public_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary private_key;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    // Get the private key (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[0], &private_key) || private_key.size != 32) {
        return make_error(env, "invalid_private_key");
    }

    // Verify the private key is valid
    if (!secp256k1_ec_seckey_verify(global_ctx, private_key.data)) {
        return make_error(env, "invalid_private_key_value");
    }

    // Create the public key
    secp256k1_pubkey pubkey;
    if (!secp256k1_ec_pubkey_create(global_ctx, &pubkey, private_key.data)) {
        return make_error(env, "pubkey_create_failed");
    }

    // Serialize in compressed form (33 bytes)
    unsigned char output[33];
    size_t output_len = 33;
    secp256k1_ec_pubkey_serialize(global_ctx, output, &output_len, &pubkey, SECP256K1_EC_COMPRESSED);

    ERL_NIF_TERM result;
    unsigned char *result_data = enif_make_new_binary(env, output_len, &result);
    memcpy(result_data, output, output_len);

    return make_ok(env, result);
}

// ============================================================================
// ECDSA Signing
// ============================================================================

// ecdsa_sign(MsgHash :: binary(), PrivateKey :: binary()) ->
//     {ok, Signature} | {error, Reason}
static ERL_NIF_TERM ecdsa_sign_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary msg_hash, private_key;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    // Get the message hash (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[0], &msg_hash) || msg_hash.size != 32) {
        return make_error(env, "invalid_message_hash");
    }

    // Get the private key (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[1], &private_key) || private_key.size != 32) {
        return make_error(env, "invalid_private_key");
    }

    // Sign the message
    secp256k1_ecdsa_signature sig;
    if (!secp256k1_ecdsa_sign(global_ctx, &sig, msg_hash.data, private_key.data, NULL, NULL)) {
        return make_error(env, "sign_failed");
    }

    // Serialize to DER format
    unsigned char output[72];
    size_t output_len = 72;
    if (!secp256k1_ecdsa_signature_serialize_der(global_ctx, output, &output_len, &sig)) {
        return make_error(env, "signature_serialize_failed");
    }

    ERL_NIF_TERM result;
    unsigned char *result_data = enif_make_new_binary(env, output_len, &result);
    memcpy(result_data, output, output_len);

    return make_ok(env, result);
}

// ============================================================================
// Schnorr Signing (BIP-340)
// ============================================================================

// schnorr_sign(MsgHash :: binary(), PrivateKey :: binary(), AuxRand :: binary()) ->
//     {ok, Signature} | {error, Reason}
static ERL_NIF_TERM schnorr_sign_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary msg_hash, private_key, aux_rand;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    // Get the message hash (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[0], &msg_hash) || msg_hash.size != 32) {
        return make_error(env, "invalid_message_hash");
    }

    // Get the private key (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[1], &private_key) || private_key.size != 32) {
        return make_error(env, "invalid_private_key");
    }

    // Get the auxiliary randomness (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[2], &aux_rand) || aux_rand.size != 32) {
        return make_error(env, "invalid_aux_rand");
    }

    // Create keypair from private key
    secp256k1_keypair keypair;
    if (!secp256k1_keypair_create(global_ctx, &keypair, private_key.data)) {
        return make_error(env, "keypair_create_failed");
    }

    // Sign the message (BIP-340)
    unsigned char sig[64];
    if (!secp256k1_schnorrsig_sign32(global_ctx, sig, msg_hash.data, &keypair, aux_rand.data)) {
        return make_error(env, "schnorr_sign_failed");
    }

    ERL_NIF_TERM result;
    unsigned char *result_data = enif_make_new_binary(env, 64, &result);
    memcpy(result_data, sig, 64);

    return make_ok(env, result);
}

// ============================================================================
// Private Key Tweaking (for HD derivation)
// ============================================================================

// tweak_private_key(PrivateKey :: binary(), Tweak :: binary()) ->
//     {ok, TweakedPrivateKey} | {error, Reason}
static ERL_NIF_TERM tweak_private_key_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary private_key, tweak;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    // Get the private key (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[0], &private_key) || private_key.size != 32) {
        return make_error(env, "invalid_private_key");
    }

    // Get the tweak (must be 32 bytes)
    if (!enif_inspect_binary(env, argv[1], &tweak) || tweak.size != 32) {
        return make_error(env, "invalid_tweak");
    }

    // Copy private key to output buffer (secp256k1 modifies in place)
    unsigned char output[32];
    memcpy(output, private_key.data, 32);

    // Add tweak to private key (mod n)
    if (!secp256k1_ec_seckey_tweak_add(global_ctx, output, tweak.data)) {
        return make_error(env, "tweak_failed");
    }

    ERL_NIF_TERM result;
    unsigned char *result_data = enif_make_new_binary(env, 32, &result);
    memcpy(result_data, output, 32);

    return make_ok(env, result);
}

// ============================================================================
// NIF Registration
// ============================================================================

static ErlNifFunc nif_funcs[] = {
    {"ecdsa_verify_nif", 3, ecdsa_verify_nif, 0},
    {"schnorr_verify_nif", 3, schnorr_verify_nif, 0},
    {"parse_pubkey_nif", 1, parse_pubkey_nif, 0},
    {"pubkey_to_xonly_nif", 1, pubkey_to_xonly_nif, 0},
    {"tweak_pubkey_nif", 2, tweak_pubkey_nif, 0},
    {"private_to_public_nif", 1, private_to_public_nif, 0},
    {"ecdsa_sign_nif", 2, ecdsa_sign_nif, 0},
    {"schnorr_sign_nif", 3, schnorr_sign_nif, 0},
    {"tweak_private_key_nif", 2, tweak_private_key_nif, 0}
};

ERL_NIF_INIT(oni_secp256k1, nif_funcs, load, NULL, upgrade, unload)
