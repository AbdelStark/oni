%%% wallet_ffi - FFI helpers for wallet cryptographic operations
%%%
%%% Provides HMAC-SHA512 and PBKDF2-SHA512 implementations using
%%% Erlang's crypto module.

-module(wallet_ffi).
-export([
    hmac_sha512/2,
    pbkdf2_sha512/4
]).

%% @doc Compute HMAC-SHA512
%% Uses Erlang's crypto:mac/4 for OTP 22+ or crypto:hmac/3 for earlier
-spec hmac_sha512(binary(), binary()) -> binary().
hmac_sha512(Key, Data) ->
    crypto:mac(hmac, sha512, Key, Data).

%% @doc Compute PBKDF2-SHA512
%% Uses Erlang's crypto:pbkdf2_hmac/5
-spec pbkdf2_sha512(binary(), binary(), pos_integer(), pos_integer()) -> binary().
pbkdf2_sha512(Password, Salt, Iterations, Length) ->
    crypto:pbkdf2_hmac(sha512, Password, Salt, Iterations, Length).
