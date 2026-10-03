function generate_all()
% GENERATE_ALL  Phase-2 data campaign (DETECTOR_DESIGN.md par.4 + PHASE2_NOTES E1).
% All splits use disjoint UCI segments and distinct seeds; whole-run splits.
%
%   TRAIN   seed 101  offset 0       logged 18000   semi-sup normal steps; supervised all
%   VAL     seed 105  offset 40000   logged 4000    thresholds @1%FPR, model selection
%   TEST-r  seeds 201-205, offsets 80k..140k (15k apart), logged 4000 each, variants logged
%   MAG-m   seed 301  offset 160000  logged 2000 x magScale {0.2..1.4}, variants logged
%           (same seed+segment for every magScale cell: controlled sweep)
%   CAD-p   seed 401  offset 165000  logged 2000, persist=1, attackProb {.25,.5,.75,1}
%           + CADI100 (persist=0, attackProb=1) control  (same seed+segment: controlled)
%
% 'steps' includes the 400-step warmup (logged = steps - warmup).

    reg = fullfile(fileparts(fileparts(mfilename('fullpath'))), '..', ...
        'Python','Validation','RegroupedDataset','RegroupedData.csv');
    t0 = tic;

    GenerateDetectorData('steps',18400,'warmup',400,'seed',101,'offset',0, ...
        'data',reg,'name','TRAIN');
    GenerateDetectorData('steps',4400,'warmup',400,'seed',105,'offset',40000, ...
        'data',reg,'name','VAL');

    testSeeds = 201:205;  testOffs = 80000:15000:140000;
    for i = 1:5
        GenerateDetectorData('steps',4400,'warmup',400,'seed',testSeeds(i), ...
            'offset',testOffs(i),'data',reg,'name',sprintf('TEST%d',testSeeds(i)), ...
            'logvariants',1);
    end

    mags = [0.2 0.4 0.6 0.8 1.0 1.2 1.4];
    for m = mags
        GenerateDetectorData('steps',2400,'warmup',400,'seed',301,'offset',160000, ...
            'data',reg,'name',sprintf('MAG%03d',round(100*m)),'magscale',m, ...
            'logvariants',1);
    end

    for ap = [0.25 0.50 0.75 1.00]
        GenerateDetectorData('steps',2400,'warmup',400,'seed',401,'offset',165000, ...
            'data',reg,'name',sprintf('CAD%03d',round(100*ap)), ...
            'attackprob',ap,'persist',1);
    end
    GenerateDetectorData('steps',2400,'warmup',400,'seed',401,'offset',165000, ...
        'data',reg,'name','CADI100','attackprob',1.0,'persist',0);

    fprintf('\n=== generate_all DONE in %.1f min ===\n', toc(t0)/60);
end
