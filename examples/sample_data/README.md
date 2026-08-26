# Sample data

Four one-port Touchstone sweeps of PZT disks, measured on a NanoVNA and
exported with `NanoVNA_Analyzer`. Total size is roughly 76 KB.

| File | Disk | Points | Span |
|---|---|---|---|
| `NanoVNA_Sweep_10_MM_PZT.s1p` | 10 mm | 501 | 20.000 kHz to 1000.000 kHz |
| `NanoVNA_Sweep_20_MM_PZT.s1p` | 20 mm | 501 | 20.000 kHz to 1000.000 kHz |
| `NanoVNA_Sweep_27_MM_PZT.s1p` | 27 mm | 501 | 20.000 kHz to 1000.000 kHz |
| `NanoVNA_Sweep_50_MM_PZT.s1p` | 50 mm | 501 | 20.000 kHz to 1000.000 kHz |

All four use the option line `# Hz S RI R 50`, so frequency is in Hz, S11 is
stored as real and imaginary parts, and the reference impedance is 50 ohm.

## What these sweeps show

Across 20 to 1000 kHz all four disks behave as near-ideal capacitors. |Z| falls
monotonically, the log-log slope runs from -0.85 to -1.00, and the phase sits
between about -70 and -90 degrees. The implied capacitances are roughly:

| Disk | Implied C |
|---|---|
| 10 mm | 3.4 nF |
| 20 mm | 7.7 nF |
| 27 mm | 13.2 nF |
| 50 mm | 23.2 nF |

There is no resonance in this range. The fundamental radial resonance of a PZT
disk this size sits above 1 MHz, so the sweeps stop short of it, and
`PZT_Impedance_Analyzer` correctly reports "no resonance in range" for all four
rather than marking a band edge as though it were a resonance.

These are real measurements, not simulated output. Files exported from
`NanoVNA_Analyzer` while it is in Simulation Mode carry a `! Source: SIMULATED`
header line, and `PZT_Impedance_Analyzer` prints a warning and appends
`[SIMULATED]` to the legend entry when it reads one. These four files predate
that header field, so they carry no `! Source:` line at all.
