// tic80remote: run a TIC-80 (0.90-dev) cart headless and control it with text commands.
//
// Links the real TIC-80 core (libtic80core.a from a TIC-80 0.70 checkout), so carts run
// exactly as in the console - same Lua, scanline/OVR callbacks, palette and font - but
// without a window. Commands come one per line from stdin (or a script file); every
// command answers with one line starting "ok" or "err". Cart trace()/errors are printed
// as lines starting with "#".
//
//   load FILE                 load a .tic cart (also: first command-line argument)
//   tick [N]                  run N frames (default 1) with the current input
//   lua CODE                  run Lua in the cart (after the first tick); a bare expression
//                             is returned: "lua G.score" -> "ok 120"
//   btn [B...]                hold gamepad buttons until changed: 0-31 or up/down/left/right/
//                             a/b/x/y (player 1); "btn" alone releases all
//   key [K...]                hold up to 4 keys: a-z, 0-9, space, return, up, ..., f12, or codes
//   mouse X Y [left|middle|right...]
//   screenshot FILE [SCALE] [border]   PNG of the 240x136 screen (or 256x144 with border)
//   peek ADDR [N]             hex bytes of RAM;  poke ADDR BYTE...
//   frame                     number of frames run so far
//   quit
//
// Note: carts with "-- input: gamepad" (or mouse) metadata cannot read the keyboard - as in
// the real console.

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <tic80.h>
#include "api.h"
#include "core/core.h"

#include "lua.h"
#include "lauxlib.h"
#include "zlib.h"

static tic80* Tic;
static tic80_input Input;
static long Frames;

static const char* KeyNames[] = {
	"", "a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u",
	"v","w","x","y","z", "0","1","2","3","4","5","6","7","8","9",
	"minus","equals","leftbracket","rightbracket","backslash","semicolon","apostrophe",
	"grave","comma","period","slash","space","tab","return","backspace","delete","insert",
	"pageup","pagedown","home","end","up","down","left","right","capslock","ctrl","shift",
	"alt","escape","f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f11","f12", NULL};

static const char* BtnNames[] = {"up","down","left","right","a","b","x","y", NULL};

static void onTrace(const char* text, u8 color) { printf("# trace: %s\n", text); }
static void onError(const char* info) { printf("# error: %s\n", info); }
static void onExit(void) { printf("# exit\n"); }

static tic_core* machine(void) { return Tic ? (tic_core*)((tic80_local*)Tic)->memory : NULL; }

static int lookup(const char* name, const char** names)
{
	for(int i = 0; names[i]; i++)
		if(names[i][0] && strcmp(names[i], name) == 0) return i;
	char* end;
	long v = strtol(name, &end, 0);
	return (*name && !*end) ? (int)v : -1;
}

// ---------------------------------------------------------------- PNG (via zlib)
static void chunk(FILE* f, const char* type, const u8* data, u32 len)
{
	u8 hdr[8] = {len >> 24, len >> 16, len >> 8, len, type[0], type[1], type[2], type[3]};
	fwrite(hdr, 1, 8, f);
	if(len) fwrite(data, 1, len, f);
	uLong crc = crc32(crc32(0, NULL, 0), hdr + 4, 4);
	if(len) crc = crc32(crc, data, len);
	u8 c[4] = {crc >> 24, crc >> 16, crc >> 8, crc};
	fwrite(c, 1, 4, f);
}

static int writePng(const char* path, int scale, int border)
{
	int x0 = border ? 0 : (TIC80_FULLWIDTH - TIC80_WIDTH) / 2;
	int y0 = border ? 0 : (TIC80_FULLHEIGHT - TIC80_HEIGHT) / 2;
	int w = (border ? TIC80_FULLWIDTH : TIC80_WIDTH), h = (border ? TIC80_FULLHEIGHT : TIC80_HEIGHT);
	int W = w * scale, H = h * scale;
	size_t rowLen = 1 + (size_t)W * 3;
	u8* raw = malloc(rowLen * H);
	for(int y = 0; y < H; y++)
	{
		u8* row = raw + y * rowLen;
		row[0] = 0;
		for(int x = 0; x < W; x++)
		{
			// screen is ABGR8888: bytes R, G, B, A in memory
			const u8* p = (const u8*)&Tic->screen[(y0 + y / scale) * TIC80_FULLWIDTH + x0 + x / scale];
			memcpy(row + 1 + x * 3, p, 3);
		}
	}
	uLongf zlen = compressBound(rowLen * H);
	u8* z = malloc(zlen);
	compress2(z, &zlen, raw, rowLen * H, 9);

	FILE* f = fopen(path, "wb");
	if(!f) { free(raw); free(z); return 0; }
	fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
	u8 ihdr[13] = {W >> 24, W >> 16, W >> 8, W, H >> 24, H >> 16, H >> 8, H, 8, 2, 0, 0, 0};
	chunk(f, "IHDR", ihdr, 13);
	chunk(f, "IDAT", z, zlen);
	chunk(f, "IEND", NULL, 0);
	fclose(f);
	free(raw);
	free(z);
	return 1;
}

// ---------------------------------------------------------------- commands
static void cmdLoad(const char* path)
{
	FILE* f = fopen(path, "rb");
	if(!f) { printf("err cannot open %s\n", path); return; }
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	void* data = malloc(size);
	size_t got = fread(data, 1, size, f);
	fclose(f);
	if(got != (size_t)size) { free(data); printf("err cannot read %s\n", path); return; }

	if(Tic) tic80_delete(Tic);
	Tic = tic80_create(44100);
	Tic->callback.trace = onTrace;
	Tic->callback.error = onError;
	Tic->callback.exit = onExit;
	tic80_load(Tic, data, (s32)size);
	free(data);
	Frames = 0;
	printf("ok loaded %s (%ld bytes)\n", path, size);
}

static void cmdLua(const char* code)
{
	tic_core* m = machine();
	if(!m || !m->state.initialized || !m->lua)
	{
		printf("err cart not started (Lua carts start on the first tick)\n");
		return;
	}
	lua_State* L = m->lua;
	int top = lua_gettop(L);
	char* ret = malloc(strlen(code) + 8);
	sprintf(ret, "return %s", code);
	int status = luaL_loadstring(L, ret);
	free(ret);
	if(status != LUA_OK)
	{
		lua_pop(L, 1);
		status = luaL_loadstring(L, code);
	}
	if(status == LUA_OK) status = lua_pcall(L, 0, LUA_MULTRET, 0);
	if(status != LUA_OK)
	{
		const char* msg = lua_tostring(L, -1);
		printf("err %s\n", msg ? msg : "?");
		lua_settop(L, top);
		return;
	}
	printf("ok");
	for(int i = top + 1; i <= lua_gettop(L); i++)
	{
		const char* s = luaL_tolstring(L, i, NULL);
		printf("%s%s", i == top + 1 ? " " : "\t", s);
		lua_pop(L, 1);
	}
	printf("\n");
	lua_settop(L, top);
}

static void cmdBtn(char* args)
{
	u32 data = 0;
	for(char* t = strtok(args, " \t"); t; t = strtok(NULL, " \t"))
	{
		int b = lookup(t, BtnNames);
		if(b < 0 || b > 31) { printf("err unknown button %s\n", t); return; }
		data |= 1u << b;
	}
	Input.gamepads.data = data;
	printf("ok\n");
}

static void cmdKey(char* args)
{
	tic80_keyboard kb = {.data = 0};
	int n = 0;
	for(char* t = strtok(args, " \t"); t; t = strtok(NULL, " \t"))
	{
		int k = lookup(t, KeyNames);
		if(k <= 0 || k >= tic_keys_count) { printf("err unknown key %s\n", t); return; }
		if(n == TIC80_KEY_BUFFER) { printf("err at most %d keys\n", TIC80_KEY_BUFFER); return; }
		kb.keys[n++] = (tic_key)k;
	}
	Input.keyboard = kb;
	printf("ok\n");
}

static void cmdMouse(char* args)
{
	char* t = strtok(args, " \t");
	char* u = t ? strtok(NULL, " \t") : NULL;
	if(!u) { printf("err usage: mouse X Y [left|middle|right...]\n"); return; }
	Input.mouse.x = (u8)atoi(t);
	Input.mouse.y = (u8)atoi(u);
	Input.mouse.btns = 0;
	for(t = strtok(NULL, " \t"); t; t = strtok(NULL, " \t"))
	{
		if(!strcmp(t, "left")) Input.mouse.left = 1;
		else if(!strcmp(t, "middle")) Input.mouse.middle = 1;
		else if(!strcmp(t, "right")) Input.mouse.right = 1;
		else { printf("err unknown mouse button %s\n", t); return; }
	}
	printf("ok\n");
}

static int handle(char* line)
{
	line[strcspn(line, "\r\n")] = 0;
	while(isspace((u8)*line)) line++;
	if(!*line || *line == '#') return 1;

	char* args = line + strcspn(line, " \t");
	if(*args) *args++ = 0;
	while(isspace((u8)*args)) args++;
	const char* cmd = line;

	if(!strcmp(cmd, "quit") || !strcmp(cmd, "exit")) { printf("ok bye\n"); return 0; }
	if(!strcmp(cmd, "load")) { cmdLoad(args); return 1; }
	if(!Tic) { printf("err no cart loaded\n"); return 1; }

	if(!strcmp(cmd, "tick"))
	{
		long n = *args ? atol(args) : 1;
		for(long i = 0; i < n; i++, Frames++) tic80_tick(Tic, &Input);
		printf("ok frame %ld\n", Frames);
	}
	else if(!strcmp(cmd, "lua")) cmdLua(args);
	else if(!strcmp(cmd, "btn")) cmdBtn(args);
	else if(!strcmp(cmd, "key")) cmdKey(args);
	else if(!strcmp(cmd, "mouse")) cmdMouse(args);
	else if(!strcmp(cmd, "screenshot"))
	{
		char* path = strtok(args, " \t");
		int scale = 1, border = 0;
		for(char* t = strtok(NULL, " \t"); t; t = strtok(NULL, " \t"))
		{
			if(!strcmp(t, "border")) border = 1;
			else scale = atoi(t) > 0 ? atoi(t) : 1;
		}
		if(!path) printf("err usage: screenshot FILE [SCALE] [border]\n");
		else if(writePng(path, scale, border)) printf("ok %s\n", path);
		else printf("err cannot write %s\n", path);
	}
	else if(!strcmp(cmd, "peek"))
	{
		char* t = strtok(args, " \t");
		char* u = t ? strtok(NULL, " \t") : NULL;
		long addr = t ? strtol(t, NULL, 0) : -1, n = u ? strtol(u, NULL, 0) : 1;
		if(addr < 0 || n < 1 || addr + n > (long)TIC_RAM_SIZE) { printf("err bad address\n"); return 1; }
		printf("ok");
		for(long i = 0; i < n; i++) printf(" %02x", Tic ? machine()->memory.ram.data[addr + i] : 0);
		printf("\n");
	}
	else if(!strcmp(cmd, "poke"))
	{
		char* t = strtok(args, " \t");
		long addr = t ? strtol(t, NULL, 0) : -1;
		int n = 0;
		for(t = strtok(NULL, " \t"); t && addr >= 0 && addr + n < (long)TIC_RAM_SIZE; t = strtok(NULL, " \t"))
			machine()->memory.ram.data[addr + n++] = (u8)strtol(t, NULL, 0);
		if(addr < 0 || !n) printf("err usage: poke ADDR BYTE...\n");
		else printf("ok %d bytes\n", n);
	}
	else if(!strcmp(cmd, "frame")) printf("ok %ld\n", Frames);
	else printf("err unknown command %s\n", cmd);
	return 1;
}

int main(int argc, char** argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	FILE* in = stdin;
	int i = 1;
	if(i < argc && strcmp(argv[i], "-h") && strcmp(argv[i], "--help"))
	{
		char cmd[4096];
		snprintf(cmd, sizeof cmd, "load %s", argv[i++]);
		handle(cmd);
	}
	else if(i < argc)
	{
		printf("usage: %s [CART.tic] [SCRIPT]   (commands from SCRIPT or stdin; see source header)\n", argv[0]);
		return 0;
	}
	if(i < argc && !(in = fopen(argv[i], "r"))) { printf("err cannot open %s\n", argv[i]); return 1; }

	char line[1 << 16];
	while(fgets(line, sizeof line, in))
		if(!handle(line)) break;

	if(Tic) tic80_delete(Tic);
	return 0;
}
