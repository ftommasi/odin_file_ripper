package file_ripper;

import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import "core:time"
import "core:reflect"

import mu "vendor:microui"
import SDL "vendor:SDL2"


bg: [3]u8 = { 90, 95, 100 };
frame_stats: Frame_Stats;

logbuf: strings.Builder;
logbuf_updated: bool;

Frame_Stats :: struct {
	samples:      [100] time.Duration,
	sample_index: int,
	sample_sum:   time.Duration,
	mspf, fps:    f64,
	last_update:  time.Time,
}

init_frame_stats :: proc(fs : ^Frame_Stats) {
	now := time.now();
	fs.last_update = now;
}

update_frame_stats :: proc(fs: ^Frame_Stats) {
	now := time.now();
	dt := time.diff(fs.last_update, now);
	fs.last_update = now;

	fs.sample_sum -= fs.samples[fs.sample_index];
	fs.samples[fs.sample_index] = dt;
	fs.sample_sum += dt;
	fs.sample_index = (fs.sample_index + 1) % len(fs.samples);

	fs.fps = len(fs.samples) / time.duration_seconds(fs.sample_sum);
	fs.mspf = 1000.0 * time.duration_seconds(fs.sample_sum) / len(fs.samples);
}

main :: proc() {
    context.logger = log.create_console_logger(ident = "demo");

	logbuf = strings.builder_make();

	/* init SDL and renderer */
	if err := SDL.Init(SDL.INIT_VIDEO); err != 0 {
		log.error("Init(): ", SDL.GetError());
		return;
	}
	if ok := r_init(); !ok {
		return;
	}

	/* init microui */
	ctx := new(mu.Context);
	defer free(ctx);
	mu.init(ctx);

	text_width  :: #force_inline proc(font: mu.Font, text: string) -> i32 { return r_get_text_width(text);}
	text_height :: #force_inline proc(font: mu.Font) -> i32 { return r_get_text_height(); }
	ctx.text_width = text_width;
	ctx.text_height = text_height;

	init_frame_stats(&frame_stats);
	main_loop: for {
		/* handle SDL events */
		e: SDL.Event = ---;
		for SDL.PollEvent(&e) != false {
			#partial switch e.type {
			case .QUIT: break main_loop;
			case .MOUSEMOTION: mu.input_mouse_move(ctx, e.motion.x, e.motion.y);
			case .MOUSEWHEEL: mu.input_scroll(ctx, 0, e.wheel.y * -30);
			case .TEXTINPUT: mu.input_text(ctx, string(cstring(&e.text.text[0])));

			case .MOUSEBUTTONDOWN, .MOUSEBUTTONUP:
				button_map :: #force_inline proc(button: u8) -> (res: mu.Mouse, ok: bool) {
					ok = true;
					switch button {
						case 1: res = .LEFT;
						case 2: res = .MIDDLE;
						case 3: res = .RIGHT;
						case: ok = false;
					}
					return;
				}
				if btn, ok := button_map(e.button.button); ok {
					switch {
					case e.type == .MOUSEBUTTONDOWN: mu.input_mouse_down(ctx, e.button.x, e.button.y, btn);
					case e.type == .MOUSEBUTTONUP:   mu.input_mouse_up(ctx, e.button.x, e.button.y, btn);
					}
				}

			case .KEYDOWN, .KEYUP:
				if e.type == .KEYUP && e.key.keysym.sym == SDL.Keycode.ESCAPE {
					quit_event: SDL.Event;
					quit_event.type = .QUIT;
					SDL.PushEvent(&quit_event);
				}

				key_map :: #force_inline proc(x: i32) -> (res: mu.Key, ok: bool) {
					ok = true;
					switch x {
						case cast(i32)SDL.Keycode.LSHIFT:    res = .SHIFT;
						case cast(i32)SDL.Keycode.RSHIFT:    res = .SHIFT;
						case cast(i32)SDL.Keycode.LCTRL:     res = .CTRL;
						case cast(i32)SDL.Keycode.RCTRL:     res = .CTRL;
						case cast(i32)SDL.Keycode.LALT:      res = .ALT;
						case cast(i32)SDL.Keycode.RALT:      res = .ALT;
						case cast(i32)SDL.Keycode.RETURN:    res = .RETURN;
						case cast(i32)SDL.Keycode.BACKSPACE: res = .BACKSPACE;
						case: ok = false;
					}
					return;
				}
				if key, ok := key_map(i32(e.key.keysym.sym)); ok {
					switch {
					case e.type == .KEYDOWN: mu.input_key_down(ctx, key);
					case e.type == .KEYUP:   mu.input_key_up(ctx, key);
					}
				}
			}
		}

		/* process frame */
		process_frame(ctx);

		r_clear(mu.Color{bg[0], bg[1], bg[2], 255});

		/* render */
		cmd: ^mu.Command;
		for mu.next_command(ctx, &cmd) {
			switch cmd_v in cmd.variant {
			case ^mu.Command_Text: r_draw_text(cmd_v.str, cmd_v.pos, cmd_v.color);
			case ^mu.Command_Rect: r_draw_rect(cmd_v.rect, cmd_v.color);
			case ^mu.Command_Icon: r_draw_icon(cmd_v.id, cmd_v.rect, cmd_v.color);
			case ^mu.Command_Clip: r_set_clip_rect(cmd_v.rect);
			case ^mu.Command_Jump: unreachable(); /* handled internally by next_command() */
			}
		}

		//r_test();

		r_present();

		update_frame_stats(&frame_stats);
	} // main_loop

	SDL.Quit();
}

test_window2:: proc(ctx: ^mu.Context) {
}
test_window :: proc(ctx: ^mu.Context) {
	@static opts: mu.Options;

	// NOTE(oskar): mu.button() returns Res_Bits and not bool (should fix this)
	button :: #force_inline proc(ctx: ^mu.Context, label: string) -> bool { return mu.button(ctx, label) == {.SUBMIT}; }

	/* do window */
	if mu.begin_window(ctx, "Demo Window", {40,40,300,450}, opts) {
		if mu.header(ctx, "Frame Stats") != {} {
			mu.layout_row(ctx,[]i32{-1});
			mu.text(ctx, fmt.tprintf("FPS %v MSPF %v", frame_stats.fps, frame_stats.mspf));
		}

		if mu.header(ctx, "Window Options") != {} {
			win := mu.get_current_container(ctx);
			mu.layout_row(ctx,  []i32{120, 120, 120});
			for opt in mu.Opt {
				state: bool = opt in opts;
				if mu.checkbox(ctx, fmt.tprintf("%v", opt), &state) != {} {
					if state {
						opts |= {opt};
					}
					else {
						opts &~= {opt};
					}
				}
			}
		}

		/* window info */
		if mu.header(ctx, "Window Info") != {} {
			win := mu.get_current_container(ctx);
			mu.layout_row(ctx, []i32{ 54, -1 });
			mu.label(ctx, "Position:");
			mu.label(ctx, fmt.tprintf("%d, %d", win.rect.x, win.rect.y));
			mu.label(ctx, "Size:");
			mu.label(ctx, fmt.tprintf("%d, %d", win.rect.w, win.rect.h));
		}

		/* labels + buttons */
		if mu.header(ctx, "Test Buttons", {.EXPANDED}) != {} {
			mu.layout_row(ctx,  []i32{ 86, -110, -1 });
			mu.label(ctx, "Test buttons 1:");
			if button(ctx, "Button 1") do write_log("Pressed button 1");
			if button(ctx, "Button 2") do write_log("Pressed button 2");
			mu.label(ctx, "Test buttons 2:");
			if button(ctx, "Button 3") do write_log("Pressed button 3");
			if button(ctx, "Button 4") do write_log("Pressed button 4");
		}

		/* tree */
		if mu.header(ctx, "Tree and Text", {.EXPANDED}) != {} {
			mu.layout_row(ctx, []i32{ 140, -1 });
			mu.layout_begin_column(ctx);
			if mu.begin_treenode(ctx, "Test 1") != {} {
				if mu.begin_treenode(ctx, "Test 1a") != {} {
					mu.label(ctx, "Hello");
					mu.label(ctx, "world");
					mu.end_treenode(ctx);
				}
				if mu.begin_treenode(ctx, "Test 1b") != {} {
					if button(ctx, "Button 1") do write_log("Pressed button 1");
					if button(ctx, "Button 2") do write_log("Pressed button 2");
					mu.end_treenode(ctx);
				}
				mu.end_treenode(ctx);
			}
			if mu.begin_treenode(ctx, "Test 2") != {} {
				mu.layout_row(ctx,  []i32{ 54, 54 });
				if button(ctx, "Button 3") do write_log("Pressed button 3");
				if button(ctx, "Button 4") do write_log("Pressed button 4");
				if button(ctx, "Button 5") do write_log("Pressed button 5");
				if button(ctx, "Button 6") do write_log("Pressed button 6");
				mu.end_treenode(ctx);
			}
			if mu.begin_treenode(ctx, "Test 3") != {} {
				@static checks := [3]bool{ true, false, true };
				mu.checkbox(ctx, "Checkbox 1", &checks[0]);
				mu.checkbox(ctx, "Checkbox 2", &checks[1]);
				mu.checkbox(ctx, "Checkbox 3", &checks[2]);
				mu.end_treenode(ctx);
			}
			mu.layout_end_column(ctx);

			mu.layout_begin_column(ctx);
			mu.layout_row(ctx,  []i32{ -1 });
			mu.text(ctx, "Lorem ipsum\n dolor sit amet, consectetur adipiscing elit. Maecenas lacinia, sem eu lacinia molestie, mi risus faucibus ipsum, eu varius magna felis a nulla.");
			mu.layout_end_column(ctx);
		}

		/* background color sliders */
		if mu.header(ctx, "Background Color", {.EXPANDED}) != {} {
			mu.layout_row(ctx, []i32{ -78, -1 }, 74);
			/* sliders */
			mu.layout_begin_column(ctx);
			mu.layout_row(ctx,  []i32{ 46, -1 });
			mu.label(ctx, "Red:");   uint8_slider(ctx, &bg[0], 0, 255);
			mu.label(ctx, "Green:"); uint8_slider(ctx, &bg[1], 0, 255);
			mu.label(ctx, "Blue:");  uint8_slider(ctx, &bg[2], 0, 255);
			mu.layout_end_column(ctx);
			/* color preview */
			r := mu.layout_next(ctx);
			mu.draw_rect(ctx, r, mu.Color{bg[0], bg[1], bg[2], 255});
			mu.draw_control_text(ctx, fmt.tprintf("#%02X%02X%02X", bg[0], bg[1], bg[2]), r, .TEXT, {.ALIGN_CENTER});
		}

		mu.end_window(ctx);
	}
}

process_frame :: proc(ctx: ^mu.Context) {
	mu.begin(ctx);
	test_window(ctx);
	log_window(ctx);
	style_window(ctx);
	mu.end(ctx);
}

@private write_log :: proc(text: string) {
	strings.write_string(&logbuf, text);
	strings.write_string(&logbuf, "\n");
	logbuf_updated = true;
}

@private uint8_slider :: proc(ctx: ^mu.Context, value: ^u8, low, high: int) -> (res: mu.Result_Set) {
	using mu;
	@static tmp: Real;
	push_id(ctx, uintptr(value));
	tmp = Real(value^);
	res = slider(ctx, &tmp, Real(low), Real(high), 0, "%.0f", {.ALIGN_CENTER});
	value^ = u8(tmp);
	pop_id(ctx);
	return;
}

@private log_window :: proc(ctx: ^mu.Context) {
	using mu;

	if begin_window(ctx, "Log Window", Rect{450,40,300,200}) {
		/* output text panel */
		layout_row(ctx,  []i32{ -1 }, -28);
		begin_panel(ctx, "Log Output");
		panel := get_current_container(ctx);
		layout_row(ctx,  []i32{ -1 }, -1);
		text(ctx, strings.to_string(logbuf));
		end_panel(ctx);
		if logbuf_updated {
			panel.scroll.y = panel.content_size.y;
			logbuf_updated = false;
		}

		/* input textbox + submit button */
		@static textlen: int;
		@static textbuf: [128] byte;
		submitted := false;
		layout_row(ctx,  []i32{ -70, -1 }, 0);
		if .SUBMIT in textbox(ctx, textbuf[:], &textlen) {
			set_focus(ctx, ctx.last_id);
			submitted = true;
		}
		if button(ctx, "Submit") != {} do submitted = true;
		if submitted {
			textstr := string(textbuf[:textlen]);
			write_log(textstr);
			textlen = 0;
		}

		end_window(ctx);
	}
}

@private style_window :: proc(ctx: ^mu.Context) {
	using mu;

	if begin_window(ctx, "Style Editor", Rect{550,250,300,240}) {
		sw := i32(Real(get_current_container(ctx).body.w) * 0.14);
		layout_row(ctx,  { 80, sw, sw, sw, sw, -1 });
		for c in Color_Type {
			label(ctx, fmt.tprintf("%s:", reflect.enum_string(c)));
			uint8_slider(ctx, &ctx.style.colors[c].r, 0, 255);
			uint8_slider(ctx, &ctx.style.colors[c].g, 0, 255);
			uint8_slider(ctx, &ctx.style.colors[c].b, 0, 255);
			uint8_slider(ctx, &ctx.style.colors[c].a, 0, 255);
			draw_rect(ctx, layout_next(ctx), ctx.style.colors[c]);
		}
		end_window(ctx);
	}
}
