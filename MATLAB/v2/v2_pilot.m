function v2_pilot(name, seed, steps, warmup)
% V2_PILOT  Pilot run + analysis.  name: 'corrected' (default) | 'original' | 'stale'
%   v2_pilot('corrected', 1, 800, 200)
% Writes out/pilot_<name>_s<seed>/{PF,QV}/... and out/pilot_<name>_s<seed>.txt
    if nargin < 1, name = 'corrected'; end
    if nargin < 2, seed = 1; end
    if nargin < 3, steps = 800; end
    if nargin < 4, warmup = 200; end
    here = fileparts(mfilename('fullpath'));
    switch name
        case 'corrected', opts = {'vmeters','der','attack','ac','estimator','acwls','ctrlinput','estimate','attknow','true'};
        case 'stale',     opts = {'vmeters','der','attack','ac','estimator','acwls','ctrlinput','estimate','attknow','stale'};
        case 'original',  opts = {};
        case 'linattack', opts = {'vmeters','der','attack','linear','estimator','acwls','ctrlinput','estimate','attknow','true'};
        case 'fmeas',     opts = {'vmeters','der','attack','ac','estimator','acwls','ctrlinput','estimate','attknow','true', ...
                                  'fsource','measured','channels',{'pf'}};
        otherwise, error('unknown pilot %s', name);
    end
    tag = sprintf('pilot_%s_s%d', name, seed);
    od = fullfile(here,'out',tag);
    t = tic;
    o = SimulateMicrogridFDI_v2('seed',seed,'steps',steps,'warmup',warmup,'data','uci', opts{:}, 'outDir',od);
    wall = toc(t);
    fid = fopen(fullfile(here,'out',[tag '.txt']),'w');
    out = @(varargin) fprintf2(fid, varargin{:});
    out('PILOT %s  seed=%d steps=%d warmup=%d data=UCI RegroupedData.csv  wall=%.1f s\n', name, seed, steps, warmup, wall);
    out('options: %s\n', strjoin(cellfun(@toStr, opts, 'UniformOutput', false), ' '));
    chs = intersect({'pf','qv'}, fieldnames(o), 'stable');
    for ch = chs(:)'          % row cell: iterate over channels (a column cell would run once)
        s = o.(ch{1}); S = s.S; atk = S.attacked==1; nor = ~atk;
        if strcmp(ch{1},'pf'), u = 'Hz'; crit = '-0.2 Hz criterion'; else, u = 'pu'; crit = '0.90 pu criterion'; end
        [lo, hi] = binoRange(sum(nor), 0.01);
        out('\n== %s: %d logged steps, %d attacked, %d normal; m=%d dof=%d tau=%.2f\n', upper(ch{1}), numel(S.J), ...
            sum(atk), sum(nor), s.dof + 65, s.dof, s.tau);
        out('  BDD alarm (J>=tau): attacked %d/%d (%.1f%%) | normal %d/%d (%.2f%%; binomial 95%% range for 1%%: [%d,%d])\n', ...
            sum(S.alarm(atk)==1), sum(atk), 100*mean(S.alarm(atk)==1), sum(S.alarm(nor)==1), sum(nor), ...
            100*mean(S.alarm(nor)==1), lo, hi);
        out('  stealthy (J<tau & footprint<0.5): %.1f%% of attacked; footprint mean %.4f max %.4f pu\n', ...
            100*mean(S.stealthy(atk)==1), mean(S.footprint(atk)), max(S.footprint(atk)));
        out('  J/dof normal: mean %.3f (expect ~1); J attacked mean %.2f median %.2f max %.2f\n', ...
            mean(S.J(nor))/s.dof, mean(S.J(atk)), median(S.J(atk)), max(S.J(atk)));
        out('  linear one-shot J (same z): attacked alarm %.1f%%, normal alarm %.2f%%\n', ...
            100*mean(S.Jlin(atk) >= s.tau), 100*mean(S.Jlin(nor) >= s.tau));
        d = S.realDev;
        out('  real deviation (%s): attacked mean|.| %.4f max|.| %.4f mean %.4f | normal mean|.| %.4f max|.| %.4f\n', u, ...
            mean(abs(d(atk)),'omitnan'), max(abs(d(atk))), mean(d(atk),'omitnan'), mean(abs(d(nor)),'omitnan'), max(abs(d(nor))));
        dd = d(atk) - S.cfDev(atk);
        out('  attack-attributable deviation (real - no-attack counterfactual, same noise): mean %.4f, mean|.| %.4f, max|.| %.4f %s\n', ...
            mean(dd,'omitnan'), mean(abs(dd),'omitnan'), max(abs(dd)), u);
        out('  criterion crossings %s: attacked %d/%d (%.1f%%) | normal %d/%d (%.2f%%) | attacked-step counterfactual (no attack) %d\n', ...
            crit, sum(S.cross(atk)==1), sum(atk), 100*mean(S.cross(atk)==1), sum(S.cross(nor)==1), sum(nor), ...
            100*mean(S.cross(nor)==1), sum(S.cfCross(atk)==1));
        out('  harmful AND undetected (cross & no alarm): %d/%d attacked\n', sum(S.cross(atk)==1 & S.alarm(atk)==0), sum(atk));
        out('  events attacked: UF/UV %d, OF/OV %d, Fail %d | normal: UF/UV %d, OF/OV %d, Fail %d\n', ...
            sum(S.eventCode(atk)==1), sum(S.eventCode(atk)==2), sum(S.eventCode(atk)==-1), ...
            sum(S.eventCode(nor)==1), sum(S.eventCode(nor)==2), sum(S.eventCode(nor)==-1));
        Lm = 1e3*S.lossMeas*5;  Lt = 1e3*S.lossTrue*5;  Lh = 1e3*S.lossHat*5;   % kW (5 MVA base)
        out('  loss statistic sum(P_inj measured) [kW]: attacked mean %.1f sd %.1f [p1 %.1f, p50 %.1f, p99 %.1f] min %.1f, <0 on %d\n', ...
            mean(Lm(atk)), std(Lm(atk)), prctile1(Lm(atk),1), prctile1(Lm(atk),50), prctile1(Lm(atk),99), min(Lm(atk)), sum(Lm(atk)<0));
        out('                                          normal   mean %.1f sd %.1f [p1 %.1f, p50 %.1f, p99 %.1f] min %.1f, <0 on %d\n', ...
            mean(Lm(nor)), std(Lm(nor)), prctile1(Lm(nor),1), prctile1(Lm(nor),50), prctile1(Lm(nor),99), min(Lm(nor)), sum(Lm(nor)<0));
        out('  true losses [kW]: attacked mean %.1f, normal mean %.1f | estimate-implied losses: attacked mean %.1f, normal mean %.1f\n', ...
            mean(Lt(atk)), mean(Lt(nor)), mean(Lh(atk)), mean(Lh(nor)));
        out('  loss excess (measured - true) [kW]: attacked mean %.2f sd %.2f | normal mean %.2f sd %.2f\n', ...
            mean(Lm(atk)-Lt(atk)), std(Lm(atk)-Lt(atk)), mean(Lm(nor)-Lt(nor)), std(Lm(nor)-Lt(nor)));
        out('  controller inputs: fHat-fTrue attacked mean %.4f Hz (|.| max %.4f), normal mean %.5f sd %.5f Hz\n', ...
            mean(S.fHat(atk)-S.fTrue(atk)), max(abs(S.fHat(atk)-S.fTrue(atk))), mean(S.fHat(nor)-S.fTrue(nor)), std(S.fHat(nor)-S.fTrue(nor)));
        out('                     frequency source: %s; f used by controller - fTrue: attacked mean %.4f Hz, normal mean %.5f sd %.5f Hz\n', ...
            ternary(all(S.fsrc==1),'MEASURED (base.f + noise)','INFERRED (fHat)'), mean(S.fCtrl(atk)-S.fTrue(atk)), ...
            mean(S.fCtrl(nor)-S.fTrue(nor)), std(S.fCtrl(nor)-S.fTrue(nor)));
        out('                     VhatDer-VtrueDer attacked mean %.4f pu, normal mean %.5f sd %.5f pu\n', ...
            mean(S.VhatDerMean(atk)-S.VtrueDerMean(atk)), mean(S.VhatDerMean(nor)-S.VtrueDerMean(nor)), std(S.VhatDerMean(nor)-S.VtrueDerMean(nor)));
        out('  side effects: fPost mean attacked %.4f / normal %.4f Hz; VminPost mean attacked %.4f / normal %.4f pu\n', ...
            mean(S.fPost(atk)), mean(S.fPost(nor)), mean(S.VminPost(atk)), mean(S.VminPost(nor)));
        out('  estimator: converged %d/%d (%.2f%%) [attacked %.2f%%, normal %.2f%%]; iters mean %.2f max %d; starts warm/flat/retry %d/%d/%d; counterfactual conv %.1f%%\n', ...
            sum(S.conv==1), numel(S.conv), 100*mean(S.conv==1), 100*mean(S.conv(atk)==1), 100*mean(S.conv(nor)==1), ...
            mean(S.iters), max(S.iters), sum(S.start==1), sum(S.start==2), sum(S.start>=3), 100*mean(S.cfConv(atk)==1));
        out('  timing: %.2f ms/logged step (estimator %.2f ms); channel total %.1f s\n', 1e3*mean(S.tStep), 1e3*mean(S.tEst), s.tTotal);
    end
    fclose(fid);
    type(fullfile(here,'out',[tag '.txt']));
end

function fprintf2(fid, varargin), fprintf(fid, varargin{:}); end
function s = ternary(c, a, b), if c, s = a; else, s = b; end, end
function s = toStr(v)
    if ischar(v), s = v; elseif iscell(v), s = ['{' strjoin(v, ',') '}']; else, s = mat2str(v); end
end
function q = prctile1(x, pc)
    x = sort(x(~isnan(x))); n = numel(x); if n == 0, q = NaN; return; end
    r = 1 + (n-1)*pc/100; lo = floor(r); hi = ceil(r); q = x(lo) + (r-lo)*(x(hi)-x(lo));
end
function [lo, hi] = binoRange(n, p)
    k = 0:n;
    lp = gammaln(n+1) - gammaln(k+1) - gammaln(n-k+1) + k*log(p) + (n-k)*log(1-p);
    cdf = cumsum(exp(lp));
    lo = find(cdf >= 0.025, 1) - 1;  hi = find(cdf >= 0.975, 1) - 1;
end
