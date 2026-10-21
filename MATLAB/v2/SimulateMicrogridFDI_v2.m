function out = SimulateMicrogridFDI_v2(varargin)
% SIMULATEMICROGRIDFDI_V2  Corrected Phase-1 FDI simulator.
%
% Derived from the project's MATLAB/SimulateMicrogridFDI.m (left untouched).
% With ALL v2 options at their defaults the arithmetic, the random-number
% stream and the 11 output CSVs are identical to the original.  The v2
% options answer the reviewers' objections:
%
%   'vmeters'   'none' (orig) | 'der'   : add |V| meters at DER buses 1,6,18,25
%                                        (sigma = 1e-3), m = 134, dof = m - 65.
%   'attack'    'linear' (orig: a = H c) | 'ac' : c designed exactly as before
%                                        (min-norm with the Jacobian of the
%                                        deployed meter set), then the
%                                        AC-consistent a = h(x+c) - h(x) is injected.
%   'estimator' 'linear' (orig one-shot WLS at the true state) | 'acwls' :
%                                        iterative nonlinear WLS (Levenberg-
%                                        Marquardt), warm start from the previous
%                                        accepted estimate, flat-start fallback,
%                                        stop on max|dx|<1e-8 or 50 iterations.
%   'ctrlinput' 'oracle' (orig: x_true + c) | 'estimate' : controller uses the
%                                        estimator output (VmHat, PinjHat = h(xhat)).
%   'attknow'   'true' (orig) | 'stale' : attacker builds H, c and h from the
%                                        PREVIOUS step's true state.
%   'attmeters' 'all' (attacker designs on / falsifies every deployed meter) |
%               'legacy' (attacker unaware of the |V| meters: designs c with the
%                                        130 legacy rows and leaves |V| meters untouched
%                                        = the committed attack seen by a |V|-metered SE)
%   'fsource'   'inferred' (orig: f loop uses the droop-inferred fHat) | 'measured'
%               (f loop uses the pre-correction real f, base.f, + N(0,'fnoise'^2),
%                'fnoise' default 1e-3 Hz; separate RandStream)
%   'outDir'    output folder (default <this folder>/out/<tag>); channel data go
%                                        to <outDir>/PF and <outDir>/QV.
%   'channels'  {'pf','qv'} (default; PF before QV as in the original)
%   'data'      CSV path, or 'uci' for the project's RegroupedData.csv
%   kept: 'seed','steps','warmup','magScale','access','attackprob','seeds',
%         'study','selftest'.   Extra: 'debugsteps',K (save first K attacked
%         steps to debug_<ch>.mat), 'lmmaxiter','lmtol','auxtests','tag',
%         'verbose','save'.
%
%   api = SimulateMicrogridFDI_v2('api')   returns handles to local functions
%                                          (used by v2_selftest.m).
%
% Extra per-step log: <outDir>/<CH>/steplog.csv (see README_v2.md).

    out = struct();
    if nargin >= 1 && ischar(varargin{1}) && strcmpi(varargin{1},'api')
        out = apiHandles(); return;
    end
    p = parseArgs(varargin{:});
    rng(p.seed);                                   % reproducibility (as original)

    selftest();                                    % consumes RNG exactly as original
    if p.selftestOnly, return; end
    p = resolveOutDir(p);
    if p.study, runStudies(p); out.outDir = p.outDir; return; end

    for k = 1:numel(p.channels)                    % default {'pf','qv'} = original order
        out.(p.channels{k}) = runChannel(p.channels{k}, p);
    end
    out.outDir = p.outDir;
end

% =========================================================================
function p = parseArgs(varargin)
    p.steps = 3000; p.warmup = 400; p.seed = 42; p.selftestOnly = false;
    p.attackProb = 0.25; p.sigma = 1e-3; p.access = 0.70; p.grossLimit = 0.5;
    p.Kf = 1.6; p.Kv = 1.2; p.dataCsv = '';
    p.study = false; p.magScale = 1; p.seeds = 1:6; p.save = true; p.verbose = true;
    % ---- v2 options: defaults reproduce the original ----
    p.outDir = ''; p.vmeters = 'none'; p.attack = 'linear'; p.estimator = 'linear';
    p.ctrlinput = 'oracle'; p.attknow = 'true'; p.channels = {'pf','qv'};
    p.debugSteps = 0; p.lmMaxIter = 50; p.lmTol = 1e-8; p.auxTests = true; p.tag = '';
    p.fsource = 'inferred'; p.fnoise = 1e-3; p.attmeters = 'all';
    k = 1;
    while k <= numel(varargin)
        a = varargin{k};
        if strcmpi(a,'selftest'), p.selftestOnly = true; k = k+1; continue; end
        if strcmpi(a,'study'),    p.study = true;        k = k+1; continue; end
        if k+1 > numel(varargin), error('v2:args','Option ''%s'' has no value', a); end
        v = varargin{k+1};
        switch lower(a)
            case 'steps',     p.steps = v;
            case 'warmup',    p.warmup = v;
            case 'seed',      p.seed = v;
            case 'data',      p.dataCsv = v;
            case 'attackprob',p.attackProb = v;
            case 'access',    p.access = v;
            case 'magscale',  p.magScale = v;
            case 'seeds',     p.seeds = v;
            case 'outdir',    p.outDir = char(v);
            case 'vmeters',   p.vmeters   = validatestring(char(v), {'none','der'});
            case 'attack',    p.attack    = lower(char(v));
                              if ~any(strcmp(p.attack,{'linear','ac'}))
                                  error('v2:args','attack must be linear|ac'); end
            case 'estimator', p.estimator = validatestring(char(v), {'linear','acwls'});
            case 'ctrlinput', p.ctrlinput = validatestring(char(v), {'oracle','estimate'});
            case 'attknow'
                if islogical(v), if v, v = 'true'; else, v = 'stale'; end, end
                p.attknow = validatestring(char(v), {'true','stale'});
            case 'fsource',   p.fsource = validatestring(char(v), {'inferred','measured'});
            case 'fnoise',    p.fnoise = v;
            case 'attmeters', p.attmeters = validatestring(char(v), {'all','legacy'});
            case 'channels',  p.channels = cellstr(v);
            case 'debugsteps',p.debugSteps = v;
            case 'lmmaxiter', p.lmMaxIter = v;
            case 'lmtol',     p.lmTol = v;
            case 'auxtests',  p.auxTests = logical(v);
            case 'tag',       p.tag = char(v);
            case 'verbose',   p.verbose = logical(v);
            case 'save',      p.save = logical(v);
            otherwise, error('v2:args','Unknown option ''%s''', a);
        end
        k = k + 2;
    end
    if strcmpi(p.dataCsv,'uci'), p.dataCsv = uciPath(); end
    if ~isempty(p.dataCsv) && ~exist(p.dataCsv,'file')
        error('v2:data','data file not found: %s', p.dataCsv);   % original fell back silently
    end
end

function f = uciPath()
    % repository layout: <repo>/MATLAB/v2/SimulateMicrogridFDI_v2.m
    %                    <repo>/Python/Validation/RegroupedDataset/RegroupedData.csv
    repoRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    f = fullfile(repoRoot, 'Python', 'Validation', 'RegroupedDataset', 'RegroupedData.csv');
end

function p = resolveOutDir(p)
    here = fileparts(mfilename('fullpath'));
    if isempty(p.outDir)
        p.outDir = fullfile(here, 'out', makeTag(p));
    elseif ~(numel(p.outDir) > 1 && (p.outDir(2) == ':' || startsWith(p.outDir,'\\')))
        p.outDir = fullfile(pwd, p.outDir);
    end
    % never overwrite the committed Phase-1 datasets of the original simulator
    low = lower(strrep(p.outDir,'\','/'));
    if contains(low,'vectordataset_pf_corrected') || contains(low,'vectordataset_qv_corrected')
        error('v2:outdir','Refusing to write into a committed dataset folder: %s', p.outDir);
    end
end

function tag = makeTag(p)
    if isempty(p.dataCsv), d = 'syn';
    else, [~,nm] = fileparts(p.dataCsv); if strcmpi(nm,'RegroupedData'), d = 'uci'; else, d = nm; end
    end
    vmT = struct('none','v0','der','vD');  atT = struct('linear','aL','ac','aAC');
    esT = struct('linear','eL','acwls','eAC'); ciT = struct('oracle','cO','estimate','cE');
    akT = struct('true','kT','stale','kS');
    tag = sprintf('%s_s%d_n%d_w%d_%s_%s_%s_%s_%s', d, p.seed, p.steps, p.warmup, ...
        vmT.(p.vmeters), atT.(p.attack), esT.(p.estimator), ciT.(p.ctrlinput), akT.(p.attknow));
    if strcmp(p.fsource,'measured'), tag = [tag '_fM']; end
    if strcmp(p.attmeters,'legacy'), tag = [tag '_atLeg']; end
    if p.fnoise ~= 1e-3,   tag = sprintf('%s_fn%g', tag, p.fnoise); end
    if p.magScale ~= 1,    tag = sprintf('%s_m%g', tag, p.magScale); end
    if p.access ~= 0.70,   tag = sprintf('%s_acc%g', tag, p.access); end
    if p.attackProb ~= 0.25, tag = sprintf('%s_p%g', tag, p.attackProb); end
    if p.study,            tag = ['study_' tag]; end
    if ~isempty(p.tag),    tag = [p.tag '_' tag]; end
end

% =========================================================================
% 1.  TEST SYSTEM  (modified IEEE 33-bus, Baran & Wu 1989)  -- unchanged
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
% 2.  NETWORK MATRICES  -- unchanged
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
% 3.  ISLANDED DROOP POWER FLOW  (Newton-Raphson, analytic Jacobian) -- unchanged
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
% 4.  MEASUREMENT MODEL + JACOBIAN  -- unchanged (+ |V|-augmented wrappers)
% =========================================================================
function z = measModel(net, Ybus, Yf, f_idx, V) %#ok<INUSL>
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

function M = makeModel(net, Ybus, Yf, f_idx, cfg, vmBus, sigma)
    % estimator / attacker model:  x = [theta(nonRef); Vm]  (65), z = h_aug(x)
    N = size(net.bus,1);
    M.net = net; M.Ybus = Ybus; M.Yf = Yf; M.f_idx = f_idx; M.N = N;
    M.ref = cfg.ref_bus; M.nonRef = setdiff(1:N, M.ref); M.nState = 2*N-1;
    M.vmBus = vmBus(:)'; M.sigma = sigma;
    nV = numel(vmBus); M.Hv = zeros(nV, M.nState);
    for k = 1:nV, M.Hv(k,(N-1)+vmBus(k)) = 1; end
end

function V = stateToV(M, x)
    th = zeros(M.N,1);  th(M.nonRef) = x(1:M.N-1);
    V = x(M.N:end) .* exp(1i*th);
end

function z = hAug(M, x)
    z = measModel(M.net, M.Ybus, M.Yf, M.f_idx, stateToV(M, x));
    if ~isempty(M.vmBus), z = [z; x((M.N-1)+M.vmBus)]; end
end

function H = HAug(M, x)
    H = measJacobian(M.net, M.Ybus, M.Yf, M.f_idx, stateToV(M, x), M.ref);
    if ~isempty(M.vmBus), H = [H; M.Hv]; end
end

% =========================================================================
% 5.  WLS + BDD + ATTACK
% =========================================================================
function [dx, J] = wlsResidual(H, W, dz)          % unchanged (one-shot, linearised)
    G = H'*W*H + 1e-10*eye(size(H,2));
    dx = G \ (H'*W*dz);
    r = dz - H*dx;
    J = real(r'*W*r);
end

function tau = chi2Threshold(dof, alpha)          % unchanged
    if exist('chi2inv','file')
        tau = chi2inv(1-alpha, dof);
    else                              % Wilson-Hilferty approximation
        z = 2.3263;                   % ~99th percentile of N(0,1)
        tau = dof*(1 - 2/(9*dof) + z*sqrt(2/(9*dof)))^3;
    end
end

function [c, a] = minFootprintAttack(H, G, A, b)  % unchanged
    % min ||H c||^2  s.t.  A c = b   ->  smallest measurement footprint
    GinvAt = G \ A';
    c = GinvAt * ((A*GinvAt) \ b);
    a = H*c;
end

% ---- 5b. iterative nonlinear AC-WLS (Levenberg-Marquardt) ---------------
function [x, J, conv, nit, used] = acwls(M, z, xWarm, tau, opt)
    % Warm start from xWarm (previous accepted estimate); if it fails to
    % converge or alarms (J >= tau), retry from flat start and keep the better
    % result (converged preferred, then lower J).  used: 1 warm, 2 flat only
    % (no warm start available), 3 warm kept after retry, 4 flat won the retry.
    flat = [zeros(M.N-1,1); ones(M.N,1)];
    if isempty(xWarm)
        [x, J, conv, nit] = lmSolve(M, z, flat, opt.mu0Flat, opt);  used = 2;
        return;
    end
    [x, J, conv, nit] = lmSolve(M, z, xWarm, opt.mu0Warm, opt);  used = 1;
    if ~conv || J >= tau
        [x2, J2, conv2, nit2] = lmSolve(M, z, flat, opt.mu0Flat, opt);
        nit = nit + nit2;  used = 3;
        if (conv2 && ~conv) || (conv2 == conv && J2 < J)
            x = x2; J = J2; conv = conv2; used = 4;
        end
    end
end

function [x, F, conv, it] = lmSolve(M, z, x0, mu0, opt)
    % minimise F(x) = || (z - h_aug(x)) / sigma ||^2  (weighted residual J)
    % Levenberg-Marquardt with Marquardt (diag) scaling, Nielsen damping update.
    % Converged when an accepted step has max|dx| < tol (with a stationarity
    % check of the undamped Gauss-Newton step), or after a rejected step the
    % undamped GN step is already < tol (round-off-limited optimum).
    s = M.sigma;  x = x0;  conv = false;  it = 0;  nS = numel(x0);
    % (only the limited-access/naive auxiliary solves, which have no AC fit, ever
    %  hit singular damped systems; non-finite steps are rejected below)
    ws = [warning('off','MATLAB:singularMatrix'), warning('off','MATLAB:nearlySingularMatrix')];
    restoreW = onCleanup(@() warning(ws)); %#ok<NASGU>
    r = (z - hAug(M,x))/s;  F = r'*r;
    if ~isfinite(F), return; end
    Hs = HAug(M,x)/s;  A = Hs'*Hs;  g = Hs'*r;  D = diag(A);
    mu = mu0;  nu = 2;
    while it < opt.maxIter
        it = it + 1;
        h = (A + mu*diag(D)) \ g;
        if ~all(isfinite(h)), mu = mu*nu; nu = 2*nu; continue; end
        xn = x + h;
        rn = (z - hAug(M,xn))/s;  Fn = rn'*rn;
        if isfinite(Fn) && Fn < F
            pred = h'*(g + mu*(D.*h));
            rho  = (F - Fn)/max(pred, realmin);
            x = xn;  F = Fn;  r = rn;
            Hs = HAug(M,x)/s;  A = Hs'*Hs;  g = Hs'*r;  D = max(D, diag(A));
            mu = max(mu*max(1/3, 1-(2*rho-1)^3), 1e-20);  nu = 2;
            if max(abs(h)) < opt.tol
                hg = (A + 1e-14*diag(D)) \ g;
                if max(abs(hg)) < 10*opt.tol, conv = true; return; end
            end
        else
            mu = mu*nu;  nu = 2*nu;
            hg = (A + 1e-14*diag(D)) \ g;
            if max(abs(hg)) < opt.tol, conv = true; return; end
        end
    end
    if nS == 0, conv = true; end
end

% =========================================================================
% 6.  SIMULATION DRIVER
% =========================================================================
function summary = runChannel(channel, p)
    if ~isfield(p,'magScale'), p.magScale = 1;    end
    if ~isfield(p,'save'),     p.save     = true; end
    if ~isfield(p,'verbose'),  p.verbose  = true; end
    summary = struct();
    tRun = tic;
    net = case33();  Ybus = makeYbus(net);  [Yf,f_idx] = makeYf(net);
    cfg = droopConfig();  der = cfg.der_bus;  ref = cfg.ref_bus;
    N = size(net.bus,1);  L = size(net.branch,1);
    f_nom = cfg.f_nom;  V_nom = cfg.V_nom;
    rateFrac = cfg.P_rate / sum(cfg.P_rate);
    nonRef = setdiff(1:N, ref);
    isPF = strcmp(channel,'pf');

    useVm = strcmp(p.vmeters,'der');
    if useVm, vmBus = der; else, vmBus = []; end
    nV = numel(vmBus);
    nMeas0 = 2*N + 2*L;                          % 130 legacy meters
    nMeas = nMeas0 + nV;  nState = (N-1) + N;  dof = nMeas - nState;
    W = eye(nMeas) / p.sigma^2;
    tau = chi2Threshold(dof, 0.01);
    G = [];                                   %#ok<NASGU> Gram matrix, set per step
    F_TRIP = 0.20;  V_TRIP = 0.10;
    M = makeModel(net, Ybus, Yf, f_idx, cfg, vmBus, p.sigma);
    useAC   = strcmp(p.attack,'ac');
    useLM   = strcmp(p.estimator,'acwls');
    useEst  = strcmp(p.ctrlinput,'estimate');
    stale   = strcmp(p.attknow,'stale');
    legacyAtk = useVm && strcmp(p.attmeters,'legacy');   % attacker ignores the |V| meters
    origAtk = ~useAC && ~stale && ~legacyAtk;    % original attack arithmetic
    lmOpt = struct('maxIter',p.lmMaxIter,'tol',p.lmTol,'mu0Warm',1e-6,'mu0Flat',1e-3);
    chanId = 1 + ~isPF;
    aux = RandStream('mt19937ar','Seed', mod(p.seed + 100003*chanId, 2^32));  % |V|-meter draws only
    fMeasMode = strcmp(p.fsource,'measured');
    fstr = RandStream('mt19937ar','Seed', mod(p.seed + 200003*chanId, 2^32)); % f-meter noise only

    [PdAll, QdAll] = loadProfile(net, p.steps, p.dataCsv);

    % ---- preallocated logs (rows = logged steps, as original) ----
    nMax = max(p.steps - p.warmup, 0);
    Z = zeros(nMax, nMeas); lab = zeros(nMax,1); Jl = lab; Jn = lab; Jlim = lab; ftp = lab;
    des = lab; perc = lab; rdev = lab; tauL = lab; stl = lab; ncaught = lab; lcaught = lab;
    ev = cell(nMax,1);
    S = struct();  fld = {'step','attacked','design','footprint','J','Jlin','tau','alarm', ...
        'stealthy','conv','iters','start','Jnaive','Jlimited','lossMeas','lossTrue','lossHat', ...
        'fTrue','fHat','VtrueDerMean','VhatDerMean','Vhat1','Vhat6','Vhat18','Vhat25', ...
        'realDev','fPost','VminPost','VmaxPost','cross','eventCode','cfDev','cfCross', ...
        'cfConv','fCtrl','fsrc','tStep','tEst'};
    for q = 1:numel(fld), S.(fld{q}) = nan(nMax,1); end
    dbg = struct('step',{},'xTrue',{},'xK',{},'c',{},'a',{},'noise',{},'zClean',{},'zAtt',{});
    nRow = 0;

    if p.verbose
        fprintf('\n=== Channel %s | steps=%d warmup=%d p_atk=%.0f%% ===\n', ...
            upper(channel), p.steps, p.warmup, p.attackProb*100);
        fprintf('    nMeas=%d nState=%d dof=%d tau_chi2(1%%)=%.2f\n', ...
            nMeas, nState, dof, tau);
        fprintf('    v2: vmeters=%s attack=%s estimator=%s ctrlinput=%s attknow=%s\n', ...
            p.vmeters, p.attack, p.estimator, p.ctrlinput, p.attknow);
    end

    nSkip = 0;  prev = [];  xWarm = [];
    for j = 1:p.steps
        tS = tic;
        Pd = PdAll(j,:)';  Qd = QdAll(j,:)';
        Pset = rateFrac * sum(Pd);   V0 = repmat(V_nom,1,numel(der));
        Qset = zeros(1,numel(der));

        base = droopPF(net, Ybus, cfg, Pset, V0, Pd, Qd, Qset);
        if ~base.success, nSkip = nSkip+1; continue; end
        V = base.V;
        zClean = measModel(net, Ybus, Yf, f_idx, V);
        noise = p.sigma*randn(nMeas0,1);                       % main stream (as original)
        if useVm
            zClean = [zClean; base.Vm(vmBus)];                 %#ok<AGROW>
            noise  = [noise; p.sigma*randn(aux, nV, 1)];       %#ok<AGROW>
        end
        zMeas = zClean + noise;   dz = zMeas - zClean;
        H = measJacobian(net, Ybus, Yf, f_idx, V, ref);
        if useVm, H = [H; M.Hv]; end                           %#ok<AGROW>
        xTrue = [base.theta(nonRef); base.Vm];
        cur = struct('x',xTrue,'H',H);
        if j <= p.warmup, prev = cur; continue; end
        if isempty(prev), prev = cur; end
        if stale, K = prev; else, K = cur; end                 % attacker's knowledge
        prev = cur;

        attacked = rand() < p.attackProb;
        c = zeros(nState,1);  a = zeros(nMeas,1);  designVal = 0;  footprint = 0;
        G = H'*H + 1e-9*eye(nState);
        zMeas0 = zMeas;
        Jnlog = NaN; Jlimlog = NaN;

        if attacked
            if stale, Hk = K.H; Gk = Hk'*Hk + 1e-9*eye(nState); else, Hk = H; Gk = G; end
            if legacyAtk                                 % design on the 130 legacy meters only
                Hk = Hk(1:nMeas0,:);  Gk = Hk'*Hk + 1e-9*eye(nState);
            end
            if isPF
                dfT = (0.20 + rand()*0.35)*p.magScale;  designVal = dfT;
                dP = (-dfT ./ cfg.m_p)';                 % column, length 4
                A = Hk(der,:);
                [c, a] = minFootprintAttack(Hk, Gk, A, dP);
            else
                dVT = (0.04 + rand()*0.05)*p.magScale;  designVal = dVT;
                A = zeros(numel(der), nState);
                for k = 1:numel(der), A(k,(N-1)+der(k)) = 1; end
                [c, a] = minFootprintAttack(Hk, Gk, A, repmat(dVT,numel(der),1));
            end
            if useAC                                     % AC-consistent injection
                a = hAug(M, K.x + c) - hAug(M, K.x);
            end
            if legacyAtk                                 % |V| meters left untouched
                a = [a(1:nMeas0); zeros(nV,1)];
            end
            footprint = max(abs(a));
            zMeas = zMeas + a;  dzAtt = zMeas - zClean;
            tE = tic;
            [dxL, Jatt] = wlsResidual(H, W, dzAtt);
            JlinLog = Jatt;
            if useLM
                [xHat, Jatt, cv, nit, used] = acwls(M, zMeas, xWarm, tau, lmOpt);
            else
                xHat = xTrue + dxL; cv = true; nit = 0; used = 0;
            end
            tEst = toc(tE);
            grossOk = footprint < p.grossLimit;
            stealthy = (Jatt < tau) && grossOk;

            eta = randn(nMeas0,1);
            if useVm, eta = [eta; randn(aux, nV, 1)]; end      %#ok<AGROW>
            eta = eta/norm(eta)*norm(a);
            accMask = rand(nMeas0,1) < p.access;
            if useVm, accMask = [accMask; rand(aux, nV, 1) < p.access]; end %#ok<AGROW>
            if useLM
                if p.auxTests
                    [~, Jnaive]   = acwls(M, zClean + (dz + eta), xWarm, tau, lmOpt);
                    [~, Jlimited] = acwls(M, zClean + (dz + a.*accMask), xWarm, tau, lmOpt);
                else
                    Jnaive = NaN; Jlimited = NaN;
                end
            else
                [~, Jnaive] = wlsResidual(H, W, dz + eta);
                [~, Jlimited] = wlsResidual(H, W, dz + a.*accMask);
            end
            naiveCaught = Jnaive >= tau;
            limitedCaught = Jlimited >= tau;
            Jlog = Jatt; Jnlog = Jnaive; Jlimlog = Jlimited;
        else
            tE = tic;
            [dxL, J0] = wlsResidual(H, W, dz);
            JlinLog = J0;
            if useLM
                [xHat, J0, cv, nit, used] = acwls(M, zMeas, xWarm, tau, lmOpt);
            else
                xHat = xTrue + dxL; cv = true; nit = 0; used = 0;
            end
            tEst = toc(tE);
            stealthy = J0 < tau;  naiveCaught = false; limitedCaught = false;
            Jlog = J0;
        end
        if useLM && cv && Jlog < tau, xWarm = xHat; end        % accepted estimate -> warm start

        % ---- perceived quantities (controller input) ----
        PinjTrue = zClean(1:N);
        if ~useEst                                   % oracle: x_hat = x_true + c
            VmHat = base.Vm;
            for b = 1:N, VmHat(b) = VmHat(b) + c((N-1)+b); end
            if origAtk, PinjHat = PinjTrue(der) + H(der,:)*c;   % original expression
            else,       PinjHat = PinjTrue(der) + a(der); end   % = P_inj(x_K + c) - P_inj(x_K) shift
        else                                         % estimator output
            [VmHat, PinjHat, PinjHatAll] = perceivedFromEstimate(M, xHat, der);
        end
        if fMeasMode, fMeas = base.f + p.fnoise*randn(fstr); else, fMeas = NaN; end
        [fHat, realDev, evt, post, fCtrl] = controlAndRespond(isPF, net, Ybus, cfg, ...
            Pset, V0, Pd, Qd, Qset, PinjHat, VmHat, rateFrac, p, F_TRIP, V_TRIP, fMeas);
        if isPF, percVal = fHat; else, percVal = mean(VmHat(der)); end

        % ---- counterfactual (same step, same noise, no attack) ----
        cfDev = NaN; cfConv = NaN;
        if attacked
            if ~useEst
                VmC = base.Vm;  PinjC = PinjTrue(der);  cfConv = 1;
            else
                if useLM
                    [xC, ~, cvC] = acwls(M, zMeas0, xWarm, tau, lmOpt);
                else
                    [dxC, ~] = wlsResidual(H, W, dz);  xC = xTrue + dxC;  cvC = true;
                end
                [VmC, PinjC] = perceivedFromEstimate(M, xC, der);  cfConv = cvC;
            end
            [~, cfDev] = controlAndRespond(isPF, net, Ybus, cfg, Pset, V0, Pd, Qd, Qset, ...
                PinjC, VmC, rateFrac, p, F_TRIP, V_TRIP, fMeas);         % same f-meter reading
        end

        nRow = nRow + 1;
        Z(nRow,:) = zMeas';  lab(nRow,1) = attacked;
        Jl(nRow,1) = Jlog; Jn(nRow,1) = Jnlog; Jlim(nRow,1) = Jlimlog;
        ftp(nRow,1) = footprint; des(nRow,1) = designVal; perc(nRow,1) = percVal;
        rdev(nRow,1) = realDev; tauL(nRow,1) = tau;
        stl(nRow,1) = stealthy;
        ncaught(nRow,1) = attacked && naiveCaught;
        lcaught(nRow,1) = attacked && limitedCaught;
        ev{nRow,1} = evt;

        % ---- v2 step log ----
        if useEst, lossHat = sum(PinjHatAll);
        else, lossHat = sum(PinjTrue) + sum(a(1:N)); end
        if isPF, cross = realDev < -F_TRIP; cfCross = cfDev < -F_TRIP;
        else,    cross = realDev < -V_TRIP; cfCross = cfDev < -V_TRIP; end
        evc = find(strcmp(evt, {'UFLS','OFLS','UVLS','OVLS'}),1);
        if isempty(evc), if strcmp(evt,'Fail'), evc = -1; else, evc = 0; end
        else, evc = 1 + (evc==2 || evc==4); end
        if post.success, fP = post.f; vmin = min(post.Vm); vmax = max(post.Vm);
        else, fP = NaN; vmin = NaN; vmax = NaN; end
        vals = {j, attacked, designVal, footprint, Jlog, JlinLog, tau, Jlog >= tau, ...
            stealthy, cv, nit, used, Jnlog, Jlimlog, sum(zMeas(1:N)), sum(PinjTrue), lossHat, ...
            base.f, fHat, mean(base.Vm(der)), mean(VmHat(der)), VmHat(der(1)), VmHat(der(2)), ...
            VmHat(der(3)), VmHat(der(4)), realDev, fP, vmin, vmax, cross, evc, cfDev, ...
            double(cfCross) + 0*cfDev, cfConv, fCtrl, fMeasMode, toc(tS), tEst};
        for q = 1:numel(fld), S.(fld{q})(nRow) = double(vals{q}); end
        if attacked && numel(dbg) < p.debugSteps
            dbg(end+1) = struct('step',j,'xTrue',xTrue,'xK',K.x,'c',c,'a',a,'noise',noise, ...
                'zClean',zClean,'zAtt',zMeas); %#ok<AGROW>
        end
    end
    % ---- trim preallocated logs ----
    Z = Z(1:nRow,:); lab = lab(1:nRow); Jl = Jl(1:nRow); Jn = Jn(1:nRow); Jlim = Jlim(1:nRow);
    ftp = ftp(1:nRow); des = des(1:nRow); perc = perc(1:nRow); rdev = rdev(1:nRow);
    tauL = tauL(1:nRow); stl = stl(1:nRow); ncaught = ncaught(1:nRow); lcaught = lcaught(1:nRow);
    ev = ev(1:nRow);
    for q = 1:numel(fld), S.(fld{q}) = S.(fld{q})(1:nRow); end
    tTotal = toc(tRun);

    % ---- summary (original fields + v2 fields) ----
    atk = lab==1;  nAtt = sum(atk);  n = numel(lab);
    valid = atk & ~isnan(rdev);
    if isPF, k1='UFLS'; k2='OFLS'; u='Hz'; else, k1='UVLS'; k2='OVLS'; u='pu'; end
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
    nor = ~atk;
    summary.dof = dof; summary.tau = tau; summary.nSkip = nSkip;
    summary.alarmAttPct = 100*mean(S.alarm(atk));
    summary.alarmNorPct = 100*mean(S.alarm(nor));  summary.nAlarmNor = sum(S.alarm(nor));
    summary.nNor = sum(nor);
    summary.crossAtt = sum(S.cross(atk) == 1);  summary.crossNor = sum(S.cross(nor) == 1);
    summary.cfCrossAtt = sum(S.cfCross(atk) == 1);
    summary.convPct = 100*mean(S.conv == 1);  summary.nNotConv = sum(S.conv ~= 1);
    summary.meanIter = mean(S.iters);  summary.maxIter = max(S.iters);
    summary.tStepMean = mean(S.tStep);  summary.tTotal = tTotal;
    summary.S = S;
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
        fprintf('    v2: alarm att %.1f%% | alarm normal %d/%d (%.2f%%) | cross att %d | cross normal %d\n', ...
            summary.alarmAttPct, summary.nAlarmNor, summary.nNor, summary.alarmNorPct, ...
            summary.crossAtt, summary.crossNor);
        fprintf('    v2: est conv %.2f%% (not conv %d) | iters mean %.2f max %d | %.2f ms/step | total %.1f s\n', ...
            summary.convPct, summary.nNotConv, summary.meanIter, summary.maxIter, ...
            1e3*summary.tStepMean, tTotal);
    end

    % ---- save dataset (skipped in study mode) ----
    if p.save
        outDir = fullfile(p.outDir, upper(channel));
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
        writetable(struct2table(S), fullfile(outDir,'steplog.csv'));
        if ~isempty(dbg), save(fullfile(outDir, ['debug_' channel '.mat']), 'dbg'); end
        fid = fopen(fullfile(outDir,'meta.txt'),'w');
        fprintf(fid, 'SimulateMicrogridFDI_v2 channel=%s\nMATLAB %s\ndate %s\n', channel, version, char(datetime('now')));
        fprintf(fid, 'seed=%d steps=%d warmup=%d attackProb=%g magScale=%g access=%g data=%s\n', ...
            p.seed, p.steps, p.warmup, p.attackProb, p.magScale, p.access, p.dataCsv);
        fprintf(fid, 'vmeters=%s attack=%s attmeters=%s estimator=%s ctrlinput=%s attknow=%s lmMaxIter=%d lmTol=%g auxTests=%d\n', ...
            p.vmeters, p.attack, p.attmeters, p.estimator, p.ctrlinput, p.attknow, p.lmMaxIter, p.lmTol, p.auxTests);
        fprintf(fid, 'fsource=%s fnoise=%g Hz (frequency loop input: %s)\n', p.fsource, p.fnoise, ...
            ternary(fMeasMode, 'measured base.f + noise', 'droop-inferred fHat from the estimate'));
        fprintf(fid, 'nMeas=%d nState=%d dof=%d tau=%.6f nSkip=%d rows=%d\n', nMeas, nState, dof, tau, nSkip, n);
        fprintf(fid, 'alarmAtt=%.3f%% alarmNor=%d/%d crossAtt=%d crossNor=%d conv=%.3f%% meanIter=%.3f tStep=%.3f ms total=%.1f s\n', ...
            summary.alarmAttPct, summary.nAlarmNor, summary.nNor, summary.crossAtt, summary.crossNor, ...
            summary.convPct, summary.meanIter, 1e3*summary.tStepMean, tTotal);
        fclose(fid);
        fprintf('    dataset -> %s\n', outDir);
    end
end

function s = ternary(c, a, b), if c, s = a; else, s = b; end, end

function [VmHat, PinjHat, PinjAll] = perceivedFromEstimate(M, xHat, der)
    VmHat = xHat(M.N:end);
    zh = measModel(M.net, M.Ybus, M.Yf, M.f_idx, stateToV(M, xHat));
    PinjAll = zh(1:M.N);  PinjHat = PinjAll(der);
end

function [fHat, realDev, evt, post, fCtrl] = controlAndRespond(isPF, net, Ybus, cfg, ...
        Pset, V0, Pd, Qd, Qset, PinjHat, VmHat, rateFrac, p, F_TRIP, V_TRIP, fMeas)
    % operator secondary control on the perceived state + real droop response
    % (arithmetic identical to the original runChannel when fMeas is NaN).
    % fsource='measured': the frequency loop uses fMeas (pre-correction real f +
    % meter noise) instead of the droop-inferred fHat.
    der = cfg.der_bus;  f_nom = cfg.f_nom;  V_nom = cfg.V_nom;
    PgHat = PinjHat + Pd(der);
    fHat = f_nom - mean(cfg.m_p(:).*(PgHat - Pset(:)));
    if isnan(fMeas), fCtrl = fHat; else, fCtrl = fMeas; end
    PsetNew = Pset;  V0New = V0;
    if isPF
        PsetNew = Pset - p.Kf*(fCtrl - f_nom).*rateFrac;
        PsetNew = min(max(PsetNew, 0), cfg.P_rate);
    else
        V0New = V0 - p.Kv*(VmHat(der)' - V_nom);
        V0New = min(max(V0New, 0.90), 1.10);
    end
    post = droopPF(net, Ybus, cfg, PsetNew, V0New, Pd, Qd, Qset);
    if post.success
        if isPF
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
end

% =========================================================================
% 6b.  STUDY MODE  (statistical rigor + sensitivity sweeps) -- outputs -> outDir
% =========================================================================
function runStudies(p)
    chans = {'pf','qv'};
    base = p; base.save = false; base.verbose = false; base.study = false;
    ci95 = @(x) 1.96*std(x)/sqrt(numel(x));
    if ~exist(p.outDir,'dir'), mkdir(p.outDir); end
    fprintf('\n############ STUDY MODE ############\n');
    fprintf('seeds=%s  steps=%d  warmup=%d\n', mat2str(p.seeds), p.steps, p.warmup);

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
    writetable(T, fullfile(p.outDir,'Study_CIs.csv'));

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
    writematrix(B, fullfile(p.outDir,'Study_mag_sweep.csv'));

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
    writematrix(C, fullfile(p.outDir,'Study_access_sweep.csv'));
    fprintf('\nStudy CSVs written to %s\n', p.outDir);
end

% =========================================================================
function [PdAll, QdAll] = loadProfile(net, nSteps, dataCsv)
    persistent cacheFile cacheCol
    baseP = net.bus(:,2)'/net.baseMVA;   baseQ = net.bus(:,3)'/net.baseMVA;
    N = size(net.bus,1);
    if ~isempty(dataCsv) && exist(dataCsv,'file')
        if isequal(cacheFile, dataCsv)
            col = cacheCol;
        else
            raw = readmatrix(dataCsv);  col = raw(:,1);
            cacheFile = dataCsv;  cacheCol = col;
        end
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
% 7.  SELF-TESTS (original; consumes the RNG exactly as before)
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

% =========================================================================
function api = apiHandles()
    api.case33 = @case33;  api.droopConfig = @droopConfig;  api.makeYbus = @makeYbus;
    api.makeYf = @makeYf;  api.droopPF = @droopPF;  api.measModel = @measModel;
    api.measJacobian = @measJacobian;  api.makeModel = @makeModel;  api.stateToV = @stateToV;
    api.hAug = @hAug;  api.HAug = @HAug;  api.lmSolve = @lmSolve;  api.acwls = @acwls;
    api.wlsResidual = @wlsResidual;  api.chi2Threshold = @chi2Threshold;
    api.loadProfile = @loadProfile;  api.minFootprintAttack = @minFootprintAttack;
    api.uciPath = @uciPath;
end
