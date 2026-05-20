function display_hex(input)
    % Convert codeword to hex and display
    input_bin_str = num2str(input')';
    input_bin_str = input_bin_str(:)';
    % Pad to multiple of 4 bits
    pad_len = mod(4 - mod(length(input_bin_str), 4), 4);
    input_bin_str = [input_bin_str, repmat('0', 1, pad_len)];
    input_hex = dec2hex(bin2dec(reshape(input_bin_str, 4, []).'), 1)';
    input_hex_str = lower(input_hex(:)');
    disp(input_hex_str);
end