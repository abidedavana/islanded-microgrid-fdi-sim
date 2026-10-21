function p = fisher_exact2(a, b, c, d)
% FISHER_EXACT2  Two-sided Fisher exact test for the 2x2 table [a b; c d]
% (no Statistics Toolbox).  p = sum of hypergeometric probabilities of all
% tables with the same margins whose probability is <= that of the observed
% table (relative tolerance 1e-7, the convention used by R and SciPy).
    r1 = a + b;  r2 = c + d;  k = a + c;  n = r1 + r2;
    if n == 0 || r1 == 0 || r2 == 0 || k == 0 || k == n, p = 1; return; end
    lo = max(0, k - r2);  hi = min(r1, k);
    x = lo:hi;
    lp = lnC(r1, x) + lnC(r2, k - x) - lnC(n, k);
    lpObs = lnC(r1, a) + lnC(r2, k - a) - lnC(n, k);
    sel = lp <= lpObs + log1p(1e-7);
    p = min(1, sum(exp(lp(sel))));
end

function v = lnC(n, k)
    v = gammaln(n + 1) - gammaln(k + 1) - gammaln(n - k + 1);
end
