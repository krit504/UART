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
        synth-reports/ — OpenLane/sky130 signoff reports cited below
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

## Physical implementation (sky130 / OpenLane)

`uart_top` was carried from RTL to a manufacturable GDSII layout using [OpenLane](https://github.com/The-OpenROAD-Project/OpenLane) (v1.0.2, `ff5509f`) against the SkyWater **sky130A** PDK (`sky130_fd_sc_hd` std cell lib, PDK build `0fe599b`), driven via Docker so the whole toolchain is pinned and reproducible.

**Flow and tools** — OpenLane chains these open-source tools into one automated run, each stage's output feeding the next:

| Stage | Tool | What it does |
|---|---|---|
| Synthesis | Yosys + ABC | RTL → gate-level netlist, mapped to `sky130_fd_sc_hd` cells |
| Floorplan | OpenROAD | die/core area, pin placement, power grid |
| Placement | OpenROAD (RePlAce/OpenDP) | global + detailed cell placement |
| Clock tree synthesis | OpenROAD (TritonCTS) | balances clock skew to the flip-flops |
| Routing | OpenROAD (FastRoute/TritonRoute) | global + detailed metal routing |
| Static timing analysis | OpenROAD (OpenSTA) | setup/hold slack at each stage, post-route with real extracted parasitics |
| DRC | Magic | design rule check on the routed layout |
| LVS | Netgen | layout-vs-schematic, confirms GDS matches the netlist |
| GDS streamout | Magic + KLayout | final GDSII, cross-checked against each other (XOR) |

Command actually run (design config at `designs/uart_top/config.json` inside the OpenLane checkout, RTL copied in from this repo's `rtl/`):

```bash
make quick_run QUICK_RUN_DESIGN=uart_top
```

`config.json` sets `DESIGN_NAME`, the `VERILOG_FILES` list (order matters — `typedefs.sv` first), `CLOCK_PORT: clk`, and `CLOCK_PERIOD` (swept below).

Flow completed clean at the 20ns baseline: 0 DRC violations, LVS clean, KLayout/Magic GDS XOR match, no setup/hold violations.

**One source change was required to synthesize** — Yosys's `read_verilog -sv` frontend doesn't support the `module x import pkg::*; (...)` header-import syntax used in `tx_top.sv`/`rx_top.sv`. Fixed by flattening `typedefs.sv` from a package into a bare global typedef (functionally identical — testbench re-verified 6/6 passing after the change). This fix lives on the `for_synthesis` branch only; `main`'s RTL is untouched by tooling workarounds.

**Area/cell count** (`CLOCK_PERIOD` 20ns / 50MHz, matching `CLK_FREQ`):

| Metric | Value | Source |
|---|---|---|
| Die area | 75.88 × 86.6 µm = 6571.2 µm² | `doc/synth-reports/baseline_20ns_50MHz/die_area.rpt` |
| Core area | 64.4 × 62.56 µm = 4028.9 µm² | `doc/synth-reports/baseline_20ns_50MHz/core_area.rpt` |
| Mapped std cells (post-synth) | 171 (33 `dfrtp` flip-flops) | `doc/synth-reports/baseline_20ns_50MHz/synth_cell_stats.rpt` |
| Total cells (post-route, incl. fill/tap/decap) | 538 | `doc/synth-reports/baseline_20ns_50MHz/metrics.csv` |

**Timing closure** — swept `CLOCK_PERIOD` down from the 20ns baseline to find where setup timing actually breaks (post-route, real parasitics, typical corner):

| Clock period | Target freq | Worst setup slack | Result | Source |
|---|---|---|---|---|
| 20 ns | 50 MHz | +13.89 ns | closes | `doc/synth-reports/baseline_20ns_50MHz/sta_summary.rpt` |
| 5 ns | 200 MHz | +1.87 ns | closes | — |
| 3 ns | 333 MHz | +0.20 ns | closes | `doc/synth-reports/sweep_3ns_333MHz_pass/sta_summary.rpt` |
| 2.5 ns | 400 MHz | −0.30 ns | **fails** | `doc/synth-reports/sweep_2.5ns_400MHz_fail/sta_summary.rpt` (failing path: `sta_max_failing_path.rpt`) |
| 2 ns | 500 MHz | −0.79 ns | fails | — |
| 1.9 ns | 526 MHz | −0.94 ns | fails | — |

**Closes at 333 MHz, breaks by 400 MHz** — worst hold slack stayed positive (+0.03 ns to +0.33 ns) across the whole sweep, so hold was never the limiter; setup at the clock-tree/logic critical path is what caps it. The "fails" rows aren't a design bug — they're the deliberate result of pushing the clock past what this particular placed/routed netlist can meet: at those periods a flip-flop's input wouldn't settle before the next clock edge, so those clock speeds just aren't usable for this implementation. Functional correctness (the testbench above) is a separate, unaffected concern. All reports above are the actual `report_worst_slack`/floorplan/synthesis-stat output, not the (sometimes misleading) `metrics.csv` summary row.
