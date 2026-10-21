function figs_only()
% FIGS_ONLY  Re-draw the three figures from the saved tidy / long-summary CSVs.
    here = fileparts(mfilename('fullpath'));  addpath(here);
    T = readtable(fullfile(here,'campaign_tidy.csv'), 'TextType','string');
    L = readtable(fullfile(here,'campaign_summary_long.csv'), 'TextType','string');
    campaign_figures(T, L);
end
