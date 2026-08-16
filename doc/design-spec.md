
Reference for implementation. Covers what each block must do, its ports, and its internal behavior. Not a tutorial (see the 0→Hero doc for SV mechanics) — this is the "what to build" sheet.

---

## 1. System Overview

```
                 ┌─────────────────┐
                 │   baud_gen       │
                 │  (free-running   │
                 │   16x tick gen)  │
                 └────────┬─────────┘
                          │ baud_tick
              ┌───────────┴───────────┐
              ▼                       ▼
     ┌─────────────────┐     ┌─────────────────┐
     │   tx_top         │     │   rx_top         │
     │ (shift reg+FSM)  │     │ (oversample+FSM) │
     └────────┬─────────┘     └────────┬─────────┘
              │ tx                     │ rx
              ▼                        ▲
         [ UART line ]  ───────────────┘
```

**Top-level parameters (shared across all blocks):**

|Parameter|Example value|Meaning|
|---|---|---|
|`CLK_FREQ`|`50_000_000`|System clock frequency, Hz|
|`BAUD_RATE`|`115200`|Target baud rate|
|`OVERSAMPLE`|`16`|Fixed — samples per bit period|

**Frame format (fixed for this project):** 1 start bit (`0`) → 8 data bits, LSB-first → 1 stop bit (`1`). No parity.

---

## 2. Block: Baud Rate Generator (`baud_gen`)

**Purpose:** produce a single-cycle tick pulse every `1/16th` of a bit period. Shared by both TX and RX.

**Ports (as implemented):**

|Signal|Dir|Width|Purpose|
|---|---|---|---|
|`clk`|in|1|system clock|
|`rst_n`|in|1|async active-low reset|
|`tick`|out|1|pulses high for one clock cycle every `DIVISOR` cycles|

Note: the port is named `tick`, not `baud_tick` — `baud_tick` is the name of the _wire_ it gets connected to one level up, at `uart_top` (see §6).

**Parameters (as implemented):** `baud_rate` (default `115200`), `clk_freq` (default `50_000_000`), `sampling_rate` (default `16`).

**Internal parameter:** `localparam DIVISOR = clk_freq / (sampling_rate × baud_rate)` — integer division truncates (e.g. `50_000_000/(16×115200)` truncates to `27`, not rounds).

**Functional behavior:**

- Free-running counter, no enable — always counting once out of reset.
- Counts `0` to `DIVISOR - 1`, wraps to `0`, and asserts `tick` for exactly one clock cycle on the wrap; `tick` is explicitly driven low on every other cycle.
- Counter width: `$clog2(DIVISOR)-1:0`.

**What "done" looks like for this block:** simulate standalone, confirm `tick` pulses are spaced exactly `DIVISOR` clock cycles apart, and that 16 consecutive `tick` pulses span `16 × DIVISOR` cycles (one full bit period).

---

## 3. Block: TX (`tx_top`) — Shift Register + FSM

**Purpose:** accept a byte, serialize it onto `tx` at the configured baud rate, framed with start/stop bits.

**Structure:** `tx_top` instantiates the `shift_reg` module and wraps an FSM around it. `shift_reg` just does what it's told (load / shift); the FSM decides when.

**Ports (as implemented):**

|Signal|Dir|Width|Purpose|
|---|---|---|---|
|`clk`, `rst_n`|in|1|clock, async active-low reset|
|`baud_tick`|in|1|from `baud_gen`'s `tick` output, wired at `uart_top`|
|`tx_start`|in|1|pulse: begin transmitting `tx_data`|
|`tx_data`|in|8|byte to send|
|`tx`|out|1|serial line (idles high)|
|`tx_busy`|out|1|high while transmitting|

`shift_reg`'s ports (as implemented): `clk`, `rst_n`, `load`, `en`, `load_val[7:0]`, `tx_data` (output — the live LSB tap), `done` (output, unused by `tx_top`).

**Internal signals:**

|Signal|Type|Purpose|
|---|---|---|
|`sr_load`|wire, FSM → `shift_reg.load`|tells shift_reg to load a fresh byte|
|`sr_en`|wire, FSM → `shift_reg.en`|tells shift_reg to shift one position|
|`sr_bit`|wire, `shift_reg.tx_data` → FSM|the live current data bit|
|`tick_cnt` (0–15)|FSM counter, `always_ff`|counts `baud_tick`s within the current bit period|
|`bit_cnt` (0–7)|FSM counter, `always_ff`|counts how many real shifts have been issued so far|

**Both counters live entirely inside `always_ff`, never `always_comb`.** Both need to _persist_ their count across many clock cycles, which only a clocked block (a real flip-flop) can do; `always_comb` has no memory element and re-evaluates fresh on every input change, so any attempt to increment a signal inside it is either a compile error (non-blocking `<=` isn't valid there) or a combinational feedback loop, not a counter.

**Both counters must be explicitly pinned to `0` while `state==IDLE` — not left to wrap naturally.** `baud_tick` free-runs continuously regardless of `tx_top`'s state, so `tick_cnt` would otherwise drift to an arbitrary phase while sitting in `IDLE`, and the _next_ `START` state (triggered by `tx_start`, which can arrive at any arbitrary cycle) would start counting from wherever `tick_cnt` happened to be — producing a start bit of the wrong length. Structure:

```systemverilog
if (state == IDLE) begin
  tick_cnt <= 0;   // (and separately, bit_cnt <= 0;)
end else if (<normal increment/wrap condition>) begin
  ...
end
```

**`bit_cnt`'s increment must be gated on `sr_en` specifically, not on `state==DATA`.** `state==DATA` is true for every clock edge across the whole `DATA` state (~hundreds of edges); `sr_en` is true for exactly one edge per bit period — the one edge `tick_cnt` actually reaches 15. Gating on `state==DATA` instead races `bit_cnt` up and wraps it many times within a single bit period, disconnected from real shift timing.

**`shift_reg`'s `done` port is deliberately ignored by `tx_top`.** `bit_cnt` is tracked independently inside the FSM instead. Reasoning: `done` is a live tap on `shift_reg`'s own registered `count`, which only updates one cycle after `en` is asserted — using it would require the FSM to reason about that cross-module register delay every time it checks completion. Tracking `bit_cnt` directly inside the FSM, incremented in the same cycle `sr_en` is asserted, avoids that delay entirely and keeps all sequencing logic self-contained in one place. The tradeoff: `shift_reg`'s internal counter becomes redundant hardware (computed but unused) — acceptable at this scale, since `tick_cnt` was already needed regardless.

**Governing rule, applies to every state below:** every bit on the UART line — start, each of the 8 data bits, stop — must occupy exactly one full bit period. `tick_cnt` counting `baud_tick`s from 0 to 15 _is_ the measurement of "one bit period has elapsed" (§10). Every state's wait for `tick_cnt==15` is not idle waiting — `tx` is already correctly driven for that entire window; the wait **is** that bit's required on-wire duration.

**Per-state spec (each entry below is self-contained — everything needed to implement that state's behavior):**

**`IDLE`**

- `tx` driven to `1'b1` (idle-high). `tx_busy = 0`.
- `sr_load = 0`, `sr_en = 0` while waiting.
- Waits for `tx_start`.
- On `tx_start` high: `sr_load = 1` combinationally, same cycle (Mealy — §8). `sr_en` stays `0`. Reset `tick_cnt` and `bit_cnt` to `0`. Next clock edge → `START`.

**`START`**

- `tx` driven to `1'b0` for the entire state — this is the start bit.
- `tx_busy = 1`.
- `sr_load = 0`, `sr_en = 0` for the entire state — `shift_reg` is untouched here, still holding exactly what `sr_load` wrote to it in `IDLE`.
- `tick_cnt` increments on every `baud_tick`.
- When `tick_cnt` reaches `15`: the start bit has now held for one full bit period. Reset `tick_cnt` to `0`. Next clock edge → `DATA`. (`sr_bit`, i.e. bit 0 of the loaded byte, is already valid at `shift_reg`'s output the instant `sr_load` fired back in `IDLE` — no `sr_en` pulse has been needed yet.)

**`DATA`**

- `tx` driven to `sr_bit` (the shift register's live LSB tap) for the entire state.
- `tx_busy = 1`.
- `sr_load = 0` for the entire state.
- `sr_en` is `0` for 15 out of every 16 cycles in `DATA`. On the one cycle each bit period where `tick_cnt` reaches `15`, `sr_en = 1` for that single cycle **if** `bit_cnt < 7` at that moment — this happens 7 separate times total (once at the end of each of the first 7 bit periods: bit0 through bit6). On the 8th such boundary (`bit_cnt == 7`, bit7's period ending), `sr_en` stays `0` instead.
- `tick_cnt` increments on every `baud_tick`. This state is re-entered internally 8 times in a row (once per data bit) without ever leaving `DATA` itself — `bit_cnt` is what tracks which of the 8 bits is currently being held on the line.
- **When `tick_cnt` reaches `15`** (current bit has held for a full period), check `bit_cnt`:
    - **If `bit_cnt < 7`:** this bit's period is done but more bits remain. Pulse `sr_en` for one cycle (shifts `shift_reg`, so `sr_bit` becomes the _next_ bit), increment `bit_cnt`, reset `tick_cnt` to `0`. Stay in `DATA` — the newly-shifted bit now begins its own full period.
    - **If `bit_cnt == 7`:** this was bit7's (the 8th and final bit's) own period completing. `sr_en` stays `0` — there is no 9th bit. Next clock edge → `STOP` instead.

**`STOP`**

- `tx` driven to `1'b1` for the entire state — this is the stop bit.
- `tx_busy = 1`.
- `sr_load = 0`, `sr_en = 0` for the entire state.
- `tick_cnt` increments on every `baud_tick`.
- When `tick_cnt` reaches `15`: stop bit has held for a full period. Next clock edge → `IDLE`. `tx_busy` drops to `0` there.

**Full cycle-accurate frame timing** (one period = 16 `baud_tick`s = one bit period; this is what actually happens on the wire for one transmitted byte):

|Period #|State|`tx` during this period|`bit_cnt` entering|Event at `tick_cnt`==15|
|---|---|---|---|---|
|—|`IDLE`|`1` (idle)|—|`tx_start` seen → `sr_load` fires, bit0 now valid on `sr_bit`|
|1|`START`|`0`|—|→ `DATA`, `tick_cnt` reset|
|2|`DATA`|`sr_bit` = bit0|0|`bit_cnt`(0)<7 → pulse `sr_en` #1, `bit_cnt`→1, `sr_bit` becomes bit1|
|3|`DATA`|`sr_bit` = bit1|1|pulse `sr_en` #2, `bit_cnt`→2|
|4|`DATA`|`sr_bit` = bit2|2|pulse `sr_en` #3, `bit_cnt`→3|
|5|`DATA`|`sr_bit` = bit3|3|pulse `sr_en` #4, `bit_cnt`→4|
|6|`DATA`|`sr_bit` = bit4|4|pulse `sr_en` #5, `bit_cnt`→5|
|7|`DATA`|`sr_bit` = bit5|5|pulse `sr_en` #6, `bit_cnt`→6|
|8|`DATA`|`sr_bit` = bit6|6|pulse `sr_en` #7, `bit_cnt`→7|
|9|`DATA`|`sr_bit` = bit7|7|`bit_cnt`==7, **no** `sr_en` → `STOP`|
|10|`STOP`|`1`|—|→ `IDLE`, `tx_busy`→0|

**Sanity check:** 1 start period + 8 data periods + 1 stop period = **10 bit periods per byte**, exactly matching standard UART "8N1" framing (8 data bits, no parity, 1 stop bit → 10 bits total on the wire). 7 total `sr_en` pulses issued (bit0 is free from the load itself; pulses 1–7 bring bits 1 through 7 into view).

**Signal drive logic, summarized:**

|Signal|Driven high when|
|---|---|
|`sr_load`|in `IDLE`, `tx_start` high|
|`sr_en`|in `DATA`, `tick_cnt` hits 15 **and** `bit_cnt < 7`|
|`tx`|`0` in `START`, `1` in `IDLE`/`STOP`, `sr_bit` in `DATA`|
|`tx_busy`|any state except `IDLE`|

**State table (quick reference — see per-state spec above for full detail):**

|State|Each cycle|Exit condition|
|---|---|---|
|`IDLE`|wait for `tx_start`|`tx_start` → `sr_load`, reset `tick_cnt`/`bit_cnt`, go `START`|
|`START`|`tick_cnt` up on each `baud_tick`|`tick_cnt`==15 → reset `tick_cnt`, go `DATA`|
|`DATA`|`tick_cnt` up each `baud_tick`; at 15: if `bit_cnt`<7, pulse `sr_en`, `bit_cnt`+=1, reset `tick_cnt`, stay; if `bit_cnt`==7, go `STOP` (no pulse)|as described in "each cycle" column|
|`STOP`|`tick_cnt` up on each `baud_tick`|`tick_cnt`==15 → go `IDLE`|

---

## 4. Block: RX (`rx_top`) — Oversampling FSM + Shift Register

**Purpose:** detect an incoming start bit on `rx`, sample each subsequent bit at its midpoint using 16x oversampling, and output the received byte once complete.

**Structure:** `rx_top` instantiates an `rx_shift` module (SIPO — serial-in, parallel-out, the mirror image of TX's `shift_reg`) and wraps an FSM around it. `rx_shift` just shifts in whatever bit it's told, when it's told; the FSM decides when and what.

**Ports (`rx_top`):**

|Signal|Dir|Width|Purpose|
|---|---|---|---|
|`clk`, `rst_n`|in|1|clock, async active-low reset|
|`baud_tick`|in|1|from `baud_gen`'s `tick` output, wired at `uart_top`|
|`rx`|in|1|serial input line (idles high)|
|`rx_data`|out|8|received byte, valid when `rx_done` pulses|
|`rx_done`|out|1|pulse: one full byte received|

**`rx_shift` ports (new module, not yet built):**

|Signal|Dir|Width|Purpose|
|---|---|---|---|
|`clk`, `rst_n`|in|1|clock, async active-low reset|
|`shift_en`|in|1|pulse: shift `serial_in` into the register|
|`serial_in`|in|1|the bit being shifted in this cycle|
|`parallel_out`|out|8|assembled byte, stable once 8 shifts have occurred|

Internally: right-shift, new bit entering at the MSB — `shift_reg <= {serial_in, shift_reg[7:1]}`. Since UART sends LSB-first, the first bit received (bit0) ends up shifted down to position 0 after 8 total shifts, and the last bit received (bit7) lands at position 7 — the register reads out as a normal byte, MSB to LSB, with no extra reordering needed. No `load`/`done` ports needed — `rx_top` reads `parallel_out` directly once it knows (via its own `bit_cnt`) that 8 shifts have happened, the same reasoning as TX ignoring `shift_reg`'s `done`.

**Internal signals (`rx_top`):**

|Signal|Type|Purpose|
|---|---|---|
|`sr_shift_en`|wire, FSM → `rx_shift.shift_en`|tells `rx_shift` to shift in the currently-sampled bit|
|`tick_cnt` (0–15)|FSM counter, `always_ff`|counts `baud_tick`s within the current bit period|
|`bit_cnt` (0–7)|FSM counter, `always_ff`|counts how many data bits have been sampled so far|

`rx_shift.serial_in` connects directly to the `rx` input port, and `rx_shift.parallel_out` connects directly to the `rx_data` output port — no intermediate signal needed for either. `rx_data` is just a continuous read of whatever `rx_shift` currently holds; `rx_done` (a separate FSM-driven pulse, still needed) is what tells the consumer "the value on `rx_data` right now is a complete, valid byte."

**Counter placement rules — identical to TX (§3), applied here without re-deriving:** both `tick_cnt` and `bit_cnt` live in `always_ff` only, both are pinned to `0` while `state==IDLE`, and `bit_cnt`'s increment gates on the same-shape single-cycle pulse condition (`sr_shift_en`/bit-boundary), never on a raw `state==DATA` check.

**Governing rule, extends TX's (§3):** same "every bit occupies exactly one full 16-tick bit period" rule applies. The one addition for RX: each bit period now has **two** meaningful tick points instead of one — `tick_cnt==7` (the midpoint, 8 ticks in — the sampling instant) and `tick_cnt==15` (the full period elapsed — the boundary to the next bit or next state). TX only needed the second; RX needs both, because RX must _read_ `rx` mid-bit (away from the unstable edges) while still waiting out the full period before advancing.

**Per-state spec:**

**`IDLE`**

- Watches `rx` directly. `tick_cnt = 0`, `bit_cnt = 0` (pinned, per the counter rules above).
- `sr_shift_en = 0` the entire time.
- On `!rx` (line goes low): next clock edge → `START`. (No Mealy output needed here — unlike TX's `sr_load`, nothing needs to fire the same cycle; `START`'s own logic handles everything from the next edge onward.)

**`START`**

- `tick_cnt` increments on every `baud_tick`, counting a full 16-tick period, identical in shape to TX's `START`.
- `sr_shift_en = 0` the entire time — no data has been confirmed yet.
- **At `tick_cnt==7`** (midpoint of the start bit): check `rx`. If `rx` is still `0`, this is a real start bit — no state change, just continue counting. If `rx` is `1` (the line went back high — a glitch, not a real start bit), abort: next clock edge → `IDLE` directly, instead of waiting out the rest of the period.
- **At `tick_cnt==15`** (full start-bit period elapsed, and it was already confirmed valid at the midpoint): reset `tick_cnt` to `0`. Next clock edge → `DATA`.

**`DATA`**

- `tick_cnt` increments on every `baud_tick`, one full 16-tick period per data bit, exactly like TX's `DATA`.
- **At `tick_cnt==7`** (midpoint of the current data bit): `sr_shift_en = 1` for that one cycle. `rx_shift.serial_in` (wired directly to `rx`) captures the live `rx` value at that instant.
- **At `tick_cnt==15`** (full period elapsed for this bit): check `bit_cnt`:
    - **If `bit_cnt < 7`:** more bits remain. Increment `bit_cnt`, reset `tick_cnt` to `0`. Stay in `DATA` — the next bit's period begins.
    - **If `bit_cnt == 7`:** this was bit7's own period completing, and it was already sampled at this period's `tick_cnt==7`. Next clock edge → `STOP`.
- `sr_shift_en` is `0` on every cycle except the single `tick_cnt==7` cycle of each period — same one-pulse-per-period shape as TX's `sr_en`, just triggered at the midpoint instead of the boundary.

**`STOP`**

- `tick_cnt` increments on every `baud_tick`, one full 16-tick period, identical in shape to TX's `STOP`.
- `sr_shift_en = 0` the entire time — the byte is already fully assembled in `rx_shift`.
- **At `tick_cnt==15`** (stop-bit period elapsed): `rx_done = 1` for that one cycle (combinational, tied to this exact condition). `rx_data` is already correct at this point — it's continuously wired to `rx_shift.parallel_out`, no separate action needed. Next clock edge → `IDLE`.

**Full cycle-accurate frame timing** (mirrors TX's table shape; one period = 16 `baud_tick`s unless noted):

|Period #|State|Key event(s) this period|`bit_cnt` entering|
|---|---|---|---|
|—|`IDLE`|`rx` goes low → `START`|—|
|1|`START`|tick7: confirm `rx==0` (or abort to `IDLE`) · tick15: → `DATA`|—|
|2|`DATA`|tick7: sample+shift bit0 · tick15: `bit_cnt`→1|0|
|3|`DATA`|tick7: sample+shift bit1 · tick15: `bit_cnt`→2|1|
|4|`DATA`|tick7: sample+shift bit2 · tick15: `bit_cnt`→3|2|
|5|`DATA`|tick7: sample+shift bit3 · tick15: `bit_cnt`→4|3|
|6|`DATA`|tick7: sample+shift bit4 · tick15: `bit_cnt`→5|4|
|7|`DATA`|tick7: sample+shift bit5 · tick15: `bit_cnt`→6|5|
|8|`DATA`|tick7: sample+shift bit6 · tick15: `bit_cnt`→7|6|
|9|`DATA`|tick7: sample+shift bit7 · tick15: `bit_cnt`==7, → `STOP` (no further shift)|7|
|10|`STOP`|tick15: `rx_done`=1 (`rx_data` already valid, wired continuously) · → `IDLE`|—|

10 periods total, matching TX's 10-bit frame exactly (start + 8 data + stop) — same framing, opposite direction.

**Signal drive logic, summarized:**

|Signal|Driven high when|
|---|---|
|`sr_shift_en`|in `DATA`, `tick_cnt`==7|
|`rx_data`|continuously tied to `rx_shift.parallel_out`; meaningful the cycle `rx_done` pulses|
|`rx_done`|in `STOP`, `tick_cnt`==15|

**State table (quick reference — see per-state spec above for full detail):**

|State|Each cycle|Exit condition|
|---|---|---|
|`IDLE`|watch `rx`|`rx` low → go `START`|
|`START`|`tick_cnt` up each `baud_tick`; at 7, confirm `rx==0` or abort to `IDLE`|`tick_cnt`==15 (and confirmed) → reset `tick_cnt`, go `DATA`|
|`DATA`|`tick_cnt` up each `baud_tick`; at 7, sample+shift; at 15, advance `bit_cnt`/loop or exit|`bit_cnt`==7 at a tick15 → go `STOP`|
|`STOP`|`tick_cnt` up each `baud_tick`; at 15, latch `rx_data`, pulse `rx_done`|`tick_cnt`==15 → go `IDLE`|

---

## 5. FSM Implementation Rules (applies to both `tx_top` and `rx_top`)

**Rule 1 — `next_state` must be declared with the enum type (`state_t`), never plain `logic`.**

```systemverilog
state_t next_state;   // correct
logic   next_state;   // wrong — silently truncates
```

`state_t` is 2 bits wide (`IDLE=00, START=01, DATA=10, STOP=11`). If `next_state` is declared as plain 1-bit `logic`, assigning it a 2-bit enum value keeps only the least significant bit — `DATA` (`2'b10`) truncates to `1'b0`, `STOP` (`2'b11`) truncates to `1'b1`. When that 1-bit value is then written into the 2-bit `state` register (`state <= next_state;`), it gets zero-extended back to 2 bits — so the truncated `1'b0` becomes `2'b00` (`IDLE`), and the truncated `1'b1` becomes `2'b01` (`START`). The net effect: `DATA` silently becomes `IDLE`, `STOP` silently becomes `START` — every assignment is legal SystemVerilog, nothing errors or warns by default, and the FSM just jumps to the wrong named state. This is a more dangerous version of the general width-truncation pitfall (§11) specifically because the corrupted value still decodes to a _valid, named_ state — there's no `x` or out-of-range value to flag it in a waveform; it looks like a legitimate (wrong) transition.

**Rule 2 — a counter must be incremented at the same trigger point that reads it for a decision, not at an earlier trigger point within the same period.**

RX's `DATA` state has two trigger points per bit period: `tick_cnt==7` (sample the bit) and `tick_cnt==15` (decide whether to continue or exit to `STOP`). If the increment sits on the _sample_ trigger but the exit decision sits on the _period-end_ trigger, the decision ends up reading a value that was already bumped earlier in that same period — one bit ahead of what it should see.

Trace it for bit6's period specifically (the period where things go wrong):

|Tick this period|Event|`bit_cnt` value|
|---|---|---|
|entering this period|—|`6`|
|`tick_cnt==7`|sample bit6, **increment fires here**|`6` → `7`|
|`tick_cnt==15`|exit decision reads `bit_cnt`|reads `7`|

The exit decision at `tick_cnt==15` sees `bit_cnt==7` and concludes "8 bits done, go to `STOP`" — but bit7 was never sampled. The increment at `tick_cnt==7` already moved `bit_cnt` to `7` _before_ the period even finished, so the decision at the end of that same period reads a count that's one bit ahead of reality.

**The fix:** move the increment to the same trigger the decision uses — `tick_cnt==15`, gated with `bit_cnt<7` — so both happen at the same point, once per period, in sync. This matches how TX already works: TX only has one trigger point per period (`tick_cnt==15`), so its increment and its decision were never at risk of drifting apart in the first place.

**Rule 3 — every state-transition condition based on `tick_cnt` must be gated by `baud_tick`, not just the counter's held value.**

`tick_cnt` only changes value on real `baud_tick` edges — between pulses (~27 system clock cycles for the default parameters), it holds steady at whatever it last became. A transition condition written as a bare level check (`if (tick_cnt==15) next_state = DATA;`, no `baud_tick` in the condition) is combinational, so it re-evaluates continuously — but `state` itself updates every system clock edge regardless of `baud_tick` (`state <= next_state;` is unconditional). So the transition into the new state happens correctly, one system clock cycle after `tick_cnt` first reads 15. The problem shows up immediately after: `tick_cnt` has _not yet_ been reset to 0 (its own reset only happens on the next real `baud_tick` pulse, still ~26 cycles away) — it's still sitting at 15, now being read by the _new_ state's own logic. If that new state's transition/decision logic also checks a bare `tick_cnt==15`, it sees the stale, leftover value from the previous state and fires immediately — using zero real ticks of its own new period — instead of waiting for a genuine fresh 16-tick count. The new state's first period gets cut to nothing; its duration is silently absorbed before a single real tick has elapsed in it. The fix: every transition/decision condition must be `baud_tick && tick_cnt==<value>`, never `tick_cnt==<value>` alone — this restricts the condition to firing only on the one genuine clock edge the tick actually changed, not on any of the ~26 subsequent cycles where it merely holds that value.

---

## 6. Integration Notes

**`tx_top` does not instantiate `baud_gen` itself.** `baud_tick` is just a port _input_ on `tx_top` (and `rx_top`) — the actual `baud_gen` instance lives one level higher, in a top-level module (call it `uart_top`) that instantiates all three blocks as siblings and wires `baud_gen`'s single `baud_tick` output to both `tx_top.baud_tick` and `rx_top.baud_tick`. One `baud_gen` instance, one `baud_tick` wire, fanned out to two consumers — never instantiate a second `baud_gen`.

```systemverilog
module uart_top (
  input  logic clk, rst_n,
  input  logic tx_start,
  input  logic [7:0] tx_data,
  output logic tx, tx_busy,
  input  logic rx,
  output logic [7:0] rx_data,
  output logic rx_done
);
  logic baud_tick;   // the one shared wire

  baud_gen u_baud (
    .clk(clk), .rst_n(rst_n),
    .tick(baud_tick)
  );

  tx_top u_tx (
    .clk(clk), .rst_n(rst_n),
    .baud_tick(baud_tick),        // <- fed from u_baud, not instantiated here
    .tx_start(tx_start), .tx_data(tx_data),
    .tx(tx), .tx_busy(tx_busy)
  );

  rx_top u_rx (
    .clk(clk), .rst_n(rst_n),
    .baud_tick(baud_tick),        // <- same wire, second consumer
    .rx(rx),
    .rx_data(rx_data), .rx_done(rx_done)
  );
endmodule
```

- For loopback testing later (out of scope for now — design-only focus): `tx` output wires directly to `rx` input, and a testbench drives `tx_start`/`tx_data`, then checks `rx_done`/`rx_data` matches.
- Suggested build/test order (matches dependency): `baud_gen` (verify tick spacing standalone) → TX shift register alone (done) → TX FSM wrapping it (standalone, driving its own `baud_tick` stub in a small testbench — don't need `uart_top` yet) → RX oversample tick-counting alone → RX FSM wrapping it → RX shift register (SIPO) integrated in → only then assemble `uart_top` and wire everything together.

---

## 7. Signals Checklist (quick reference while coding)

|Block|Inputs|Outputs|Internal state|
|---|---|---|---|
|`baud_gen`|`clk`, `rst_n`|`tick` (wired to `baud_tick` at the `uart_top` level)|divisor counter|
|`tx_top`|`clk`, `rst_n`, `baud_tick`, `tx_start`, `tx_data[7:0]`|`tx`, `tx_busy`|state, tick counter, bit counter, shift register|
|`rx_top`|`clk`, `rst_n`, `baud_tick`, `rx`|`rx_data[7:0]`, `rx_done`|state, `tick_cnt`, `bit_cnt`, `rx_shift` instance|