// AD8232 ECG front-end -> Arduino Uno (ATmega328P) -> USB serial.
//
// The Uno does nothing but sample and frame. R-peak detection, BPM and phase
// stay on the PYNQ board, so the thresholds can be tuned without reflashing.
//
// Wiring (AD8232 breakout -> Uno):
//   GND    -> GND
//   3.3v   -> 3V3          (the AD8232 needs 2.0-3.5 V; never 5 V)
//   OUTPUT -> A0
//   LO-    -> D2           active high = that electrode is off
//   LO+    -> D3
//   SDN    -> D4           driven HIGH (active low shutdown)
//
// Optional jumper, see ECG_USE_EXTERNAL_AREF below.
//
// Frame, 17 bytes fixed, 115200 8N1, 50 frames/s (5 samples each @ 250 Hz):
//   0      0xA5              sync 1
//   1      0xEC              sync 2
//   2      N_SAMPLES         samples in this frame
//   3      flags             bit0 LO-  bit1 LO+  (1 = lead off)
//   4..5   seq               uint16 LE frame counter, wraps
//   6..15  samples           N_SAMPLES x uint16 LE, raw ADC counts
//   16     checksum          XOR of bytes 0..15
//
// Frames whose USB buffer is full are dropped whole (never truncated), so the
// host parser always sees complete frames; the seq gap tells it what was lost.

#include <Arduino.h>

// AREF tied to the Uno 3V3 pin gives the full 3.3 V span of the AD8232 output
// in 1024 counts instead of 676. It needs one physical jumper wire, so it is
// off by default; flip to 1 once AREF is wired.
#define ECG_USE_EXTERNAL_AREF 0

// 0 = binary frames (what the board expects), 1 = one text line per sample
// ("raw,lo_neg,lo_pos") so a plain serial monitor can eyeball the signal.
#define ECG_TEXT_MODE 0

#define PIN_ECG_OUT A0
#define PIN_LO_NEG 2
#define PIN_LO_POS 3
#define PIN_SDN 4

static const uint8_t N_SAMPLES = 5;
static const uint16_t FS_HZ = 250;
static const uint8_t OVERSAMPLE = 4;    // 4 conversions per sample: +1 bit, ~450 us
static const uint16_t WARMUP_MS = 1500; // AD8232 settles slowly after power-up

static const uint8_t SYNC0 = 0xA5, SYNC1 = 0xEC;
static const uint8_t FRAME_LEN = 6 + N_SAMPLES * 2 + 1;

static volatile uint8_t g_tick = 0;  // incremented by the sampling timer
static uint16_t g_seq = 0;
static uint32_t g_missed_ticks = 0, g_dropped_frames = 0;
static uint8_t g_buf[N_SAMPLES * 2];
static uint8_t g_fill = 0;

static void setup_timer() {
    noInterrupts();
    TCCR1A = 0;
    TCCR1B = _BV(WGM12) | _BV(CS11) | _BV(CS10);  // CTC, clk/64
    OCR1A = (F_CPU / 64UL / FS_HZ) - 1;
    TCNT1 = 0;
    TIMSK1 = _BV(OCIE1A);
    interrupts();
}

ISR(TIMER1_COMPA_vect) { g_tick++; }

static void emit(const uint8_t *payload, uint8_t flags) {
#if ECG_TEXT_MODE
    (void)payload;
    Serial.print(g_seq);
    Serial.print(',');
    Serial.print(uint16_t(payload[0] | (payload[1] << 8)));
    Serial.print(',');
    Serial.print((flags & 1) ? 1 : 0);
    Serial.print(',');
    Serial.println((flags & 2) ? 1 : 0);
    g_seq++;
#else
    // Drop whole frames rather than stall the sampler when the host is slow.
    if (Serial.availableForWrite() < FRAME_LEN) {
        g_dropped_frames++;
        g_seq++;
        return;
    }
    uint8_t f[FRAME_LEN];
    f[0] = SYNC0;
    f[1] = SYNC1;
    f[2] = N_SAMPLES;
    f[3] = flags;
    f[4] = uint8_t(g_seq & 0xFF);
    f[5] = uint8_t(g_seq >> 8);
    memcpy(f + 6, payload, N_SAMPLES * 2);
    uint8_t sum = 0;
    for (uint8_t i = 0; i < FRAME_LEN - 1; i++) sum ^= f[i];
    f[FRAME_LEN - 1] = sum;
    Serial.write(f, FRAME_LEN);
    g_seq++;
#endif
}

void setup() {
    pinMode(PIN_SDN, OUTPUT);
    digitalWrite(PIN_SDN, HIGH);  // active low: HIGH = running
    pinMode(PIN_LO_NEG, INPUT);
    pinMode(PIN_LO_POS, INPUT);

#if ECG_USE_EXTERNAL_AREF
    analogReference(EXTERNAL);  // AREF must be wired to 3V3
#else
    analogReference(DEFAULT);
#endif
    analogRead(PIN_ECG_OUT);  // prime the ADC mux so the first real read is clean

    Serial.begin(115200);
    setup_timer();

    // Discard the settling transient (lead-off detection also flaps here).
    const uint32_t until = millis() + WARMUP_MS;
    while (int32_t(millis() - until) < 0) {
        if (g_tick) {
            noInterrupts();
            g_tick = 0;
            interrupts();
            analogRead(PIN_ECG_OUT);
        }
    }
}

void loop() {
    noInterrupts();
    const uint8_t ticks = g_tick;
    g_tick = 0;
    interrupts();
    if (!ticks) return;
    if (ticks > 1) g_missed_ticks += ticks - 1;

    uint32_t acc = 0;
    for (uint8_t i = 0; i < OVERSAMPLE; i++) acc += analogRead(PIN_ECG_OUT);
    const uint16_t v = uint16_t(acc / OVERSAMPLE);

    g_buf[g_fill * 2] = uint8_t(v & 0xFF);
    g_buf[g_fill * 2 + 1] = uint8_t(v >> 8);
    if (++g_fill < N_SAMPLES) return;
    g_fill = 0;

    const uint8_t flags = uint8_t((digitalRead(PIN_LO_NEG) ? 1 : 0) | (digitalRead(PIN_LO_POS) ? 2 : 0));
    emit(g_buf, flags);
}
