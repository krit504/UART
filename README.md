# UART

SystemVerilog UART transceiver — 16x-oversampled RX, shift-register TX, shared baud generator. 8N1 framing (1 start, 8 data LSB-first, 1 stop, no parity).

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

## Layout

```
rtl/    synthesizable design: baud_gen, tx_top, rx_top, piso (TX shift reg),
        sipo (RX shift reg), uart_top (top-level), typedefs (shared enums)
tb/     tb_uart_top.sv — loopback testbench (tx wired straight to rx),
        checks byte value and frame timing (10 bit periods x 16 ticks)
doc/    design-spec.md — block-by-block port/behavior spec, FSM rules,
        integration notes
```

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `CLK_FREQ` | `50_000_000` | system clock, Hz |
| `BAUD_RATE` | `115200` | target baud rate |
| `OVERSAMPLE` | `16` | fixed, ticks per bit period |

## Simulate

```bash
iverilog -g2012 -o tb.out rtl/typedefs.sv rtl/baud_gen.sv rtl/piso.sv rtl/sipo.sv rtl/tx_top.sv rtl/rx_top.sv rtl/uart_top.sv tb/tb_uart_top.sv
vvp tb.out
```

Dumps `uart_top.vcd` (gitignored) for waveform viewing (gtkwave, surfer, etc).

## Status

TX and RX FSMs implemented and passing loopback testbench (6 test bytes, byte + timing checks). See `doc/design-spec.md` for the full spec this was built against.
