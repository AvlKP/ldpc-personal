% Get user input for hex message and base graph
hex_msg = input('Enter hex message: ', 's');
base_graph = input('Enter base graph (1 or 2): ');
bc_msg = reshape(dec2bin(hex2dec(hex_msg(:)), 4).' - '0', 1, []);
use_input_B = input('Do you want to input B manually? (y/n): ', 's');
if strcmpi(use_input_B, 'y')
    B = input('Enter value for B: ');
    if B < length(bc_msg)
        bc_msg = bc_msg(1:B);
    end
else
    B = length(bc_msg);
end

[C, Kb, K_prime, iLS, Zc, K, L] = choose_zc_full(B, base_graph);

if length(bc_msg) < K
    bc_msg = [bc_msg, zeros(1, K - length(bc_msg))];
elseif length(bc_msg) > K
    bc_msg = bc_msg(1:K);
end

disp(['Using Zc (lifting size) = ', num2str(Zc)]);
disp(['C (number of code blocks) = ', num2str(C)]);
disp(['Kb = ', num2str(Kb)]);
disp(['K_prime = ', num2str(K_prime)]);
disp(['iLS = ', num2str(iLS)]);
disp(['K = ', num2str(K)]);
disp(['L = ', num2str(L)]);
disp(['B (message length) = ', num2str(B)]);

files = dir(sprintf('./base-graphs/NR_%d_*_%d.txt', base_graph, Zc));
if isempty(files)
    error('No matching base graph file found for base_graph=%d, Zc=%d', base_graph, Zc);
end
BG = load(fullfile(files(1).folder, files(1).name));
H = logical(expandLDPC(BG, Zc));
e_cfg = ldpcEncoderConfig(H);

code = ldpcEncode(bc_msg.', e_cfg);

disp("--------------------------------------------------");
disp("Output:");
display_hex(code.');