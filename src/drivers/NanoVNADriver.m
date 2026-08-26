classdef NanoVNADriver < handle
    % NanoVNADriver Hardware interface class for NanoVNA Vector Network Analyzer
    % Encapsulates serialport communication, SCPI string TX/RX, chunked frequency 
    % sweeping, timeout management, verbose logging, and an explicitly opt-in
    % simulation mode. Simulation is never entered automatically: if the serial
    % port cannot be opened, connect() reports failure and stays disconnected.
    %
    % Authors:
    %   Vedat Ulas
    %   Osman Sayginer
    %
    % Copyright (c) 2026 Vedat Ulas and Osman Sayginer
    % Licensed under the MIT License. See LICENSE for details.
    
    properties
        Port            char    = ''        % Serial port name (e.g., 'COM3', '/dev/ttyACM0')
        BaudRate        double  = 115200    % Serial baud rate
        SerialObj               = []        % MATLAB serialport object handle
        IsConnected     logical = false     % Connection status flag
        IsSimulated     logical = false     % Simulation fallback flag
        Verbose         logical = false     % Verbose command logging flag
        LogFcn                  = []        % Function handle for logging messages: @(str) logMsg(str)
        ChunkCallback           = []        % Callback for live chunk updates: @(k, numChunks, f_vec, s11_vec)
        SpeedMode       char    = 'PRECISION' % Sweep speed mode: 'PRECISION' (default) or 'FAST'
        CustomChunkPause double = 1.0       % User-configurable chunk settling pause in seconds (default 1000ms)
        AbortRequested  logical = false     % User abort signal flag
        Timeout         double  = 2.0       % Serial read timeout in seconds
    end
    
    methods
        function obj = NanoVNADriver(logFcn)
            % Constructor - accepts optional logging function handle
            if nargin >= 1 && ~isempty(logFcn)
                obj.LogFcn = logFcn;
            else
                obj.LogFcn = @(msg) fprintf('%s\n', msg);
            end
        end
        
        function log(obj, msg)
            % Internal logging helper
            if ~isempty(obj.LogFcn)
                try
                    obj.LogFcn(msg);
                catch
                    fprintf('%s\n', msg);
                end
            end
        end
        
        function success = connect(obj, port, baud, forceSimulation)
            % Connect to hardware via serialport, or fall back to simulation
            if nargin < 4, forceSimulation = false; end
            if nargin < 3 || isempty(baud), baud = 115200; end
            
            obj.Port = port;
            obj.BaudRate = baud;
            
            % Force simulation mode if requested or if port is empty / 'SIM'
            if forceSimulation || isempty(port) || strcmpi(port, 'SIM') || strcmpi(port, 'SIMULATION')
                obj.IsSimulated = true;
                obj.IsConnected = true;
                obj.log('*****************************************************');
                obj.log('*** SIMULATION MODE: output is SYNTHETIC data.    ***');
                obj.log('*** Nothing produced in this mode is a measurement. ***');
                obj.log('*****************************************************');
                success = true;
                return;
            end
            
            try
                % Disconnect existing connection if open
                obj.disconnect();
                
                obj.log(sprintf('Attempting serial connection to %s at %d baud...', port, baud));
                obj.SerialObj = serialport(port, baud, 'Timeout', obj.Timeout);
                configureTerminator(obj.SerialObj, "CR/LF");
                flush(obj.SerialObj);
                
                % Wakeup ping to clear prompt buffer
                writeline(obj.SerialObj, ' ');
                pause(0.1);
                flush(obj.SerialObj);
                
                obj.IsConnected = true;
                obj.IsSimulated = false;
                obj.log(sprintf('Successfully connected to NanoVNA on %s.', port));
                success = true;
            catch ME
                % No silent fallback. A failed serial open leaves the driver
                % disconnected so that no synthetic data can be mistaken for a
                % measurement. Simulation must be requested explicitly by
                % passing forceSimulation = true or the port name 'SIMULATION'.
                obj.log(sprintf('[ERROR] Failed to open serial port %s: %s', port, ME.message));
                obj.log('[ERROR] Driver is NOT connected. No data will be produced.');
                obj.SerialObj = [];
                obj.IsConnected = false;
                obj.IsSimulated = false;
                success = false;
            end
        end
        
        function disconnect(obj)
            % Close serial connection safely
            if ~isempty(obj.SerialObj) && isvalid(obj.SerialObj)
                try
                    flush(obj.SerialObj);
                    delete(obj.SerialObj);
                catch
                end
            end
            obj.SerialObj = [];
            obj.IsConnected = false;
            obj.log('Serial connection closed.');
        end
        
        function sendCommand(obj, cmdStr)
            % Send raw SCPI/ASCII command to hardware
            if obj.IsSimulated
                if obj.Verbose
                    obj.log(sprintf('[TX SIM] %s', cmdStr));
                end
                return;
            end
            
            if isempty(obj.SerialObj) || ~isvalid(obj.SerialObj)
                error('Serial port is not connected.');
            end
            
            if obj.Verbose
                obj.log(sprintf('[TX] %s', cmdStr));
            end
            
            writeline(obj.SerialObj, cmdStr);
        end
        
        function rawS11 = readData0(obj)
            % Request and parse 101-point complex S11 array ('data 0')
            if obj.IsSimulated
                % Generate a nominal 101-point S11 for single-chunk call
                rawS11 = obj.generateSimulationData(linspace(1e6, 900e6, 101), 'DUT');
                obj.log('[SIMULATED] Returned 101 synthetic S11 points. THIS IS NOT A MEASUREMENT.');
                return;
            end
            
            % 2. Implement a Robust "Dummy Read" Buffer Flush
            if ~isempty(obj.SerialObj) && isvalid(obj.SerialObj)
                % Clear software buffer
                flush(obj.SerialObj, "input");
                pause(0.05); % 50ms pause for hardware UART RX fifo to stabilize
                
                % Non-blocking dummy read loop to discard lingering RX strings/artifacts
                while obj.SerialObj.NumBytesAvailable > 0
                    try
                        readline(obj.SerialObj);
                    catch
                        break;
                    end
                end
                flush(obj.SerialObj, "input");
            end
            
            obj.sendCommand('data 0');
            
            % Read returned lines directly as bytes arrive
            rawS11 = zeros(101, 1);
            lineCount = 0;
            
            startTime = tic;
            maxWaitSec = 4.0;
            
            while lineCount < 101 && toc(startTime) < maxWaitSec
                if obj.SerialObj.NumBytesAvailable == 0
                    pause(0.001);
                    continue;
                end
                
                try
                    strLine = strtrim(readline(obj.SerialObj));
                catch
                    break;
                end
                
                % Filter out command prompt artifacts and SCPI echoes
                if isempty(strLine) || contains(strLine, 'ch>') || contains(strLine, 'data') || contains(strLine, 'sweep')
                    continue;
                end
                
                % Parse space-separated real and imaginary values
                vals = sscanf(strLine, '%f %f');
                if length(vals) >= 2 && abs(vals(1)) < 10.0 && abs(vals(2)) < 10.0
                    lineCount = lineCount + 1;
                    rawS11(lineCount) = complex(vals(1), vals(2));
                end
            end
            
            if lineCount < 101
                obj.log(sprintf('[WARN] Only received %d/101 S11 values.', lineCount));
            end
            
            if obj.Verbose
                obj.log(sprintf('[RX] Parsed %d complex S11 points from hardware.', lineCount));
            end
        end
        
        function abortSweep(obj)
            % Abort active sweep loop
            obj.AbortRequested = true;
        end
        
        function [f_vector, s11_raw] = executeChunkedSweep(obj, startFreqHz, stopFreqHz, totalPoints, sweepType)
            % Execute high-resolution sweep by chunking the frequency span
            if nargin < 5 || isempty(sweepType), sweepType = 'DUT'; end
            if totalPoints < 2, totalPoints = 101; end
            
            obj.AbortRequested = false;
            
            % Generate master target frequency vector
            f_vector = linspace(startFreqHz, stopFreqHz, totalPoints).';
            
            % Hardware native chunk size
            CHUNK_PTS = 101;
            
            if totalPoints <= CHUNK_PTS
                numChunks = 1;
            else
                % Duplicate overlap: each chunk overlaps 1 point with previous chunk
                numChunks = ceil((totalPoints - 1) / (CHUNK_PTS - 1));
            end
            
            obj.log(sprintf('Starting Sweep: %.3f MHz to %.3f MHz (%d points across %d chunks)...', ...
                startFreqHz/1e6, stopFreqHz/1e6, totalPoints, numChunks));
            
            s11_raw = complex(zeros(totalPoints, 1));
            
            if obj.IsSimulated
                % In simulation mode, directly generate full high-res profile with high fidelity
                s11_raw = obj.generateSimulationData(f_vector, sweepType);
                obj.log(sprintf('[SIMULATED] Generated %d synthetic S11 points. THIS IS NOT A MEASUREMENT.', totalPoints));
                return;
            end
            
            % Physical Hardware Execution Loop
            for chunkIdx = 1:numChunks
                % Check abort signal
                if obj.AbortRequested
                    obj.log('[ABORT] Sweep execution halted by user.');
                    error('SWEEP_ABORTED');
                end
                
                % Calculate sub-indices in master vector
                idxStart = (chunkIdx - 1) * (CHUNK_PTS - 1) + 1;
                idxEnd = min(idxStart + CHUNK_PTS - 1, totalPoints);
                
                chunkStartFreq = f_vector(idxStart);
                chunkStopFreq = f_vector(idxEnd);
                
                % Program hardware synthesizer bounds using dual syntax for universal compatibility
                obj.sendCommand(sprintf('sweep %.0f %.0f', chunkStartFreq, chunkStopFreq));
                obj.sendCommand(sprintf('sweep start %.0f', chunkStartFreq));
                obj.sendCommand(sprintf('sweep stop %.0f', chunkStopFreq));
                
                % Hardware settling time per chunk
                if ~isempty(obj.CustomChunkPause) && obj.CustomChunkPause > 0
                    pause(obj.CustomChunkPause);
                elseif strcmpi(obj.SpeedMode, 'FAST')
                    pause(0.35); % FAST mode pause (350ms)
                else
                    pause(0.75); % PRECISION mode pause (750ms)
                end
                
                % Fetch 101 S11 points for this chunk
                chunkS11_raw = obj.readData0();
                
                % Hardware always returns 101 points linearly spaced from chunkStartFreq to chunkStopFreq
                f_hw = linspace(chunkStartFreq, chunkStopFreq, 101).';
                
                % Interpolate chunk S11 onto the target master frequencies for this segment
                f_target_segment = f_vector(idxStart:idxEnd);
                
                if length(chunkS11_raw) == length(f_target_segment)
                    % Direct 1-to-1 assignment (zero interpolation phase distortion)
                    s11_segment = chunkS11_raw;
                elseif isscalar(f_target_segment)
                    s11_segment = chunkS11_raw(1);
                else
                    s11_segment = interp1(f_hw, chunkS11_raw, f_target_segment, 'linear', 'extrap');
                end
                
                % Insert into master array
                s11_raw(idxStart:idxEnd) = s11_segment;
                
                if obj.Verbose
                    obj.log(sprintf('  Chunk %d/%d (%.2f - %.2f MHz) complete.', ...
                        chunkIdx, numChunks, chunkStartFreq/1e6, chunkStopFreq/1e6));
                end
                
                % Invoke live streaming callback if registered
                if ~isempty(obj.ChunkCallback)
                    try
                        obj.ChunkCallback(chunkIdx, numChunks, f_vector(1:idxEnd), s11_raw(1:idxEnd));
                    catch
                    end
                end
            end
            
            obj.log(sprintf('High-resolution chunked sweep complete (%d points assembled).', totalPoints));
        end
        
        function s11 = generateSimulationData(obj, f_vec, sweepType)
            % Generate realistic mathematical S11 data for testing
            N = length(f_vec);
            if N == 0, s11 = []; return; end
            
            f_min = f_vec(1);
            f_max = f_vec(end);
            f_center = (f_min + f_max) / 2;
            span = f_max - f_min;
            if span == 0, span = 1e6; end
            
            % Add small realistic measurement noise
            noise = (randn(N, 1) + 1j*randn(N, 1)) * 0.003;
            
            switch upper(sweepType)
                case 'OPEN'
                    % Open standard: High magnitude (~0.98), small capacitive phase delay
                    tau = 25e-12; % 25 ps delay
                    mag = 0.985 - 0.01 * (f_vec / 1e9);
                    phase = -2 * pi * f_vec * tau;
                    s11 = mag .* exp(1j * phase) + noise;
                    
                case 'SHORT'
                    % Short standard: High magnitude (~0.98), 180 deg phase shift + small inductive delay
                    tau = 15e-12; % 15 ps delay
                    mag = 0.980 - 0.01 * (f_vec / 1e9);
                    phase = pi - 2 * pi * f_vec * tau;
                    s11 = mag .* exp(1j * phase) + noise;
                    
                case 'LOAD'
                    % 50-Ohm Load standard: Very low reflection (~ -35 dB to -45 dB)
                    mag = 0.012 + 0.008 * sin(2 * pi * f_vec / (span/2));
                    phase = 2 * pi * rand(N, 1);
                    s11 = mag .* exp(1j * phase) + noise * 0.5;
                    
                otherwise % 'DUT'
                    % Device Under Test: Transmission line with a notch filter / resonator at f_center
                    f0 = f_center;
                    Q = 25;
                    
                    % Transmission line phase delay
                    tau_line = 3.5e-9;
                    base_s11 = 0.92 * exp(-1j * 2 * pi * f_vec * tau_line);
                    
                    % Resonant dip / notch model (Lorentzian reflection dip)
                    delta_f = (f_vec - f0) / f0;
                    notch = 0.85 ./ (1 + 1j * 2 * Q * delta_f);
                    
                    s11 = base_s11 .* (1 - notch) + noise;
            end
        end
    end
    
    methods(Static)
        function portList = scanPorts()
            % Automatically scan available serial ports on host OS
            try
                ports = serialportlist("available");
                portList = cellstr(ports);
            catch
                portList = {};
            end
            
            % Only genuinely available ports are listed. 'SIMULATION' is always
            % offered as an explicit, clearly named choice, but no placeholder
            % port names are invented when the scan comes back empty.
            portList = portList(~cellfun(@isempty, portList));
            if ~any(strcmpi(portList, 'SIMULATION'))
                portList{end+1} = 'SIMULATION';
            end
        end
    end
end
