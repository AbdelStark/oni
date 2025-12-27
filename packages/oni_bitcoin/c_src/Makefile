# Makefile for secp256k1 NIF
#
# Build requirements:
# - Erlang/OTP development headers
# - libsecp256k1 with schnorrsig and extrakeys modules
#
# Install libsecp256k1:
#   git clone https://github.com/bitcoin-core/secp256k1.git
#   cd secp256k1
#   ./autogen.sh
#   ./configure --enable-module-schnorrsig --enable-module-extrakeys
#   make
#   sudo make install

# Erlang paths
ERL_INCLUDE_DIR ?= $(shell erl -eval 'io:format("~s~n", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
ERTS_INCLUDE_DIR ?= $(ERL_INCLUDE_DIR)

# Compiler settings
CC ?= gcc
CFLAGS ?= -O2 -fPIC -Wall -Wextra -Werror
LDFLAGS ?= -shared

# Platform-specific settings
UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
    LDFLAGS += -dynamiclib -undefined dynamic_lookup
    SO_EXT = .so
else
    LDFLAGS += -shared
    SO_EXT = .so
endif

# Include paths
INCLUDES = -I$(ERL_INCLUDE_DIR) -I$(ERTS_INCLUDE_DIR)

# Libraries
LIBS = -lsecp256k1

# Source and target
SRC = secp256k1_nif.c
TARGET = ../priv/oni_secp256k1$(SO_EXT)

# Build rules
.PHONY: all clean

all: ../priv $(TARGET)

../priv:
	mkdir -p ../priv

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(INCLUDES) $(LDFLAGS) -o $@ $< $(LIBS)

clean:
	rm -f $(TARGET)
