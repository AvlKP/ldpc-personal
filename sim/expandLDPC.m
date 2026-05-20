function H = expandLDPC(BG, Zc)
    [m, n] = size(BG);
    H = sparse(m*Zc, n*Zc);
    I = speye(Zc);

    for i = 1:m
        for j = 1:n
            p = BG(i, j);
            row_idx = (i-1)*Zc + 1 : i*Zc;
            col_idx = (j-1)*Zc + 1 : j*Zc;

            if p == -1
                % zero matrix
                H(row_idx, col_idx) = sparse(Zc, Zc);
            else
                % circulant permutation matrix with shift p
                H(row_idx, col_idx) = circshift(I, [0 p]);
            end
        end
    end
end