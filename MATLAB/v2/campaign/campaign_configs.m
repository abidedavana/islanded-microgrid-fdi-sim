function [jobs, cfgs] = campaign_configs(mode)
% CAMPAIGN_CONFIGS  Configuration table and job list of the sim_v2 campaign.
%   [jobs, cfgs] = campaign_configs()        full campaign (3000 steps / 400 warm-up)
%   [jobs, cfgs] = campaign_configs('test')  quick smoke test (600 / 100, seed 1, C0 C2 C5)
% Each job: .cfg (config id), .seed, .magScale, .opts (cell of name-value pairs).
    if nargin < 1, mode = 'full'; end
    common = {'data','uci','steps',3000,'warmup',400,'attackprob',0.25,'debugsteps',1e6};
    seeds20 = 1:20;  seeds10 = 1:10;
    corr = {'vmeters','der','attack','ac','estimator','acwls','ctrlinput','estimate', ...
            'attknow','true','fsource','inferred'};
    cfgs = struct('id',{},'desc',{},'opts',{},'seeds',{},'magScale',{});
    add('C0', 'ORIGINAL (all defaults)', {}, seeds20, 1);
    add('C1', 'NAIVE attacker (linear a=Hc, |V|-unaware) vs CORRECTED defender', ...
        {'vmeters','der','attack','linear','attmeters','legacy','estimator','acwls', ...
         'ctrlinput','estimate','attknow','true','fsource','inferred'}, seeds20, 1);
    add('C2', 'MAIN corrected attacker + defender', corr, seeds20, 1);
    add('C3', 'C2 + attknow stale', setOpt(corr,'attknow','stale'), seeds20, 1);
    add('C4', 'C2 + fsource measured', setOpt(corr,'fsource','measured'), seeds20, 1);
    add('C5', 'AC attacker on the 130 legacy meters, |V| meters unreachable', ...
        {'vmeters','der','attack','ac','attmeters','legacy','estimator','acwls', ...
         'ctrlinput','estimate','attknow','true','fsource','inferred'}, seeds20, 1);
    for m = [0.25 0.5 0.75 1.0 1.25 1.5]
        add(sprintf('C6_m%.2f', m), sprintf('C2 with magScale %.2f', m), corr, seeds10, m);
    end
    if strcmpi(mode,'test')
        common = {'data','uci','steps',600,'warmup',100,'attackprob',0.25,'debugsteps',1e6};
        keep = ismember({cfgs.id}, {'C0','C2','C5'});
        cfgs = cfgs(keep);
        for k = 1:numel(cfgs), cfgs(k).seeds = 1; end
    end
    jobs = struct('cfg',{},'seed',{},'magScale',{},'opts',{});
    % order: C0 (fast) first, then heavy configs interleaved by seed so that
    % partial results cover every configuration early
    maxS = max(arrayfun(@(c) max(c.seeds), cfgs));
    for s = 1:maxS
        for k = 1:numel(cfgs)
            if ~ismember(s, cfgs(k).seeds), continue; end
            o = [common, cfgs(k).opts];
            if cfgs(k).magScale ~= 1, o = [o, {'magScale', cfgs(k).magScale}]; end %#ok<AGROW>
            jobs(end+1) = struct('cfg',cfgs(k).id,'seed',s,'magScale',cfgs(k).magScale,'opts',{o}); %#ok<AGROW>
        end
    end

    function add(id, desc, opts, seeds, mag)
        cfgs(end+1) = struct('id',id,'desc',desc,'opts',{opts},'seeds',seeds,'magScale',mag);
    end
end

function o = setOpt(o, name, val)
    k = find(strcmpi(o(1:2:end), name), 1);
    o{2*k} = val;
end
