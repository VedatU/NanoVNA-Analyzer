function PZT_Impedance_Analyzer(varargin)
    % PZT_Impedance_Analyzer  Plot electrical impedance of PZT disks from .s1p files.
    %
    %   Reads one or more Touchstone 1.0 .s1p files containing one-port S11 data,
    %   converts to complex input impedance using
    %
    %       Z_in = Z0 * (1 + S11) / (1 - S11)
    %
    %   and draws two figures:
    %     Figure 1  impedance magnitude |Z| and phase angle against frequency
    %     Figure 2  |Z| overlay with the resonance minimum of each disk marked
    %
    %   USAGE
    %     PZT_Impedance_Analyzer()
    %         Opens a file picker. Select any number of .s1p files, using Ctrl or
    %         Shift for a multiple selection. Trace labels are derived from the
    %         file names. This is the normal way to run the tool.
    %
    %     PZT_Impedance_Analyzer(fileList)
    %         fileList is a cell array of paths, for scripted or batch use.
    %
    %     PZT_Impedance_Analyzer(fileList, labelList)
    %         labelList is a matching cell array of legend labels.
    %
    %   This function never fabricates data. If a file is missing or cannot be
    %   parsed it reports the problem and stops. Nothing it plots is synthetic.
    %
    %   See also NANOVNA_ANALYZER.
    %
    % Authors:
    %   Vedat Ulas
    %   Osman Sayginer
    %
    % Copyright (c) 2026 Vedat Ulas and Osman Sayginer
    % Licensed under the MIT License. See LICENSE for details.

    close all;

    %% =========================================================
    % 1. CONFIGURATION
    %% =========================================================
    % Frequency axis limits for the plots, in kHz. The included sample sweeps
    % span 20 kHz to 1000 kHz.
    F_AXIS_KHZ  = [20 1000];
    F_TICKS_KHZ = [20 50 100 200 500 1000];

    % Band searched for the electromechanical resonance minimum, in kHz.
    % Set to the full span by default. The previous default of [150 400] was
    % narrower than the data and reported three of the four bundled disks as
    % resonating at exactly 398.28 kHz, which was simply the last sample inside
    % the window rather than a physical resonance.
    %
    % Note that a minimum inside the search window is not by itself evidence of
    % resonance. See findResonance below, which checks whether the located
    % minimum is a genuine interior dip before reporting it as one.
    RESONANCE_BAND_KHZ = [20 1000];

    % Colour order for the traces, cycled if you load more files than entries.
    PALETTE = [ ...
        0.00 0.45 0.74; ...
        0.85 0.33 0.10; ...
        0.93 0.69 0.13; ...
        0.49 0.18 0.56; ...
        0.47 0.67 0.19; ...
        0.30 0.75 0.93];

    %% =========================================================
    % 2. RESOLVE INPUT FILES
    %% =========================================================
    [filePaths, labels] = resolveInputs(varargin{:});
    if isempty(filePaths)
        fprintf('No files selected. Nothing to do.\n');
        return;
    end

    numDisks = numel(filePaths);
    datasets = cell(1, numDisks);

    fprintf('=========================================================\n');
    fprintf('  PZT IMPEDANCE ANALYZER - IMPORTING S1P DATA\n');
    fprintf('=========================================================\n');

    %% =========================================================
    % 3. IMPORT AND IMPEDANCE CONVERSION
    %% =========================================================
    for k = 1:numDisks
        filePath = filePaths{k};

        if exist(filePath, 'file') ~= 2
            error('PZT_Impedance_Analyzer:FileNotFound', ...
                  ['Touchstone file not found:\n  %s\n\n' ...
                   'This tool does not generate substitute data. Supply a real ' ...
                   'measurement, or export one from NanoVNA_Analyzer.'], filePath);
        end

        [f_hz, s11, z0, srcTag] = parseTouchstoneS1P(filePath);

        if isempty(f_hz)
            error('PZT_Impedance_Analyzer:EmptyFile', ...
                  'No usable data rows were found in:\n  %s', filePath);
        end

        % Z_in = Z0 * (1 + S11) / (1 - S11).
        % Guard the denominator, which approaches zero at an ideal open circuit.
        denom = 1 - s11;
        denom(abs(denom) < 1e-12) = 1e-12;
        Z_in = z0 * ((1 + s11) ./ denom);

        datasets{k} = struct( ...
            'f_kHz',    f_hz / 1e3, ...
            'magZ',     abs(Z_in), ...
            'phaseDeg', angle(Z_in) * (180 / pi), ...
            'label',    labels{k}, ...
            'color',    PALETTE(mod(k - 1, size(PALETTE, 1)) + 1, :));

        fprintf('  Loaded %-24s %4d points, %7.1f to %7.1f kHz, Z0 = %g Ohm\n', ...
            labels{k}, numel(f_hz), f_hz(1)/1e3, f_hz(end)/1e3, z0);

        % Surface the provenance tag written by NanoVNA_Analyzer, if present.
        if strcmpi(srcTag, 'SIMULATED')
            fprintf(2, ['  [WARNING] %s is tagged "Source: SIMULATED". ' ...
                        'It is synthetic data, not a measurement.\n'], labels{k});
            datasets{k}.label = [labels{k} ' [SIMULATED]'];
        end
    end

    %% =========================================================
    % 4. FIGURE 1: IMPEDANCE MAGNITUDE AND PHASE
    %% =========================================================
    fig1 = figure('Name', 'Electrical Impedance of the PZT Disks', ...
                  'Position', [120 100 950 780], 'Color', [0.95 0.96 0.98]);

    tiledlayout(fig1, 2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

    % Panel (a): impedance magnitude
    ax1a = nexttile;
    hold(ax1a, 'on');
    for k = 1:numDisks
        ds = datasets{k};
        plot(ax1a, ds.f_kHz, ds.magZ, 'LineWidth', 1.8, ...
             'Color', ds.color, 'DisplayName', ds.label);
    end
    set(ax1a, 'XScale', 'log', 'YScale', 'log');
    xlim(ax1a, F_AXIS_KHZ);
    xticks(ax1a, F_TICKS_KHZ);
    applyPlotAesthetics(ax1a, '(a) Impedance Magnitude |Z|', ...
        'Frequency (kHz)', 'Impedance Magnitude |Z| (\Omega)');
    legend(ax1a, 'Location', 'northeast', 'FontSize', 9);
    hold(ax1a, 'off');

    % Panel (b): phase angle
    ax1b = nexttile;
    hold(ax1b, 'on');
    for k = 1:numDisks
        ds = datasets{k};
        plot(ax1b, ds.f_kHz, ds.phaseDeg, 'LineWidth', 1.8, ...
             'Color', ds.color, 'DisplayName', ds.label);
    end
    set(ax1b, 'XScale', 'log', 'YScale', 'linear');
    xlim(ax1b, F_AXIS_KHZ);
    ylim(ax1b, [-90 90]);
    xticks(ax1b, F_TICKS_KHZ);
    yticks(ax1b, -90:30:90);
    applyPlotAesthetics(ax1b, '(b) Impedance Phase Angle', ...
        'Frequency (kHz)', 'Phase (Degrees)');
    legend(ax1b, 'Location', 'northeast', 'FontSize', 9);
    hold(ax1b, 'off');

    sgtitle(fig1, 'Electrical impedance of the PZT disks', ...
            'FontSize', 13, 'FontWeight', 'bold');

    %% =========================================================
    % 5. FIGURE 2: RESONANCE COMPARISON
    %% =========================================================
    fig2 = figure('Name', 'Loading Effect on Resonance', ...
                  'Position', [200 150 900 520], 'Color', [0.95 0.96 0.98]);

    ax2 = axes(fig2);
    hold(ax2, 'on');

    fprintf('\nResonance search over %g to %g kHz:\n', ...
        RESONANCE_BAND_KHZ(1), RESONANCE_BAND_KHZ(2));

    anyFound = false;

    for k = 1:numDisks
        ds = datasets{k};
        plot(ax2, ds.f_kHz, ds.magZ, 'LineWidth', 1.8, ...
             'Color', ds.color, 'DisplayName', ds.label);

        [fRes, minZ, status] = findResonance(ds.f_kHz, ds.magZ, RESONANCE_BAND_KHZ);

        switch status
            case 'found'
                anyFound = true;
                plot(ax2, fRes, minZ, 'v', 'MarkerSize', 7, ...
                     'MarkerFaceColor', ds.color, 'MarkerEdgeColor', 'k', ...
                     'HandleVisibility', 'off');
                fprintf('  %-24s f_res = %7.2f kHz, |Z| = %9.2f Ohm\n', ...
                        ds.label, fRes, minZ);

            case 'monotonic'
                % |Z| falls across the whole window and bottoms out at the edge.
                % That is the capacitive skirt below resonance, not a resonance.
                % Marking the edge sample would invent a result, so do not.
                fprintf(['  %-24s no resonance in range. |Z| decreases to the ' ...
                         'sweep edge (%.2f kHz, %.2f Ohm),\n%26s which is ' ...
                         'capacitive behaviour below resonance.\n'], ...
                        ds.label, fRes, minZ, '');

            case 'nodata'
                fprintf('  %-24s no samples in the search band, skipped\n', ds.label);
        end
    end

    if ~anyFound
        fprintf(['\n  NOTE: no interior resonance was found for any trace. The ' ...
                 'sweep range probably\n        sits below the fundamental ' ...
                 'resonance of these disks. Widen the sweep\n        upward to ' ...
                 'capture it.\n']);
    end

    set(ax2, 'XScale', 'log', 'YScale', 'log');
    xlim(ax2, F_AXIS_KHZ);
    xticks(ax2, F_TICKS_KHZ);
    applyPlotAesthetics(ax2, 'Loading effect on resonance', ...
        'Frequency (kHz)', 'Impedance Magnitude |Z| (\Omega)');
    legend(ax2, 'Location', 'northeast', 'FontSize', 10);
    hold(ax2, 'off');

    fprintf('\nPlots rendered successfully.\n');
end

%% =========================================================
% 6. HELPER FUNCTIONS
%% =========================================================

function [filePaths, labels] = resolveInputs(varargin)
    % Build the file list either from arguments or from an interactive picker.

    labels = {};

    if nargin >= 1 && ~isempty(varargin{1})
        filePaths = varargin{1};
        if ischar(filePaths) || isstring(filePaths)
            filePaths = cellstr(filePaths);
        end
        filePaths = filePaths(:).';
    else
        % Start the picker in the bundled sample data folder when it is present,
        % so a fresh clone runs without the user hunting for the examples.
        startDir = defaultSampleDir();

        [files, folder] = uigetfile( ...
            {'*.s1p', 'Touchstone one-port files (*.s1p)'; '*.*', 'All files (*.*)'}, ...
            'Select one or more .s1p files (Ctrl or Shift for multiple)', ...
            startDir, 'MultiSelect', 'on');

        if isequal(files, 0)
            filePaths = {};
            return;
        end

        if ischar(files)
            files = {files};
        end
        filePaths = cellstr(fullfile(folder, files));
        filePaths = filePaths(:).';
    end

    % Labels: caller supplied, otherwise derived from the file names
    if nargin >= 2 && ~isempty(varargin{2})
        labels = varargin{2};
        if ischar(labels) || isstring(labels)
            labels = cellstr(labels);
        end
        labels = labels(:).';
        if numel(labels) ~= numel(filePaths)
            error('PZT_Impedance_Analyzer:LabelMismatch', ...
                  'Supplied %d labels for %d files.', numel(labels), numel(filePaths));
        end
    else
        labels = cell(1, numel(filePaths));
        for k = 1:numel(filePaths)
            [~, base] = fileparts(filePaths{k});
            labels{k} = strrep(base, '_', ' ');
        end
    end
end

function startDir = defaultSampleDir()
    % Locate examples/sample_data relative to this file. Falls back to pwd.
    thisDir = fileparts(mfilename('fullpath'));
    candidate = fullfile(thisDir, '..', 'examples', 'sample_data');
    if exist(candidate, 'dir') == 7
        startDir = candidate;
    else
        startDir = pwd;
    end
end

function [fRes, minZ, status] = findResonance(f_kHz, magZ, bandKHz)
    % Locate an electromechanical resonance, defined as an interior local
    % minimum of |Z| within the search band.
    %
    % Returns status:
    %   'found'      genuine interior dip, fRes and minZ describe it
    %   'monotonic'  |Z| bottoms out at a band edge, so no resonance is in
    %                range. fRes and minZ still describe that edge sample, for
    %                reporting only, and must not be presented as a resonance.
    %   'nodata'     no samples inside the band
    %
    % The edge test matters. A blind min() over a window that lies entirely
    % below resonance returns the last sample in the window, which looks like a
    % result and is not one. A PZT disk below its fundamental behaves as a
    % capacitor, so |Z| falls monotonically as 1/(2*pi*f*C) with no dip at all.

    fRes = NaN;
    minZ = NaN;

    mask = (f_kHz >= bandKHz(1)) & (f_kHz <= bandKHz(2));
    if ~any(mask)
        status = 'nodata';
        return;
    end

    idx = find(mask);
    [minZ, rel] = min(magZ(mask));
    absIdx = idx(rel);
    fRes = f_kHz(absIdx);

    % A minimum sitting on either end of the search window is an edge effect,
    % not a dip. Require at least one sample on each side within the window.
    if absIdx <= idx(1) || absIdx >= idx(end)
        status = 'monotonic';
        return;
    end

    status = 'found';
end

function applyPlotAesthetics(ax, titleStr, xLabelStr, yLabelStr)
    ax.Color = [0.94 0.97 0.99];
    ax.XGrid = 'on';
    ax.YGrid = 'on';
    ax.XMinorGrid = 'on';
    ax.YMinorGrid = 'on';
    ax.GridColor = [0.75 0.80 0.85];
    ax.MinorGridColor = [0.85 0.88 0.92];
    ax.GridAlpha = 0.7;
    ax.MinorGridAlpha = 0.5;
    ax.LineWidth = 1.2;
    ax.Box = 'on';

    title(ax, titleStr, 'FontSize', 11, 'FontWeight', 'bold');
    xlabel(ax, xLabelStr, 'FontSize', 10, 'FontWeight', 'bold');
    ylabel(ax, yLabelStr, 'FontSize', 10, 'FontWeight', 'bold');
end

function [f_hz, s11, z0, srcTag] = parseTouchstoneS1P(filePath)
    % Touchstone 1.0 one-port reader.
    %
    % Handles the option line "# <freq unit> S <format> R <z0>" for the RI, MA
    % and DB formats, and returns the "! Source:" provenance tag when the file
    % carries one, so simulated exports can be flagged downstream.

    z0        = 50;     % reference impedance, overridden by the option line
    freqScale = 1;      % Hz by default
    fmt       = 'RI';   % real and imaginary by default
    srcTag    = '';

    fid = fopen(filePath, 'r');
    if fid == -1
        error('PZT_Impedance_Analyzer:OpenFailed', 'Failed to open file: %s', filePath);
    end
    cleanupObj = onCleanup(@() fclose(fid));

    f_hz = zeros(0, 1);
    a    = zeros(0, 1);
    b    = zeros(0, 1);

    while ~feof(fid)
        rawLine = fgetl(fid);
        if ~ischar(rawLine)
            break;
        end
        lineStr = strtrim(rawLine);

        if isempty(lineStr)
            continue;
        end

        if startsWith(lineStr, '!')
            % Comment line. Pick up the provenance tag written on export.
            tok = regexpi(lineStr, '^!\s*Source:\s*(\S+)', 'tokens', 'once');
            if ~isempty(tok)
                srcTag = tok{1};
            end
            continue;
        end

        if startsWith(lineStr, '#')
            [freqScale, fmt, z0] = parseOptionLine(lineStr, freqScale, fmt, z0);
            continue;
        end

        % Strip any trailing inline comment before parsing numbers
        lineStr = strtrim(extractBefore([lineStr '!'], '!'));

        vals = sscanf(lineStr, '%f');
        if numel(vals) >= 3
            f_hz(end+1, 1) = vals(1) * freqScale; %#ok<AGROW>
            a(end+1, 1)    = vals(2);             %#ok<AGROW>
            b(end+1, 1)    = vals(3);             %#ok<AGROW>
        end
    end

    switch upper(fmt)
        case 'MA'   % magnitude and angle in degrees
            s11 = a .* exp(1j * b * pi / 180);
        case 'DB'   % magnitude in dB and angle in degrees
            s11 = (10 .^ (a / 20)) .* exp(1j * b * pi / 180);
        otherwise   % 'RI', real and imaginary
            s11 = a + 1j * b;
    end
end

function [freqScale, fmt, z0] = parseOptionLine(lineStr, freqScale, fmt, z0)
    % Parse a Touchstone option line, for example "# Hz S RI R 50".
    tokens = split(strtrim(erase(lineStr, '#')));
    tokens = tokens(~cellfun(@isempty, tokens));

    for idx = 1:numel(tokens)
        tok = upper(tokens{idx});
        switch tok
            case 'HZ',  freqScale = 1;
            case 'KHZ', freqScale = 1e3;
            case 'MHZ', freqScale = 1e6;
            case 'GHZ', freqScale = 1e9;
            case {'RI', 'MA', 'DB'}
                fmt = tok;
            case 'R'
                if idx < numel(tokens)
                    parsed = str2double(tokens{idx+1});
                    if ~isnan(parsed) && parsed > 0
                        z0 = parsed;
                    end
                end
        end
    end
end
