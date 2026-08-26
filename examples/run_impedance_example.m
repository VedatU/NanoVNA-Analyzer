% run_impedance_example  Plot the four bundled PZT sweeps without any prompts.
%
% This is the scripted path through PZT_Impedance_Analyzer. It passes the
% bundled sample files explicitly, so it runs end to end with no dialogs and
% no hardware attached. Run PZT_Impedance_Analyzer with no arguments instead
% if you would rather pick the files yourself.
%
% From the repository root:
%     run examples/run_impedance_example.m
%
% Authors:
%   Vedat Ulas
%   Osman Sayginer
%
% Copyright (c) 2026 Vedat Ulas and Osman Sayginer
% Licensed under the MIT License. See LICENSE for details.

thisDir = fileparts(mfilename('fullpath'));
repoRoot = fullfile(thisDir, '..');
addpath(fullfile(repoRoot, 'src'));
addpath(fullfile(repoRoot, 'src', 'drivers'));

sampleDir = fullfile(thisDir, 'sample_data');

files = { ...
    fullfile(sampleDir, 'NanoVNA_Sweep_10_MM_PZT.s1p'), ...
    fullfile(sampleDir, 'NanoVNA_Sweep_20_MM_PZT.s1p'), ...
    fullfile(sampleDir, 'NanoVNA_Sweep_27_MM_PZT.s1p'), ...
    fullfile(sampleDir, 'NanoVNA_Sweep_50_MM_PZT.s1p')};

labels = { ...
    'Disk A (10 mm)', ...
    'Disk B (20 mm)', ...
    'Disk C (27 mm)', ...
    'Disk D (50 mm)'};

PZT_Impedance_Analyzer(files, labels);
