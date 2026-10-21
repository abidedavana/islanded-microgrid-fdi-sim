function campaign_aggregate()
% CAMPAIGN_AGGREGATE  Tidy CSVs, seed-level 95% CIs (Student t), pooled Fisher
% tests, determinism checks and the three IEEE figures of the sim_v2 campaign.
% Reads  metrics\*.csv  (one file per config x seed, one row per channel).
% Writes campaign_tidy.csv, campaign_summary_long.csv, campaign_summary_main.csv,
%        campaign_fisher.csv, campaign_paired.csv, campaign_checks.txt, figs\*.
    here = fileparts(mfilename('fullpath'));  addpath(here);
    fprintf('tcrit95: nu=19 -> %.6f, nu=9 -> %.6f (expect 2.093024, 2.262157)\n', tcrit95(19), tcrit95(9));
    F = dir(fullfile(here,'metrics','*.csv'));
    F = F(~contains({F.name}, '.tmp'));
    T = table();
    for k = 1:numel(F)
        t = readtable(fullfile(F(k).folder, F(k).name), 'TextType','string');
        T = [T; t]; %#ok<AGROW>
    end
    T = sortrows(T, {'config','channel','seed'});
    writetable(T, fullfile(here,'campaign_tidy.csv'));
    fprintf('tidy: %d rows (%d files)\n', height(T), numel(F));

    % ---- seed-level summary (mean +/- t-CI) ----
    vars = T.Properties.VariableNames;
    num = vars(cellfun(@(v) isnumeric(T.(v)), vars));
    num = setdiff(num, {'seed'}, 'stable');
    [G, cfgK, chK] = findgroups(T.config, T.channel);
    L = table();
    for g = 1:max(G)
        sel = G == g;
        for v = 1:numel(num)
            x = T.(num{v})(sel);  x = x(~isnan(x));  n = numel(x);
            if n == 0, mu = NaN; sd = NaN; hw = NaN; mn = NaN; mxv = NaN;
            else
                mu = mean(x);  sd = std(x);  mn = min(x);  mxv = max(x);
                if n > 1, hw = tcrit95(n-1)*sd/sqrt(n); else, hw = NaN; end
            end
            L = [L; table(cfgK(g), chK(g), string(num{v}), n, mu, sd, hw, mu-hw, mu+hw, ...
                mn, mxv, ...
                'VariableNames', {'config','channel','metric','n','mean','sd','ci95_half','ci95_lo','ci95_hi','min','max'})]; %#ok<AGROW>
        end
    end
    writetable(L, fullfile(here,'campaign_summary_long.csv'));

    % ---- main wide summary (mean and CI half-width of key metrics) ----
    key = {'nAtt','nNor','alarmAtt_rate','alarmNor_rate','fisher_p','alarmLinAtt_rate','devAtt_meanAbs','devAtt_maxAbs', ...
        'devNor_meanAbs','devAttrib_meanAbs','crossAtt_rate','crossNor_rate','crossNor_n','cfCrossAtt_n','hs_rate', ...
        'alarmGivenCross_rate','lossAtt_mean_kW','lossNor_mean_kW','lossAtt_negFrac','lossNor_negFrac','Jatt_mean','Jnor_mean', ...
        'conv_rate','convAtt_rate','convNor_rate','nNotConv','iters_mean','iters_max','ctrlBiasAtt_mean','ctrlUsedBiasAtt_mean', ...
        'footprint_mean','footprint_max','maxA_Pinj','maxA_Qinj','maxA_Pflow','maxA_Qflow','maxA_Vm', ...
        'naiveCaught_rate','limitedCaught_rate','pfFailAtt_n','eventOver_n','tStep_ms'};
    W = table();
    for g = 1:max(G)
        row = table(cfgK(g), chK(g), sum(G==g), 'VariableNames', {'config','channel','nSeeds'});
        for v = 1:numel(key)
            r = L(L.config==cfgK(g) & L.channel==chK(g) & L.metric==key{v}, :);
            row.([key{v} '_mean']) = r.mean;  row.([key{v} '_ci']) = r.ci95_half;
            if any(strcmp(key{v}, {'devAtt_maxAbs','footprint_max','maxA_Pinj','maxA_Qinj','maxA_Pflow', ...
                    'maxA_Qflow','maxA_Vm','iters_max','nNotConv','crossNor_n','cfCrossAtt_n','pfFailAtt_n','eventOver_n'}))
                row.([key{v} '_maxOverSeeds']) = r.max;
            end
        end
        W = [W; row]; %#ok<AGROW>
    end
    writetable(W, fullfile(here,'campaign_summary_main.csv'));

    % ---- Fisher: per-seed p distribution and pooled counts ----
    Fz = table();
    for g = 1:max(G)
        s = T(G==g,:);
        aA = sum(s.alarmAtt_n); nA = sum(s.nAtt); aN = sum(s.alarmNor_n); nN = sum(s.nNor);
        Fz = [Fz; table(cfgK(g), chK(g), height(s), aA, nA, aN, nN, aA/nA, aN/nN, ...
            fisher_exact2(aA, nA-aA, aN, nN-aN), median(s.fisher_p), min(s.fisher_p), sum(s.fisher_p < 0.05), ...
            'VariableNames', {'config','channel','nSeeds','alarmAtt_pooled','nAtt_pooled','alarmNor_pooled', ...
            'nNor_pooled','alarmAtt_rate_pooled','alarmNor_rate_pooled','fisher_p_pooled','fisher_p_median', ...
            'fisher_p_min','nSeeds_p_lt_0p05'})]; %#ok<AGROW>
    end
    writetable(Fz, fullfile(here,'campaign_fisher.csv'));

    % ---- paired (same seed) differences ----
    pairs = {'C2','C0'; 'C1','C0'; 'C2','C1'; 'C3','C2'; 'C4','C2'; 'C5','C2'};
    pm = {'alarmAtt_rate','crossAtt_rate','hs_rate','devAtt_meanAbs','devAttrib_meanAbs'};
    P = table();
    for i = 1:size(pairs,1)
        for ch = ["PF","QV"]
            A = T(T.config==pairs{i,1} & T.channel==ch,:);  B = T(T.config==pairs{i,2} & T.channel==ch,:);
            [s, ia, ib] = intersect(A.seed, B.seed);
            if isempty(s), continue; end
            for v = 1:numel(pm)
                d = A.(pm{v})(ia) - B.(pm{v})(ib);  n = numel(d);
                hw = tcrit95(n-1)*std(d)/sqrt(n);
                P = [P; table(string(pairs{i,1}), string(pairs{i,2}), ch, string(pm{v}), n, mean(d), hw, ...
                    'VariableNames', {'configA','configB','channel','metric','n','meanDiff_AminusB','ci95_half'})]; %#ok<AGROW>
            end
        end
    end
    writetable(P, fullfile(here,'campaign_paired.csv'));

    % ---- determinism / sanity checks ----
    fid = fopen(fullfile(here,'campaign_checks.txt'),'w');
    skipV = {'tStep_ms','tEst_ms','tChannel_s','wall_s','threads','magScale'};
    cmpV = setdiff(num, skipV);
    chk(fid, T, 'C6_m1.00', 'C2', ["PF","QV"], cmpV, 'C6 magScale 1.00 re-run vs C2 (seeds 1-10)');
    chk(fid, T, 'C4', 'C2', "QV", cmpV, 'C4 QV (fsource only affects the PF loop) vs C2 QV');
    fprintf(fid, 'threads used (unique): %s\n', mat2str(unique(T.threads)'));
    fprintf(fid, 'skipped (non-converged base PF) steps, total over all runs: %d\n', sum(T.nSkip));
    fprintf(fid, 'PF post-control power-flow failures on attacked steps, total: %d\n', sum(T.pfFailAtt_n));
    fclose(fid);
    type(fullfile(here,'campaign_checks.txt'));

    campaign_figures(T, L);
    fprintf('aggregate done\n');
end

function chk(fid, T, a, b, chans, cmpV, label)
    worst = 0;  worstV = '';  nCmp = 0;
    for ch = chans
        A = T(T.config==a & T.channel==ch,:);  B = T(T.config==b & T.channel==ch,:);
        [~, ia, ib] = intersect(A.seed, B.seed);  nCmp = nCmp + numel(ia);
        for v = 1:numel(cmpV)
            x = A.(cmpV{v})(ia);  y = B.(cmpV{v})(ib);
            d = abs(x - y);  d(isnan(x) & isnan(y)) = 0;  d(isnan(d)) = Inf;
            if max([d; 0]) > worst, worst = max(d); worstV = cmpV{v}; end
        end
    end
    fprintf(fid, '%s: %d seed-channel pairs, max |diff| over %d non-timing metrics = %g (%s)\n', ...
        label, nCmp, numel(cmpV), worst, worstV);
end
