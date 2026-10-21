function t = tcrit95(nu)
% TCRIT95  Two-sided 95% Student-t critical value t_{0.975,nu} without the
% Statistics Toolbox: P(|T|>t) = I_{nu/(nu+t^2)}(nu/2, 1/2) = 0.05.
    x = betaincinv(0.05, nu/2, 0.5);
    t = sqrt(nu .* (1 - x) ./ x);
end
