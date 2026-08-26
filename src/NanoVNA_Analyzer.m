function NanoVNA_Analyzer()
    % NanoVNA_Analyzer - Primary UI Application for NanoVNA Controller & Analyzer
    % Modular, object-oriented MATLAB application interfacing with NanoVNA hardware.
    % Features auto COM port scanning, chunked high-res frequency sweeping, internal 1-port
    % OSL Vector Error Correction, data smoothing, timestamped logging console, and dual 
    % visualization tabs (Log-Magnitude Return Loss and a hand-drawn Smith Chart).
    % The Smith chart grid is drawn from first principles, no RF Toolbox required.
    %
    % Authors:
    %   Vedat Ulas
    %   Osman Sayginer
    %
    % Copyright (c) 2026 Vedat Ulas and Osman Sayginer
    % Licensed under the MIT License. See LICENSE for details.

    %% =========================================================
    % 0. PATH BOOTSTRAP
    %% =========================================================
    % Resolve the driver folder relative to this file so the app runs from any
    % working directory without the user having to set up the MATLAB path first.
    thisDir = fileparts(mfilename('fullpath'));
    driverDir = fullfile(thisDir, 'drivers');
    if exist(driverDir, 'dir') == 7 && ~contains([path pathsep], [driverDir pathsep])
        addpath(driverDir);
    end

    % Where the calibration preset slots are stored. This deliberately lives in
    % the MATLAB per-user preferences folder rather than the working directory,
    % so running the app never writes stray .mat files into a cloned repository.
    % Change this one line if you would rather keep presets next to your data.
    PRESET_STORE = fullfile(prefdir, 'NanoVNA_Analyzer_Presets.mat');

    %% =========================================================
    % 1. CENTRAL APP STATE REGISTRY
    %% =========================================================
    appState = struct();
    appState.driver         = NanoVNADriver(@logMessage); % Instantiate hardware driver
    appState.driver.ChunkCallback = @(~, ~, f, s) onLiveChunkUpdate(f, s);
    appState.f_vector       = [];       % Master frequency vector (Hz)
    appState.s11_raw        = [];       % Raw measured complex S11 array (Gamma_M)
    appState.s11_cal        = [];       % Calibrated complex S11 array (Gamma_A)
    appState.s11_smooth     = [];       % Filtered S11 array
    appState.history        = {};       % Sliding window array storing up to 5 trial sweeps
    appState.presetSlots    = cell(1, 5); % 5 self-contained internal calibration preset slots
    
    % Calibration Storage Arrays
    appState.gamma_open     = [];       % Open reference sweep
    appState.gamma_short    = [];       % Short reference sweep
    appState.gamma_load     = [];       % Load reference sweep
    appState.f_vector_cal   = [];       % Frequency vector when standards were measured
    
    % Calibration Error Terms Struct
    appState.calTerms = struct(...
        'ED', [], ...           % Directivity vector
        'ES', [], ...           % Source Match vector
        'ER', [], ...           % Reflection Tracking vector
        'isCalibrated', false ...% Calibration validity flag
    );

    % Execution Control Flags
    appState.isSweeping = false;
    appState.contSweep  = false;
    appState.timerObj   = [];

    % Clean up any lingering background timers from previous runs
    oldTimers = timerfindall('Name', 'NanoVNA_ContSweepTimer');
    if ~isempty(oldTimers)
        try
            stop(oldTimers);
            delete(oldTimers);
        catch
        end
    end

    %% =========================================================
    % 2. PROGRAMMATIC UI CREATION (uifigure & uigridlayout)
    %% =========================================================
    fig = uifigure('Name', 'NanoVNA Controller & Vector Network Analyzer', ...
                   'Position', [100 80 1280 820], ...
                   'Color', [0.95 0.96 0.98], ...
                   'CloseRequestFcn', @(~,~) onCloseApp());

    % Root Grid Layout (Left Controls: 390px, Right Visuals: 1x)
    mainGrid = uigridlayout(fig, [1 2], 'ColumnWidth', {390, '1x'}, ...
                            'Padding', [12 12 12 12], 'ColumnSpacing', 12);

    % Left Column Layout (6 Vertical Panels / Regions)
    leftCol = uigridlayout(mainGrid, [6 1], ...
        'RowHeight', {115, 145, 165, 105, 125, '1x'}, ...
        'Padding', [0 0 0 0], 'RowSpacing', 6);

    % ---------------------------------------------------------
    % PANEL 1: Connection & Serial Control
    % ---------------------------------------------------------
    connPanel = uipanel(leftCol, 'Title', '1. Hardware Connection', ...
                        'FontWeight', 'bold', 'FontSize', 11, 'BackgroundColor', [1 1 1]);
    connGrid = uigridlayout(connPanel, [3 3], ...
        'ColumnWidth', {55, '1x', 85}, 'RowHeight', {26, 26, 24}, ...
        'Padding', [8 8 8 8], 'RowSpacing', 5, 'ColumnSpacing', 6);

    uilabel(connGrid, 'Text', 'Port:', 'FontWeight', 'bold');
    ddPort = uidropdown(connGrid);
    btnRefreshPorts = uibutton(connGrid, 'Text', 'Refresh', ...
                               'ButtonPushedFcn', @(~,~) populateCOMPorts());

    uilabel(connGrid, 'Text', 'Baud:', 'FontWeight', 'bold');
    ddBaud = uidropdown(connGrid, 'Items', {'115200', '57600', '9600'}, 'Value', '115200');
    btnConnect = uibutton(connGrid, 'Text', 'Connect', 'FontWeight', 'bold', ...
                          'BackgroundColor', [0.85 0.95 0.85], ...
                          'ButtonPushedFcn', @(~,~) toggleConnection());

    chkSimulation = uicheckbox(connGrid, 'Text', 'Simulation Mode', ...
                              'Value', false, 'ValueChangedFcn', @(~,~) onSimModeChanged());

    chkVerbose = uicheckbox(connGrid, 'Text', 'Verbose', ...
                            'Value', false, 'ValueChangedFcn', @(~,~) onVerboseChanged());

    ddSpeedMode = uidropdown(connGrid, 'Items', {'Precision', 'Fast (Max Speed)'}, 'Value', 'Precision', ...
                             'ValueChangedFcn', @(~,~) onSpeedModeChanged());

    % ---------------------------------------------------------
    % PANEL 2: Sweep Parameters
    % ---------------------------------------------------------
    paramPanel = uipanel(leftCol, 'Title', '2. Sweep Configuration', ...
                         'FontWeight', 'bold', 'FontSize', 11, 'BackgroundColor', [1 1 1]);
    paramGrid = uigridlayout(paramPanel, [4 2], ...
        'ColumnWidth', {'1x', '1x'}, 'RowHeight', {24, 24, 24, 24}, ...
        'Padding', [6 6 6 6], 'RowSpacing', 3);

    uilabel(paramGrid, 'Text', 'Freq Unit:');
    ddFreqUnit = uidropdown(paramGrid, 'Items', {'kHz', 'MHz', 'GHz'}, 'Value', 'kHz', ...
                            'ValueChangedFcn', @(~,~) onFreqUnitChanged());

    lblStartFreq = uilabel(paramGrid, 'Text', 'Start Freq (kHz):');
    numStartFreq = uieditfield(paramGrid, 'numeric', 'Value', 50, 'Limits', [0.001 3000000]);
    numStartFreq.ValueChangedFcn = @(~,~) updateChunkInfo();

    lblStopFreq = uilabel(paramGrid, 'Text', 'Stop Freq (kHz):');
    numStopFreq = uieditfield(paramGrid, 'numeric', 'Value', 1000, 'Limits', [0.001 3000000]);
    numStopFreq.ValueChangedFcn = @(~,~) updateChunkInfo();

    uilabel(paramGrid, 'Text', 'Sweep Divisions (101 pts/div):');
    spinDivisions = uispinner(paramGrid, 'Limits', [1 1000], 'Value', 5, 'Step', 1);
    spinDivisions.ValueChangedFcn = @(~,~) updateChunkInfo();

    % ---------------------------------------------------------
    % PANEL 3: 1-Port OSL Calibration Engine
    % ---------------------------------------------------------
    calPanel = uipanel(leftCol, 'Title', '3. 1-Port OSL Vector Calibration', ...
                       'FontWeight', 'bold', 'FontSize', 11, 'BackgroundColor', [1 1 1]);
    calGrid = uigridlayout(calPanel, [4 3], ...
        'ColumnWidth', {'1x', '1x', '1x'}, 'RowHeight', {26, 26, 24, 26}, ...
        'Padding', [6 6 6 6], 'RowSpacing', 4, 'ColumnSpacing', 6);

    btnCalOpen  = uibutton(calGrid, 'Text', 'Meas OPEN', 'ButtonPushedFcn', @(~,~) measureStandard('OPEN'));
    btnCalShort = uibutton(calGrid, 'Text', 'Meas SHORT', 'ButtonPushedFcn', @(~,~) measureStandard('SHORT'));
    btnCalLoad  = uibutton(calGrid, 'Text', 'Meas LOAD', 'ButtonPushedFcn', @(~,~) measureStandard('LOAD'));

    btnApplyCal = uibutton(calGrid, 'Text', 'Compute OSL Terms', 'FontWeight', 'bold', ...
                           'BackgroundColor', [0.88 0.93 1.0], 'ButtonPushedFcn', @(~,~) computeCalibrationTerms());
    btnApplyCal.Layout.Column = [1 2];

    btnClearCal = uibutton(calGrid, 'Text', 'Clear Cal', 'ButtonPushedFcn', @(~,~) clearCalibration());

    chkEnableCal = uicheckbox(calGrid, 'Text', 'Enable Correction', 'Value', true, ...
                              'Enable', 'off', 'ValueChangedFcn', @(~,~) updatePlots());
    chkEnableCal.Layout.Column = [1 2];

    lblCalStatus = uilabel(calGrid, 'Text', 'Status: Uncalibrated', ...
                           'FontColor', [0.7 0.2 0.2], 'FontWeight', 'bold');

    btnManagePresets = uibutton(calGrid, 'Text', 'Calibration Preset Manager (5 Slots)', ...
                             'FontWeight', 'bold', 'BackgroundColor', [0.88 0.94 1.0], ...
                             'ButtonPushedFcn', @(~,~) openPresetsPopup());
    btnManagePresets.Layout.Column = [1 3];

    % ---------------------------------------------------------
    % PANEL 4: Sweep Execution
    % ---------------------------------------------------------
    execPanel = uipanel(leftCol, 'Title', '4. Measurement Sweep Execution', ...
                        'FontWeight', 'bold', 'FontSize', 11, 'BackgroundColor', [1 1 1]);
    execGrid = uigridlayout(execPanel, [2 4], ...
        'ColumnWidth', {'1x', '1x', '1x', 75}, 'RowHeight', {28, 24}, ...
        'Padding', [6 6 6 6], 'RowSpacing', 4, 'ColumnSpacing', 6);

    btnSingleSweep = uibutton(execGrid, 'Text', 'SINGLE SWEEP', 'FontWeight', 'bold', ...
                              'FontSize', 11, 'BackgroundColor', [0.82 0.95 0.85], ...
                              'ButtonPushedFcn', @(~,~) runSingleSweep());
    btnSingleSweep.Layout.Column = [1 2];

    chkContSweep = uicheckbox(execGrid, 'Text', 'Continuous Sweep', 'FontWeight', 'bold', ...
                              'FontSize', 10, 'Value', false, ...
                              'ValueChangedFcn', @(~, e) toggleContinuousSweep(e.Value));

    btnAbortSweep = uibutton(execGrid, 'Text', 'ABORT', 'FontWeight', 'bold', ...
                             'FontSize', 11, 'BackgroundColor', [0.98 0.85 0.85], ...
                             'ButtonPushedFcn', @(~,~) abortCurrentSweep());

    uilabel(execGrid, 'Text', 'Sweep Interval (s):', 'FontWeight', 'bold', 'FontSize', 9);
    spinSweepInterval = uispinner(execGrid, 'Limits', [0.2 60.0], 'Value', 1.0, 'Step', 0.5, ...
                                  'FontSize', 9, 'ValueChangedFcn', @(~,~) onSweepIntervalChanged());

    uilabel(execGrid, 'Text', 'Chunk Pause (ms):', 'FontWeight', 'bold', 'FontSize', 9);
    spinChunkPause = uispinner(execGrid, 'Limits', [10 2000], 'Value', 1000, 'Step', 50, ...
                               'FontSize', 9, 'ValueChangedFcn', @(~,~) onChunkPauseChanged());

    % ---------------------------------------------------------
    % PANEL 5: Data Smoothing, Overlay & Export
    % ---------------------------------------------------------
    filterPanel = uipanel(leftCol, 'Title', '5. Data Smoothing, Overlay & Export', ...
                          'FontWeight', 'bold', 'FontSize', 11, 'BackgroundColor', [1 1 1]);
    filterGrid = uigridlayout(filterPanel, [3 3], ...
        'ColumnWidth', {120, '1x', 85}, 'RowHeight', {24, 24, 24}, ...
        'Padding', [6 6 6 6], 'RowSpacing', 4, 'ColumnSpacing', 6);

    uilabel(filterGrid, 'Text', 'Smoothing Method:');
    ddFilterMethod = uidropdown(filterGrid, 'Items', ...
        {'None', 'Moving Average (movmean)', 'Savitzky-Golay (sgolay)', 'Median (movmedian)', 'Gaussian'}, ...
        'Value', 'Moving Average (movmean)', 'ValueChangedFcn', @(~,~) updatePlots());
    ddFilterMethod.Layout.Column = [2 3];

    uilabel(filterGrid, 'Text', 'Window (Pts):');
    spinSmoothWin = uispinner(filterGrid, 'Limits', [1 101], 'Value', 5, ...
                              'Step', 2, 'ValueChangedFcn', @(~,~) updatePlots());

    btnExportS1P = uibutton(filterGrid, 'Text', 'Export S1P', 'FontWeight', 'bold', ...
                            'ButtonPushedFcn', @(~,~) exportTouchstoneS1P());

    chkOverlayHistory = uicheckbox(filterGrid, 'Text', 'Overlay Last 5 Sweeps', ...
                                  'FontWeight', 'bold', 'Value', false, ...
                                  'ValueChangedFcn', @(~,~) updatePlots());
    chkOverlayHistory.Layout.Column = [1 2];

    btnClearHistory = uibutton(filterGrid, 'Text', 'Clear Overlay', ...
                               'ButtonPushedFcn', @(~,~) clearTrialHistory());

    % ---------------------------------------------------------
    % PANEL 6: Timestamped System Logging Console
    % ---------------------------------------------------------
    logPanel = uipanel(leftCol, 'Title', 'System Log Console', ...
                       'FontWeight', 'bold', 'FontSize', 11, 'BackgroundColor', [1 1 1]);
    logGrid = uigridlayout(logPanel, [1 1], 'Padding', [4 4 4 4]);
    txtLog = uitextarea(logGrid, 'Value', {'System initialized. Ready.'}, ...
                        'Editable', 'off', 'FontName', 'Consolas', 'FontSize', 9);

    % ---------------------------------------------------------
    % RIGHT COLUMN: Visualization Tab Group
    % ---------------------------------------------------------
    plotTabGroup = uitabgroup(mainGrid);
    
    % Tab 1: Log-Magnitude Return Loss
    tabLogMag = uitab(plotTabGroup, 'Title', 'Log-Magnitude (Return Loss)');
    tabLogMagGrid = uigridlayout(tabLogMag, [1 1], 'Padding', [8 8 8 8]);
    axLogMag = uiaxes(tabLogMagGrid);
    applyPlotAesthetics(axLogMag, 'S11 Return Loss (Log-Magnitude)', 'Frequency (MHz)', 'Return Loss |S11| (dB)');

    % Tab 2: Smith Chart
    tabSmith = uitab(plotTabGroup, 'Title', 'Smith Chart (Impedance)');
    tabSmithGrid = uigridlayout(tabSmith, [1 1], 'Padding', [8 8 8 8]);
    axSmith = uiaxes(tabSmithGrid);
    applyPlotAesthetics(axSmith, 'Smith Chart (Complex S11 / Z_in)', 'Real Reflection (u)', 'Imaginary Reflection (v)');
    axSmith.DataAspectRatio = [1 1 1];
    
    % Tab 3: VSWR & Phase
    tabVSWR = uitab(plotTabGroup, 'Title', 'VSWR & Phase');
    tabVSWRGrid = uigridlayout(tabVSWR, [2 1], 'Padding', [8 8 8 8], 'RowSpacing', 8);
    axVSWR = uiaxes(tabVSWRGrid);
    applyPlotAesthetics(axVSWR, 'Voltage Standing Wave Ratio (VSWR)', 'Frequency (MHz)', 'VSWR (:1)');
    axPhase = uiaxes(tabVSWRGrid);
    applyPlotAesthetics(axPhase, 'S11 Phase Response', 'Frequency (MHz)', 'Phase (Degrees)');

    %% =========================================================
    % 3. INITIALIZATION & SETUP PROCEDURES
    %% =========================================================
    populateCOMPorts();
    updateChunkInfo();
    onSimModeChanged();
    drawCustomSmithChartGrid(axSmith);
    
    % Load persistent internal preset slots store
    loadPresetSlotsStore();
    
    % Initial welcome log
    logMessage('NanoVNA MATLAB Controller & Analyzer App Ready.');
    logMessage('Auto-scanned serial ports. Select a port and press Connect.');
    logMessage('Tick the Simulation Mode box only if you want synthetic test data.');

    %% =========================================================
    % 4. HELPER & EVENT CALLBACK FUNCTIONS
    %% =========================================================

    function logMessage(msg)
        % Append timestamped system log [HH:MM:SS] to txtLog
        tStr = char(datetime('now', 'Format', 'HH:mm:ss'));
        formattedMsg = sprintf('[%s] %s', tStr, msg);
        
        try
            currentLogs = txtLog.Value;
            if ischar(currentLogs), currentLogs = {currentLogs}; end
            txtLog.Value = [currentLogs; {formattedMsg}];
            % Auto scroll to bottom line
            scroll(txtLog, 'bottom');
        catch
            fprintf('%s\n', formattedMsg);
        end
    end

    function onLiveChunkUpdate(f_partial, s11_partial)
        % Live real-time plot rendering as each chunk is received
        appState.f_vector = f_partial;
        appState.s11_raw = s11_partial;
        applyOSLCorrection();
        updatePlots();
        drawnow limitrate;
    end

    function populateCOMPorts()
        % Auto-scan and populate COM port dropdown menu
        logMessage('Scanning available COM ports on host system...');
        ports = NanoVNADriver.scanPorts();
        ddPort.Items = ports;
        if ~isempty(ports)
            % Prefer a real serial port over SIMULATION when one is available
            physicalPorts = ports(~strcmpi(ports, 'SIMULATION'));
            if ~isempty(physicalPorts)
                ddPort.Value = physicalPorts{1};
            else
                ddPort.Value = ports{1};
            end
        end
        logMessage(sprintf('Found %d serial port target(s).', length(ports)));
    end

    function onSimModeChanged()
        isSim = chkSimulation.Value;
        appState.driver.IsSimulated = isSim;
        if isSim
            logMessage('Simulation Mode activated (Mock Hardware).');
        else
            logMessage('Hardware Serial Mode selected.');
        end
    end

    function onVerboseChanged()
        appState.driver.Verbose = chkVerbose.Value;
        if chkVerbose.Value
            logMessage('Verbose Command Logging ENABLED.');
        else
            logMessage('Verbose Command Logging DISABLED.');
        end
    end

    function onSpeedModeChanged()
        if contains(ddSpeedMode.Value, 'Precision')
            appState.driver.SpeedMode = 'PRECISION';
            logMessage('Sweep mode set to PRECISION (Extra Settling Pause).');
        else
            appState.driver.SpeedMode = 'FAST';
            logMessage('Sweep mode set to FAST (Maximum Speed).');
        end
    end

    function toggleConnection()
        if appState.driver.IsConnected && ~appState.driver.IsSimulated
            appState.driver.disconnect();
            btnConnect.Text = 'Connect';
            btnConnect.BackgroundColor = [0.85 0.95 0.85];
        else
            port = ddPort.Value;
            baud = str2double(ddBaud.Value);
            isSim = chkSimulation.Value;
            
            success = appState.driver.connect(port, baud, isSim);
            if success
                btnConnect.Text = 'Disconnect';
                btnConnect.BackgroundColor = [0.95 0.85 0.85];
            else
                btnConnect.Text = 'Connect';
                btnConnect.BackgroundColor = [0.85 0.95 0.85];
                uialert(fig, sprintf(['Could not open serial port %s.\n\n' ...
                    'The driver is NOT connected and will not produce any data. ' ...
                    'Check the cable and the port selection, or tick Simulation ' ...
                    'Mode if you deliberately want synthetic data.'], port), ...
                    'Connection Failed');
            end
        end
    end

    function [mult, unitStr] = getFreqMultiplier()
        if exist('ddFreqUnit', 'var') && isvalid(ddFreqUnit)
            unitStr = ddFreqUnit.Value;
        else
            unitStr = 'kHz';
        end
        switch unitStr
            case 'kHz'
                mult = 1e3;
            case 'GHz'
                mult = 1e9;
            otherwise % 'MHz'
                mult = 1e6;
        end
    end

    function onFreqUnitChanged()
        [~, unitStr] = getFreqMultiplier();
        lblStartFreq.Text = sprintf('Start Freq (%s):', unitStr);
        lblStopFreq.Text = sprintf('Stop Freq (%s):', unitStr);
        xlabel(axLogMag, sprintf('Frequency (%s)', unitStr));
        xlabel(axVSWR, sprintf('Frequency (%s)', unitStr));
        xlabel(axPhase, sprintf('Frequency (%s)', unitStr));
        updateChunkInfo();
        if ~isempty(appState.f_vector)
            updatePlots();
        end
    end

    function pts = getTotalPoints()
        numDivs = spinDivisions.Value;
        % Native chunk size is 101 points with 1-point overlap per chunk boundary:
        % 1 div = 101 pts (1 chunk)
        % 2 divs = 201 pts (2 chunks)
        % 5 divs = 501 pts (5 chunks)
        pts = (numDivs * 100) + 1;
    end

    function updateChunkInfo()
        [mult, unitStr] = getFreqMultiplier();
        fStart = numStartFreq.Value * mult;
        fStop = numStopFreq.Value * mult;
        numDivs = spinDivisions.Value;
        pts = getTotalPoints();
        
        if fStop <= fStart
            logMessage('[WARN] Stop Frequency must be greater than Start Frequency.');
        end
        
        % Update status prompt
        logMessage(sprintf('Configuration updated: %.2f - %.2f %s (%d division(s) = %d total points).', ...
            numStartFreq.Value, numStopFreq.Value, unitStr, numDivs, pts));
    end

    %% =========================================================
    % 5. SWEEP EXECUTION & CALIBRATION ENGINE
    %% =========================================================

    function runSingleSweep()
        if ~exist('fig', 'var') || ~isvalid(fig) || ~isvalid(btnSingleSweep) || appState.isSweeping, return; end
        appState.isSweeping = true;
        
        btnSingleSweep.Enable = 'off';
        btnSingleSweep.Text = 'SWEEPING...';
        btnSingleSweep.BackgroundColor = [0.90 0.90 0.90];
        
        [mult, ~] = getFreqMultiplier();
        fStart = numStartFreq.Value * mult;
        fStop = numStopFreq.Value * mult;
        pts = getTotalPoints();
        
        % Auto-connect driver if not already initialized
        if ~appState.driver.IsConnected
            toggleConnection();
        end

        % Refuse to sweep without a connection rather than quietly yielding data
        if ~appState.driver.IsConnected
            logMessage('[ERROR] Sweep cancelled: no hardware connection.');
            appState.isSweeping = false;
            if isvalid(btnSingleSweep)
                btnSingleSweep.Enable = 'on';
                btnSingleSweep.Text = 'SINGLE SWEEP';
                btnSingleSweep.BackgroundColor = [0.82 0.95 0.85];
            end
            return;
        end
        
        % Execute chunked sweep
        try
            [appState.f_vector, appState.s11_raw] = ...
                appState.driver.executeChunkedSweep(fStart, fStop, pts, 'DUT');
            
            % Apply 1-port OSL error correction if calibrated
            applyOSLCorrection();
            
            % Render updated plots
            updatePlots();
            
            % Store completed trial in sliding window history
            pushToHistory();
            
        catch ME
            logMessage(sprintf('[ERROR] Sweep failed: %s', ME.message));
        end
        
        appState.isSweeping = false;
        
        % Re-enable button if continuous sweep is not active and button is valid
        if ~chkContSweep.Value && isvalid(btnSingleSweep)
            btnSingleSweep.Enable = 'on';
            btnSingleSweep.Text = 'SINGLE SWEEP';
            btnSingleSweep.BackgroundColor = [0.82 0.95 0.85];
        end
    end

    function pushToHistory()
        if isempty(appState.f_vector) || isempty(appState.s11_smooth), return; end
        
        tStr = char(datetime('now', 'Format', 'HH:mm:ss'));
        trialStruct = struct(...
            'f_vector', appState.f_vector, ...
            's11_display', appState.s11_smooth, ...
            'time', tStr);
            
        if isempty(appState.history)
            appState.history = {trialStruct};
        else
            appState.history{end+1} = trialStruct;
            if length(appState.history) > 5
                appState.history(1) = []; % Retain sliding window of last 5 trials
            end
        end
    end

    function clearTrialHistory()
        appState.history = {};
        logMessage('Cleared trial overlay history.');
        updatePlots();
    end

    function onSweepIntervalChanged()
        intervalSec = spinSweepInterval.Value;
        logMessage(sprintf('Continuous sweep interval set to %.2f seconds.', intervalSec));
        if appState.contSweep && ~isempty(appState.timerObj) && isvalid(appState.timerObj)
            try
                stop(appState.timerObj);
                appState.timerObj.Period = intervalSec;
                start(appState.timerObj);
            catch
            end
        end
    end

    function onChunkPauseChanged()
        pauseMs = spinChunkPause.Value;
        pauseSec = pauseMs / 1000;
        appState.driver.CustomChunkPause = pauseSec;
        logMessage(sprintf('Hardware chunk settling pause set to %d ms (%.3f s).', pauseMs, pauseSec));
    end

    function toggleContinuousSweep(enable)
        if enable
            appState.contSweep = true;
            if isvalid(btnSingleSweep)
                btnSingleSweep.Enable = 'off';
                btnSingleSweep.Text = 'SWEEPING...';
                btnSingleSweep.BackgroundColor = [0.90 0.90 0.90];
            end
            
            intervalSec = spinSweepInterval.Value;
            logMessage(sprintf('Started continuous background sweep (%.2fs interval).', intervalSec));
            
            % Stop and delete any existing timer
            if ~isempty(appState.timerObj) && isvalid(appState.timerObj)
                try
                    stop(appState.timerObj);
                    delete(appState.timerObj);
                catch
                end
            end
            
            appState.timerObj = timer('Name', 'NanoVNA_ContSweepTimer', ...
                'ExecutionMode', 'fixedSpacing', ...
                'Period', intervalSec, 'TimerFcn', @(~,~) triggerContSweep());
            start(appState.timerObj);
        else
            appState.contSweep = false;
            if ~isempty(appState.timerObj) && isvalid(appState.timerObj)
                try
                    stop(appState.timerObj);
                    delete(appState.timerObj);
                catch
                end
                appState.timerObj = [];
            end
            if isvalid(btnSingleSweep)
                btnSingleSweep.Enable = 'on';
                btnSingleSweep.Text = 'SINGLE SWEEP';
                btnSingleSweep.BackgroundColor = [0.82 0.95 0.85];
            end
            logMessage('Stopped continuous background sweep.');
        end
    end

    function abortCurrentSweep()
        logMessage('[ABORT] Halting live measurement sweep...');
        
        if ~isempty(appState.driver)
            appState.driver.abortSweep();
        end
        
        if chkContSweep.Value
            chkContSweep.Value = false;
            toggleContinuousSweep(false);
        end
        
        appState.isSweeping = false;
        btnSingleSweep.Enable = 'on';
        btnSingleSweep.Text = 'SINGLE SWEEP';
        btnSingleSweep.BackgroundColor = [0.82 0.95 0.85];
        
        % Void current active measurement arrays
        appState.s11_raw = [];
        appState.s11_cal = [];
        appState.s11_smooth = [];
        
        logMessage('[ABORT] Active measurement halted and voided.');
    end

    function loadPresetSlotsStore()
        storePath = PRESET_STORE;
        if exist(storePath, 'file') == 2
            try
                d = load(storePath, 'presetSlots');
                if isfield(d, 'presetSlots') && iscell(d.presetSlots) && length(d.presetSlots) == 5
                    appState.presetSlots = d.presetSlots;
                end
            catch
            end
        end
    end

    function savePresetSlotsStore()
        storePath = PRESET_STORE;
        try
            presetSlots = appState.presetSlots;
            save(storePath, 'presetSlots');
        catch ME
            logMessage(sprintf('[ERROR] Failed to write preset store: %s', ME.message));
        end
    end

    function openPresetsPopup()
        popFig = uifigure('Name', 'Calibration Presets Manager', ...
                          'Position', [350 200 620 440], ...
                          'WindowStyle', 'modal', ...
                          'Color', [0.96 0.97 0.98]);

        popGrid = uigridlayout(popFig, [7 1], ...
            'RowHeight', {30, 56, 56, 56, 56, 56, 35}, ...
            'Padding', [12 12 12 12], 'RowSpacing', 6);

        titleLbl = uilabel(popGrid, 'Text', 'Self-Contained Calibration Presets (5 Slots)', ...
                           'FontWeight', 'bold', 'FontSize', 13, 'HorizontalAlignment', 'center');
        titleLbl.Layout.Row = 1;

        slotLabels = cell(1, 5);

        for i = 1:5
            pnl = uipanel(popGrid, 'Title', sprintf('Preset Slot %d', i), ...
                          'FontWeight', 'bold', 'BackgroundColor', [1 1 1]);
            pnl.Layout.Row = i + 1;
            
            pGrid = uigridlayout(pnl, [1 4], ...
                'ColumnWidth', {'1x', 95, 60, 55}, 'Padding', [4 4 4 4], 'ColumnSpacing', 6);

            slotLabels{i} = uilabel(pGrid, 'Text', getSlotInfoText(i), 'FontSize', 10, 'FontWeight', 'bold');

            btnSaveSlot = uibutton(pGrid, 'Text', 'Save Active', 'FontWeight', 'bold', ...
                                   'BackgroundColor', [0.90 0.95 1.0], ...
                                   'ButtonPushedFcn', @(~,~) saveSlotAction(i));

            btnLoadSlot = uibutton(pGrid, 'Text', 'Load', 'FontWeight', 'bold', ...
                                   'BackgroundColor', [0.85 0.95 0.85], ...
                                   'ButtonPushedFcn', @(~,~) loadSlotAction(i));

            btnClearSlot = uibutton(pGrid, 'Text', 'Clear', ...
                                    'ButtonPushedFcn', @(~,~) clearSlotAction(i));
        end

        btnClose = uibutton(popGrid, 'Text', 'Close Manager', 'FontWeight', 'bold', ...
                            'ButtonPushedFcn', @(~,~) delete(popFig));
        btnClose.Layout.Row = 7;

        function txt = getSlotInfoText(idx)
            if isempty(appState.presetSlots) || length(appState.presetSlots) < idx || isempty(appState.presetSlots{idx})
                txt = '[ Empty Slot ]';
            else
                ps = appState.presetSlots{idx};
                divs = max(1, round(ps.totalPoints / 101));
                if isfield(ps, 'divisions'), divs = ps.divisions; end
                txt = sprintf('%.2f-%.2f %s | %d Divs (%d Pts) [%s]', ...
                    ps.startFreq, ps.stopFreq, ps.freqUnit, divs, ps.totalPoints, ps.date);
            end
        end

        function saveSlotAction(idx)
            if ~appState.calTerms.isCalibrated
                uialert(popFig, 'Please measure or compute OSL calibration before saving to a slot.', 'No Active Calibration');
                return;
            end
            
            [~, unitStr] = getFreqMultiplier();
            slotStruct = struct(...
                'slotIdx', idx, ...
                'name', sprintf('Slot %d (%.0f-%.0f %s)', idx, numStartFreq.Value, numStopFreq.Value, unitStr), ...
                'date', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm')), ...
                'freqUnit', ddFreqUnit.Value, ...
                'startFreq', numStartFreq.Value, ...
                'stopFreq', numStopFreq.Value, ...
                'divisions', spinDivisions.Value, ...
                'totalPoints', getTotalPoints(), ...
                'f_vector_cal', appState.f_vector_cal, ...
                'gamma_open', appState.gamma_open, ...
                'gamma_short', appState.gamma_short, ...
                'gamma_load', appState.gamma_load, ...
                'ED', appState.calTerms.ED, ...
                'ES', appState.calTerms.ES, ...
                'ER', appState.calTerms.ER ...
            );
            
            appState.presetSlots{idx} = slotStruct;
            savePresetSlotsStore();
            slotLabels{idx}.Text = getSlotInfoText(idx);
            logMessage(sprintf('Saved active calibration and config into Preset Slot %d.', idx));
        end

        function loadSlotAction(idx)
            if isempty(appState.presetSlots) || length(appState.presetSlots) < idx || isempty(appState.presetSlots{idx})
                uialert(popFig, sprintf('Preset Slot %d is currently empty.', idx), 'Empty Slot');
                return;
            end
            
            ps = appState.presetSlots{idx};
            
            % Restore calibration into appState
            appState.f_vector_cal   = ps.f_vector_cal;
            appState.gamma_open     = ps.gamma_open;
            appState.gamma_short    = ps.gamma_short;
            appState.gamma_load     = ps.gamma_load;
            appState.calTerms.ED    = ps.ED;
            appState.calTerms.ES    = ps.ES;
            appState.calTerms.ER    = ps.ER;
            appState.calTerms.isCalibrated = true;
            
            % Update UI inputs
            if isfield(ps, 'freqUnit') && any(strcmp(ddFreqUnit.Items, ps.freqUnit))
                ddFreqUnit.Value = ps.freqUnit;
            end
            if isfield(ps, 'startFreq'), numStartFreq.Value = ps.startFreq; end
            if isfield(ps, 'stopFreq'), numStopFreq.Value = ps.stopFreq; end
            if isfield(ps, 'divisions')
                spinDivisions.Value = ps.divisions;
            elseif isfield(ps, 'totalPoints')
                spinDivisions.Value = max(1, round(ps.totalPoints / 101));
            end
            
            onFreqUnitChanged();
            
            btnCalOpen.Text = 'OPEN (Slot)';  btnCalOpen.BackgroundColor = [0.85 0.95 0.85];
            btnCalShort.Text = 'SHORT (Slot)'; btnCalShort.BackgroundColor = [0.85 0.95 0.85];
            btnCalLoad.Text = 'LOAD (Slot)';  btnCalLoad.BackgroundColor = [0.85 0.95 0.85];
            
            chkEnableCal.Enable = 'on';
            chkEnableCal.Value = true;
            lblCalStatus.Text = sprintf('Loaded Slot %d', idx);
            lblCalStatus.FontColor = [0.1 0.6 0.2];
            
            logMessage(sprintf('Loaded Preset Slot %d (%.2f - %.2f %s, %d divisions).', ...
                idx, ps.startFreq, ps.stopFreq, ps.freqUnit, spinDivisions.Value));
                
            if ~isempty(appState.s11_raw)
                applyOSLCorrection();
                updatePlots();
            end
            
            delete(popFig);
        end

        function clearSlotAction(idx)
            appState.presetSlots{idx} = [];
            savePresetSlotsStore();
            slotLabels{idx}.Text = getSlotInfoText(idx);
            logMessage(sprintf('Cleared Preset Slot %d.', idx));
        end
    end

    function onCloseApp()
        % Clean up continuous sweep timer
        if ~isempty(appState.timerObj) && isvalid(appState.timerObj)
            try
                stop(appState.timerObj);
                delete(appState.timerObj);
            catch
            end
            appState.timerObj = [];
        end
        
        % Disconnect serial driver
        if ~isempty(appState.driver)
            try
                appState.driver.disconnect();
            catch
            end
        end
        
        if exist('fig', 'var') && isvalid(fig)
            delete(fig);
        end
    end

    function triggerContSweep()
        if exist('fig', 'var') && isvalid(fig) && isvalid(btnSingleSweep) && ~appState.isSweeping
            runSingleSweep();
        end
    end

    function measureStandard(typeStr)
        % Capture Open, Short, or Load standard array across target frequency range
        [mult, ~] = getFreqMultiplier();
        fStart = numStartFreq.Value * mult;
        fStop = numStopFreq.Value * mult;
        pts = getTotalPoints();
        
        if ~appState.driver.IsConnected
            toggleConnection();
        end
        
        logMessage(sprintf('Measuring OSL Standard [%s]...', typeStr));
        
        try
            [f_vec_std, s11_std] = appState.driver.executeChunkedSweep(fStart, fStop, pts, typeStr);
            
            switch upper(typeStr)
                case 'OPEN'
                    appState.gamma_open = s11_std;
                    btnCalOpen.Text = 'OPEN (Done)';
                    btnCalOpen.BackgroundColor = [0.85 0.95 0.85];
                case 'SHORT'
                    appState.gamma_short = s11_std;
                    btnCalShort.Text = 'SHORT (Done)';
                    btnCalShort.BackgroundColor = [0.85 0.95 0.85];
                case 'LOAD'
                    appState.gamma_load = s11_std;
                    btnCalLoad.Text = 'LOAD (Done)';
                    btnCalLoad.BackgroundColor = [0.85 0.95 0.85];
            end
            
            appState.f_vector_cal = f_vec_std;
            logMessage(sprintf('Standard [%s] sweep acquired (%d points).', typeStr, length(s11_std)));
        catch ME
            logMessage(sprintf('[ERROR] Standard [%s] measurement failed: %s', typeStr, ME.message));
        end
    end

    function computeCalibrationTerms()
        % Compute Directivity (ED), Source Match (ES), Reflection Tracking (ER)
        if isempty(appState.gamma_open) || isempty(appState.gamma_short) || isempty(appState.gamma_load)
            uialert(fig, 'Please measure Open, Short, and Load standards before computing calibration.', 'Missing Standards');
            logMessage('[ERROR] OSL calibration requires Open, Short, and Load reference sweeps.');
            return;
        end
        
        logMessage('Computing 1-Port OSL Vector Error Correction terms...');
        
        gO = appState.gamma_open;
        gS = appState.gamma_short;
        gL = appState.gamma_load;
        
        % Exact 1-Port OSL Vector Error Model Equations:
        % vO = Gamma_Open - Gamma_Load
        % vS = Gamma_Short - Gamma_Load
        vO = gO - gL;
        vS = gS - gL;
        
        denom = vO - vS; % (Gamma_Open - Gamma_Short)
        denom(abs(denom) < 1e-12) = 1e-12; % Guard against div by zero
        
        % 1. Directivity Vector: ED = Gamma_Load
        ED = gL;
        
        % 2. Source Match Vector: ES = (vO + vS) / (vO - vS)
        ES = (vO + vS) ./ denom;
        
        % 3. Reflection Tracking Vector: ER = -2 * vO * vS / (vO - vS)
        ER = (-2 * vO .* vS) ./ denom;
        
        % Store into appState
        appState.calTerms.ED = ED;
        appState.calTerms.ES = ES;
        appState.calTerms.ER = ER;
        appState.calTerms.isCalibrated = true;
        
        % Update UI controls
        chkEnableCal.Enable = 'on';
        chkEnableCal.Value = true;
        lblCalStatus.Text = 'Status: Calibrated (OSL)';
        lblCalStatus.FontColor = [0.1 0.6 0.2];
        logMessage('OSL Error Terms computed successfully (ED, ES, ER active).');
        
        % Re-apply correction if raw data present
        if ~isempty(appState.s11_raw)
            applyOSLCorrection();
            updatePlots();
        end
    end

    function clearCalibration()
        appState.gamma_open = [];
        appState.gamma_short = [];
        appState.gamma_load = [];
        appState.calTerms.ED = [];
        appState.calTerms.ES = [];
        appState.calTerms.ER = [];
        appState.calTerms.isCalibrated = false;
        
        btnCalOpen.Text = 'Meas OPEN'; btnCalOpen.BackgroundColor = [0.94 0.94 0.94];
        btnCalShort.Text = 'Meas SHORT'; btnCalShort.BackgroundColor = [0.94 0.94 0.94];
        btnCalLoad.Text = 'Meas LOAD'; btnCalLoad.BackgroundColor = [0.94 0.94 0.94];
        
        chkEnableCal.Enable = 'off';
        chkEnableCal.Value = false;
        lblCalStatus.Text = 'Status: Uncalibrated';
        lblCalStatus.FontColor = [0.7 0.2 0.2];
        
        logMessage('OSL Calibration cleared.');
        if ~isempty(appState.s11_raw)
            applyOSLCorrection();
            updatePlots();
        end
    end

    function applyOSLCorrection()
        if isempty(appState.s11_raw), return; end
        
        if appState.calTerms.isCalibrated && chkEnableCal.Value
            % Correct measured raw Gamma_M to actual Gamma_A:
            % Gamma_A = (Gamma_M - ED) / [ ER + ES * (Gamma_M - ED) ]
            gM = appState.s11_raw;
            ED = appState.calTerms.ED;
            ES = appState.calTerms.ES;
            ER = appState.calTerms.ER;
            
            % Interpolate error terms if frequency vector size differs
            if length(ED) ~= length(gM)
                f_cal = appState.f_vector_cal;
                f_raw = appState.f_vector;
                ED = interp1(f_cal, ED, f_raw, 'linear', 'extrap');
                ES = interp1(f_cal, ES, f_raw, 'linear', 'extrap');
                ER = interp1(f_cal, ER, f_raw, 'linear', 'extrap');
            end
            
            diff_M_ED = gM - ED;
            denom = ER + ES .* diff_M_ED;
            denom(abs(denom) < 1e-12) = 1e-12;
            
            appState.s11_cal = diff_M_ED ./ denom;
        else
            % Uncalibrated: Gamma_A = Gamma_M
            appState.s11_cal = appState.s11_raw;
        end
    end

    %% =========================================================
    % 6. DATA VISUALIZATION & FILTERING
    %% =========================================================

    function updatePlots()
        if isempty(appState.f_vector) || isempty(appState.s11_cal)
            return;
        end
        
        [mult, unitStr] = getFreqMultiplier();
        fScaled = appState.f_vector / mult;
        s11 = appState.s11_cal;
        
        % --- Apply Selected Data Smoothing ---
        smoothMethod = ddFilterMethod.Value;
        smoothWin = spinSmoothWin.Value;
        
        if ~strcmpi(smoothMethod, 'None') && smoothWin > 1
            % Separate magnitude (dB) and phase for smooth filtering
            magdB = 20 * log10(abs(s11));
            phaseDeg = unwrap(angle(s11)) * (180/pi);
            
            if contains(smoothMethod, 'movmean')
                magdB_sm = smoothdata(magdB, 'movmean', smoothWin);
                phaseDeg_sm = smoothdata(phaseDeg, 'movmean', smoothWin);
            elseif contains(smoothMethod, 'sgolay')
                order = min(3, smoothWin - 1);
                magdB_sm = smoothdata(magdB, 'sgolay', smoothWin, 'Degree', order);
                phaseDeg_sm = smoothdata(phaseDeg, 'sgolay', smoothWin, 'Degree', order);
            elseif contains(smoothMethod, 'movmedian')
                magdB_sm = smoothdata(magdB, 'movmedian', smoothWin);
                phaseDeg_sm = smoothdata(phaseDeg, 'movmedian', smoothWin);
            elseif contains(smoothMethod, 'Gaussian')
                magdB_sm = smoothdata(magdB, 'gaussian', smoothWin);
                phaseDeg_sm = smoothdata(phaseDeg, 'gaussian', smoothWin);
            else
                magdB_sm = magdB;
                phaseDeg_sm = phaseDeg;
            end
            
            % Reconstruct smoothed complex S11
            magLin = 10.^(magdB_sm / 20);
            s11_disp = magLin .* exp(1j * (phaseDeg_sm * pi/180));
            magdB_disp = magdB_sm;
        else
            s11_disp = s11;
            magdB_disp = 20 * log10(abs(s11));
            phaseDeg_sm = unwrap(angle(s11)) * (180/pi);
        end
        
        appState.s11_smooth = s11_disp;

        % ---------------------------------------------------------
        % TAB 1: Log-Magnitude (Return Loss in dB)
        % ---------------------------------------------------------
        cla(axLogMag); hold(axLogMag, 'on');
        
        % Plot Historical Trials Overlay if enabled
        if chkOverlayHistory.Value && ~isempty(appState.history)
            numHist = length(appState.history);
            colors = lines(max(5, numHist + 1));
            for k = 1:numHist
                hData = appState.history{k};
                if ~isempty(hData.f_vector) && ~isempty(hData.s11_display)
                    f_h_scaled = hData.f_vector / mult;
                    magdB_h = 20 * log10(abs(hData.s11_display));
                    plot(axLogMag, f_h_scaled, magdB_h, ':', 'LineWidth', 1.2, ...
                         'Color', colors(k, :), ...
                         'DisplayName', sprintf('Trial #%d (%s)', k, hData.time));
                end
            end
        end

        % Plot Raw S11 (if calibrated and available for comparison)
        if appState.calTerms.isCalibrated && chkEnableCal.Value && ~isempty(appState.s11_raw)
            rawdB = 20 * log10(abs(appState.s11_raw));
            plot(axLogMag, fScaled, rawdB, '--', 'Color', [0.6 0.6 0.6], ...
                 'LineWidth', 1.0, 'DisplayName', 'Raw Uncalibrated');
        end
        
        % Main Active S11 Trace
        plot(axLogMag, fScaled, magdB_disp, '-', 'Color', [0.0 0.45 0.74], ...
             'LineWidth', 2.0, 'DisplayName', 'Active Sweep (dB)');
        
        % Highlight Minimum Peak / Resonance Notch
        [minVal, minIdx] = min(magdB_disp);
        fMin = fScaled(minIdx);
        plot(axLogMag, fMin, minVal, 'rv', 'MarkerSize', 8, 'MarkerFaceColor', 'r', ...
             'DisplayName', sprintf('Min: %.2f dB @ %.2f %s', minVal, fMin, unitStr));
        
        title(axLogMag, sprintf('Return Loss |S11| (Min: %.2f dB at %.2f %s)', minVal, fMin, unitStr), ...
              'FontSize', 12, 'FontWeight', 'bold');
        xlabel(axLogMag, sprintf('Frequency (%s)', unitStr));
        legend(axLogMag, 'Location', 'best');
        hold(axLogMag, 'off');

        % ---------------------------------------------------------
        % TAB 2: Smith Chart (Impedance Trajectory)
        % ---------------------------------------------------------
        renderSmithChart(axSmith, s11_disp);

        % ---------------------------------------------------------
        % TAB 3: VSWR & Phase Response
        % ---------------------------------------------------------
        gammaMag = abs(s11_disp);
        gammaMag(gammaMag >= 0.999) = 0.999; % Clamp for stability
        vswr = (1 + gammaMag) ./ (1 - gammaMag);
        
        cla(axVSWR); hold(axVSWR, 'on');
        cla(axPhase); hold(axPhase, 'on');
        
        % Overlay Historical Trials on VSWR & Phase if enabled
        if chkOverlayHistory.Value && ~isempty(appState.history)
            numHist = length(appState.history);
            colors = lines(max(5, numHist + 1));
            for k = 1:numHist
                hData = appState.history{k};
                if ~isempty(hData.f_vector) && ~isempty(hData.s11_display)
                    f_h_scaled = hData.f_vector / mult;
                    gMag_h = abs(hData.s11_display);
                    gMag_h(gMag_h >= 0.999) = 0.999;
                    vswr_h = (1 + gMag_h) ./ (1 - gMag_h);
                    phase_h = angle(hData.s11_display) * (180/pi);
                    
                    plot(axVSWR, f_h_scaled, vswr_h, ':', 'LineWidth', 1.2, 'Color', colors(k, :));
                    plot(axPhase, f_h_scaled, phase_h, ':', 'LineWidth', 1.2, 'Color', colors(k, :));
                end
            end
        end
        
        plot(axVSWR, fScaled, vswr, 'Color', [0.85 0.32 0.09], 'LineWidth', 1.6);
        ylim(axVSWR, [1 min(20, max(vswr)*1.1)]);
        title(axVSWR, sprintf('Voltage Standing Wave Ratio (Min VSWR: %.2f:1)', min(vswr)), ...
              'FontSize', 11, 'FontWeight', 'bold');
        xlabel(axVSWR, sprintf('Frequency (%s)', unitStr));
        hold(axVSWR, 'off');

        % Wrapped phase in [-180, 180] deg
        phaseWrapped = angle(s11_disp) * (180/pi);
        plot(axPhase, fScaled, phaseWrapped, 'Color', [0.49 0.18 0.56], 'LineWidth', 1.5);
        ylim(axPhase, [-185 185]);
        yticks(axPhase, -180:45:180);
        xlabel(axPhase, sprintf('Frequency (%s)', unitStr));
        hold(axPhase, 'off');
    end

    function renderSmithChart(ax, s11_data)
        % Render Smith Chart using RF Toolbox (smithplot) or Custom Fallback Grid
        cla(ax);
        
        % Check if smithplot exists in license / toolbox
        if exist('smithplot', 'file') == 2 || exist('smithplot', 'builtin') == 5
            try
                % If RF Toolbox is present
                smithplot(ax, s11_data, 'GridType', 'Z');
                return;
            catch
                % Fall through to custom renderer on failure
            end
        end
        
        % --- Custom Mathematical Fallback Smith Chart Renderer ---
        drawCustomSmithChartGrid(ax);
        hold(ax, 'on');
        
        % Overlay historical trial trajectories on custom Smith Chart if enabled
        if chkOverlayHistory.Value && ~isempty(appState.history)
            numHist = length(appState.history);
            colors = lines(max(5, numHist + 1));
            for k = 1:numHist
                hData = appState.history{k};
                if ~isempty(hData.s11_display)
                    u_h = real(hData.s11_display);
                    v_h = imag(hData.s11_display);
                    plot(ax, u_h, v_h, ':', 'LineWidth', 1.2, 'Color', colors(k, :), ...
                         'DisplayName', sprintf('Trial %d', k));
                end
            end
        end
        
        % Overlay active complex S11 trajectory: Gamma = u + j*v
        u = real(s11_data);
        v = imag(s11_data);
        
        plot(ax, u, v, 'LineWidth', 2.0, 'Color', [0.0 0.45 0.74], 'DisplayName', 'Active S11');
        
        % Plot start (green circle) and stop (red square) markers
        if ~isempty(u)
            plot(ax, u(1), v(1), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 7, 'DisplayName', 'Start Freq');
            plot(ax, u(end), v(end), 'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 7, 'DisplayName', 'Stop Freq');
        end
        hold(ax, 'off');
    end

    function drawCustomSmithChartGrid(ax)
        % Programmatically draw exact mathematical Smith Chart (r-circles & x-arcs)
        cla(ax);
        hold(ax, 'on');
        
        % Colors & styling
        gridColor = [0.70 0.75 0.82];
        axisColor = [0.20 0.25 0.35];
        
        % 1. Outer boundary circle (r = 0, |Gamma| = 1)
        theta = linspace(0, 2*pi, 360);
        plot(ax, cos(theta), sin(theta), 'LineWidth', 1.8, 'Color', axisColor);
        
        % 2. Horizontal Prime Real Axis (v = 0) from u = -1 to +1
        plot(ax, [-1 1], [0 0], 'LineWidth', 1.2, 'Color', axisColor);
        
        % 3. Constant Resistance Circles (r = 0.2, 0.5, 1.0, 2.0, 5.0)
        r_values = [0.2, 0.5, 1.0, 2.0, 5.0];
        for r = r_values
            center_u = r / (1 + r);
            radius = 1 / (1 + r);
            plot(ax, center_u + radius*cos(theta), radius*sin(theta), ...
                 ':', 'LineWidth', 1.0, 'Color', gridColor);
            
            % Add text labels along real axis
            text(ax, center_u - radius + 0.02, 0.04, sprintf('%.1f', r), ...
                 'FontSize', 7, 'Color', [0.3 0.3 0.4]);
        end
        
        % 4. Constant Reactance Arcs (x = +/- 0.2, 0.5, 1.0, 2.0, 5.0)
        x_values = [0.2, 0.5, 1.0, 2.0, 5.0];
        for x = x_values
            for sign_x = [-1, 1]
                x_val = sign_x * x;
                center_v = 1 / x_val;
                radius = 1 / abs(x_val);
                
                % Arc angle bounds so circle remains inside unit circle |u^2 + v^2| <= 1
                % Center is at (1, center_v)
                t = linspace(0, 2*pi, 400);
                u_arc = 1 + radius * cos(t);
                v_arc = center_v + radius * sin(t);
                
                % Filter points inside unit circle
                inside = (u_arc.^2 + v_arc.^2) <= 1.001;
                plot(ax, u_arc(inside), v_arc(inside), ':', 'LineWidth', 0.9, 'Color', gridColor);
            end
        end
        
        % Standard formatting
        xlim(ax, [-1.05 1.05]);
        ylim(ax, [-1.05 1.05]);
        axis(ax, 'equal');
        hold(ax, 'off');
    end

    function applyPlotAesthetics(ax, titleStr, xLabelStr, yLabelStr)
        % Apply clean, unified aesthetic to uiaxes: light blue-grey background,
        % bold borders, active minor grids.
        ax.BackgroundColor = [0.92 0.97 0.99];
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

    %% =========================================================
    % 7. DATA EXPORT (TOUCHSTONE S1P & CSV/MAT)
    %% =========================================================

    function exportTouchstoneS1P()
        if isempty(appState.f_vector) || isempty(appState.s11_cal)
            uialert(fig, 'No S11 sweep data available to export.', 'Export Error');
            return;
        end
        
        [file, folder] = uiputfile('*.s1p', 'Export Touchstone S1P File', 'NanoVNA_Sweep.s1p');
        if isequal(file, 0), return; end
        
        fullPath = fullfile(folder, file);
        fid = fopen(fullPath, 'w');
        if fid == -1
            logMessage('[ERROR] Could not open file for writing.');
            return;
        end
        
        % Write Touchstone 1.0 S1P Header
        [mult, unitStr] = getFreqMultiplier();
        fprintf(fid, '! NanoVNA MATLAB Controller & Analyzer Export\n');
        if appState.driver.IsSimulated
            srcTag = 'SIMULATED';
        else
            srcTag = 'MEASURED';
        end
        fprintf(fid, '! Source: %s\n', srcTag);
        if appState.driver.IsSimulated
            fprintf(fid, '! WARNING: synthetic data from Simulation Mode. NOT a measurement.\n');
        end
        fprintf(fid, '! Date: %s\n', char(datetime('now')));
        fprintf(fid, '! Freq Range: %.3f %s - %.3f %s (%d pts)\n', ...
            appState.f_vector(1)/mult, unitStr, appState.f_vector(end)/mult, unitStr, length(appState.f_vector));
        fprintf(fid, '# Hz S RI R 50\n');
        
        % Data lines: Freq_Hz Re(S11) Im(S11)
        s11_exp = appState.s11_smooth;
        if isempty(s11_exp), s11_exp = appState.s11_cal; end
        
        for k = 1:length(appState.f_vector)
            fprintf(fid, '%.0f %.8e %.8e\n', ...
                appState.f_vector(k), real(s11_exp(k)), imag(s11_exp(k)));
        end
        
        fclose(fid);
        if appState.driver.IsSimulated
            logMessage(sprintf('[SIMULATED] Exported SYNTHETIC S1P file: %s', file));
            uialert(fig, ['The exported file contains SIMULATED data, not a measurement. ' ...
                'It is tagged with "! Source: SIMULATED" in its header.'], ...
                'Simulated Data Exported', 'Icon', 'warning');
        else
            logMessage(sprintf('Exported Touchstone S1P file: %s', file));
        end
    end

end
