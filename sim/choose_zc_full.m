function [C, Kb, K_prime, iLS, Zc, K, L] = choose_zc_full(B, base_graph)
% Full procedure to choose iLS and Zc according to the 5G NR standard.
%
%   Inputs:
%       B          - Number of bits before segmentation (data bits).
%       base_graph - Base graph, must be 1 or 2 (BG1 or BG2).
%
%   Outputs:
%       C          - Number of code blocks.
%       Kb         - A constant related to the base graph.
%       K_prime    - Number of bits per code block after segmentation.
%       iLS        - The chosen lifting set index.
%       Zc         - The chosen lifting size.
%       K          - The final code block length.

% Table 5.3.2-1: Lifting sets (iLS → available Z_c values)
lifting_sets = { ...
    [2, 4, 8, 16, 32, 64, 128, 256], ...     % iLS = 0
    [3, 6, 12, 24, 48, 96, 192, 384], ...    % iLS = 1
    [5, 10, 20, 40, 80, 160, 320], ...       % iLS = 2
    [7, 14, 28, 56, 112, 224], ...           % iLS = 3
    [9, 18, 36, 72, 144, 288], ...           % iLS = 4
    [11, 22, 44, 88, 176, 352], ...          % iLS = 5
    [13, 26, 52, 104, 208], ...              % iLS = 6
    [15, 30, 60, 120, 240] ...               % iLS = 7
};

% Constants
Kcb_BG1 = 8448; % = Maximum available Z_c * Maximum Kb = 384*22
Kcb_BG2 = 3840; % = Maximum available Z_c * Maximum Kb = 384*10
CRC_bits = 24;

% Step 1: Choose Kcb
if base_graph == 1
    Kcb = Kcb_BG1;
elseif base_graph == 2
    Kcb = Kcb_BG2;
else
    error('Base graph must be 1 or 2.');
end

% Step 2: Check if segmentation is needed
if B <= Kcb
    C = 1;
    L = 0; % no CRC needed if no segmentation
    B_prime = B;
else
    L = CRC_bits;
    C = ceil((B) / (Kcb - L));
    B_prime = B + C * L;
end

% Step 3: Calculate K' (bits per code block after segmentation)
K_prime = ceil(B_prime / C);

% Step 4: Choose Kb
if base_graph == 1
    Kb = 22;
else % base_graph == 2
    Kb = 10;
end

% Step 5: Find minimum Zc such that Kb * Zc >= K'
required_zc = ceil(K_prime / Kb);

best_zc = inf;
best_iLS = -1; % Use -1 to indicate not found

for i = 1:length(lifting_sets)
    z_list = lifting_sets{i};
    for j = 1:length(z_list)
        z = z_list(j);
        if z >= required_zc
            if z < best_zc
                best_zc = z;
                best_iLS = i - 1; % Adjust for 0-based index
            end
        end
    end
end

if isinf(best_zc)
    error('No valid Zc found. Check B or adjust parameters.');
end

Zc = best_zc;
iLS = best_iLS;

% Step 6: Calculate final K
if base_graph == 1
    K = 22 * Zc;
else % base_graph == 2
    K = 10 * Zc;
end

end