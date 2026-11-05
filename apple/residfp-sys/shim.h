/*
 * C API over libsidplayfp + libresidfp for Resonance's reSIDfp engine.
 *
 * A player renders audio on demand (`rsfp_render`), so the audio output
 * callback can drive it directly: no frame clock, no ring buffer. Each SID
 * is a sidemu of our own around reSIDfp's chip that also keeps a register
 * shadow, records register writes with cycle stamps and samples every
 * voice's waveform × envelope for the visualizers.
 *
 * GPL-2.0-or-later, like libsidplayfp.
 */

#ifndef RSFP_SHIM_H
#define RSFP_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rsfp_player rsfp_player;

enum { RSFP_CLOCK_PAL = 0, RSFP_CLOCK_NTSC = 1 };
enum { RSFP_MODEL_6581 = 0, RSFP_MODEL_8580 = 1 };
/* SidConfig's names: INTERPOLATE is reSIDfp's cheap zero-order resampler,
 * RESAMPLE its two-pass sinc resampler. */
enum { RSFP_SAMPLING_INTERPOLATE = 0, RSFP_SAMPLING_RESAMPLE = 1 };
/* Which chip emulation plays: reSIDfp (libresidfp) or libsidplayfp's SIDLite
 * (cRSID-based, far cheaper, output rate at most 48000). */
enum { RSFP_CHIP_RESIDFP = 0, RSFP_CHIP_SIDLITE = 1 };
/* How rsfp_skip clocks the chips: RENDER runs them as when playing and drops
 * the audio; DIGITAL clocks reSIDfp's oscillators and envelopes but not its
 * filter and resampler (SIDLite has no such mode and renders as RENDER);
 * NONE leaves the chips alone, so only the C64 runs. */
enum { RSFP_SKIP_RENDER = 0, RSFP_SKIP_DIGITAL = 1, RSFP_SKIP_NONE = 2 };

typedef struct {
    uint32_t sample_rate;   /* 8000–192000 */
    uint8_t  sampling;      /* RSFP_SAMPLING_* */
    uint8_t  default_clock; /* RSFP_CLOCK_*: when the tune doesn't say, or always when forced */
    uint8_t  force_clock;
    uint8_t  default_model; /* RSFP_MODEL_*: when the tune doesn't say, or always when forced */
    uint8_t  force_model;
    uint8_t  digi_boost;    /* 8580 digi boost */
    uint8_t  mono_2sid;     /* mix a 2SID tune to both channels instead of left/right */
    uint8_t  scope_cycles;  /* C64 cycles per visualizer scope sample; 0 keeps no scope */
    uint8_t  chip;          /* RSFP_CHIP_* */
    uint16_t power_on_delay; /* cycles before the tune's init, 0–0x1FFF; above that libsidplayfp picks one at random */
} rsfp_config;

/* The loaded tune, as its header describes it (for the selected song). */
typedef struct {
    uint16_t songs;
    uint16_t start_song;
    uint16_t current_song;
    uint8_t  chips;          /* SIDs the tune uses, 1–3 */
    uint8_t  clock;          /* 0 unknown, 1 PAL, 2 NTSC, 3 any */
    uint8_t  model[3];       /* per chip: 0 unknown, 1 6581, 2 8580, 3 any */
    uint8_t  compatibility;  /* 0 C64, 1 PSID, 2 real C64 only, 3 BASIC */
    uint8_t  speed_cia;      /* 1 when the song runs off CIA timer A, 0 for VBI */
    uint16_t chip_base[3];   /* $D400 and the extra chips' addresses */
    uint16_t load_addr;
    uint16_t init_addr;
    uint16_t play_addr;
    uint32_t data_len;
    uint8_t  info_strings;    /* title, author, released */
    uint8_t  comment_strings; /* MUS credit lines */
} rsfp_tune_info_t;

/* What the engine chose when a song started. */
typedef struct {
    uint16_t song;
    uint8_t  is_pal;
    uint8_t  chips;          /* SIDs installed */
    uint8_t  model[3];       /* RSFP_MODEL_* per installed chip */
    uint16_t cia1_timer_a;
    double   cpu_hz;
    uint16_t power_on_delay; /* the delay used; pass it back to start another instance at the same alignment */
} rsfp_play_info;

/* One chip, now. */
typedef struct {
    uint8_t regs[32];        /* the last value written to each register */
    uint8_t env[3];          /* envelope counters, 0–255 */
    uint8_t env_phase[3];    /* 0 attack, 1 decay/sustain, 2 release */
    uint8_t osc3;
    uint8_t env3;
} rsfp_chip_state_t;

typedef struct {
    uint32_t cycle;          /* C64 cycles since the song started */
    uint8_t  reg;
    uint8_t  val;
} rsfp_write;

rsfp_player *rsfp_new(void);
void rsfp_free(rsfp_player *p);
const char *rsfp_error(const rsfp_player *p);
/* "libsidplayfp x.y.z, libresidfp a.b.c" */
const char *rsfp_version(void);

/* ROM images, or NULL for libsidplayfp's built-in stubs: kernal and basic
 * 8192 bytes, chargen 4096. Copy them before loading a tune. */
void rsfp_set_roms(rsfp_player *p, const uint8_t *kernal, const uint8_t *basic,
                   const uint8_t *chargen);

/* Load a tune. Loading by path lets libsidplayfp find a MUS file's companion
 * .str. Returns 1 on success, 0 with rsfp_error set. */
int rsfp_load_bytes(rsfp_player *p, const uint8_t *data, uint32_t len);
int rsfp_load_path(rsfp_player *p, const char *path);

int rsfp_tune_info(const rsfp_player *p, rsfp_tune_info_t *out);
const char *rsfp_info_string(const rsfp_player *p, unsigned i);
const char *rsfp_comment_string(const rsfp_player *p, unsigned i);
const char *rsfp_format_string(const rsfp_player *p);
/* The HVSC MD5 (Songlengths.md5's key) into out[33]. */
int rsfp_md5(const rsfp_player *p, char out[33]);

/* Select `song` (1-based; 0 = the tune's start song), configure the C64 and
 * SIDs and run the tune's init. Rendering may begin afterwards. */
int rsfp_start(rsfp_player *p, unsigned song, const rsfp_config *cfg, rsfp_play_info *out);

/* Render `frames` interleaved stereo frames. Returns the frames rendered;
 * fewer means the emulation stopped (rsfp_error). Layout: one chip to both
 * channels; two chips left and right (or both to both with mono_2sid);
 * three chips left, right and the third at half level in the middle. */
uint32_t rsfp_render(rsfp_player *p, int16_t *stereo, uint32_t frames);

/* C64 cycles emulated since rsfp_start. */
uint64_t rsfp_cycles(const rsfp_player *p);
unsigned rsfp_chips(const rsfp_player *p);
int rsfp_chip_state(const rsfp_player *p, unsigned chip, rsfp_chip_state_t *out);
/* Take the scope samples recorded since the last call: `cap` per voice,
 * voice-major (voice v at out + v * cap). Returns the count per voice. */
uint32_t rsfp_take_scope(rsfp_player *p, unsigned chip, float *out, uint32_t cap);
/* Take the register writes since the last call, up to `cap` into out; `*total`
 * gets the number that happened (which may exceed cap). Returns the copied count. */
uint32_t rsfp_take_writes(rsfp_player *p, unsigned chip, rsfp_write *out, uint32_t cap,
                          uint32_t *total);

void rsfp_mute(rsfp_player *p, unsigned chip, unsigned voice, int mute);
/* Run the emulation `cycles` C64 cycles ahead without producing audio, the
 * chips clocked per RSFP_SKIP_*. Returns the cycles run: `cycles` or a few
 * more, or fewer when the emulation stopped (rsfp_error). */
uint64_t rsfp_skip(rsfp_player *p, uint64_t cycles, int mode);
void rsfp_filter(rsfp_player *p, unsigned chip, int enable);

#ifdef __cplusplus
}
#endif

#endif /* RSFP_SHIM_H */
