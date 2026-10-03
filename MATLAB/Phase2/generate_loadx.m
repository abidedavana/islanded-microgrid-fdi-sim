function generate_loadx()
% GENERATE_LOADX  E9 heterogeneous-load robustness cells (user-approved).
% Per-bus multiplicative load jitter thickens the rank-1 normal manifold.
% All UCI segments disjoint from the main campaign (which uses 0-18400,
% 40000-44400, 80000-144400, 160000-167400):
%
%   LXTRAIN  seed 501  offset 20000  logged 18000  jitter 5%
%   LXVAL    seed 505  offset 45000  logged  4000  jitter 5%
%   LXT5-r   seeds 511-515, offsets 50000..74000 (6k apart), logged 4000, jitter 5%
%   LXT2-r   seeds 521-522, offsets 168000,174000, logged 4000, jitter 2%
%
% Two analyses downstream (Python/Detector/loadx_eval.py):
%   shift:   rank-1-trained detectors evaluated on jittered TEST (FPR stress)
%   retrain: jitter-trained detectors, thresholds on LXVAL, eval on LXT5

    reg = fullfile(fileparts(fileparts(mfilename('fullpath'))), '..', ...
        'Python','Validation','RegroupedDataset','RegroupedData.csv');
    t0 = tic;

    GenerateDetectorData('steps',18400,'warmup',400,'seed',501,'offset',20000, ...
        'data',reg,'name','LXTRAIN','loadjitter',0.05);
    GenerateDetectorData('steps',4400,'warmup',400,'seed',505,'offset',45000, ...
        'data',reg,'name','LXVAL','loadjitter',0.05);

    offs = 50000:6000:74000;  seeds = 511:515;
    for i = 1:5
        GenerateDetectorData('steps',4400,'warmup',400,'seed',seeds(i), ...
            'offset',offs(i),'data',reg,'name',sprintf('LXT5%d',seeds(i)), ...
            'loadjitter',0.05);
    end
    for i = 1:2
        GenerateDetectorData('steps',4400,'warmup',400,'seed',520+i, ...
            'offset',168000+(i-1)*6000,'data',reg,'name',sprintf('LXT2%d',520+i), ...
            'loadjitter',0.02);
    end

    fprintf('\n=== generate_loadx DONE in %.1f min ===\n', toc(t0)/60);
end
