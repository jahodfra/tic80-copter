# Headless TIC-80 runner linked against the 0.90-dev core in ~/TIC-80 (build that first).
#   make -C tools/tic80remote && printf 'tick 8\nscreenshot /tmp/a.png 2\nquit\n' | tools/tic80remote/tic80remote build/copter.tic
T ?= $(HOME)/TIC-80
L = $(T)/build/lib
tic80remote: tic80remote.c
	$(CC) -O2 -std=gnu11 -w -I$(T)/include -I$(T)/src -I$(T)/vendor/lua -I$(T)/vendor/zlib -I$(T)/vendor/blip-buf \
		-o $@ $< $(L)/libtic80core.a $(L)/liblua.a $(L)/liblpeg.a $(L)/libwren.a $(L)/libsquirrel.a \
		$(L)/libduktape.a $(L)/libgiflib.a $(L)/libblipbuf.a $(L)/libzlib.a -lstdc++ -lm -ldl
