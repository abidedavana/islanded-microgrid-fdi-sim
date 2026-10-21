function R = v2_selftest(which, t1tag)
% V2_SELFTEST  Self-tests for SimulateMicrogridFDI_v2.
%   v2_selftest              % T0..T5
%   v2_selftest('T1')        % one test (or a cell list)
% Each test prints PASS/FAIL with numbers and appends to out/selftest_results.txt.
%   T0  augmented model sanity: H_aug vs finite differences, LM recovers x from
%       noise-free z (flat start), both meter sets.
%   T1  regression: all v2 options at default (seed 42, 3000 steps, 400 warm-up,
%       data = RegroupedData.csv) reproduce every committed CSV in
%       MATLAB/VectorDataset_PF_corrected and _QV_corrected (byte-identical, or
%       max-abs-diff <= 1e-12).
%   T2  AC-consistency: z_att - noise == h_aug(x_true + c) to 1e-10 (checked with
%       the simulator's h_aug AND an independent branch-flow implementation).
%   T3  AC-WLS on 500 normal steps: convergence >= 99 %, false-alarm count inside
%       the exact binomial 95 % range for alpha = 1 %.
%   T4  linear attack (a = H c) under AC-WLS with |V| meters is detected.
%   T5  timing per step.
    if nargin < 1, which = {'T0','T1','T2','T3','T4','T5'}; end
    if nargin < 2, t1tag = ''; end
    which = cellstr(which);
    here = fileparts(mfilename('fullpath'));
    od = fullfile(here,'out');  if ~exist(od,'dir'), mkdir(od); end
    resFile = fullfile(od,'selftest_results.txt');
    R = struct();
    for k = 1:numel(which)
        t0 = tic;
        switch upper(which{k})
            case 'T0', [ok, msg] = T0();
            case 'T1', [ok, msg] = T1(here, t1tag);
            case 'T2', [ok, msg] = T2(here);
            case 'T3', [ok, msg] = T3(here);
            case 'T4', [ok, msg] = T4(here);
            case 'T5', [ok, msg] = T5(here);
            otherwise, error('unknown test %s', which{k});
        end
        line = sprintf('[%s] %s %s  (%.0f s)\n%s\n', char(datetime('now','Format','yyyy-MM-dd HH:mm')), ...
            upper(which{k}), passStr(ok), toc(t0), msg);
        fprintf('%s', line);
        fid = fopen(resFile,'a'); fprintf(fid, '%s', line); fclose(fid);
        R.(upper(which{k})) = struct('ok',ok,'msg',msg);
    end
end

function s = passStr(ok), if ok, s = 'PASS'; else, s = 'FAIL'; end, end

function [M, base, x, api, cfg, net] = setupBase(vmeters)
    api = SimulateMicrogridFDI_v2('api');
    net = api.case33(); Ybus = api.makeYbus(net); [Yf,f_idx] = api.makeYf(net);
    cfg = api.droopConfig(); N = size(net.bus,1);
    if strcmp(vmeters,'der'), vb = cfg.der_bus; else, vb = []; end
    M = api.makeModel(net, Ybus, Yf, f_idx, cfg, vb, 1e-3);
    Pd = net.bus(:,2)/net.baseMVA;  Qd = net.bus(:,3)/net.baseMVA;
    Pset = cfg.P_rate/sum(cfg.P_rate)*sum(Pd);
    base = api.droopPF(net, Ybus, cfg, Pset, ones(1,4), Pd, Qd);
    x = [base.theta(setdiff(1:N,cfg.ref_bus)); base.Vm];
end

% -------------------------------------------------------------------------
function [ok, msg] = T0()
    msg = ''; ok = true;
    for vm = {'none','der'}
        [M, ~, x, api] = setupBase(vm{1});
        H = api.HAug(M, x);  z0 = api.hAug(M, x);  e = 1e-7;  Hn = zeros(size(H));
        for i = 1:numel(x), xp = x; xp(i) = xp(i)+e; Hn(:,i) = (api.hAug(M,xp)-z0)/e; end
        err = max(abs(H(:)-Hn(:)))/max(abs(H(:)));
        opt = struct('maxIter',50,'tol',1e-8,'mu0Warm',1e-6,'mu0Flat',1e-3);
        flat = [zeros(M.N-1,1); ones(M.N,1)];
        [xs, J, cv, it] = api.lmSolve(M, z0, flat, 1e-3, opt);
        ex = max(abs(xs-x));
        okk = err < 1e-5 && cv && ex < 1e-7 && J < 1e-8;
        ok = ok && okk;
        msg = [msg sprintf(['  vmeters=%-4s m=%d: rel|H_aug-FD|=%.2e; LM flat start on noise-free z: ' ...
            'conv=%d iters=%d J=%.2e max|x-x_true|=%.2e -> %s\n'], vm{1}, size(H,1), err, cv, it, J, ex, passStr(okk))]; %#ok<AGROW>
    end
end

% -------------------------------------------------------------------------
function [ok, msg] = T1(here, t1tag)
    api = SimulateMicrogridFDI_v2('api');
    od = fullfile(here,'out',['T1_regress' t1tag]);
    t = tic;
    SimulateMicrogridFDI_v2('steps',3000,'warmup',400,'seed',42,'data',api.uciPath(),'outDir',od);
    tRun = toc(t);
    proj = fileparts(fileparts(fileparts(api.uciPath())));      % ...\Python
    proj = fileparts(proj);                                       % project root
    msg = sprintf('  run time (both channels, 3000 steps each) %.1f s; maxNumCompThreads=%d; outDir %s\n', ...
        tRun, maxNumCompThreads, od); ok = true;
    for ch = {'PF','QV'}
        cdir = fullfile(proj,'MATLAB',['VectorDataset_' ch{1} '_corrected']);
        F = dir(fullfile(cdir,'*.csv'));
        for k = 1:numel(F)
            fa = fullfile(cdir, F(k).name);  fb = fullfile(od, ch{1}, F(k).name);
            if ~exist(fb,'file'), ok = false; msg = [msg sprintf('  %s/%s MISSING\n', ch{1}, F(k).name)]; continue; end %#ok<AGROW>
            ba = fileread(fa); bb = fileread(fb);
            same = strcmp(ba, bb);
            if same
                d = 0; how = 'byte-identical';
            elseif strcmp(F(k).name,'events.csv')
                d = NaN; how = 'TEXT DIFFERS';
            else
                A = readmatrix(fa); B = readmatrix(fb);
                if ~isequal(size(A),size(B)), d = Inf; else
                    nanOk = isequal(isnan(A), isnan(B));
                    d = max(abs(A(~isnan(A)) - B(~isnan(B))), [], 'all'); if isempty(d), d = 0; end
                    if ~nanOk, d = Inf; end
                end
                how = sprintf('numeric max|diff|=%.3e', d);
            end
            okk = same || (~isnan(d) && d <= 1e-12);
            ok = ok && okk;
            msg = [msg sprintf('  %s/%-18s %s %s\n', ch{1}, F(k).name, how, passStr(okk))]; %#ok<AGROW>
        end
        nf = numel(F);
        msg = [msg sprintf('  %s: %d committed CSVs compared (Fig*.png/pdf are plotting outputs, not simulator outputs)\n', ch{1}, nf)]; %#ok<AGROW>
    end
end

% -------------------------------------------------------------------------
function [ok, msg] = T2(here)
    ok = true; msg = '';
    cases = {'der','true'; 'none','true'; 'der','stale'};
    for ci = 1:size(cases,1)
        vm = cases{ci,1}; kn = cases{ci,2};
        od = fullfile(here,'out',sprintf('T2_%s_%s', vm, kn));
        SimulateMicrogridFDI_v2('steps',160,'warmup',20,'seed',3,'data','uci','vmeters',vm, ...
            'attack','ac','estimator','linear','attknow',kn,'debugsteps',8,'outDir',od,'verbose',false);
        [M, ~, ~, api, cfg, net] = setupBase(vm);
        for ch = {'pf','qv'}
            S = load(fullfile(od, upper(ch{1}), ['debug_' ch{1} '.mat'])); dbg = S.dbg;
            e1 = 0; e2 = 0; e3 = 0;
            for q = 1:numel(dbg)
                d = dbg(q);
                lhs = d.zAtt - d.noise;
                if strcmp(kn,'true')
                    rhs1 = api.hAug(M, d.xTrue + d.c);
                    rhs2 = indepH(net, cfg, M, d.xTrue + d.c);
                else       % stale: a = h(x_prev + c) - h(x_prev) added to h(x_true)
                    rhs1 = api.hAug(M, d.xTrue) + api.hAug(M, d.xK + d.c) - api.hAug(M, d.xK);
                    rhs2 = indepH(net, cfg, M, d.xTrue) + indepH(net, cfg, M, d.xK + d.c) - indepH(net, cfg, M, d.xK);
                end
                e1 = max(e1, max(abs(lhs - rhs1)));  e2 = max(e2, max(abs(lhs - rhs2)));
                e3 = max(e3, max(abs(d.a)));
            end
            okk = e1 < 1e-10 && e2 < 1e-10 && numel(dbg) > 0;
            ok = ok && okk;
            msg = [msg sprintf(['  vmeters=%-4s attknow=%-5s %s: %d attacked steps, m=%d, max|z_att-noise-h_aug(x+c)| ' ...
                '= %.2e (sim h) / %.2e (independent branch-flow h); max|a|=%.3f -> %s\n'], ...
                vm, kn, upper(ch{1}), numel(dbg), numel(dbg(1).zAtt), e1, e2, e3, passStr(okk))]; %#ok<AGROW>
        end
    end
end

function z = indepH(net, cfg, M, x)
    % independent measurement function from branch data (no Ybus):
    % S_ij = V_i conj((V_i - V_j) y),  S_ji = V_j conj((V_j - V_i) y)
    N = size(net.bus,1);  Zb = (net.baseKV*1e3)^2/(net.baseMVA*1e6);
    th = zeros(N,1); th(setdiff(1:N,cfg.ref_bus)) = x(1:N-1); Vm = x(N:end);
    V = Vm.*exp(1i*th);  Lb = size(net.branch,1);
    Sinj = zeros(N,1); Sf = zeros(Lb,1);
    for k = 1:Lb
        i = net.branch(k,1); j = net.branch(k,2);
        y = 1/((net.branch(k,3)+1i*net.branch(k,4))/Zb);
        Sij = V(i)*conj((V(i)-V(j))*y);  Sji = V(j)*conj((V(j)-V(i))*y);
        Sinj(i) = Sinj(i) + Sij;  Sinj(j) = Sinj(j) + Sji;  Sf(k) = Sij;
    end
    z = [real(Sinj); imag(Sinj); real(Sf); imag(Sf)];
    if ~isempty(M.vmBus), z = [z; abs(V(M.vmBus))]; end
end

% -------------------------------------------------------------------------
function [lo, hi] = binoRange(n, p)
    k = 0:n;
    lp = gammaln(n+1) - gammaln(k+1) - gammaln(n-k+1) + k*log(p) + (n-k)*log(1-p);
    cdf = cumsum(exp(lp));
    lo = find(cdf >= 0.025, 1) - 1;  hi = find(cdf >= 0.975, 1) - 1;
end

function [ok, msg] = T3(here)
    ok = true; msg = '';
    for vm = {'der','none'}
        od = fullfile(here,'out',['T3_' vm{1}]);
        o = SimulateMicrogridFDI_v2('steps',600,'warmup',100,'seed',42,'data','uci','attackprob',0, ...
            'vmeters',vm{1},'attack','ac','estimator','acwls','ctrlinput','estimate','channels',{'pf'}, ...
            'outDir',od,'verbose',false);
        S = o.pf.S;  n = numel(S.J);  nc = sum(S.conv==1);  na = sum(S.alarm==1);
        [lo, hi] = binoRange(n, 0.01);
        conv = 100*nc/n;  okk = conv >= 99 && na >= lo && na <= hi;
        st = S.start;
        J = S.J(S.conv==1);  dof = o.pf.dof;
        msg = [msg sprintf(['  vmeters=%-4s n=%d normal steps: converged %d (%.2f%%), iters mean %.2f max %d, ' ...
            'starts warm/flat/retry=%d/%d/%d; alarms %d (%.2f%%), binomial 95%% range for alpha=1%%: [%d,%d]; ' ...
            'mean J=%.2f (dof %d), var J=%.1f (2dof=%d) -> %s%s\n'], vm{1}, n, nc, conv, mean(S.iters), max(S.iters), ...
            sum(st==1), sum(st==2), sum(st>=3), na, 100*na/n, lo, hi, mean(J), dof, var(J), 2*dof, passStr(okk), ...
            ternary(strcmp(vm{1},'none'),' (info only; not required)',''))]; %#ok<AGROW>
        if strcmp(vm{1},'der'), ok = okk; end
    end
end

function s = ternary(c, a, b), if c, s = a; else, s = b; end, end

% -------------------------------------------------------------------------
function [ok, msg] = T4(here)
    ok = true; msg = '';
    % row 1 = the PASS case: the committed linear attack (a = H c designed on the 130
    % legacy meters, |V| meters untouched) seen by AC-WLS with |V| meters.
    cfgs = {'der','acwls','legacy'; 'none','acwls','all'; 'der','acwls','all'; 'der','linear','legacy'};
    for ci = 1:size(cfgs,1)
        od = fullfile(here,'out',sprintf('T4_%s_%s_%s', cfgs{ci,:}));
        o = SimulateMicrogridFDI_v2('steps',500,'warmup',100,'seed',42,'data','uci', ...
            'vmeters',cfgs{ci,1},'attack','linear','estimator',cfgs{ci,2},'attmeters',cfgs{ci,3}, ...
            'ctrlinput','estimate','outDir',od,'verbose',false);
        for ch = {'pf','qv'}
            s = o.(ch{1}); S = s.S; atk = S.attacked==1;
            dr = 100*mean(S.alarm(atk)==1); fa = 100*mean(S.alarm(~atk)==1);
            msg = [msg sprintf(['  vmeters=%-4s estimator=%-6s attmeters=%-6s %s: linear attack detected %d/%d (%.1f%%), ' ...
                'normal alarms %d/%d (%.2f%%), median J/tau att %.3g, conv %.1f%%, lossMeas<0 on %d/%d att, ' ...
                'mean VhatDer-Vtrue att %+.4f pu, mean fHat-fTrue att %+.4f Hz, cross att %d\n'], ...
                cfgs{ci,:}, upper(ch{1}), sum(S.alarm(atk)==1), sum(atk), dr, sum(S.alarm(~atk)==1), ...
                sum(~atk), fa, median(S.J(atk))/s.tau, s.convPct, sum(S.lossMeas(atk) < 0), sum(atk), ...
                mean(S.VhatDerMean(atk)-S.VtrueDerMean(atk)), mean(S.fHat(atk)-S.fTrue(atk)), sum(S.cross(atk)==1))]; %#ok<AGROW>
            if ci == 1 && strcmp(ch{1},'pf'), ok = dr >= 95; end
        end
    end
    msg = [msg ['  PASS criterion: committed (legacy, |V|-unaware) P-f linear attack detected on >= 95% of ' ...
        'attacked steps by AC-WLS with |V| meters' newline]];
end

% -------------------------------------------------------------------------
function [ok, msg] = T5(here)
    msg = ''; ok = true;
    runs = {'orig-default',  {}; ...
            'corrected',     {'vmeters','der','attack','ac','estimator','acwls','ctrlinput','estimate'}; ...
            'corrected-noaux', {'vmeters','der','attack','ac','estimator','acwls','ctrlinput','estimate','auxtests',false}};
    for r = 1:size(runs,1)
        od = fullfile(here,'out',['T5_' strrep(runs{r,1},'-','_')]);
        t = tic;
        o = SimulateMicrogridFDI_v2('steps',600,'warmup',100,'seed',5,'data','uci', runs{r,2}{:}, ...
            'outDir',od,'verbose',false);
        tt = toc(t);
        msg = [msg sprintf(['  %-16s PF %.2f ms/step, QV %.2f ms/step (logged steps; 100 warm-up steps cost ~PF only); ' ...
            'wall %.1f s for 2x600 steps incl. start-up and CSV writing\n'], runs{r,1}, 1e3*o.pf.tStepMean, ...
            1e3*o.qv.tStepMean, tt)]; %#ok<AGROW>
    end
end
