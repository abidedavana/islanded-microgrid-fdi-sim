function campaign_figures(T, L)
% CAMPAIGN_FIGURES  Three IEEE single-column figures (3.5 in wide, Times, >= 7 pt),
% vector PDF + 600-dpi PNG, from the tidy table T and long summary L.
%   figs\fig_a_alarm.(pdf|png)   alarm rate attacked (C0-C3) vs normal false-alarm rate
%   figs\fig_b_sweep.(pdf|png)   C6 sweep: alarm rate and harmful-and-stealthy vs magScale
%   figs\fig_c_fsource.(pdf|png) C2 vs C4: criterion-crossing rates, inferred vs measured f
% Error bars: 95% Student-t CI over seeds.  Source CSV: campaign_tidy.csv / campaign_summary_long.csv.
    here = fileparts(mfilename('fullpath'));
    od = fullfile(here,'figs');  if ~exist(od,'dir'), mkdir(od); end
    fn = 'Times New Roman';  fsAx = 8;  fsTk = 7;
    cBlue = hex('#2a78d6');  cOrange = hex('#eb6834');  cGray = hex('#a3a3a3');  cInk = hex('#222222');
    q = @(cfg, ch, m) getS(L, cfg, ch, m);
    chans = ["PF","QV"];  chLab = {['P' char(8211) 'f channel'], ['Q' char(8211) 'V channel']};

    % ================= (a) alarm rates C0..C3 =================
    cfgA = ["C0","C1","C2","C3"];
    xl = {'C0','C1','C2','C3'};
    fig = newFig(3.5, 2.25);
    tl = tiledlayout(fig, 1, 2, 'TileSpacing','compact', 'Padding','compact');
    for c = 1:2
        ax = nexttile(tl);  hold(ax,'on');
        Y = zeros(4,2); LO = Y; HI = Y;
        for i = 1:4
            [Y(i,1), LO(i,1), HI(i,1)] = q(cfgA(i), chans(c), "alarmAtt_rate");
            [Y(i,2), LO(i,2), HI(i,2)] = q(cfgA(i), chans(c), "alarmNor_rate");
        end
        Y = 100*Y; LO = 100*LO; HI = 100*HI;
        floorV = 0.1;
        b = bar(ax, 1:4, max(Y, floorV), 'grouped', 'BaseValue', floorV, 'BarWidth', 0.8, 'EdgeColor','none');
        b(1).FaceColor = cBlue;  b(2).FaceColor = cGray;
        for k = 1:2
            x = b(k).XEndPoints;
            errorbar(ax, x, max(Y(:,k),floorV), max(Y(:,k)-max(LO(:,k),floorV),0), max(HI(:,k)-Y(:,k),0), ...
                'LineStyle','none','Color',cInk,'CapSize',2,'LineWidth',0.5,'HandleVisibility','off');
        end
        yline(ax, 1, ':', 'Color', cInk, 'LineWidth', 0.6, 'HandleVisibility','off');
        set(ax, 'YScale','log', 'YLim',[floorV 200], 'XLim',[0.4 4.6], 'XTick',1:4, 'XTickLabel', xl, ...
            'YTick',[0.1 1 10 100], 'YTickLabel',{'0.1','1','10','100'}, 'TickDir','out', 'Box','off', ...
            'FontName',fn, 'FontSize',fsTk, 'YMinorTick','off', 'LineWidth',0.5, 'Layer','top');
        ax.YGrid = 'on';  ax.GridAlpha = 0.15;  ax.YMinorGrid = 'off';
        title(ax, chLab{c}, 'FontName',fn, 'FontSize',fsAx, 'FontWeight','normal');
        if c == 1, ylabel(ax, 'BDD alarm rate (%)', 'FontName',fn, 'FontSize',fsAx); end
        if c == 1
            lg = legend(ax, {'Attacked steps','Normal steps (false alarms)'}, 'Orientation','horizontal', ...
                'FontName',fn, 'FontSize',fsTk, 'Box','off');
            lg.Layout.Tile = 'north';
            lg.ItemTokenSize = [10 6];
        end
    end
    saveFig(fig, fullfile(od,'fig_a_alarm'));

    % ================= (b) magnitude sweep =================
    mags = [0.25 0.5 0.75 1.0 1.25 1.5];
    fig = newFig(3.5, 3.1);
    tl = tiledlayout(fig, 2, 1, 'TileSpacing','compact', 'Padding','compact');
    mk = {'o','s'};  ls = {'-','--'};  cc = {cBlue, cOrange};
    metr = ["alarmAtt_rate","hs_rate"];
    yl = {'BDD alarm rate (%)', 'Harmful & stealthy (%)'};
    hL = gobjects(0);
    for pnl = 1:2
        ax = nexttile(tl);  hold(ax,'on');
        for c = 1:2
            Y = nan(size(mags)); LO = Y; HI = Y; YN = Y;
            for i = 1:numel(mags)
                cf = sprintf("C6_m%.2f", mags(i));
                [Y(i), LO(i), HI(i)] = q(cf, chans(c), metr(pnl));
                YN(i) = q(cf, chans(c), "alarmNor_rate");
            end
            Y = 100*Y; LO = 100*LO; HI = 100*HI; YN = 100*YN;
            if pnl == 1
                hn = plot(ax, mags + (c-1.5)*0.02, YN, ':', 'Color', cGray, 'LineWidth', 0.9, 'Marker', mk{c}, ...
                    'MarkerSize', 3, 'MarkerFaceColor', 'w', 'MarkerEdgeColor', cGray);
                if c == 1, hNor = hn; end
            end
            h = errorbar(ax, mags + (c-1.5)*0.02, Y, Y-LO, HI-Y, ls{c}, 'Color', cc{c}, 'LineWidth', 1.0, ...
                'Marker', mk{c}, 'MarkerSize', 3, 'MarkerFaceColor', cc{c}, 'CapSize', 2);
            if pnl == 1, hL(end+1) = h; end %#ok<AGROW>
        end
        set(ax, 'XLim',[0.15 1.6], 'XTick', mags, 'XTickLabel', {'0.25','0.5','0.75','1','1.25','1.5'}, ...
            'XTickLabelRotation', 0, 'TickDir','out', 'Box','off', 'FontName',fn, 'FontSize',fsTk, 'LineWidth',0.5);
        ax.YGrid = 'on';  ax.GridAlpha = 0.15;
        if pnl == 1, ylim(ax, [0 3]); set(ax,'YTick',0:1:3); xticklabels(ax, {});
        else, ylim(ax, [0 100]); set(ax,'YTick',0:25:100);
            xlabel(ax, 'Attack magnitude scale (magScale)', 'FontName',fn, 'FontSize',fsAx);
        end
        ylabel(ax, yl{pnl}, 'FontName',fn, 'FontSize',fsAx);
    end
    lg = legend([hL hNor], {['P' char(8211) 'f attacked'], ['Q' char(8211) 'V attacked'], 'Normal steps'}, ...
        'Orientation','horizontal', 'FontName',fn, 'FontSize',fsTk, 'Box','off');
    lg.Layout.Tile = 'north';  lg.ItemTokenSize = [14 6];
    saveFig(fig, fullfile(od,'fig_b_sweep'));

    % ================= (c) inferred vs measured frequency =================
    fig = newFig(3.5, 2.0);
    tl = tiledlayout(fig, 1, 1, 'Padding','compact');
    ax = nexttile(tl);  hold(ax,'on');
    grpLab = {['P' char(8211) 'f, attacked'], ['P' char(8211) 'f, normal'], ...
              ['Q' char(8211) 'V, attacked'], ['Q' char(8211) 'V, normal']};
    Y = zeros(4,2); LO = Y; HI = Y;
    src = ["C2","C4"];
    for s = 1:2
        for c = 1:2
            [Y(2*c-1,s), LO(2*c-1,s), HI(2*c-1,s)] = q(src(s), chans(c), "crossAtt_rate");
            [Y(2*c,s),   LO(2*c,s),   HI(2*c,s)]   = q(src(s), chans(c), "crossNor_rate");
        end
    end
    Y = 100*Y; LO = 100*LO; HI = 100*HI;
    b = bar(ax, 1:4, Y, 'grouped', 'BarWidth', 0.8, 'EdgeColor','none');
    b(1).FaceColor = cBlue;  b(2).FaceColor = cOrange;
    for k = 1:2
        x = b(k).XEndPoints;
        errorbar(ax, x, Y(:,k), max(Y(:,k)-LO(:,k),0), max(HI(:,k)-Y(:,k),0), 'LineStyle','none', ...
            'Color',cInk,'CapSize',2,'LineWidth',0.5,'HandleVisibility','off');
        for i = 1:4
            text(ax, x(i), max(HI(i,k), Y(i,k)) + 2.5, sprintf('%.1f', Y(i,k)), 'HorizontalAlignment','center', ...
                'VerticalAlignment','bottom', 'FontName',fn, 'FontSize',fsTk, 'Color', cInk);
        end
    end
    set(ax, 'XLim',[0.4 4.6], 'XTick',1:4, 'XTickLabel', grpLab, 'YLim',[0 100], 'TickDir','out', 'Box','off', ...
        'FontName',fn, 'FontSize',fsTk, 'LineWidth',0.5, 'Layer','top');
    ax.YGrid = 'on';  ax.GridAlpha = 0.15;
    ylabel(ax, 'Criterion crossings (% of steps)', 'FontName',fn, 'FontSize',fsAx);
    lg = legend(ax, {'Inferred f (C2)','Measured f (C4)'}, 'Orientation','horizontal', ...
        'FontName',fn, 'FontSize',fsTk, 'Box','off');
    lg.Layout.Tile = 'north';  lg.ItemTokenSize = [10 6];
    saveFig(fig, fullfile(od,'fig_c_fsource'));
end

% -------------------------------------------------------------------------
function [m, lo, hi] = getS(L, cfg, ch, metric)
    r = L(L.config==cfg & L.channel==ch & L.metric==metric, :);
    if isempty(r), m = NaN; lo = NaN; hi = NaN; return; end
    m = r.mean;  lo = r.ci95_lo;  hi = r.ci95_hi;
    if isnan(lo), lo = m; hi = m; end
end

function fig = newFig(w, h)
    fig = figure('Visible','off', 'Units','inches', 'Position',[1 1 w h], 'Color','w', ...
        'PaperUnits','inches', 'PaperSize',[w h], 'PaperPosition',[0 0 w h]);
    try, fig.Theme = 'light'; catch, end          % R2025a+ default theme may follow the OS (dark)
    ink = [0.133 0.133 0.133];
    set(fig, 'DefaultAxesFontName','Times New Roman', 'DefaultTextFontName','Times New Roman', ...
        'DefaultAxesColor','w', 'DefaultAxesXColor',ink, 'DefaultAxesYColor',ink, ...
        'DefaultAxesGridColor',[0.15 0.15 0.15], 'DefaultTextColor',ink, ...
        'DefaultLegendTextColor',ink, 'DefaultLegendColor','w');
end

function styleAll(fig)
    % force light styling on every axes / legend / text (independent of the theme)
    ink = [0.133 0.133 0.133];
    for ax = findall(fig,'Type','axes')'
        ax.Color = 'w';  ax.XColor = ink;  ax.YColor = ink;  ax.GridColor = [0.15 0.15 0.15];
        ax.Title.Color = ink;  ax.XLabel.Color = ink;  ax.YLabel.Color = ink;
    end
    for lg = findall(fig,'Type','legend')', lg.TextColor = ink; lg.Color = 'w'; end
    for tx = findall(fig,'Type','text')', tx.Color = ink; end
end

function saveFig(fig, base)
    styleAll(fig);
    exportgraphics(fig, [base '.pdf'], 'ContentType','vector', 'BackgroundColor','white', 'Padding','figure');
    exportgraphics(fig, [base '.png'], 'Resolution', 600, 'BackgroundColor','white', 'Padding','figure');
    close(fig);
end

function c = hex(h)
    c = sscanf(h(2:end), '%2x%2x%2x', [1 3]) / 255;
end
