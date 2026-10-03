#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gridmodel.py -- detector-side grid model for Phase 2.

Network constants + measurement model are the audited numerics of
_verify/mirror_check.py (itself a literal mirror of the frozen
MATLAB/SimulateMicrogridFDI.m). The state estimator here is the DETECTOR'S OWN:
a full iterative Gauss-Newton WLS from flat start (DETECTOR_DESIGN.md par.6).
It does NOT reuse the simulator's linearization about the true state -- the
simulator's stealth guarantee is exact only in its own linearized convention
(PHASE2_NOTES E2), so the detector must not inherit that convention.

Also provides the F2 physics features (DETECTOR_DESIGN.md par.3) and the
physics-oracle droop-consistency score (par.2).
"""
import numpy as np

# ---------------- case33 (frozen constants) ----------------
def case33():
    baseMVA, baseKV = 5.0, 12.66
    busKW = np.array([
        [1,0,0],[2,100,60],[3,90,40],[4,120,80],[5,60,30],[6,60,20],[7,200,100],
        [8,200,100],[9,60,20],[10,60,20],[11,45,30],[12,60,35],[13,60,35],
        [14,120,80],[15,60,10],[16,60,20],[17,60,20],[18,90,40],[19,90,40],
        [20,90,40],[21,90,40],[22,90,40],[23,90,50],[24,420,200],[25,420,200],
        [26,60,25],[27,60,25],[28,60,20],[29,120,70],[30,200,600],[31,150,70],
        [32,210,100],[33,60,40]], dtype=float)
    bus = np.column_stack([busKW[:,0], busKW[:,1]/1e3, busKW[:,2]/1e3])  # MW, MVAr
    branch = np.array([
        [1,2,0.0922,0.0470],[2,3,0.4930,0.2511],[3,4,0.3660,0.1864],
        [4,5,0.3811,0.1941],[5,6,0.8190,0.7070],[6,7,0.1872,0.6188],
        [7,8,0.7114,0.2351],[8,9,1.0300,0.7400],[9,10,1.0440,0.7400],
        [10,11,0.1966,0.0650],[11,12,0.3744,0.1238],[12,13,1.4680,1.1550],
        [13,14,0.5416,0.7129],[14,15,0.5910,0.5260],[15,16,0.7463,0.5450],
        [16,17,1.2890,1.7210],[17,18,0.7320,0.5740],[2,19,0.1640,0.1565],
        [19,20,1.5042,1.3554],[20,21,0.4095,0.4784],[21,22,0.7089,0.9373],
        [3,23,0.4512,0.3083],[23,24,0.8980,0.7091],[24,25,0.8960,0.7011],
        [6,26,0.2030,0.1034],[26,27,0.2842,0.1447],[27,28,1.0590,0.9337],
        [28,29,0.8042,0.7006],[29,30,0.5075,0.2585],[30,31,0.9744,0.9630],
        [31,32,0.3105,0.3619],[32,33,0.3410,0.5302]], dtype=float)
    return dict(baseMVA=baseMVA, baseKV=baseKV, bus=bus, branch=branch)

def droopConfig():
    cfg = {}
    cfg['f_nom'] = 50.0; cfg['V_nom'] = 1.0
    cfg['der_bus'] = np.array([1, 6, 18, 25]); cfg['ref_bus'] = 1
    cfg['P_rate'] = np.array([0.40, 0.20, 0.20, 0.20])
    cfg['Q_rate'] = np.array([0.30, 0.15, 0.15, 0.15])
    cfg['m_p'] = 0.01*cfg['f_nom']/cfg['P_rate']
    cfg['n_q'] = 0.05*cfg['V_nom']/cfg['Q_rate']
    return cfg

def makeYbus(net):
    Zbase = (net['baseKV']*1e3)**2/(net['baseMVA']*1e6)
    N = net['bus'].shape[0]; Y = np.zeros((N, N), complex)
    for k in range(net['branch'].shape[0]):
        i = int(net['branch'][k,0])-1; j = int(net['branch'][k,1])-1
        y = 1/((net['branch'][k,2]+1j*net['branch'][k,3])/Zbase)
        Y[i,i] += y; Y[j,j] += y; Y[i,j] -= y; Y[j,i] -= y
    return Y

def makeYf(net):
    Zbase = (net['baseKV']*1e3)**2/(net['baseMVA']*1e6)
    N = net['bus'].shape[0]; L = net['branch'].shape[0]
    Yf = np.zeros((L, N), complex); f_idx = np.zeros(L, int)
    for k in range(L):
        i = int(net['branch'][k,0])-1; j = int(net['branch'][k,1])-1
        y = 1/((net['branch'][k,2]+1j*net['branch'][k,3])/Zbase)
        Yf[k,i] += y; Yf[k,j] -= y; f_idx[k] = i
    return Yf, f_idx

def dSbus_dV(Ybus, V):
    Ibus = Ybus@V
    diagV = np.diag(V); diagIbus = np.diag(Ibus); diagVnorm = np.diag(V/np.abs(V))
    dS_dVm = diagV@np.conj(Ybus@diagVnorm) + np.conj(diagIbus)@diagVnorm
    dS_dVa = 1j*diagV@np.conj(diagIbus - Ybus@diagV)
    return dS_dVa, dS_dVm

def measModel(Ybus, Yf, f_idx, V):
    S = V*np.conj(Ybus@V); Sf = V[f_idx]*np.conj(Yf@V)
    return np.concatenate([S.real, S.imag, Sf.real, Sf.imag])

def measJacobian(Ybus, Yf, f_idx, V, ref):
    N = Ybus.shape[0]; L = Yf.shape[0]
    nonRef = np.array([b for b in range(N) if b != ref])
    dVa, dVm = dSbus_dV(Ybus, V)
    Vnorm = V/np.abs(V)
    E = np.zeros((L, N)); E[np.arange(L), f_idx] = 1
    diagVf = np.diag(V[f_idx]); If = Yf@V; diagIf = np.diag(If)
    dSf_dVa = 1j*diagVf@(np.conj(diagIf)@E - np.conj(Yf@np.diag(V)))
    dSf_dVm = diagVf@np.conj(Yf@np.diag(Vnorm)) + np.conj(diagIf)@E@np.diag(Vnorm)
    def cols(Mva, Mvm): return np.hstack([Mva[:,nonRef], Mvm])
    H = np.vstack([cols(dVa.real, dVm.real),
                   cols(dVa.imag, dVm.imag),
                   cols(dSf_dVa.real, dSf_dVm.real),
                   cols(dSf_dVa.imag, dSf_dVm.imag)])
    return H


class GridSE:
    """Iterative Gauss-Newton AC-WLS state estimator from flat start."""

    def __init__(self, sigma=1e-3):
        self.net = case33(); self.cfg = droopConfig()
        self.Ybus = makeYbus(self.net)
        self.Yf, self.f_idx = makeYf(self.net)
        self.N = self.net['bus'].shape[0]
        self.L = self.net['branch'].shape[0]
        self.ref = self.cfg['ref_bus'] - 1
        self.der = self.cfg['der_bus'] - 1
        self.nonRef = np.array([b for b in range(self.N) if b != self.ref])
        self.nMeas = 2*self.N + 2*self.L
        self.nState = (self.N - 1) + self.N
        self.dof = self.nMeas - self.nState
        self.sigma = sigma
        self.Winv_diag = sigma**2   # W = I/sigma^2 (uniform weights, as frozen sim)
        # nominal load pattern (operator knowledge; no oracle access)
        self.baseP = self.net['bus'][:,1]/self.net['baseMVA']
        self.baseQ = self.net['bus'][:,2]/self.net['baseMVA']

    def estimate(self, z, tol=1e-8, maxIter=50):
        """Damped Gauss-Newton WLS from flat start (backtracking line search on
        the WLS cost -- plain GN diverges on ~17% of operating points).
        Returns (theta, Vm, J, converged, iters)."""
        N = self.N

        def cost(theta, Vm):
            V = Vm*np.exp(1j*theta)
            r = z - measModel(self.Ybus, self.Yf, self.f_idx, V)
            return float(r@r), r

        theta = np.zeros(N); Vm = np.ones(N)
        phi, r = cost(theta, Vm)
        ok = False
        for it in range(maxIter):
            V = Vm*np.exp(1j*theta)
            H = measJacobian(self.Ybus, self.Yf, self.f_idx, V, self.ref)
            G = H.T@H + 1e-10*np.eye(self.nState)
            dx = np.linalg.solve(G, H.T@r)
            step = 1.0
            for _ in range(25):
                th_new = theta.copy(); th_new[self.nonRef] += step*dx[:N-1]
                Vm_new = np.clip(Vm + step*dx[N-1:], 0.5, 1.5)
                phi_new, r_new = cost(th_new, Vm_new)
                if phi_new < phi:
                    break
                step *= 0.5
            if phi_new >= phi:           # no descent step found: stop
                break
            theta, Vm, r = th_new, Vm_new, r_new
            phi_prev, phi = phi, phi_new
            if step*np.max(np.abs(dx)) < tol or (phi_prev - phi) < tol*max(phi, 1.0):
                ok = True
                break
        J = phi/self.sigma**2
        return theta, Vm, J, ok, it+1

    # ---------------- F2 physics features ----------------
    def physics_features(self, z, est=None):
        """F2 features from the detector's own WLS estimate of one snapshot z.

        Returns a flat vector; feature names in PHYS_NAMES. All quantities are
        computable by the EMS: measurement z, network model, droop parameters,
        nominal load pattern. No oracle access to true state or true loads.
        """
        cfg = self.cfg; N = self.N; der = self.der
        if est is None:
            est = self.estimate(z)
        theta, Vm, J, ok, _ = est
        V = Vm*np.exp(1j*theta)
        zhat = measModel(self.Ybus, self.Yf, self.f_idx, V)
        Pinj = zhat[:N]; Qinj = zhat[N:2*N]

        # losses implied by the estimate (sum of injections)
        p_balance = float(Pinj.sum())
        q_balance = float(Qinj.sum())

        # estimated total load: non-DER buses inject -load; scale the nominal
        # pattern so its non-DER sum matches, then infer DER-bus loads
        nonDer = np.array([b for b in range(N) if b not in set(der.tolist())])
        t_nonDer = -Pinj[nonDer].sum()
        sP = t_nonDer/max(self.baseP[nonDer].sum(), 1e-12)
        Pd_hat = sP*self.baseP
        tq_nonDer = -Qinj[nonDer].sum()
        sQ = tq_nonDer/max(self.baseQ[nonDer].sum(), 1e-12)
        Qd_hat = sQ*self.baseQ

        # implied DER outputs and dispatch
        Pg_hat = Pinj[der] + Pd_hat[der]
        Qg_hat = Qinj[der] + Qd_hat[der]
        totP_hat = Pd_hat.sum()
        rateFrac = cfg['P_rate']/cfg['P_rate'].sum()
        Pset_hat = rateFrac*totP_hat

        # per-DER implied frequency offsets: equal across DERs at true droop
        # equilibria; spread is a droop-consistency residual
        df = cfg['m_p']*(Pset_hat - Pg_hat)
        df_spread = float(df.max() - df.min())

        # Q-V droop residuals: V(der_i) - (V_nom - n_q_i Qg_i)  (V0=V_nom, Qset=0)
        qv_res = Vm[der] - (cfg['V_nom'] - cfg['n_q']*Qg_hat)

        feats = np.concatenate([
            Vm,                       # 33: estimated voltage profile
            [J],                      # 1 : WLS objective of own iterative SE
            df,                       # 4 : per-DER implied frequency offsets
            [df_spread],              # 1 : droop-consistency spread
            qv_res,                   # 4 : Q-V droop residuals
            [p_balance, q_balance],   # 2 : total-injection balance
            [Vm.min(), Vm.max()],     # 2 : voltage envelope
        ])
        return feats

    def oracle_score(self, z, est=None):
        """Physics-oracle droop-consistency score (model-based upper bound):
        max abs droop residual, using exact droop parameters. Scalar."""
        f = self.physics_features(z, est=est)
        # df spread and qv residuals are the droop-consistency block
        df_spread = f[PHYS_IDX['df_spread']]
        qv = f[PHYS_IDX['qv_res']]
        return float(max(df_spread, np.max(np.abs(qv))))


N_BUS = 33
PHYS_NAMES = (
    ['Vhat_%d' % (i+1) for i in range(N_BUS)] + ['J_wls'] +
    ['df_der%d' % (i+1) for i in range(4)] + ['df_spread'] +
    ['qvres_der%d' % (i+1) for i in range(4)] +
    ['p_balance', 'q_balance', 'v_min', 'v_max'])
PHYS_IDX = {
    'Vhat': slice(0, 33), 'J_wls': 33, 'df': slice(34, 38), 'df_spread': 38,
    'qv_res': slice(39, 43), 'p_balance': 43, 'q_balance': 44,
    'v_min': 45, 'v_max': 46}


def physics_features_batch(Z, se=None, verbose_every=0):
    """Compute F2 features for a matrix of snapshots (rows). NaN rows pass through."""
    if se is None:
        se = GridSE()
    out = np.full((Z.shape[0], len(PHYS_NAMES)), np.nan)
    for i in range(Z.shape[0]):
        if np.any(np.isnan(Z[i])):
            continue
        out[i] = se.physics_features(Z[i])
        if verbose_every and (i+1) % verbose_every == 0:
            print('  physics features: %d/%d' % (i+1, Z.shape[0]), flush=True)
    return out


if __name__ == '__main__':
    # smoke test: SE recovers a clean operating point and a=Hc bias shifts it
    se = GridSE()
    net, cfg = se.net, se.cfg
    Pd = se.baseP.copy(); Qd = se.baseQ.copy()
    # build a droop PF operating point via simple fixed-point on the mirror model
    from numpy.linalg import solve
    # reuse mirror droopPF inline (minimal): Newton on [theta(nonRef); Vm; f]
    N = se.N; der = se.der; ref = se.ref; nonRef = se.nonRef
    m_p, n_q, f_nom = cfg['m_p'], cfg['n_q'], cfg['f_nom']
    Pset = cfg['P_rate']/cfg['P_rate'].sum()*Pd.sum(); V0 = np.ones(len(der))
    theta = np.zeros(N); Vm = np.ones(N); f = f_nom
    for it in range(40):
        V = Vm*np.exp(1j*theta)
        S = V*np.conj(se.Ybus@V)
        Pg = np.zeros(N); Qg = np.zeros(N)
        for k in range(len(der)):
            b = der[k]
            Pg[b] = Pset[k]-(f-f_nom)/m_p[k]
            Qg[b] = Qg[b]+(V0[k]-Vm[b])/n_q[k]
        F = np.concatenate([S.real-(Pg-Pd), S.imag-(Qg-Qd)])
        if np.max(np.abs(F)) < 1e-9: break
        dVa, dVm_ = dSbus_dV(se.Ybus, V)
        J_Pth = dVa[:,nonRef].real; J_PV = dVm_.real
        J_Qth = dVa[:,nonRef].imag; J_QV = dVm_.imag.copy()
        colPf = np.zeros((N,1)); colQf = np.zeros((N,1))
        for k in range(len(der)):
            J_QV[der[k],der[k]] += 1/n_q[k]
            colPf[der[k],0] = 1/m_p[k]
        Jac = np.block([[J_Pth,J_PV,colPf],[J_Qth,J_QV,colQf]])
        du = solve(Jac, -F)
        theta[nonRef] += du[:N-1]; Vm = np.clip(Vm+du[N-1:2*N-1],0.5,1.5); f += du[2*N-1]
    V = Vm*np.exp(1j*theta)
    print('operating point: f=%.4f Vmin=%.4f' % (f, Vm.min()))
    rng = np.random.default_rng(0)
    z = measModel(se.Ybus, se.Yf, se.f_idx, V) + 1e-3*rng.standard_normal(se.nMeas)
    th_e, Vm_e, J, ok, iters = se.estimate(z)
    print('SE: converged=%s iters=%d J=%.2f (dof=%d)  max|Vm err|=%.2e' % (
        ok, iters, J, se.dof, np.max(np.abs(Vm_e-Vm))))
    ff = se.physics_features(z)
    print('df_spread=%.3e  max|qv_res|=%.3e  oracle=%.3e' % (
        ff[PHYS_IDX['df_spread']], np.max(np.abs(ff[PHYS_IDX['qv_res']])),
        se.oracle_score(z)))
    # biased snapshot: a = Hc with c targeting +0.05 Vm at DER buses
    H = measJacobian(se.Ybus, se.Yf, se.f_idx, V, se.ref)
    G = H.T@H + 1e-9*np.eye(se.nState)
    A = np.zeros((len(der), se.nState))
    for k, b in enumerate(der): A[k, (N-1)+b] = 1
    GinvAt = np.linalg.solve(G, A.T)
    c = GinvAt@np.linalg.solve(A@GinvAt, 0.05*np.ones(len(der)))
    za = z + H@c
    th_a, Vm_a, Ja, ok_a, _ = se.estimate(za)
    fa = se.physics_features(za)
    print('attacked: J=%.2f  df_spread=%.3e  max|qv_res|=%.3e  oracle=%.3e' % (
        Ja, fa[PHYS_IDX['df_spread']], np.max(np.abs(fa[PHYS_IDX['qv_res']])),
        se.oracle_score(za)))
