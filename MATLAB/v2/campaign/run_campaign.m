function run_campaign(wid, launchId, mode)
% RUN_CAMPAIGN  Campaign worker for SimulateMicrogridFDI_v2 (does NOT modify it).
%   run_campaign(wid, launchId)          full campaign; several workers share the
%                                        job list through atomic claim folders
%   run_campaign(wid, launchId, 'test')  smoke test (600 steps) into campaign\test\
%   run_campaign('aggregate')            -> campaign_aggregate (tidy CSVs, CIs, figures)
% A job is skipped when its metrics CSV already exists (resumable).
% Outputs: runs\<cfg>\s<seed>\{PF,QV}\ (simulator files), metrics\<cfg>_s<seed>.csv
% (one row per channel), logs (stdout, redirected by the launcher).
    here = fileparts(mfilename('fullpath'));
    simDir = fileparts(here);                       % ...\MATLAB\v2
    addpath(simDir);  addpath(here);
    if ischar(wid) && strcmpi(wid,'aggregate'), campaign_aggregate(); return; end
    if nargin < 3, mode = 'full'; end
    if strcmpi(mode,'test'), root = fullfile(here,'test'); else, root = here; end
    runRoot = fullfile(root,'runs');  metRoot = fullfile(root,'metrics');
    claimRoot = fullfile(root,'claims', char(launchId));
    for d = {runRoot, metRoot, claimRoot, fullfile(root,'logs')}, if ~exist(d{1},'dir'), mkdir(d{1}); end, end
    jobs = campaign_configs(mode);
    fprintf('[w%d] %s | %d jobs | maxNumCompThreads=%d | MATLAB %s\n', wid, char(datetime('now')), ...
        numel(jobs), maxNumCompThreads, version);
    nDone = 0;
    for k = 1:numel(jobs)
        jb = jobs(k);
        name = sprintf('%s_s%d', jb.cfg, jb.seed);
        metFile = fullfile(metRoot, [name '.csv']);
        if exist(metFile,'file'), continue; end
        if ~java.io.File(fullfile(claimRoot, name)).mkdir(), continue; end   % atomic claim
        od = fullfile(runRoot, jb.cfg, sprintf('s%d', jb.seed));
        t0 = tic;
        try
            o = SimulateMicrogridFDI_v2('seed', jb.seed, jb.opts{:}, 'outDir', od, 'verbose', false);
            wall = toc(t0);
            rows = {};
            for ch = {'pf','qv'}
                dbgFile = fullfile(od, upper(ch{1}), ['debug_' ch{1} '.mat']);
                meta = struct('config',string(jb.cfg),'channel',string(upper(ch{1})), ...
                              'seed',jb.seed,'magScale',jb.magScale);
                r = campaign_metrics(o.(ch{1}), ch{1}, dbgFile);
                rows{end+1} = mergeRow(meta, r); %#ok<AGROW>
            end
            T = [struct2table(rows{1},'AsArray',true); struct2table(rows{2},'AsArray',true)];
            T.wall_s = repmat(wall, height(T), 1);
            T.threads = repmat(maxNumCompThreads, height(T), 1);
            writetable(T, [metFile '.tmp.csv']);
            movefile([metFile '.tmp.csv'], metFile);
            nDone = nDone + 1;
            fprintf('[w%d] %s done in %.1f s (PF alarm att %.2f%% / nor %.2f%%; QV %.2f%% / %.2f%%)\n', wid, name, wall, ...
                100*T.alarmAtt_rate(1), 100*T.alarmNor_rate(1), 100*T.alarmAtt_rate(2), 100*T.alarmNor_rate(2));
        catch err
            fprintf(2, '[w%d] %s FAILED: %s\n', wid, name, getReport(err,'extended','hyperlinks','off'));
            fid = fopen(fullfile(root,'logs', sprintf('FAILED_%s.txt', name)),'w');
            if fid > 0, fprintf(fid, '%s\n', getReport(err,'extended','hyperlinks','off')); fclose(fid); end
        end
    end
    fprintf('[w%d] finished %s, %d jobs run by this worker\n', wid, char(datetime('now')), nDone);
end

function s = mergeRow(a, b)
    % concatenate the fields of two scalar structs (a first)
    s = a;  f = fieldnames(b);
    for i = 1:numel(f), s.(f{i}) = b.(f{i}); end
end
