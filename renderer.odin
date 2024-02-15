package file_ripper;

import "core:fmt"
import "core:log"
import "core:mem"

import mu "vendor:microui"
import SDL "vendor:SDL2"

window:        ^SDL.Window;
renderer:      ^SDL.Renderer;
atlas_texture: ^SDL.Texture;

width:  i32 = 800;
height: i32 = 600;

@(private="file")
logger: log.Logger = log.create_console_logger(ident = "renderer");

r_test :: proc() {
	WHITE   :: mu.Color{255,255,255,255};
	BLACK   :: mu.Color{0,0,0,255};
	MAGENTA :: mu.Color{255,0,255,255};

	context.logger = logger;

	r_clear(MAGENTA);
    r_set_clip_rect({0,0,width,height});
    r_draw_rect({100,100,100,100}, BLACK);
	r_draw_rect({100+2,100+2,100-4,100-4}, WHITE);
	r_draw_icon(.EXPANDED, {100,100,100,100}, BLACK);
    r_draw_text("Hellope", {0,0}, WHITE);
}


r_init :: proc() ->(ok : bool) {
    context.logger = logger;

	window = SDL.CreateWindow(title = "Odin File Ripper", x = cast(i32) SDL.WINDOWPOS_UNDEFINED, y = cast(i32) SDL.WINDOWPOS_UNDEFINED, w = width, h = height, flags = SDL.WINDOW_SHOWN | SDL.WINDOW_RESIZABLE);
	if window == nil {
		log.error("CreateWindow(): ", SDL.GetError());
		return false;
	}

	log.info("================================================================================");
	log.info("Querying available render drivers");

	if n := SDL.GetNumRenderDrivers(); n <= 0 {
		log.error("No render drivers available");
		return false;
	} else do for i in 0..<n {
		info: SDL.RendererInfo = ---;
		if err := SDL.GetRenderDriverInfo(i, &info); err == 0 {
			log.infof("[%d]: %v", i, info);
		} else {
			log.warn("GetRenderDriverInfo(): ", SDL.GetError());
		}
	}

	log.info("--------------------------------------------------------------------------------");

	SDL.SetHint("SDL_RENDER_SCALE_QUALITY", "nearest");

	renderer = SDL.CreateRenderer(window, -1, SDL.RENDERER_ACCELERATED /* |.Present_VSync */);
	if renderer == nil {
		log.error("CreateRenderer(): ", SDL.GetError());
		return false;
	}

	info: SDL.RendererInfo;
	if err := SDL.GetRendererInfo(renderer, &info); err == 0 do log.info("Selected renderer: ", info);
	else do log.warn("GetRendererInfo(): ", SDL.GetError());

	log.info("================================================================================");

	// Atlas image data contains only alpha values, need to expand this to RGBA8
	// (solution from https://github.com/floooh/sokol-samples/blob/master/sapp/sgl-microui-sapp.c)
	rgba8_pixels, _:= mem.make([]u32, ATLAS_WIDTH * ATLAS_HEIGHT);
	defer delete(rgba8_pixels);
	for y in 0..<ATLAS_HEIGHT {
		#no_bounds_check for x in 0..<ATLAS_WIDTH {
			index := y*ATLAS_WIDTH + x;
			rgba8_pixels[index] = 0x00FFFFFF | (u32(atlas_alpha[index]) << 24);
		}
	}

	atlas_texture = SDL.CreateTexture(renderer, u32(SDL.PixelFormatEnum(.RGBA32)), SDL.TextureAccess.TARGET, ATLAS_WIDTH, ATLAS_HEIGHT);
	assert(atlas_texture != nil);
	SDL.SetTextureBlendMode(atlas_texture, .BLEND);
	if err := SDL.UpdateTexture(atlas_texture, nil, &rgba8_pixels[0], 4*ATLAS_WIDTH); err != 0 {
		log.error("SDL.UpdateTexture(): ", SDL.GetError());
		return false;
	}

	return true;
}

r_set_clip_rect :: proc(using rect: mu.Rect) {
    //NOTE(ftommasi) there is a bug with the rect clipping. setting the clip to the size of the screen fixes the issue
    //rect := transmute(SDL.Rect) rect;
    rect := SDL.Rect{0,0,width,height};
	SDL.RenderSetClipRect(renderer, &rect);
}

r_draw_icon :: proc(id: mu.Icon, rect: mu.Rect, color: mu.Color) {
	src := atlas[int(id)];
	x := rect.x + (rect.w - src.w) / 2;
	y := rect.y + (rect.h - src.h) / 2;
	atlas_quad({x, y, src.w, src.h}, src, color);
}

r_draw_rect :: proc(rect: mu.Rect, using color: mu.Color) {
    atlas_quad(rect, atlas[ATLAS_WHITE], color);

	// NOTE(oskar): alternative implementation since SDL2 supports filled rects.
	//rect := transmute(SDL.Rect) rect;
	//SDL.SetRenderDrawColor(renderer, r, g, b, a);
	//SDL.RenderFillRect(renderer, &rect);
}

r_draw_text :: proc(text: string, pos: mu.Vec2, color: mu.Color) {
	dst := mu.Rect{ pos.x, pos.y, 0, 0 };
	for ch in text {
		if ch&0xc0 == 0x80 do continue;
		chr := min(int(ch), 127);
		src := atlas[ATLAS_FONT + chr];
		dst.w = src.w;
		dst.h = src.h;
		atlas_quad(dst, src, color);
		dst.x += dst.w;
	}
}

r_get_text_width :: proc(text: string) -> (res: i32) {
	for ch in text {
		if ch&0xc0 == 0x80 do continue;
		chr := min(int(ch), 127);
		res += atlas[ATLAS_FONT + chr].w;
	}
	return;
}

r_get_text_height :: proc() -> i32 {
	return 18;
}

r_clear :: proc(using color: mu.Color) {
	SDL.SetRenderDrawColor(renderer, r, g, b, a);
	SDL.RenderClear(renderer);
}


r_present :: proc() {
	SDL.RenderPresent(renderer);
}

@(private="file")
atlas_quad :: proc(dst, src: mu.Rect, using color: mu.Color) {
	src := transmute(SDL.Rect) src;
	dst := transmute(SDL.Rect) dst;
	SDL.SetTextureAlphaMod(atlas_texture, a);
	SDL.SetTextureColorMod(atlas_texture, r, g, b);
	SDL.RenderCopy(renderer, atlas_texture, &src, &dst);
}
