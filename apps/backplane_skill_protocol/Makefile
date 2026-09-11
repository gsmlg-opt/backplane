MIX_APP_PATH ?= $(shell mix app.path)
PRIV_DIR := $(MIX_APP_PATH)/priv
NIF := $(PRIV_DIR)/cache_native_lock.so
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s", [filename:join([code:root_dir(), "usr", "include"])])' -s init stop)
CC ?= cc
CFLAGS ?= -O2
CFLAGS += -std=c11 -fPIC -Wall -Wextra -Werror -I$(ERTS_INCLUDE_DIR)

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
  LDFLAGS += -shared
endif

.PHONY: all clean

all: $(NIF)

$(NIF): c_src/cache_native_lock.c
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	$(RM) $(NIF)
