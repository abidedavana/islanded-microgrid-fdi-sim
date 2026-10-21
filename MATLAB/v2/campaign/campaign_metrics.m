function r = campaign_metrics(s, ch, dbgFile)
% CAMPAIGN_METRICS  Per-run, per-channel metrics from the simulator's step log.
%   s       summary struct returned by SimulateMicrogridFDI_v2 for one channel (s.S = steplog)
%   ch      'pf' | 'qv'
%   dbgFile debug_<ch>.mat written with 'debugsteps' (every attacked step's a)
% Definitions (attacked = S.attacked==1, normal = S.attacked==0):
%   alarm        S.alarm (J >= tau, chosen estimator);  undetected = ~alarm
%   cross        S.cross (PF: f_post - 50 < -0.2 Hz; QV: min V_post < 0.90 pu)
%   harmful & stealthy (hs) = attacked & ~alarm & cross, as a fraction of attacked steps
%   dev          S.realDev (PF: f_post - 50 [Hz]; QV: min V_post - 1 [pu])
%   attributable dev = realDev - cfDev (no-attack counterfactual on the same step and noise)
%   loss statistic = sum of the 33 measured P injections (S.lossMeas, pu) -> kW (x 5000)
    S = s.S;  isPF = strcmpi(ch,'pf');
    atk = S.attacked == 1;  nor = S.attacked == 0;
    nA = sum(atk);  nN = sum(nor);
    al = S.alarm == 1;  cr = S.cross == 1;
    r = struct();
    r.nLogged = numel(S.step);  r.nSkip = s.nSkip;  r.nAtt = nA;  r.nNor = nN;
    r.dof = s.dof;  r.tau = s.tau;
    % ---- detection ----
    r.alarmAtt_n = sum(al & atk);  r.alarmAtt_rate = r.alarmAtt_n / nA;
    r.alarmNor_n = sum(al & nor);  r.alarmNor_rate = r.alarmNor_n / nN;
    r.fisher_p = fisher_exact2(r.alarmAtt_n, nA - r.alarmAtt_n, r.alarmNor_n, nN - r.alarmNor_n);
    r.alarmLinAtt_rate = mean(S.Jlin(atk) >= S.tau(atk));     % one-shot linear BDD on the same z
    r.alarmLinNor_rate = mean(S.Jlin(nor) >= S.tau(nor));
    r.stealthyOrig_rate = mean(S.stealthy(atk) == 1);          % J<tau & footprint<0.5 (orig. def.)
    r.Jatt_mean = mean(S.J(atk));  r.Jnor_mean = mean(S.J(nor));
    r.Jatt_median = median(S.J(atk));
    r.naiveCaught_rate = mean(S.Jnaive(atk) >= S.tau(atk));    % NaN if auxtests off
    r.limitedCaught_rate = mean(S.Jlimited(atk) >= S.tau(atk));
    % ---- physical impact ----
    d = S.realDev;  dd = S.realDev - S.cfDev;
    r.devAtt_meanAbs = mean(abs(d(atk)), 'omitnan');  r.devAtt_maxAbs = max(abs(d(atk)));
    r.devAtt_mean = mean(d(atk), 'omitnan');
    r.devNor_meanAbs = mean(abs(d(nor)), 'omitnan');  r.devNor_maxAbs = max(abs(d(nor)));
    r.devAttrib_meanAbs = mean(abs(dd(atk)), 'omitnan');  r.devAttrib_maxAbs = max(abs(dd(atk)));
    r.pfFailAtt_n = sum(isnan(d(atk)));  r.pfFailNor_n = sum(isnan(d(nor)));
    r.crossAtt_n = sum(cr & atk);  r.crossAtt_rate = r.crossAtt_n / nA;
    r.crossNor_n = sum(cr & nor);  r.crossNor_rate = r.crossNor_n / nN;
    r.cfCrossAtt_n = sum(S.cfCross(atk) == 1);
    r.hs_n = sum(atk & ~al & cr);  r.hs_rate = r.hs_n / nA;
    r.hsOrig_rate = mean(S.stealthy(atk) == 1 & cr(atk));      % with the original stealthy flag
    r.alarmGivenCross_rate = sum(atk & cr & al) / max(sum(atk & cr), 1);   % harm-conditioned TPR
    if sum(atk & cr) == 0, r.alarmGivenCross_rate = NaN; end
    r.eventOver_n = sum(S.eventCode(atk) == 2);                 % OFLS/OVLS on attacked steps
    % ---- loss statistic (kW, 5 MVA base) ----
    kW = 5e3;
    r.lossAtt_mean_kW = kW*mean(S.lossMeas(atk));  r.lossNor_mean_kW = kW*mean(S.lossMeas(nor));
    r.lossAtt_sd_kW = kW*std(S.lossMeas(atk));     r.lossNor_sd_kW = kW*std(S.lossMeas(nor));
    r.lossAtt_negFrac = mean(S.lossMeas(atk) < 0);  r.lossNor_negFrac = mean(S.lossMeas(nor) < 0);
    r.lossTrueAtt_mean_kW = kW*mean(S.lossTrue(atk));  r.lossTrueNor_mean_kW = kW*mean(S.lossTrue(nor));
    r.lossHatAtt_mean_kW = kW*mean(S.lossHat(atk));  r.lossHatNor_mean_kW = kW*mean(S.lossHat(nor));
    % ---- controller-input bias ----
    if isPF
        b = S.fHat - S.fTrue;  bc = S.fCtrl - S.fTrue;
    else
        b = S.VhatDerMean - S.VtrueDerMean;  bc = b;
    end
    r.ctrlBiasAtt_mean = mean(b(atk));  r.ctrlBiasNor_mean = mean(b(nor));  r.ctrlBiasNor_sd = std(b(nor));
    r.ctrlUsedBiasAtt_mean = mean(bc(atk));   % what the loop actually used (fCtrl for PF)
    % ---- estimator ----
    r.conv_rate = mean(S.conv == 1);  r.convAtt_rate = mean(S.conv(atk) == 1);
    r.convNor_rate = mean(S.conv(nor) == 1);  r.nNotConv = sum(S.conv ~= 1);
    r.cfConvAtt_rate = mean(S.cfConv(atk) == 1);
    r.iters_mean = mean(S.iters);  r.iters_max = max(S.iters);
    r.itersAtt_mean = mean(S.iters(atk));
    r.retry_n = sum(S.start >= 3);
    % ---- attack vector ----
    r.footprint_mean = mean(S.footprint(atk));  r.footprint_max = max(S.footprint(atk));
    r.design_mean = mean(S.design(atk));
    grp = {'Pinj',1:33; 'Qinj',34:66; 'Pflow',67:98; 'Qflow',99:130; 'Vm',131:134};
    mx = nan(1,5);  mstep = nan(1,5);  nDbg = 0;
    if exist(dbgFile,'file')
        L = load(dbgFile,'dbg');  dbg = L.dbg;  nDbg = numel(dbg);
        if nDbg > 0
            A = abs([dbg.a]);                         % m x nAttacked
            for g = 1:5
                rows = grp{g,2};  rows = rows(rows <= size(A,1));
                if isempty(rows), continue; end
                pm = max(A(rows,:), [], 1);           % per-step max within the group
                mx(g) = max(pm);  mstep(g) = mean(pm);
            end
        end
    end
    r.nDbgSteps = nDbg;
    for g = 1:5
        r.(['maxA_' grp{g,1}]) = mx(g);  r.(['meanStepMaxA_' grp{g,1}]) = mstep(g);
    end
    % ---- timing ----
    r.tStep_ms = 1e3*mean(S.tStep);  r.tEst_ms = 1e3*mean(S.tEst);  r.tChannel_s = s.tTotal;
end
