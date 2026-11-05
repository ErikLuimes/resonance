/*
 * C API over libsidplayfp + libresidfp (and libsidplayfp's SIDLite) for
 * Resonance's pull-driven engines. See shim.h. GPL-2.0-or-later, like libsidplayfp.
 *
 * Built with the renaming defines from build.rs, so `SidTune` below is
 * really `RsfpSidTune`, `libsidplayfp` is `rsfp_libsidplayfp`, and so on.
 */

#include "shim.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <vector>

#include "sidplayfp/sidplayfp.h"
#include "sidplayfp/SidTune.h"
#include "sidplayfp/SidTuneInfo.h"
#include "sidplayfp/SidConfig.h"
#include "sidplayfp/SidInfo.h"
#include "sidplayfp/sidbuilder.h"
#include "residfp/residfp.h" // for LIBRESIDFP_VERSION_*
#include "sidemu.h"
#include "EventScheduler.h"

// The chips themselves (not libsidplayfp's emu wrappers): the visualizers
// read each voice's envelope and waveform through the accessors Resonance
// added to both.
#include "SID.h"                                  // libresidfp
#include "builders/sidlite-builder/sidlite/SID.h" // SIDLite

using namespace libsidplayfp;

namespace {

/// Player::play clocks at most this many cycles per call (about 20 ms).
constexpr unsigned MAX_PLAY_CYCLES = 20000;
/// Per voice; the player drains these every audio buffer (about 10 ms).
constexpr size_t SCOPE_CAPACITY = 8192;
constexpr size_t WRITE_CAPACITY = 4096;

/// c64::getCpuFreq for PAL_B and NTSC_M.
constexpr double PAL_CPU_HZ = 985248.4;
constexpr double NTSC_CPU_HZ = 1022727.14;

enum class SamplingResult { Ok, BadMethod, BadFrequency };

/**
 * A SID for the player that also keeps what the visualizers want: the
 * register shadow, the writes with cycle stamps, each voice's waveform ×
 * envelope every `scopeCycles` cycles and an inferred envelope phase.
 * Subclasses supply the chip.
 */
class VizEmu : public sidemu
{
    unsigned scopeCycles;
    unsigned scopePhase = 0;
    double samplesPerCycle = 48000.0 / PAL_CPU_HZ;
    int bufferSize = 0;
    uint8_t shadow[32] = {};
    uint8_t prevEnv[3] = {};
    /// 0 attack, 1 decay/sustain, 2 release: inferred from the gate and
    /// the counter's direction (the generators' states are private).
    uint8_t phase[3] = {2, 2, 2};
    std::vector<float> scope[3];
    std::vector<rsfp_write> writes;
    uint32_t writeCount = 0;
    event_clock_t origin = 0;
    /// RSFP_SKIP_*: how the chip is clocked while the player skips ahead.
    uint8_t skip = RSFP_SKIP_RENDER;

protected:
    uint8_t chipModel = RSFP_MODEL_6581;

    // ── the chip ──
    virtual int chipClock(unsigned cycles, short *buf) = 0;
    /// Clock the chip without producing audio (RSFP_SKIP_DIGITAL).
    virtual void chipSkip(unsigned cycles) = 0;
    virtual void chipReset() = 0;
    virtual void chipWrite(uint8_t addr, uint8_t data) = 0;
    virtual uint8_t chipRead(uint8_t addr) = 0;
    virtual SamplingResult chipSampling(float systemclock, float freq,
                                        SidConfig::sampling_method_t method) = 0;
    virtual bool chipModelSet(SidConfig::sid_model_t model, bool digiboost) = 0;
    virtual uint8_t voiceEnv(int v) const = 0;
    /// The voice's waveform output, 8-bit.
    virtual uint8_t voiceWave(int v) const = 0;
    virtual uint8_t osc3() const = 0;
    virtual uint8_t env3() const = 0;

    event_clock_t now() const
    {
        return eventScheduler ? eventScheduler->getTime(EVENT_CLOCK_PHI1) : 0;
    }

private:
    void run(unsigned step)
    {
        if (skip != RSFP_SKIP_RENDER)
        {
            if (skip == RSFP_SKIP_DIGITAL)
                chipSkip(step);
            return;
        }
        const int room = bufferSize - m_bufferpos;
        const int worst = static_cast<int>(step * samplesPerCycle) + 2;
        if (room >= worst)
        {
            m_bufferpos += chipClock(step, m_buffer + m_bufferpos);
        }
        else
        {
            // Never within Player::play's cap; keeps the buffer safe.
            short spill[64];
            chipClock(std::min(step, 16u), spill);
        }
    }

    void sample()
    {
        for (int v = 0; v < 3; ++v)
        {
            const uint8_t env = voiceEnv(v);
            const uint8_t control = shadow[v * 7 + 4];
            float s = 0.f;
            if (control >> 4)
                s = (voiceWave(v) / 127.5f - 1.f) * (env / 255.f);
            if (scope[v].size() < scope[v].capacity())
                scope[v].push_back(s);
            if (!(control & 1))
                phase[v] = 2;
            else if (env > prevEnv[v])
                phase[v] = 0;
            else if (env < prevEnv[v])
                phase[v] = 1;
            else if (phase[v] == 2)
                phase[v] = 0;
            else if (phase[v] == 0 && env == 0xff)
                phase[v] = 1;
            prevEnv[v] = env;
        }
    }

public:
    VizEmu(sidbuilder *builder, unsigned scopeCycles) :
        sidemu(builder),
        scopeCycles(scopeCycles)
    {
        for (auto &v : scope)
            v.reserve(SCOPE_CAPACITY);
        writes.reserve(WRITE_CAPACITY);
    }

    ~VizEmu() override { delete[] m_buffer; }

    // ── sidemu ──

    uint8_t read(uint_least8_t addr) override
    {
        clock();
        return chipRead(addr);
    }

    void write(uint_least8_t addr, uint8_t data) override
    {
        clock();
        chipWrite(addr, data);
        addr &= 0x1f;
        if (addr == 0x04 || addr == 0x0b || addr == 0x12)
        {
            const unsigned v = (addr - 4) / 7;
            const bool was = shadow[addr] & 1, gate = data & 1;
            if (was != gate)
                phase[v] = gate ? 0 : 2;
        }
        shadow[addr] = data;
        ++writeCount;
        if (writes.size() < writes.capacity())
            writes.push_back({static_cast<uint32_t>(now() - origin), addr, data});
    }

    void clock() override
    {
        if (!eventScheduler)
            return;
        const event_clock_t t = now();
        unsigned cycles = static_cast<unsigned>(t - m_accessClk);
        m_accessClk = t;
        const unsigned scoped = skip == RSFP_SKIP_RENDER ? scopeCycles : 0;
        while (cycles)
        {
            unsigned step = std::min(cycles, 1024u);
            if (scoped)
                step = std::min(step, scoped - scopePhase);
            run(step);
            cycles -= step;
            if (scoped)
            {
                scopePhase += step;
                if (scopePhase == scopeCycles)
                {
                    scopePhase = 0;
                    sample();
                }
            }
        }
    }

    void reset(uint8_t volume) override
    {
        m_accessClk = 0;
        chipReset();
        chipWrite(0x18, volume);
        std::memset(shadow, 0, sizeof shadow);
        shadow[0x18] = volume;
        scopePhase = 0;
        for (auto &v : scope)
            v.clear();
        writes.clear();
        writeCount = 0;
        std::memset(prevEnv, 0, sizeof prevEnv);
        phase[0] = phase[1] = phase[2] = 2;
    }

    void sampling(float systemclock, float freq, SidConfig::sampling_method_t method) override
    {
        switch (chipSampling(systemclock, freq, method))
        {
        case SamplingResult::BadMethod:
            m_status = false;
            m_error = ERR_INVALID_SAMPLING;
            return;
        case SamplingResult::BadFrequency:
            m_status = false;
            m_error = ERR_UNSUPPORTED_FREQ;
            return;
        case SamplingResult::Ok:
            break;
        }
        samplesPerCycle = freq / systemclock;
        delete[] m_buffer;
        bufferSize = static_cast<int>(std::ceil(MAX_PLAY_CYCLES * samplesPerCycle)) + 64;
        m_buffer = new short[bufferSize]();
        m_bufferpos = 0;
        m_status = true;
    }

    void model(SidConfig::sid_model_t model, bool digiboost) override
    {
        if (!chipModelSet(model, digiboost))
        {
            m_status = false;
            m_error = ERR_INVALID_CHIP;
            return;
        }
        chipModel = model == SidConfig::MOS8580 ? RSFP_MODEL_8580 : RSFP_MODEL_6581;
        m_status = true;
    }

    // ── for the shim ──

    int bufferCapacity() const { return bufferSize; }
    uint8_t chipModelId() const { return chipModel; }
    void setOrigin() { origin = now(); }
    void setSkip(uint8_t mode) { skip = mode; }
    /// Forget the scope samples and writes logged so far (after a skip,
    /// which the visualizers never saw).
    void clearViz()
    {
        scopePhase = 0;
        for (auto &v : scope)
            v.clear();
        writes.clear();
        writeCount = 0;
    }
    uint64_t cyclesSinceOrigin() const { return static_cast<uint64_t>(m_accessClk - origin); }

    void state(rsfp_chip_state_t *out) const
    {
        std::memcpy(out->regs, shadow, sizeof shadow);
        for (int v = 0; v < 3; ++v)
        {
            out->env[v] = voiceEnv(v);
            out->env_phase[v] = phase[v];
        }
        out->osc3 = osc3();
        out->env3 = env3();
    }

    uint32_t takeScope(float *out, uint32_t cap)
    {
        size_t n = cap;
        for (auto &v : scope)
            n = std::min(n, v.size());
        for (int v = 0; v < 3; ++v)
        {
            if (out && n)
                std::memcpy(out + static_cast<size_t>(v) * cap, scope[v].data(), n * sizeof(float));
            scope[v].clear();
        }
        return static_cast<uint32_t>(n);
    }

    uint32_t takeWrites(rsfp_write *out, uint32_t cap, uint32_t *total)
    {
        const size_t n = std::min<size_t>(cap, writes.size());
        if (out && n)
            std::memcpy(out, writes.data(), n * sizeof(rsfp_write));
        if (total)
            *total = writeCount;
        writes.clear();
        writeCount = 0;
        return static_cast<uint32_t>(n);
    }
};

/// libresidfp's reSIDfp, as libsidplayfp's reSIDfpEmu drives it.
class ResidFpEmu final : public VizEmu
{
    reSIDfp::SID sid;

protected:
    int chipClock(unsigned cycles, short *buf) override { return sid.clock(cycles, buf); }
    void chipSkip(unsigned cycles) override { sid.clockDigital(cycles); }
    void chipReset() override { sid.reset(); }
    void chipWrite(uint8_t addr, uint8_t data) override { sid.write(addr, data); }
    uint8_t chipRead(uint8_t addr) override { return sid.read(addr); }

    SamplingResult chipSampling(float systemclock, float freq,
                                SidConfig::sampling_method_t method) override
    {
        reSIDfp::SamplingMethod m;
        switch (method)
        {
        case SidConfig::INTERPOLATE:
            m = reSIDfp::DECIMATE;
            break;
        case SidConfig::RESAMPLE_INTERPOLATE:
            m = reSIDfp::RESAMPLE;
            break;
        default:
            return SamplingResult::BadMethod;
        }
        try
        {
            sid.setSamplingParameters(systemclock, m, freq);
        }
        catch (reSIDfp::SIDError const &)
        {
            return SamplingResult::BadFrequency;
        }
        return SamplingResult::Ok;
    }

    bool chipModelSet(SidConfig::sid_model_t model, bool digiboost) override
    {
        reSIDfp::ChipModel cm;
        switch (model)
        {
        case SidConfig::MOS6581:
            cm = reSIDfp::MOS6581;
            sid.input(0);
            break;
        case SidConfig::MOS8580:
            cm = reSIDfp::CSG8580;
            sid.input(digiboost ? -32768 : 0);
            break;
        default:
            return false;
        }
        try
        {
            sid.setChipModel(cm);
        }
        catch (reSIDfp::SIDError const &)
        {
            return false;
        }
        return true;
    }

    uint8_t voiceEnv(int v) const override { return sid.voiceRef(v).envelope()->output(); }
    uint8_t voiceWave(int v) const override { return sid.voiceRef(v).wave()->readOSC(); }
    uint8_t osc3() const override { return sid.voiceRef(2).wave()->readOSC(); }
    uint8_t env3() const override { return sid.voiceRef(2).envelope()->readENV(); }

public:
    ResidFpEmu(sidbuilder *builder, unsigned scopeCycles) : VizEmu(builder, scopeCycles)
    {
        reset(0);
    }
};

/// libsidplayfp's SIDLite (cRSID-based), as its SIDLiteEmu drives it. Its
/// voices run at the output rate, so the scope holds each value until the
/// next output sample.
class SidLiteEmu final : public VizEmu
{
    SIDLite::SID sid;

protected:
    int chipClock(unsigned cycles, short *buf) override { return sid.clock(cycles, buf); }
    /// SIDLite has no silent clock; at most 1024 cycles come at a time, under
    /// 51 samples at its 48 kHz ceiling.
    void chipSkip(unsigned cycles) override
    {
        short spill[256];
        sid.clock(std::min(cycles, 1024u), spill);
    }
    void chipReset() override { sid.reset(); }
    void chipWrite(uint8_t addr, uint8_t data) override { sid.write(addr, data); }
    uint8_t chipRead(uint8_t addr) override { return static_cast<uint8_t>(sid.read(addr)); }

    SamplingResult chipSampling(float systemclock, float freq,
                                SidConfig::sampling_method_t /*method*/) override
    {
        if (freq > 48000.f)
            return SamplingResult::BadFrequency;
        return sid.setSamplingParameters(static_cast<unsigned>(systemclock),
                                         static_cast<unsigned short>(freq))
                   ? SamplingResult::Ok
                   : SamplingResult::BadFrequency;
    }

    bool chipModelSet(SidConfig::sid_model_t model, bool /*digiboost*/) override
    {
        switch (model)
        {
        case SidConfig::MOS6581:
            sid.setChipModel(SIDLite::SID::model_t::MOS6581);
            return true;
        case SidConfig::MOS8580:
            sid.setChipModel(SIDLite::SID::model_t::MOS8580);
            return true;
        default:
            return false;
        }
    }

    uint8_t voiceEnv(int v) const override { return sid.envelopes().counter(v); }
    uint8_t voiceWave(int v) const override
    {
        return static_cast<uint8_t>(sid.waveforms().voiceOutput(v) >> 8);
    }
    uint8_t osc3() const override { return sid.waveforms().getOsc3(); }
    uint8_t env3() const override { return sid.waveforms().getEnv3(); }

public:
    SidLiteEmu(sidbuilder *builder, unsigned scopeCycles) : VizEmu(builder, scopeCycles)
    {
        reset(0);
    }
};

class VizBuilder final : public sidbuilder
{
    unsigned scopeCycles = 0;
    uint8_t chip = RSFP_CHIP_RESIDFP;

public:
    VizBuilder() : sidbuilder("Resonance") {}
    ~VizBuilder() override { remove(); }

    void configure(uint8_t chipKind, unsigned cycles)
    {
        chip = chipKind;
        scopeCycles = cycles;
    }

    /// The emu whose sample buffer this is (sidplayfp::buffers gives them
    /// in chip order; sidobjs doesn't).
    VizEmu *find(const short *buffer) const
    {
        for (sidemu *e : sidobjs)
            if (e->buffer() == buffer)
                return static_cast<VizEmu *>(e);
        return nullptr;
    }

protected:
    sidemu *create() override
    {
        try
        {
            if (chip == RSFP_CHIP_SIDLITE)
                return new SidLiteEmu(this, scopeCycles);
            return new ResidFpEmu(this, scopeCycles);
        }
        catch (std::bad_alloc const &)
        {
            m_errorBuffer = "Resonance: out of memory";
            return nullptr;
        }
    }

    const char *getCredits() const override { return "Resonance (libresidfp, SIDLite)"; }
};

inline int16_t sat(int v)
{
    return static_cast<int16_t>(std::min(std::max(v, -32768), 32767));
}

} // namespace

// Destroyed in reverse order: the engine (which points at the tune and the
// builder's chips) first, then the tune, then the builder and its chips.
struct rsfp_player
{
    VizBuilder builder;
    std::unique_ptr<SidTune> tune;
    sidplayfp engine;
    std::string error;
    std::vector<VizEmu *> chips;
    std::vector<short *> bufs;
    /// Samples play() produced beyond what the last render needed.
    std::vector<int16_t> pending[3];
    size_t pendingHead = 0;
    size_t pendingCount = 0;
    double cpuHz = PAL_CPU_HZ;
    uint32_t rate = 48000;
    bool mono2sid = false;
    bool isPal = true;
    bool ready = false;
};

namespace {

void mixInto(rsfp_player *p, int16_t *out, size_t n)
{
    const size_t h = p->pendingHead;
    const int16_t *a = p->pending[0].data() + h;
    switch (p->chips.size())
    {
    case 1:
        for (size_t i = 0; i < n; ++i)
            out[2 * i] = out[2 * i + 1] = a[i];
        break;
    case 2:
    {
        const int16_t *b = p->pending[1].data() + h;
        if (p->mono2sid)
        {
            for (size_t i = 0; i < n; ++i)
            {
                const int16_t m = sat(static_cast<int>((a[i] + b[i]) * 0.70710678f));
                out[2 * i] = out[2 * i + 1] = m;
            }
        }
        else
        {
            for (size_t i = 0; i < n; ++i)
            {
                out[2 * i] = a[i];
                out[2 * i + 1] = b[i];
            }
        }
        break;
    }
    default:
    {
        // SID3 in the middle at half level, as Phosphor's engines mix it.
        const int16_t *b = p->pending[1].data() + h;
        const int16_t *c = p->pending[2].data() + h;
        for (size_t i = 0; i < n; ++i)
        {
            const int centre = c[i] / 2;
            out[2 * i] = sat(a[i] + centre);
            out[2 * i + 1] = sat(b[i] + centre);
        }
        break;
    }
    }
}

void unload(rsfp_player *p)
{
    p->ready = false;
    p->chips.clear();
    p->pendingCount = 0;
    p->pendingHead = 0;
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
//  C API
// ─────────────────────────────────────────────────────────────────────────────

rsfp_player *rsfp_new(void)
{
    try
    {
        return new rsfp_player();
    }
    catch (...)
    {
        return nullptr;
    }
}

void rsfp_free(rsfp_player *p)
{
    delete p;
}

const char *rsfp_error(const rsfp_player *p)
{
    return p ? p->error.c_str() : "";
}

#define RSFP_STR2(x) #x
#define RSFP_STR(x) RSFP_STR2(x)

const char *rsfp_version(void)
{
    return "libsidplayfp " RSFP_STR(LIBSIDPLAYFP_VERSION_MAJ) "." RSFP_STR(LIBSIDPLAYFP_VERSION_MIN) "." RSFP_STR(LIBSIDPLAYFP_VERSION_LEV)
           ", libresidfp " RSFP_STR(LIBRESIDFP_VERSION_MAJ) "." RSFP_STR(LIBRESIDFP_VERSION_MIN) "." RSFP_STR(LIBRESIDFP_VERSION_LEV);
}

void rsfp_set_roms(rsfp_player *p, const uint8_t *kernal, const uint8_t *basic, const uint8_t *chargen)
{
    if (p)
        p->engine.setRoms(kernal, basic, chargen);
}

int rsfp_load_bytes(rsfp_player *p, const uint8_t *data, uint32_t len)
{
    if (!p || !data)
        return 0;
    unload(p);
    p->tune.reset(new (std::nothrow) SidTune(data, len));
    if (!p->tune)
    {
        p->error = "out of memory";
        return 0;
    }
    if (!p->tune->getStatus())
    {
        p->error = p->tune->statusString();
        p->tune.reset();
        return 0;
    }
    return 1;
}

int rsfp_load_path(rsfp_player *p, const char *path)
{
    if (!p || !path)
        return 0;
    unload(p);
    p->tune.reset(new (std::nothrow) SidTune(path));
    if (!p->tune)
    {
        p->error = "out of memory";
        return 0;
    }
    if (!p->tune->getStatus())
    {
        p->error = p->tune->statusString();
        p->tune.reset();
        return 0;
    }
    return 1;
}

int rsfp_tune_info(const rsfp_player *p, rsfp_tune_info_t *out)
{
    if (!p || !p->tune || !out)
        return 0;
    const SidTuneInfo *info = p->tune->getInfo();
    if (!info)
        return 0;
    std::memset(out, 0, sizeof *out);
    out->songs = static_cast<uint16_t>(info->songs());
    out->start_song = static_cast<uint16_t>(info->startSong());
    out->current_song = static_cast<uint16_t>(info->currentSong());
    const int chips = std::min(std::max(info->sidChips(), 1), 3);
    out->chips = static_cast<uint8_t>(chips);
    out->clock = static_cast<uint8_t>(info->clockSpeed());
    for (int i = 0; i < 3; ++i)
    {
        out->model[i] = i < chips ? static_cast<uint8_t>(info->sidModel(i)) : 0;
        out->chip_base[i] = i < chips ? info->sidChipBase(i) : 0;
    }
    out->compatibility = static_cast<uint8_t>(info->compatibility());
    out->speed_cia = info->songSpeed() == SidTuneInfo::SPEED_CIA_1A ? 1 : 0;
    out->load_addr = info->loadAddr();
    out->init_addr = info->initAddr();
    out->play_addr = info->playAddr();
    out->data_len = info->c64dataLen();
    out->info_strings = static_cast<uint8_t>(std::min(info->numberOfInfoStrings(), 255u));
    out->comment_strings = static_cast<uint8_t>(std::min(info->numberOfCommentStrings(), 255u));
    return 1;
}

const char *rsfp_info_string(const rsfp_player *p, unsigned i)
{
    if (!p || !p->tune)
        return "";
    const SidTuneInfo *info = p->tune->getInfo();
    if (!info || i >= info->numberOfInfoStrings())
        return "";
    const char *s = info->infoString(i);
    return s ? s : "";
}

const char *rsfp_comment_string(const rsfp_player *p, unsigned i)
{
    if (!p || !p->tune)
        return "";
    const SidTuneInfo *info = p->tune->getInfo();
    if (!info || i >= info->numberOfCommentStrings())
        return "";
    const char *s = info->commentString(i);
    return s ? s : "";
}

const char *rsfp_format_string(const rsfp_player *p)
{
    if (!p || !p->tune)
        return "";
    const SidTuneInfo *info = p->tune->getInfo();
    const char *s = info ? info->formatString() : nullptr;
    return s ? s : "";
}

int rsfp_md5(const rsfp_player *p, char out[33])
{
    if (!p || !p->tune || !out)
        return 0;
    // createMD5New isn't const upstream, but computes from the tune's data.
    const char *md5 = const_cast<SidTune *>(p->tune.get())->createMD5New(nullptr);
    if (!md5)
        return 0;
    std::strncpy(out, md5, 32);
    out[32] = 0;
    return 1;
}

int rsfp_start(rsfp_player *p, unsigned song, const rsfp_config *cfg, rsfp_play_info *out)
{
    if (!p || !cfg)
        return 0;
    if (!p->tune)
    {
        p->error = "no tune loaded";
        return 0;
    }
    if (cfg->sample_rate < 8000 || cfg->sample_rate > 192000)
    {
        p->error = "unsupported sample rate";
        return 0;
    }
    if (cfg->chip == RSFP_CHIP_SIDLITE && cfg->sample_rate > 48000)
    {
        p->error = "SIDLite plays at output rates up to 48000 Hz";
        return 0;
    }
    unload(p);
    p->builder.configure(cfg->chip, cfg->scope_cycles);
    const unsigned selected = p->tune->selectSong(song);

    SidConfig c;
    c.frequency = cfg->sample_rate;
    c.samplingMethod = cfg->sampling == RSFP_SAMPLING_RESAMPLE ? SidConfig::RESAMPLE_INTERPOLATE
                                                               : SidConfig::INTERPOLATE;
    c.defaultC64Model = cfg->default_clock == RSFP_CLOCK_NTSC ? SidConfig::NTSC : SidConfig::PAL;
    c.forceC64Model = cfg->force_clock != 0;
    c.defaultSidModel = cfg->default_model == RSFP_MODEL_8580 ? SidConfig::MOS8580 : SidConfig::MOS6581;
    c.forceSidModel = cfg->force_model != 0;
    c.digiBoost = cfg->digi_boost != 0;
    c.powerOnDelay = cfg->power_on_delay;
    c.sidEmulation = &p->builder;
    if (!p->engine.config(c))
    {
        p->error = p->engine.error();
        return 0;
    }
    if (!p->engine.load(p->tune.get()))
    {
        p->error = p->engine.error();
        return 0;
    }

    const unsigned n = p->engine.installedSIDs();
    if (n == 0 || n > 3)
    {
        p->error = "unexpected number of SIDs";
        return 0;
    }
    p->bufs.assign(n, nullptr);
    p->engine.buffers(p->bufs.data());
    for (unsigned i = 0; i < n; ++i)
    {
        VizEmu *e = p->builder.find(p->bufs[i]);
        if (!e)
        {
            p->error = "SID emulation not found";
            p->chips.clear();
            return 0;
        }
        e->setOrigin();
        p->chips.push_back(e);
    }

    // The C64 model the engine chose (Player::c64model).
    const SidTuneInfo *info = p->tune->getInfo();
    const SidTuneInfo::clock_t clock = info->clockSpeed();
    const bool pal = (c.forceC64Model || clock == SidTuneInfo::CLOCK_UNKNOWN || clock == SidTuneInfo::CLOCK_ANY)
                         ? c.defaultC64Model == SidConfig::PAL
                         : clock == SidTuneInfo::CLOCK_PAL;
    p->isPal = pal;
    p->cpuHz = pal ? PAL_CPU_HZ : NTSC_CPU_HZ;
    p->rate = cfg->sample_rate;
    p->mono2sid = cfg->mono_2sid != 0 && n == 2;
    for (auto &buf : p->pending)
    {
        buf.clear();
        buf.reserve(static_cast<size_t>(p->chips[0]->bufferCapacity()));
    }

    if (out)
    {
        std::memset(out, 0, sizeof *out);
        out->song = static_cast<uint16_t>(selected);
        out->is_pal = pal ? 1 : 0;
        out->chips = static_cast<uint8_t>(n);
        for (unsigned i = 0; i < n; ++i)
            out->model[i] = p->chips[i]->chipModelId();
        out->cia1_timer_a = p->engine.getCia1TimerA();
        out->cpu_hz = p->cpuHz;
        // libsidplayfp adds a fixed 8000 cycles to the delay it was given (or
        // chose) and reports the sum; report what rsfp_config takes.
        out->power_on_delay = static_cast<uint16_t>(p->engine.info().powerOnDelay() - 8000);
    }
    p->error.clear();
    p->ready = true;
    return 1;
}

uint32_t rsfp_render(rsfp_player *p, int16_t *out, uint32_t frames)
{
    if (!out)
        return 0;
    if (!p || !p->ready)
    {
        std::memset(out, 0, static_cast<size_t>(frames) * 2 * sizeof(int16_t));
        return 0;
    }
    uint32_t done = 0;
    int stalls = 0;
    while (done < frames)
    {
        if (p->pendingCount == 0)
        {
            const uint32_t need = frames - done;
            unsigned cycles = static_cast<unsigned>(std::ceil(need * p->cpuHz / p->rate)) + 1;
            cycles = std::min(cycles, MAX_PLAY_CYCLES);
            const int n = p->engine.play(cycles);
            if (n < 0 || (n == 0 && ++stalls > 64))
            {
                p->error = n < 0 ? p->engine.error() : "the emulation produced no audio";
                p->ready = false;
                std::memset(out + 2 * done, 0, static_cast<size_t>(frames - done) * 2 * sizeof(int16_t));
                return done;
            }
            if (n == 0)
                continue;
            stalls = 0;
            for (size_t c = 0; c < p->chips.size(); ++c)
                p->pending[c].assign(p->bufs[c], p->bufs[c] + n);
            p->pendingHead = 0;
            p->pendingCount = static_cast<size_t>(n);
        }
        const size_t take = std::min<size_t>(p->pendingCount, frames - done);
        mixInto(p, out + 2 * done, take);
        p->pendingHead += take;
        p->pendingCount -= take;
        done += static_cast<uint32_t>(take);
    }
    return done;
}

uint64_t rsfp_cycles(const rsfp_player *p)
{
    return (p && !p->chips.empty()) ? p->chips[0]->cyclesSinceOrigin() : 0;
}

unsigned rsfp_chips(const rsfp_player *p)
{
    return p ? static_cast<unsigned>(p->chips.size()) : 0;
}

int rsfp_chip_state(const rsfp_player *p, unsigned chip, rsfp_chip_state_t *out)
{
    if (!p || !out || chip >= p->chips.size())
        return 0;
    p->chips[chip]->state(out);
    return 1;
}

uint32_t rsfp_take_scope(rsfp_player *p, unsigned chip, float *out, uint32_t cap)
{
    if (!p || chip >= p->chips.size())
        return 0;
    return p->chips[chip]->takeScope(out, cap);
}

uint32_t rsfp_take_writes(rsfp_player *p, unsigned chip, rsfp_write *out, uint32_t cap, uint32_t *total)
{
    if (!p || chip >= p->chips.size())
    {
        if (total)
            *total = 0;
        return 0;
    }
    return p->chips[chip]->takeWrites(out, cap, total);
}

void rsfp_mute(rsfp_player *p, unsigned chip, unsigned voice, int mute)
{
    if (p)
        p->engine.mute(chip, voice, mute != 0);
}

void rsfp_filter(rsfp_player *p, unsigned chip, int enable)
{
    if (p)
        p->engine.filter(chip, enable != 0);
}

uint64_t rsfp_skip(rsfp_player *p, uint64_t cycles, int mode)
{
    if (!p || !p->ready)
        return 0;
    // Samples rendered before the skip belong before it.
    p->pendingHead = 0;
    p->pendingCount = 0;
    for (VizEmu *e : p->chips)
        e->setSkip(static_cast<uint8_t>(mode));
    // play(n) runs n scheduler events, which is fewer than n cycles when
    // the CIAs and VIC-II fire alongside the CPU, so go by the chips' clock.
    const uint64_t start = p->chips[0]->cyclesSinceOrigin();
    const uint64_t target = start + cycles;
    uint64_t now = start;
    while (now < target)
    {
        const unsigned step = static_cast<unsigned>(std::min<uint64_t>(target - now, MAX_PLAY_CYCLES));
        const int n = p->engine.play(step);
        if (n < 0)
        {
            p->error = p->engine.error();
            p->ready = false;
            break;
        }
        now = p->chips[0]->cyclesSinceOrigin();
    }
    for (VizEmu *e : p->chips)
    {
        e->setSkip(RSFP_SKIP_RENDER);
        e->clearViz();
    }
    return now - start;
}
