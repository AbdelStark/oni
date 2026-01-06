%%% oni_secp256k1 - NIF wrapper for secp256k1 Bitcoin cryptography
%%%
%%% This module provides efficient cryptographic operations for Bitcoin:
%%% - ECDSA signature verification (secp256k1)
%%% - Schnorr signature verification (BIP-340)
%%% - Public key operations for Taproot
%%%
%%% The NIF is loaded from priv/oni_secp256k1.so. If the NIF is not available,
%%% fallback implementations using Erlang's crypto module are used where possible.

-module(oni_secp256k1).
-export([
    %% Verification
    ecdsa_verify/3,
    schnorr_verify/3,
    %% Public key operations
    parse_pubkey/1,
    pubkey_to_xonly/1,
    tweak_pubkey/2,
    %% Signing
    private_to_public/1,
    ecdsa_sign/2,
    schnorr_sign/3,
    tweak_private_key/2
]).

%% NIF stubs that get replaced when the NIF is loaded
-on_load(init/0).

init() ->
    %% Try to load the NIF from the priv directory
    PrivDir = case code:priv_dir(oni_bitcoin) of
        {error, _} ->
            %% Fallback for development
            case code:which(?MODULE) of
                Filename when is_list(Filename) ->
                    filename:join([filename:dirname(Filename), "..", "priv"]);
                _ ->
                    "./priv"
            end;
        Dir ->
            Dir
    end,
    NifPath = filename:join(PrivDir, "oni_secp256k1"),
    case erlang:load_nif(NifPath, 0) of
        ok -> ok;
        {error, {reload, _}} -> ok;
        {error, Reason} ->
            %% Log warning but don't fail - we have fallbacks
            error_logger:warning_msg("Failed to load secp256k1 NIF: ~p~nUsing Erlang crypto fallback~n", [Reason]),
            ok
    end.

%% ============================================================================
%% ECDSA Signature Verification
%% ============================================================================

%% @doc Verify an ECDSA signature on secp256k1
%% @param MsgHash 32-byte message hash (typically double-SHA256 of sighash preimage)
%% @param Signature DER-encoded ECDSA signature
%% @param PubKey 33-byte compressed or 65-byte uncompressed public key
%% @returns {ok, true | false} | {error, Reason}
-spec ecdsa_verify(binary(), binary(), binary()) -> {ok, boolean()} | {error, atom()}.
ecdsa_verify(MsgHash, Signature, PubKey) when byte_size(MsgHash) =:= 32 ->
    %% Try NIF first
    case catch ecdsa_verify_nif(MsgHash, Signature, PubKey) of
        {'EXIT', {undef, _}} ->
            %% NIF not loaded, use Erlang crypto fallback
            ecdsa_verify_fallback(MsgHash, Signature, PubKey);
        Result ->
            Result
    end;
ecdsa_verify(_, _, _) ->
    {error, invalid_message_hash}.

%% Fallback using Erlang's crypto module
ecdsa_verify_fallback(MsgHash, Signature, PubKey) ->
    try
        %% Use Erlang's crypto:verify/5 with ecdsa and secp256k1
        Result = crypto:verify(ecdsa, sha256, {digest, MsgHash}, Signature, [PubKey, secp256k1]),
        {ok, Result}
    catch
        error:badarg ->
            {error, invalid_input};
        error:notsup ->
            {error, not_supported};
        _:_ ->
            {error, verification_failed}
    end.

%% NIF stub
ecdsa_verify_nif(_MsgHash, _Signature, _PubKey) ->
    erlang:nif_error(nif_not_loaded).

%% ============================================================================
%% Schnorr Signature Verification (BIP-340)
%% ============================================================================

%% @doc Verify a BIP-340 Schnorr signature
%% @param MsgHash 32-byte message hash
%% @param Signature 64-byte Schnorr signature
%% @param XOnlyPubKey 32-byte x-only public key
%% @returns {ok, true | false} | {error, Reason}
-spec schnorr_verify(binary(), binary(), binary()) -> {ok, boolean()} | {error, atom()}.
schnorr_verify(MsgHash, Signature, XOnlyPubKey)
    when byte_size(MsgHash) =:= 32, byte_size(Signature) =:= 64, byte_size(XOnlyPubKey) =:= 32 ->
    %% Try NIF first (Schnorr requires the NIF, no Erlang fallback)
    case catch schnorr_verify_nif(MsgHash, Signature, XOnlyPubKey) of
        {'EXIT', {undef, _}} ->
            {error, nif_not_loaded};
        Result ->
            Result
    end;
schnorr_verify(_, _, _) ->
    {error, invalid_input_lengths}.

%% NIF stub
schnorr_verify_nif(_MsgHash, _Signature, _XOnlyPubKey) ->
    erlang:nif_error(nif_not_loaded).

%% ============================================================================
%% Public Key Operations
%% ============================================================================

%% @doc Parse and validate a public key, returning compressed form
%% @param PubKeyBytes Raw public key bytes (33 or 65 bytes)
%% @returns {ok, CompressedPubKey} | {error, Reason}
-spec parse_pubkey(binary()) -> {ok, binary()} | {error, atom()}.
parse_pubkey(PubKeyBytes) when byte_size(PubKeyBytes) =:= 33; byte_size(PubKeyBytes) =:= 65 ->
    case catch parse_pubkey_nif(PubKeyBytes) of
        {'EXIT', {undef, _}} ->
            %% No fallback for parsing without NIF
            {error, nif_not_loaded};
        Result ->
            Result
    end;
parse_pubkey(_) ->
    {error, invalid_pubkey_length}.

%% NIF stub
parse_pubkey_nif(_PubKeyBytes) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Convert a public key to x-only format (for Taproot)
%% @param PubKeyBytes Raw public key bytes (33 or 65 bytes)
%% @returns {ok, {XOnlyPubKey, Parity}} | {error, Reason}
-spec pubkey_to_xonly(binary()) -> {ok, {binary(), integer()}} | {error, atom()}.
pubkey_to_xonly(PubKeyBytes) when byte_size(PubKeyBytes) =:= 33; byte_size(PubKeyBytes) =:= 65 ->
    case catch pubkey_to_xonly_nif(PubKeyBytes) of
        {'EXIT', {undef, _}} ->
            %% Fallback: just strip the prefix for compressed keys
            case PubKeyBytes of
                <<_Prefix:8, XOnly:32/binary>> when byte_size(PubKeyBytes) =:= 33 ->
                    Parity = case binary:first(PubKeyBytes) of 2 -> 0; 3 -> 1 end,
                    {ok, {XOnly, Parity}};
                _ ->
                    {error, nif_not_loaded}
            end;
        Result ->
            Result
    end;
pubkey_to_xonly(_) ->
    {error, invalid_pubkey_length}.

%% NIF stub
pubkey_to_xonly_nif(_PubKeyBytes) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Tweak a public key for Taproot key path spending (BIP-341)
%% @param InternalKey 32-byte x-only internal public key
%% @param TweakHash 32-byte tweak hash
%% @returns {ok, {OutputKey, Parity}} | {error, Reason}
-spec tweak_pubkey(binary(), binary()) -> {ok, {binary(), integer()}} | {error, atom()}.
tweak_pubkey(InternalKey, TweakHash)
    when byte_size(InternalKey) =:= 32, byte_size(TweakHash) =:= 32 ->
    case catch tweak_pubkey_nif(InternalKey, TweakHash) of
        {'EXIT', {undef, _}} ->
            {error, nif_not_loaded};
        Result ->
            Result
    end;
tweak_pubkey(_, _) ->
    {error, invalid_input_lengths}.

%% NIF stub
tweak_pubkey_nif(_InternalKey, _TweakHash) ->
    erlang:nif_error(nif_not_loaded).

%% ============================================================================
%% Signing Operations
%% ============================================================================

%% @doc Derive public key from private key
%% @param PrivateKey 32-byte private key
%% @returns {ok, CompressedPubKey} | {error, Reason}
-spec private_to_public(binary()) -> {ok, binary()} | {error, atom()}.
private_to_public(PrivateKey) when byte_size(PrivateKey) =:= 32 ->
    case catch private_to_public_nif(PrivateKey) of
        {'EXIT', {undef, _}} ->
            %% Fallback using Erlang's crypto module
            private_to_public_fallback(PrivateKey);
        Result ->
            Result
    end;
private_to_public(_) ->
    {error, invalid_private_key_length}.

private_to_public_fallback(PrivateKey) ->
    try
        PubKey = crypto:generate_key(ecdh, secp256k1, PrivateKey),
        case PubKey of
            {Pub, _} when byte_size(Pub) =:= 65 ->
                %% Compress the public key
                <<_:8, X:256, Y:256>> = Pub,
                Prefix = case Y band 1 of
                    0 -> 2;
                    1 -> 3
                end,
                {ok, <<Prefix:8, X:256>>};
            _ ->
                {error, invalid_public_key}
        end
    catch
        _:_ ->
            {error, key_derivation_failed}
    end.

%% NIF stub
private_to_public_nif(_PrivateKey) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Sign a message hash with ECDSA
%% @param MsgHash 32-byte message hash
%% @param PrivateKey 32-byte private key
%% @returns {ok, DERSignature} | {error, Reason}
-spec ecdsa_sign(binary(), binary()) -> {ok, binary()} | {error, atom()}.
ecdsa_sign(MsgHash, PrivateKey)
    when byte_size(MsgHash) =:= 32, byte_size(PrivateKey) =:= 32 ->
    case catch ecdsa_sign_nif(MsgHash, PrivateKey) of
        {'EXIT', {undef, _}} ->
            %% Fallback using Erlang's crypto module
            ecdsa_sign_fallback(MsgHash, PrivateKey);
        Result ->
            Result
    end;
ecdsa_sign(_, _) ->
    {error, invalid_input_lengths}.

ecdsa_sign_fallback(MsgHash, PrivateKey) ->
    try
        Sig = crypto:sign(ecdsa, sha256, {digest, MsgHash}, [PrivateKey, secp256k1]),
        {ok, Sig}
    catch
        _:_ ->
            {error, sign_failed}
    end.

%% NIF stub
ecdsa_sign_nif(_MsgHash, _PrivateKey) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Sign a message hash with BIP-340 Schnorr
%% @param MsgHash 32-byte message hash
%% @param PrivateKey 32-byte private key
%% @param AuxRand 32-byte auxiliary randomness
%% @returns {ok, Signature} | {error, Reason}
-spec schnorr_sign(binary(), binary(), binary()) -> {ok, binary()} | {error, atom()}.
schnorr_sign(MsgHash, PrivateKey, AuxRand)
    when byte_size(MsgHash) =:= 32, byte_size(PrivateKey) =:= 32, byte_size(AuxRand) =:= 32 ->
    case catch schnorr_sign_nif(MsgHash, PrivateKey, AuxRand) of
        {'EXIT', {undef, _}} ->
            {error, nif_not_loaded};
        Result ->
            Result
    end;
schnorr_sign(_, _, _) ->
    {error, invalid_input_lengths}.

%% NIF stub
schnorr_sign_nif(_MsgHash, _PrivateKey, _AuxRand) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Tweak a private key for HD derivation
%% @param PrivateKey 32-byte private key
%% @param Tweak 32-byte tweak value
%% @returns {ok, TweakedPrivateKey} | {error, Reason}
-spec tweak_private_key(binary(), binary()) -> {ok, binary()} | {error, atom()}.
tweak_private_key(PrivateKey, Tweak)
    when byte_size(PrivateKey) =:= 32, byte_size(Tweak) =:= 32 ->
    case catch tweak_private_key_nif(PrivateKey, Tweak) of
        {'EXIT', {undef, _}} ->
            {error, nif_not_loaded};
        Result ->
            Result
    end;
tweak_private_key(_, _) ->
    {error, invalid_input_lengths}.

%% NIF stub
tweak_private_key_nif(_PrivateKey, _Tweak) ->
    erlang:nif_error(nif_not_loaded).
