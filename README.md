# NanoVNA Impedance Analyzer

MATLAB tooling for driving a NanoVNA over a serial connection and turning the
resulting one-port S-parameter sweeps into electrical impedance plots. Built to
characterize piezoelectric (PZT) disks, where the quantity of interest is the
electromechanical resonance visible in the impedance magnitude.

The repository contains two programs that can be used together or separately:

- **`NanoVNA_Analyzer`**, a GUI application that connects to the instrument,
  runs high resolution sweeps, applies a one-port OSL calibration, and exports
  Touchstone `.s1p` files.
- **`PZT_Impedance_Analyzer`**, an offline tool that reads `.s1p` files, converts
  S11 to complex impedance, and plots magnitude, phase, and resonance minima.

Four measured sweeps are included, so the offline half runs with no hardware.
Note that those sweeps cover the capacitive region below resonance, see
Limitations.

---

## What it does

### Acquisition, `src/NanoVNA_Analyzer.m`

- Scans the host for available serial ports and lists them for selection.
- Connects at 115200, 57600, or 9600 baud.
- **Chunked high resolution sweeps.** The NanoVNA returns 101 points per sweep.
  The driver walks the requested span in 101-point segments that overlap by one
  point, then stitches them into a single vector. The number of segments is set
  by a Divisions spinner, and total points are `divisions * 100 + 1`. With the
  default of 5 divisions that is 501 points; the spinner accepts 1 to 1000
  divisions, so 101 to 100001 points.
- Start and stop frequency are entered in kHz, MHz, or GHz, defaulting to
  50 kHz and 1000 kHz. The numeric fields accept 0.001 to 3000000 in the
  selected unit.
- **One-port OSL vector error correction.** Measure open, short, and load
  standards, compute the directivity, source match, and reflection tracking
  terms, and apply them to subsequent sweeps.
- **Calibration preset manager** with five slots, saved between sessions.
- Continuous repeat sweeps on a timer, with a configurable interval of 0.2 to
  60 seconds, and an abort control.
- Per-chunk settling pause, configurable from 10 to 2000 ms, defaulting to
  1000 ms. A faster pause trades settling time for sweep rate.
- Optional trace smoothing: moving average, Savitzky-Golay, median, or Gaussian,
  with a window of 1 to 101 points.
- Overlay of the last 5 sweeps for run-to-run comparison.
- Three plot tabs: log-magnitude return loss, a Smith chart, and VSWR with phase.
  The Smith chart grid is drawn directly, so no RF Toolbox license is needed.
- Touchstone `.s1p` export, written as `# Hz S RI R 50`.
- Timestamped logging console, with an optional verbose mode that echoes every
  serial command.

### Analysis, `src/PZT_Impedance_Analyzer.m`

- Reads Touchstone 1.0 one-port files. The option line is honoured for frequency
  unit (Hz, kHz, MHz, GHz), data format (RI, MA, DB), and reference impedance.
- Converts reflection to impedance with `Z_in = Z0 * (1 + S11) / (1 - S11)`.
- Plots impedance magnitude and phase against frequency on log axes, and an
  overlay marking each disk's resonance, printing the located frequency and
  magnitude to the console. Resonance detection requires a genuine interior
  minimum: if |Z| simply falls to the edge of the search band, the tool reports
  that no resonance is in range rather than marking the edge sample.
- Accepts any number of files. Run it with no arguments and it opens a file
  picker, starting in the bundled sample data folder.

---

## Hardware, and how this was tested

Developed against a NanoVNA over a USB serial connection, using the text command
interface (`sweep`, `data 0`) common to the NanoVNA-H and NanoVNA-H4 firmware
families. The device under test was a set of four PZT disks of 10, 20, 27, and
50 mm diameter, swept from 20 kHz to 1000 kHz.

The included sample sweeps in `examples/sample_data/` are real measurements from
that setup. That range turned out to sit below the disks' fundamental
resonance, so the sweeps show capacitive behaviour rather than a resonance
peak.

Compatibility beyond that specific setup is untested. See Limitations.

---

## Requirements

- MATLAB R2019b or newer. The code uses `serialport` and `configureTerminator`
  (R2019a), `uifigure` and `uigridlayout` app building, `tiledlayout` and
  `nexttile` (R2019b), and `smoothdata`.
- **Instrument Control Toolbox**, required by `NanoVNA_Analyzer` and
  `NanoVNADriver` for `serialport`, `serialportlist`, `configureTerminator`,
  `writeline`, and `readline`. This is only needed to talk to hardware.
- No toolbox beyond base MATLAB is required for `PZT_Impedance_Analyzer`. It
  uses only file I/O and plotting, so the offline analysis path works on a plain
  MATLAB installation.
- The Smith chart is drawn from first principles and does **not** require the RF
  Toolbox.

---

## Install

```
git clone https://github.com/VedatU/NanoVNA-Analyzer.git
cd NanoVNA-Analyzer
```

Then in MATLAB, from the repository root:

```matlab
addpath(genpath('src'));
```

Both entry points also resolve their own dependencies relative to their own
location, so `NanoVNA_Analyzer` finds `src/drivers/` on its own and can be
launched from any working directory.

---

## Minimal runnable example

No hardware needed. From the repository root:

```matlab
run examples/run_impedance_example.m
```

This loads the four bundled sweeps and draws both figures. It should print
something close to:

```
=========================================================
  PZT IMPEDANCE ANALYZER - IMPORTING S1P DATA
=========================================================
  Loaded Disk A (10 mm)            501 points,    20.0 to  1000.0 kHz, Z0 = 50 Ohm
  ...

Resonance search over 20 to 1000 kHz:
  Disk A (10 mm)           no resonance in range. |Z| decreases to the sweep edge ...
  ...
```

On the bundled sample data every trace reports "no resonance in range". That is
the correct result, not a failure: see Limitations below.

To pick files yourself instead:

```matlab
PZT_Impedance_Analyzer
```

To drive an instrument:

```matlab
NanoVNA_Analyzer
```

Select a port, press Connect, then Single Sweep.

---

## File layout

```
NanoVNA-Analyzer/
  README.md
  LICENSE
  .gitignore
  src/
    NanoVNA_Analyzer.m          GUI acquisition and calibration application
    PZT_Impedance_Analyzer.m    offline .s1p to impedance analysis
    drivers/
      NanoVNADriver.m           serial transport and chunked sweep engine
  examples/
    run_impedance_example.m     no-prompt demo over the bundled sweeps
    sample_data/
      NanoVNA_Sweep_10_MM_PZT.s1p
      NanoVNA_Sweep_20_MM_PZT.s1p
      NanoVNA_Sweep_27_MM_PZT.s1p
      NanoVNA_Sweep_50_MM_PZT.s1p
      README.md                 provenance and format of the sample sweeps
```

---

## Simulation mode, and how measured data is kept distinct

`NanoVNADriver` can generate synthetic S11 for testing the interface without an
instrument. This is useful, and it is also the sort of feature that can quietly
contaminate a dataset, so it is deliberately constrained:

- Simulation is **never entered automatically**. If the serial port fails to
  open, the driver reports the failure and stays disconnected. It does not fall
  back to synthetic data. A sweep attempted without a connection is refused.
- Entering simulation mode requires ticking the Simulation Mode box, or passing
  the port name `SIMULATION`, and prints a banner saying the output is synthetic.
- Every simulated sweep logs `[SIMULATED] ... THIS IS NOT A MEASUREMENT.`
- Any `.s1p` exported while simulating carries `! Source: SIMULATED` in its
  header, plus an explicit warning line, and the export shows a warning dialog.
- `PZT_Impedance_Analyzer` reads that header, prints a warning to stderr, and
  appends `[SIMULATED]` to the plot legend entry.
- `PZT_Impedance_Analyzer` never fabricates input. A missing file is an error.

---

## Limitations

Worth knowing before relying on this:

- **Tested against one instrument and one class of device under test.** A single
  NanoVNA and four PZT disks, over 20 kHz to 1000 kHz. Other NanoVNA firmware
  variants may use a different command set or return a different number of
  points per sweep. The 101-point chunk size is a hardcoded constant in
  `NanoVNADriver.executeChunkedSweep`.
- **Chunked sweeping is not the same as a native wide sweep.** Each chunk is a
  separate hardware sweep with its own settling. Stitching assumes the
  instrument returns exactly 101 points spaced linearly across the programmed
  chunk span. Segment boundaries can show small discontinuities, and the trace
  smoothing option will partly mask rather than fix them.
- **Total sweep time scales with the number of chunks.** At the default 1000 ms
  per-chunk pause, a 501-point sweep takes roughly 5 seconds of settling alone.
  A 100001-point sweep would take over 16 minutes.
- **The OSL calibration is one-port and scalar in its standards model.** The
  standards are treated as ideal, with no open fringing capacitance, short
  inductance, or load parasitics, and no cable de-embedding. It corrects
  directivity, source match, and reflection tracking, and nothing else.
- **Calibration is tied to the frequency grid it was measured on.** Correction
  terms are interpolated onto the sweep grid; recalibrate if you change the span
  substantially.
- **No S2P and no transmission measurements.** One port, S11 only.
- **The impedance conversion is undefined at a perfect open**, where `1 - S11`
  approaches zero. The denominator is floored at 1e-12, so magnitudes near an
  open are bounded by that floor rather than being physically meaningful.
- **The bundled sample sweeps do not contain a resonance.** Over 20 to
  1000 kHz all four disks behave as near-ideal capacitors: |Z| falls
  monotonically with a log-log slope of -0.85 to -1.00 and a phase between
  about -70 and -90 degrees, implying roughly 3.4, 7.7, 13.2, and 23.2 nF for
  the 10, 20, 27, and 50 mm disks. The fundamental radial resonance of a PZT
  disk this size sits above 1 MHz, so the sweep range stops short of it. The
  data is good, it just measures the capacitive region. Sweep higher to capture
  resonance.
- **The search band and plot axis limits are named constants** at the top of
  `PZT_Impedance_Analyzer` (`RESONANCE_BAND_KHZ`, `F_AXIS_KHZ`). Edit them for
  other devices or wider sweeps.
- **The GUI is not a soak-tested application.** Continuous sweep runs on a MATLAB
  timer, and closing the window mid-sweep is handled but not extensively
  exercised.

---

## License

MIT. See [LICENSE](LICENSE).
