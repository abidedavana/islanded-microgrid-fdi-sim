function SimulateMicrogridFDI(varargin)
% SIMULATEMICROGRIDFDI  Corrected stealthy FDI simulation for an ISLANDED,
% inverter-based AC microgrid (modified IEEE 33-bus Baran & Wu feeder).
%
% This is a faithful MATLAB port of microgrid_fdi_sim.py.  It is deliberately
% self-contained (NO MATPOWER dependency) so it cannot reintroduce the
% infinite-slack-bus error of the previous SimulateIsland.m / SimulateIsland_Q.m,
% in which an ideal slack absorbed all power imbalance and the "frequency" was a
% cosmetic post-processing constant.
%
% Here the islanded droop power flow has NO slack: the common system frequency f
% is a genuine unknown solved from global active-power balance, and every grid-
% forming inverter shares load through its P-f and Q-V droop characteristics.
% A stealthy FDI a = H*c biases the operator's state estimate; the operator's
% secondary control then mis-dispatches the DERs and the REAL frequency/voltage
% (from a converged power flow) deviate, triggering UFLS/OFLS or UVLS/OVLS.
%
% Usage:
%   SimulateMicrogridFDI                 % run self-tests + both channels
%   SimulateMicrogridFDI('selftest')     % self-tests only
%   SimulateMicrogridFDI('steps',3000,'warmup',400)
%
% Outputs go to  VectorDataset_PF_corrected/  and  VectorDataset_QV_corrected/.

    p = parseArgs(varargin{:});
    rng(p.seed);                                   % reproducibility

    selftest();
    if p.selftestOnly, return; end
    if p.study, runStudies(p); return; end

    runChannel('pf', p);
    runChannel('qv', p);
end

% =========================================================================
function p = parseArgs(varargin)
    p.steps = 3000; p.warmup = 400; p.seed = 42; p.selftestOnly = false;
    p.attackProb = 0.25; p.sigma = 1e-3; p.access = 0.70; p.grossLimit = 0.5;
    p.Kf = 1.6; p.Kv = 1.2; p.dataCsv = '';
    p.study = false; p.magScale = 1; p.seeds = 1:6; p.save = true; p.verbose = true;
    k = 1;
    while k <= numel(varargin)
        a = varargin{k};
        if strcmpi(a,'selftest'), p.selftestOnly = true; k = k+1; continue; end
        if strcmpi(a,'study'),    p.study = true;        k = k+1; continue; end
        switch lower(a)
            case 'steps',     p.steps = varargin{k+1};
            case 'warmup',    p.warmup = varargin{k+1};
            case 'seed',      p.seed = varargin{k+1};
            case 'data',      p.dataCsv = varargin{k+1};
            case 'attackprob',p.attackProb = varargin{k+1};
            case 'access',    p.access = varargin{k+1};
            case 'magscale',  p.magScale = varargin{k+1};
            case 'seeds',     p.seeds = varargin{k+1};
        end
        k = k + 2;
    end
end

% =========================================================================
% 1.  TEST SYSTEM  (modified IEEE 33-bus, Baran & Wu 1989)
% =========================================================================
function net = case33()
    net.baseMVA = 5.0;  net.baseKV = 12.66;
    % bus_id, Pd[kW], Qd[kVAr]
    busKW = [ ...
        1 0 0; 2 100 60; 3 90 40; 4 120 80; 5 60 30; 6 60 20; 7 200 100; ...
        8 200 100; 9 60 20; 10 60 20; 11 45 30; 12 60 35; 13 60 35; ...
        14 120 80; 15 60 10; 16 60 20; 17 60 20; 18 90 40; 19 90 40; ...
        20 90 40; 21 90 40; 22 90 40; 23 90 50; 24 420 200; 25 420 200; ...
        26 60 25; 27 60 25; 28 60 20; 29 120 70; 30 200 600; 31 150 70; ...
        32 210 100; 33 60 40];
    net.bus = [busKW(:,1), busKW(:,2)/1e3, busKW(:,3)/1e3];     % -> MW, MVAr
    % from, to, R[ohm], X[ohm]
    net.branch = [ ...
        1 2 0.0922 0.0470; 2 3 0.4930 0.2511; 3 4 0.3660 0.1864; ...
        4 5 0.3811 0.1941; 5 6 0.8190 0.7070; 6 7 0.1872 0.6188; ...
        7 8 0.7114 0.2351; 8 9 1.0300 0.7400; 9 10 1.0440 0.7400; ...
        10 11 0.1966 0.0650; 11 12 0.3744 0.1238; 12 13 1.4680 1.1550; ...
        13 14 0.5416 0.7129; 14 15 0.5910 0.5260; 15 16 0.7463 0.5450; ...
        16 17 1.2890 1.7210; 17 18 0.7320 0.5740; 2 19 0.1640 0.1565; ...
        19 20 1.5042 1.3554; 20 21 0.4095 0.4784; 21 22 0.7089 0.9373; ...
        3 23 0.4512 0.3083; 23 24 0.8980 0.7091; 24 25 0.8960 0.7011; ...
        6 26 0.2030 0.1034; 26 27 0.2842 0.1447; 27 28 1.0590 0.9337; ...
        28 29 0.8042 0.7006; 29 30 0.5075 0.2585; 30 31 0.9744 0.9630; ...
        31 32 0.3105 0.3619; 32 33 0.3410 0.5302];
end

function cfg = droopConfig()
    cfg.f_nom = 50.0;  cfg.V_nom = 1.0;
    cfg.der_bus = [1 6 18 25];   cfg.ref_bus = 1;
    cfg.P_rate = [0.40 0.20 0.20 0.20];      % pu on 5 MVA base
    cfg.Q_rate = [0.30 0.15 0.15 0.15];
    cfg.m_p = 0.01 * cfg.f_nom ./ cfg.P_rate;    % Hz/pu  (1% f-droop)
    cfg.n_q = 0.05 * cfg.V_nom ./ cfg.Q_rate;    % puV/puQ (5% V-droop)
end

% =========================================================================
% 2.  NETWORK MATRICES
% =========================================================================
function Ybus = makeYbus(net)
    Zbase = (net.baseKV*1e3)^2 / (net.baseMVA*1e6);
    N = size(net.bus,1);   Ybus = zeros(N);
    for k = 1:size(net.branch,1)
        i = net.branch(k,1); j = net.branch(k,2);
        y = 1 / ((net.branch(k,3) + 1i*net.branch(k,4)) / Zbase);
        Ybus(i,i) = Ybus(i,i)+y;  Ybus(j,j) = Ybus(j,j)+y;
        Ybus(i,j) = Ybus(i,j)-y;  Ybus(j,i) = Ybus(j,i)-y;
    end
end

function [Yf, f_idx] = makeYf(net)
    Zbase = (net.baseKV*1e3)^2 / (net.baseMVA*1e6);
    N = size(net.bus,1);  L = size(net.branch,1);
    Yf = zeros(L,N);  f_idx = zeros(L,1);
    for k = 1:L
        i = net.branch(k,1); j = net.branch(k,2);
        y = 1 / ((net.branch(k,3) + 1i*net.branch(k,4)) / Zbase);
        Yf(k,i) = Yf(k,i)+y;  Yf(k,j) = Yf(k,j)-y;  f_idx(k) = i;
    end
end

% =========================================================================
% 3.  ISLANDED DROOP POWER FLOW  (Newton-Raphson, analytic Jacobian)
% =========================================================================
function [dS_dVa, dS_dVm] = dSbus_dV(Ybus, V)
    Ibus = Ybus*V;
    diagV = diag(V);  diagIbus = diag(Ibus);  diagVnorm = diag(V./abs(V));
    dS_dVm = diagV*conj(Ybus*diagVnorm) + conj(diagIbus)*diagVnorm;
    dS_dVa = 1i*diagV*conj(diagIbus - Ybus*diagV);
end

function out = droopPF(net, Ybus, cfg, Pset, V0, Pd, Qd, Qset, tol, maxIter)
    if nargin < 9 || isempty(Qset), Qset = zeros(1,numel(cfg.der_bus)); end
    if nargin < 10, tol = 1e-9; maxIter = 40; end
    N = size(net.bus,1);  der = cfg.der_bus;  ref = cfg.ref_bus;
    nonRef = setdiff(1:N, ref);
    m_p = cfg.m_p;  n_q = cfg.n_q;  f_nom = cfg.f_nom;

    theta = zeros(N,1);  Vm = ones(N,1);  f = f_nom;

    for it = 0:maxIter
        V = Vm .* exp(1i*theta);
        S = V .* conj(Ybus*V);
        [Psp, Qsp, Pg, Qg] = specInj(Vm, f);
        Fp = real(S) - Psp;   Fq = imag(S) - Qsp;
        F = [Fp; Fq];
        if max(abs(F)) < tol
            out = pack(true); return;
        end
        [dVa, dVm] = dSbus_dV(Ybus, V);
        J_Pth = real(dVa(:,nonRef));   J_PV = real(dVm);
        J_Qth = imag(dVa(:,nonRef));   J_QV = imag(dVm);
        colPf = zeros(N,1);  colQf = zeros(N,1);
        for kk = 1:numel(der)
            J_QV(der(kk),der(kk)) = J_QV(der(kk),der(kk)) + 1/n_q(kk);
            colPf(der(kk)) = 1/m_p(kk);
        end
        Jac = [J_Pth, J_PV, colPf; J_Qth, J_QV, colQf];
        du = Jac \ (-F);
        theta(nonRef) = theta(nonRef) + du(1:N-1);
        Vm = min(max(Vm + du(N:2*N-1), 0.5), 1.5);
        f  = f + du(2*N);
    end
    out = pack(false);

    function [Psp,Qsp,Pg,Qg] = specInj(Vm, f)
        Pg = zeros(N,1);  Qg = zeros(N,1);
        for kk = 1:numel(der)
            b = der(kk);
            Pg(b) = Pset(kk) - (f - f_nom)/m_p(kk);
            Qg(b) = Qset(kk) + (V0(kk) - Vm(b))/n_q(kk);
        end
        Psp = Pg - Pd;   Qsp = Qg - Qd;
    end
    function o = pack(ok)
        V = Vm .* exp(1i*theta);
        [~,~,Pg,Qg] = specInj(Vm, f);
        o = struct('success',ok,'V',V,'f',f,'theta',theta,'Vm',Vm, ...
                   'Pg',Pg(der),'Qg',Qg(der));
    end
end

% =========================================================================
% 4.  MEASUREMENT MODEL + JACOBIAN
% =========================================================================
function z = measModel(net, Ybus, Yf, f_idx, V)
    S  = V .* conj(Ybus*V);
    Sf = V(f_idx) .* conj(Yf*V);
    z  = [real(S); imag(S); real(Sf); imag(Sf)];
end

function H = measJacobian(net, Ybus, Yf, f_idx, V, ref)
    N = size(net.bus,1);  L = size(Yf,1);  nonRef = setdiff(1:N, ref);
    [dVa, dVm] = dSbus_dV(Ybus, V);

    Vnorm = V./abs(V);
    E = zeros(L,N);  E(sub2ind([L N], (1:L)', f_idx)) = 1;   % from-bus selector
    diagVf = diag(V(f_idx));  If = Yf*V;  diagIf = diag(If);
    dSf_dVa = 1i*diagVf*(conj(diagIf)*E - conj(Yf*diag(V)));
    dSf_dVm = diagVf*conj(Yf*diag(Vnorm)) + conj(diagIf)*E*diag(Vnorm);

    cols = @(Mva,Mvm) [Mva(:,nonRef), Mvm];
    H = [ cols(real(dVa), real(dVm));    % Pinj
          cols(imag(dVa), imag(dVm));    % Qinj
          cols(real(dSf_dVa), real(dSf_dVm));   % Pflow
          cols(imag(dSf_dVa), imag(dSf_dVm)) ]; % Qflow
end

% =========================================================================
% 5.  WLS + BDD + ATTACK
% =========================================================================
function [dx, J] = wlsResidual(H, W, dz)
    G = H'*W*H + 1e-10*eye(size(H,2));
    dx = G \ (H'*W*dz);
    r = dz - H*dx;
    J = real(r'*W*r);
end

function tau = chi2Threshold(dof, alpha)
    if exist('chi2inv','file')
        tau = chi2inv(1-alpha, dof);
    else                              % Wilson-Hilferty approximation
        z = 2.3263;                   % ~99th percentile of N(0,1)
        tau = dof*(1 - 2/(9*dof) + z*sqrt(2/(9*dof)))^3;
    end
end

function [c, a] = minFootprintAttack(H, G, A, b)
    % min ||H c||^2  s.t.  A c = b   ->  smallest measurement footprint
    GinvAt = G \ A';
    c = GinvAt * ((A*GinvAt) \ b);
    a = H*c;
end

% =========================================================================
% 6.  SIMULATION DRIVER
% =========================================================================
function summary = runChannel(channel, p)
    if ~isfield(p,'magScale'), p.magScale = 1;    end
    if ~isfield(p,'save'),     p.save     = true; end
    if ~isfield(p,'verbose'),  p.verbose  = true; end
    summary = struct();
    net = case33();  Ybus = makeYbus(net);  [Yf,f_idx] = makeYf(net);
    cfg = droopConfig();  der = cfg.der_bus;  ref = cfg.ref_bus;
    N = size(net.bus,1);  L = size(net.branch,1);
    f_nom = cfg.f_nom;  V_nom = cfg.V_nom;
    rateFrac = cfg.P_rate / sum(cfg.P_rate);

    nMeas = 2*N + 2*L;  nState = (N-1) + N;  dof = nMeas - nState;
    W = eye(nMeas) / p.sigma^2;
    tau = chi2Threshold(dof, 0.01);
    G = [];                                   % Gram matrix, lazily set per step
    F_TRIP = 0.20;  V_TRIP = 0.10;

    [PdAll, QdAll] = loadProfile(net, p.steps, p.dataCsv);

    Z = []; lab = []; Jl = []; Jn = []; Jlim = []; ftp = [];
    des = []; perc = []; rdev = []; tauL = []; stl = []; ncaught = []; lcaught = [];
    ev = {};   Jbase = [];

    if p.verbose
        fprintf('\n=== Channel %s | steps=%d warmup=%d p_atk=%.0f%% ===\n', ...
            upper(channel), p.steps, p.warmup, p.attackProb*100);
        fprintf('    nMeas=%d nState=%d dof=%d tau_chi2(1%%)=%.2f\n', ...
            nMeas, nState, dof, tau);
    end

    nSkip = 0;
    for j = 1:p.steps
        Pd = PdAll(j,:)';  Qd = QdAll(j,:)';
        Pset = rateFrac * sum(Pd);   V0 = repmat(V_nom,1,numel(der));
        Qset = zeros(1,numel(der));

        base = droopPF(net, Ybus, cfg, Pset, V0, Pd, Qd, Qset);
        if ~base.success, nSkip = nSkip+1; continue; end
        V = base.V;
        zClean = measModel(net, Ybus, Yf, f_idx, V);
        noise = p.sigma*randn(nMeas,1);
        zMeas = zClean + noise;   dz = zMeas - zClean;
        H = measJacobian(net, Ybus, Yf, f_idx, V, ref);

        [~, J0] = wlsResidual(H, W, dz);
        Jbase(end+1,1) = J0; %#ok<AGROW>
        if j <= p.warmup, continue; end

        attacked = rand() < p.attackProb;
        c = zeros(nState,1);  designVal = 0;  footprint = 0;
        G = H'*H + 1e-9*eye(nState);

        if attacked
            if strcmp(channel,'pf')
                dfT = (0.20 + rand()*0.35)*p.magScale;  designVal = dfT;
                dP = (-dfT ./ cfg.m_p)';                 % column, length 4
                A = H(der,:);
                [c, a] = minFootprintAttack(H, G, A, dP);
            else
                dVT = (0.04 + rand()*0.05)*p.magScale;  designVal = dVT;
                A = zeros(numel(der), nState);
                for k = 1:numel(der), A(k,(N-1)+der(k)) = 1; end
                [c, a] = minFootprintAttack(H, G, A, repmat(dVT,numel(der),1));
            end
            footprint = max(abs(a));
            zMeas = zMeas + a;  dzAtt = zMeas - zClean;
            [~, Jatt] = wlsResidual(H, W, dzAtt);
            grossOk = footprint < p.grossLimit;
            stealthy = (Jatt < tau) && grossOk;

            eta = randn(nMeas,1);  eta = eta/norm(eta)*norm(a);
            [~, Jnaive] = wlsResidual(H, W, dz + eta);
            naiveCaught = Jnaive >= tau;

            accMask = rand(nMeas,1) < p.access;
            [~, Jlimited] = wlsResidual(H, W, dz + a.*accMask);
            limitedCaught = Jlimited >= tau;
            Jlog = Jatt; Jnlog = Jnaive; Jlimlog = Jlimited;
        else
            stealthy = J0 < tau;  naiveCaught = false; limitedCaught = false;
            Jlog = J0; Jnlog = NaN; Jlimlog = NaN;
        end

        % ---- perceived quantities from biased estimate x_hat = x_true + c ----
        VmHat = base.Vm;
        for b = 1:N, VmHat(b) = VmHat(b) + c((N-1)+b); end
        PinjTrue = zClean(1:N);
        PinjHat = PinjTrue(der) + H(der,:)*c;
        PgHat = PinjHat + Pd(der);
        fHat = f_nom - mean(cfg.m_p(:).*(PgHat - Pset(:)));
        if strcmp(channel,'pf'), percVal = fHat; else, percVal = mean(VmHat(der)); end

        % ---- operator secondary control reacts to the biased estimate ----
        PsetNew = Pset;  V0New = V0;
        if strcmp(channel,'pf')
            PsetNew = Pset - p.Kf*(fHat - f_nom).*rateFrac;
            PsetNew = min(max(PsetNew, 0), cfg.P_rate);
        else
            V0New = V0 - p.Kv*(VmHat(der)' - V_nom);
            V0New = min(max(V0New, 0.90), 1.10);
        end

        % ---- REAL system response with mis-dispatched setpoints ----
        post = droopPF(net, Ybus, cfg, PsetNew, V0New, Pd, Qd, Qset);
        if post.success
            if strcmp(channel,'pf')
                realDev = post.f - f_nom;
                if realDev < -F_TRIP, evt = 'UFLS';
                elseif realDev > F_TRIP, evt = 'OFLS'; else, evt = 'None'; end
            else
                realDev = min(post.Vm) - V_nom;
                if realDev < -V_TRIP, evt = 'UVLS';
                elseif (max(post.Vm)-V_nom) > V_TRIP, evt = 'OVLS'; else, evt = 'None'; end
            end
        else
            realDev = NaN;  evt = 'Fail';
        end

        Z(end+1,:) = zMeas';  lab(end+1,1) = attacked; %#ok<AGROW>
        Jl(end+1,1) = Jlog; Jn(end+1,1) = Jnlog; Jlim(end+1,1) = Jlimlog; %#ok<AGROW>
        ftp(end+1,1) = footprint; des(end+1,1) = designVal; perc(end+1,1) = percVal; %#ok<AGROW>
        rdev(end+1,1) = realDev; tauL(end+1,1) = tau; %#ok<AGROW>
        stl(end+1,1) = stealthy; %#ok<AGROW>
        ncaught(end+1,1) = attacked && naiveCaught; %#ok<AGROW>
        lcaught(end+1,1) = attacked && limitedCaught; %#ok<AGROW>
        ev{end+1,1} = evt; %#ok<AGROW>
    end

    % ---- summary (always built; printed only if verbose) ----
    atk = lab==1;  nAtt = sum(atk);  n = numel(lab);
    valid = atk & ~isnan(rdev);
    if strcmp(channel,'pf'), k1='UFLS'; k2='OFLS'; u='Hz'; else, k1='UVLS'; k2='OVLS'; u='pu'; end
    summary.channel = channel;  summary.n = n;  summary.nAtt = nAtt;  summary.ev1name = k1;
    if nAtt > 0
        summary.stealthPct = 100*mean(stl(atk));
        summary.naivePct   = 100*mean(ncaught(atk));
        summary.limitedPct = 100*mean(lcaught(atk));
        summary.footprint  = mean(ftp(atk));
        summary.meanAbsDev = mean(abs(rdev(valid)));
        summary.maxAbsDev  = max(abs(rdev(valid)));
        summary.ev1Pct     = 100*sum(strcmp(ev(atk),k1))/nAtt;
    else
        [summary.stealthPct,summary.naivePct,summary.limitedPct,summary.footprint, ...
         summary.meanAbsDev,summary.maxAbsDev,summary.ev1Pct] = deal(NaN);
    end
    if p.verbose
        fprintf('    converged steps logged : %d  (skipped %d)\n', n, nSkip);
        if nAtt > 0
            fprintf('    attacks                : %d (%.1f%%)\n', nAtt, 100*nAtt/n);
            fprintf('    FDI stealthy (J<tau)   : %.1f%%\n', summary.stealthPct);
            fprintf('    mean meter footprint   : %.4f pu\n', summary.footprint);
            fprintf('    naive same-norm caught : %.1f%%\n', summary.naivePct);
            fprintf('    limited-access caught  : %.1f%%\n', summary.limitedPct);
            fprintf('    mean |real dev|        : %.4f %s (max %.4f)\n', ...
                summary.meanAbsDev, u, summary.maxAbsDev);
            fprintf('    %s/%s/Fail events       : %d/%d/%d\n', k1, k2, ...
                sum(strcmp(ev(atk),k1)), sum(strcmp(ev(atk),k2)), sum(strcmp(ev(atk),'Fail')));
        end
    end

    % ---- save dataset (skipped in study mode) ----
    if p.save
        if strcmp(channel,'pf'), outDir = 'VectorDataset_PF_corrected';
        else, outDir = 'VectorDataset_QV_corrected'; end
        if ~exist(outDir,'dir'), mkdir(outDir); end
        writematrix(Z,    fullfile(outDir,'features_z.csv'));
        writematrix(lab,  fullfile(outDir,'labels.csv'));
        writematrix(Jl,   fullfile(outDir,'J_residual.csv'));
        writematrix(Jn,   fullfile(outDir,'J_naive.csv'));
        writematrix(Jlim, fullfile(outDir,'J_limited.csv'));
        writematrix(ftp,  fullfile(outDir,'footprint.csv'));
        writematrix(des,  fullfile(outDir,'design.csv'));
        writematrix(perc, fullfile(outDir,'perceived.csv'));
        writematrix(rdev, fullfile(outDir,'real_deviation.csv'));
        writematrix(tauL, fullfile(outDir,'bdd_tau.csv'));
        writecell(ev,     fullfile(outDir,'events.csv'));
        fprintf('    dataset -> %s/\n', outDir);
    end
end

% =========================================================================
% 6b.  STUDY MODE  (statistical rigor + sensitivity sweeps)
% =========================================================================
function runStudies(p)
    chans = {'pf','qv'};
    base = p; base.save = false; base.verbose = false; base.study = false;
    ci95 = @(x) 1.96*std(x)/sqrt(numel(x));
    fprintf('\n############ STUDY MODE ############\n');
    fprintf('seeds=%s  steps=%d  warmup=%d\n', mat2str(p.seeds), p.steps, p.warmup);

    % ---- (A) Statistical rigor: multiple seeds, mean +/- 95%% CI ----
    fprintf('\n[A] Statistical rigor (%d seeds)\n', numel(p.seeds));
    Arows = {};
    for ci = 1:2
        ch = chans{ci};  St=[]; Nv=[]; Lm=[]; Dv=[]; Ev=[]; en='';
        for s = p.seeds
            rng(s);  sp = base;  sp.seed = s;
            sm = runChannel(ch, sp);
            St(end+1)=sm.stealthPct; Nv(end+1)=sm.naivePct; Lm(end+1)=sm.limitedPct; %#ok<AGROW>
            Dv(end+1)=sm.meanAbsDev; Ev(end+1)=sm.ev1Pct;  en=sm.ev1name; %#ok<AGROW>
        end
        fprintf(['  %s: stealthy %.1f+/-%.1f%%  naive-caught %.1f+/-%.1f%%  ' ...
                 'limited-caught %.1f+/-%.1f%%  mean|dev| %.4f+/-%.4f  %s %.1f+/-%.1f%%\n'], ...
            upper(ch), mean(St),ci95(St), mean(Nv),ci95(Nv), mean(Lm),ci95(Lm), ...
            mean(Dv),ci95(Dv), en, mean(Ev),ci95(Ev));
        Arows(end+1,:) = {upper(ch), mean(St),ci95(St), mean(Nv),ci95(Nv), ...
            mean(Lm),ci95(Lm), mean(Dv),ci95(Dv), mean(Ev),ci95(Ev)}; %#ok<AGROW>
    end
    T = cell2table(Arows, 'VariableNames', {'channel','stealthy_pct','stealthy_ci', ...
        'naive_caught_pct','naive_ci','limited_caught_pct','limited_ci', ...
        'mean_absdev','absdev_ci','event_pct','event_ci'});
    writetable(T, 'Study_CIs.csv');

    % ---- (B) Sensitivity: attack-magnitude sweep ----
    mags = [0.6 0.8 1.0 1.2 1.4];
    fprintf('\n[B] Magnitude sweep (impact vs attack size)\n');
    B = [];
    for ci = 1:2
        ch = chans{ci};
        for m = mags
            rng(7); sp = base; sp.seed = 7; sp.magScale = m;
            sm = runChannel(ch, sp);
            B(end+1,:) = [ci, m, sm.stealthPct, sm.meanAbsDev, sm.ev1Pct]; %#ok<AGROW>
            fprintf('  %s mag=%.2f: stealthy %.1f%%  mean|dev| %.4f  %s %.1f%%\n', ...
                upper(ch), m, sm.stealthPct, sm.meanAbsDev, sm.ev1name, sm.ev1Pct);
        end
    end
    writematrix(B, 'Study_mag_sweep.csv');   % [chan(1=pf,2=qv), magScale, stealthy%, mean|dev|, event%]

    % ---- (C) Sensitivity: meter-access sweep ----
    accs = [0.4 0.6 0.8 1.0];
    fprintf('\n[C] Meter-access sweep (detection vs attacker reach)\n');
    C = [];
    for ci = 1:2
        ch = chans{ci};
        for ac = accs
            rng(7); sp = base; sp.seed = 7; sp.access = ac;
            sm = runChannel(ch, sp);
            C(end+1,:) = [ci, ac, sm.limitedPct]; %#ok<AGROW>
            fprintf('  %s access=%.0f%%: limited-attack detected %.1f%%\n', ...
                upper(ch), 100*ac, sm.limitedPct);
        end
    end
    writematrix(C, 'Study_access_sweep.csv'); % [chan, access, detected%]

    fprintf('\nStudy CSVs: Study_CIs.csv, Study_mag_sweep.csv, Study_access_sweep.csv\n');
end

% =========================================================================
function [PdAll, QdAll] = loadProfile(net, nSteps, dataCsv)
    baseP = net.bus(:,2)'/net.baseMVA;   baseQ = net.bus(:,3)'/net.baseMVA;
    N = size(net.bus,1);
    if ~isempty(dataCsv) && exist(dataCsv,'file')
        raw = readmatrix(dataCsv);  col = raw(:,1);
        if numel(col) < nSteps, col = repmat(col, ceil(nSteps/numel(col)),1); end
        col = col(1:nSteps);
        scale = 0.6 + 0.8*(col-min(col))/(max(col)-min(col)+1e-9);
        PdAll = baseP .* scale;  QdAll = baseQ .* scale;
        return;
    end
    t = (0:nSteps-1)';
    diurnal = 0.75 + 0.25*sin(2*pi*t/1440 - pi/2) + 0.05*sin(2*pi*t/60);
    noise = 1 + 0.03*randn(nSteps, N);
    PdAll = (baseP .* diurnal) .* noise;
    QdAll = (baseQ .* diurnal) .* noise;
end

% =========================================================================
% 7.  SELF-TESTS
% =========================================================================
function selftest()
    fprintf('Running self-tests...\n');
    net = case33();  Ybus = makeYbus(net);  [Yf,f_idx] = makeYf(net);
    cfg = droopConfig();  der = cfg.der_bus;  ref = cfg.ref_bus;  N = size(net.bus,1);
    Pd = net.bus(:,2)/net.baseMVA;  Qd = net.bus(:,3)/net.baseMVA;
    Pset = cfg.P_rate/sum(cfg.P_rate)*sum(Pd);  V0 = ones(1,numel(der));

    % T1: droop PF converges + global power balance holds
    r = droopPF(net, Ybus, cfg, Pset, V0, Pd, Qd);
    assert(r.success, 'T1 FAIL: droop PF did not converge');
    losses = sum(real(r.V .* conj(Ybus*r.V)));
    bal = sum(r.Pg) - sum(Pd) - losses;
    assert(abs(bal) < 1e-6, sprintf('T1 FAIL: power balance off by %.2e', bal));
    fprintf('  [T1] droop PF OK: f=%.4f Hz, Vmin=%.4f, losses=%.1f kW\n', ...
        r.f, min(r.Vm), losses*net.baseMVA*1e3);

    % T2: analytic H vs finite differences
    V = r.V;  H = measJacobian(net, Ybus, Yf, f_idx, V, ref);
    nonRef = setdiff(1:N, ref);  z0 = measModel(net, Ybus, Yf, f_idx, V);
    eps0 = 1e-6;  Hnum = zeros(size(H));
    Vm = abs(V);  th = angle(V);
    for ci = 1:numel(nonRef)
        thp = th; thp(nonRef(ci)) = thp(nonRef(ci)) + eps0;
        Hnum(:,ci) = (measModel(net, Ybus, Yf, f_idx, Vm.*exp(1i*thp)) - z0)/eps0;
    end
    for b = 1:N
        Vmp = Vm; Vmp(b) = Vmp(b) + eps0;
        Hnum(:,(N-1)+b) = (measModel(net, Ybus, Yf, f_idx, Vmp.*exp(1i*th)) - z0)/eps0;
    end
    err = max(abs(H(:) - Hnum(:)));
    assert(err < 1e-3, sprintf('T2 FAIL: H vs finite-diff err %.2e', err));
    fprintf('  [T2] analytic H matches finite differences (max err %.2e)\n', err);

    % T3: stealthy a=Hc leaves WLS residual invariant
    nMeas = size(H,1);  W = eye(nMeas)/(1e-3^2);
    dz = 1e-3*randn(nMeas,1);  [~,J0] = wlsResidual(H,W,dz);
    c = 0.01*randn(size(H,2),1);  [~,J1] = wlsResidual(H,W,dz + H*c);
    assert(abs(J0-J1) < 1e-6, sprintf('T3 FAIL: dJ=%.2e', abs(J0-J1)));
    fprintf('  [T3] stealthy a=Hc invariance OK: dJ=%.2e\n', abs(J0-J1));

    % T4: same-norm naive injection raises residual
    eta = randn(nMeas,1);  eta = eta/norm(eta)*norm(H*c);
    [~,J2] = wlsResidual(H,W,dz + eta);
    assert(J2 > J0, 'T4 FAIL: naive injection did not raise residual');
    fprintf('  [T4] naive injection raises residual: J0=%.3f -> J_naive=%.3f\n', J0, J2);

    fprintf('All self-tests PASSED.\n');
end
