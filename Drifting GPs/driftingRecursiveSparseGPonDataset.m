clear all, %close all
%% Run once:
%
pathGPML = 'C:\Users\wout7\Documents\GitHub\gpml\startup.m';
run(pathGPML)
addpath('Plot_tools')
addpath('Functions')
%}

%% Select and open Dataset ('Default' opens file explorer)
dataID = 'TFlex1D-2.mat';
[X,Y,ts,N_io] = selectData('dataset',dataID);
X(1:376,:) = [];
Y(1:376,:) = [];
Y = movmean(Y,10);

X_max = max(X);
X = X./X_max;
load('Y_predict.mat');
Y_predict = YMUVall';
X = [X,Y_predict];

X_active     = [1,2,4];     % Active columns in X; 1=pos,2=vel,3=acc
%X = X(2000:end,:); Y = Y(2000:end,:);
%% Online Sparse Gaussian Process regression
param_update   =  true;     % Update hyperparameters in the loop (true/false)
param_fix      =  [];    % Exclude hyperparams from update (by indices) (only if param_updata == true)
showAnimation  =  false;    % Show an (online) animation of predictions
loadSettings   =  false;
saveSettings   =  false;
settingsFile   =  ['Results/',dataID(1:end-4),'_settings.mat'];

Z = 500;        % Size of drifting window
M = 50;         % Number of inducing points (for sparse GPR)

batchSize  =  5;           % Size of batched received each timestep
method     =  [1,4];       % Sampling method (see initSampling.m & updateSampling.m)
resamp     =  5;           % Resample factor (1 = no resampling)
maxSamples =  1e7;         % Max number of samples
N_query    =  5;           % Predict N number of timesteps in the future
N_search   =  10;          % Max. iter. of gradient descent for inference
t_period   =  17.66*2;        % [s] period

% Learning rates (exponential smootheners)
alpha = 0.5;         % Hyperparameters
beta  = 0.5;       % Inducing points
kappa = 0.1;       % Prediction

% Approximation method:
s = 1;      %S = 0: VFE    0<s<1: SPEP     s = 1: FITC

N = N_io(1);    % Number of inputs
Q = N;          % Number of latent functions
P = N_io(2);    % Number of outputs

%% Resampling & select active signals
TS =  batchSize*ts; % Stepsize over each batch update
X = X(:,X_active);  % Select signals
NX = size(X,2);     % Dimension of input vector

%% Initialize Gaussian process
% Initial inducing points
[indi_indc] = initSampling(method(1),Z,M);

% Initial (unit) covariance 
sf      =   exp(1);                  % Sigma_f       (at t=0, 1)
ell     =   ones(NX*Q,1)*exp(1);     % Length scales (at t=0, 1)

%'TFlex1D5G.mat'
sf      = exp([5.8256]);
ell     = exp([1.3916    3.1059   12.9106    6.7833]');
ell     = ell(X_active,:);
%{
%'TFlex1D-2.mat'
%sf      = exp(10.6224);
%ell     = exp([15.0823    7.5480   17.9270]');

%'TFlex1D-2.mat'
%sf      = exp(5.7702);
%sf      = exp(10.6224);
%ell     = exp([-1.4131   -0.4285    4.8100]');

%'doublePendulum.mat'
%sf(1)       = exp(-2.6841)
%sf(2)       = exp([-2.0767])
%ell(:,1)    = exp([1.4066    0.8909    1.2408    0.6191    1.7097    1.9975])
%ell(:,2)    = exp([1.0361    0.8823    1.0771    0.5396    0.8840    1.3924])
%}

%Covariance
xu      =   X(indi_indc,:);         % Initial inducing points
hyp.cov =   log([ell;sf]);          % Hyperparameters of covariance function
hyp.xu  =   xu;                     % Inducing points as hyperparameters (so we can optimize them)
cov     =   @covSEard;              % Squared exponentioal covariance with automatic relevance determination
cov_sp  =   {'apxSparse',{cov}}; % Sparse version of cov

% mean function
mean_gp =   @meanZero;              % Zero mean function

% likelihood
sn      =   exp(1);                 % Standard diviation of likelihood function
lik     =   {@likGauss};            % Gaussian likelihood
hyp.lik =   log(sn);                % Hyperparameter likelihood

% inference
inf     =   @infGaussLik;           % Inference gaussian likelihood
inf     =   @(varargin) inf(varargin{:},struct('s',s)); % Sparse version of inf

% Prior distributions - Exlude some hyperparams from optimization
if param_update == true && length(param_fix) > 0
    prior.cov = {};
    prior.cov{length(hyp.cov),1} = [];
    for jj = param_fix
        prior.cov{jj} = {@priorDelta};      % @priorDelta fixes the jj'th hyperparam in hyp.cov
    end
    inf       =  {@infPrior,inf,prior};     % Add prior to inference method
end

% Copy to all dof's (To)
for ii = 1:Q
    hypStruc(ii).hyp.xu = xu;
    hypStruc(ii).hyp.lik = hyp.lik;
    hypStruc(ii).hyp.cov = log([ell(:,ii);sf(:,ii)]);
end
%% Overwrite GP settings
if loadSettings == true
load(settingsFile)
X  = X(:,X_active);  % Select signals
NX = size(X,2);     % Dimension of input vector
end
%% Preallocate some matrices
tic
%Loop over the following indices of X
i_loop  = (resamp*Z + batchSize):(batchSize):(min(maxSamples,length(X))-(N_query+1));
%i_loop  = (resamp*Z + batchSize):batchSize:(length(X)-N_query);

N_loop  = length(i_loop) + 1;  % + 1 because of initial step.

% In order to track predictions & hyperparams pre-allocate matrices;
hyp_old = zeros(size(hyp.cov,1),Q);   % Hyperparams of covFunc of previous timestep
HYP     = zeros(P,N*NX+1,N_loop);     % For covFunc hyperparams at each timestep
YMUV    = zeros(P,N_loop);            % For t+1 prediction mean
YMUVall = zeros(P,N_loop*N_query);    % For t+N_query predictions
YS2S    = zeros(P,N_loop);            % For t+1 prediction variance
YS2Sall = zeros(P,N_loop);            % For t+1 prediction variance
T       = zeros(1,N_loop);            % For t
I       = ones(1,N_loop);             % For indices
Iall    = ones(P,N_loop*N_query);     % For indices (t+N_query predictions)

%% Drifting sparse GPR - intitial timestep (iter = 1)
%Indices vectors
indi         =   [1 :resamp:(Z*resamp)];
indi_predict =   indi(end) + [1:N_query];
indi_tot     =   union(indi,indi_predict);  % indices of both

%time vector and plot limits
t            =               indi*ts;   % For training points
t_predict    =       indi_predict*ts;   % For predictions
t_tot        =           indi_tot*ts;   % For training + predictions
Xlimits      =  [indi_tot(1)-5, indi_tot(end)+5]*ts;   % Plot limits

% First time step
iter = 1;

% Select initial training and query data
X_train     =   X(indi,:);
Y_train     =   Y(indi,:);
X_predict   =   X(indi_predict,:);
T(iter)     =   t_predict(1);
I(iter)     =   indi_predict(1);
Iall(iter:(iter*N_query)) = indi_predict;

% Hyperparameter optimization
if param_update == true
    for ii = 1:Q
        hyp_old(:,ii)        =  hypStruc(ii).hyp.cov;  % initial hyperparams
        hypStruc(ii).hyp     =  minimize(hypStruc(ii).hyp,@gp,-N_search,inf,mean_gp,cov_sp,lik,X_train,Y_train(:,ii));
        hypStruc(ii).hyp.cov =  (1-alpha)*hyp_old(:,ii) + alpha*hypStruc(ii).hyp.cov; % Quadratic smoothener
        HYP(ii,:,iter)       =  hypStruc(ii).hyp.cov;  % Save data
    end
end

% Conditioning on training data & prediction
for ii = 1:P
[nlZ dnlZ, post(ii)]             = gp(hypStruc(ii).hyp,inf,mean_gp,cov_sp,lik,X_train,Y_train(:,ii));
[ymuv(:,ii),ys2s(:,ii),~,~,~,~]  = gp(hypStruc(ii).hyp,inf,mean_gp,cov_sp,lik,X_train,post(ii),X_predict);
%[ymuv(:,ii),ys2s(:,ii),~,~,~,]   = gp(hypStruc(ii).hyp,inf,mean_gp,cov,lik,X_train,Y_train(:,ii),X_predict);
end
YMUVall(:,iter:(iter*N_query)) = ymuv';
X(iter:(iter*N_query),size(X_active,2)) = ymuv;


if showAnimation == true;
    h = figure(112);clf(h);
end

% start loop
iter = 2;
t_iter = 0;
for i = i_loop
    %% Update moving window
    % Indices vectors:
    indi          =  indi         + batchSize;
    indi_predict  =  indi_predict + batchSize;
    indi_tot      =  indi_tot     + batchSize;
    % Time vectors:
    t             =  t         + TS;
    t_predict     =  t_predict + TS;
    t_tot         =  t_tot     + TS;
    Xlimits       =  Xlimits   + TS;
    % Training and query data:
    X_train   = X(indi,:);
    Y_train   = Y(indi,:);
    X_predict = X(indi_predict,:);
    I(iter)   = indi_predict(1);
    T(iter)   = t_predict(1);
    Iall(:,((iter-1)*N_query+1):(iter*N_query)) = indi_predict;
    tic;
    % Inducing points
    xu_old    =    hypStruc(1).hyp.xu;      % Old inducing points
    xu_new    =    updateInducingPoints(xu_old,X_train,indi_indc,beta,batchSize,Z,method(2));
    
    for ii = 1:Q
        hypStruc(ii).hyp.xu = xu_new;       % Update inducing points
    end
    
    %% Hyperparameter optimization & pseudo input search
    if param_update == true
        for ii = 1:Q
            hyp_old(:,ii)        =  hypStruc(ii).hyp.cov;  % initial hyperparams
            hypStruc(ii).hyp     =  minimize(hypStruc(ii).hyp,@gp,-N_search,inf,mean_gp,cov_sp,lik,X_train,Y_train(:,ii));
            hypStruc(ii).hyp.cov =  (1-alpha)*hyp_old(:,ii) + alpha*hypStruc(ii).hyp.cov; % Quadratic smoothener
            HYP(ii,:,iter)       =  hypStruc(ii).hyp.cov;  % Save hyperparam data
        end
    end
    %% Prediction
    for ii = 1:Q
        %[nlZ dnlZ, post(ii)]                     = gp(hypStruc(ii).hyp,inf,mean_gp,cov_sp,lik,X_train,Y_train(:,ii));
        %[ymuv(:,ii),ys2s(:,ii),~,~,~,~]  = gp(hypStruc(ii).hyp,inf,mean_gp,cov_sp,lik,X_train,post(ii),X_predict);
        [ymuv(:,ii),ys2s(:,ii)]  = gp(hypStruc(ii).hyp,inf,mean_gp,cov_sp,lik,X_train,Y_train(:,ii),X_predict);
    end 
    t_iter = t_iter+toc;
    
    i_add = ((iter-1)*N_query+1):(iter*N_query);
    YMUVall(:,i_add) = (1-kappa)*YMUVall(:,i_add(1)-1) + kappa*ymuv';      %save data of t+N_query step
    YS2Sall(:,i_add) = (1-kappa)*YMUVall(:,i_add(1)-1) + kappa*ys2s';  %save smoothened data of t+1 step
    X(i_add,size(X_active,2)) = YMUVall(:,i_add)';
    %% Plot (moving) time window and predictions
    if showAnimation == true
        plot(t_tot,Y(indi_tot,:));          %actual values
        hold on
        for ii = 1:Q
            plot(t_predict,ymuv,'--k');              % Predicted mean
            plot(t_predict,ymuv+2*sqrt(ys2s),'-xk'); % 95% confidence bound  
            plot(t_predict,ymuv-2*sqrt(ys2s),'-xk'); % 95% confidence bound  
        end
        hold off
        xlim(Xlimits); title(['TARGET: Torque/Current']);
        drawnow;
    end
   %% Update Iterations
   iter  =  iter + 1;
      if mod(iter,round(N_loop/10)) == 0
       round(iter/N_loop*100)
   end
end

%%
t_total = t_iter;
t_iter  = t_iter/iter;
%Y = Y*Y_max + Y_avg;
%YMUVall = YMUVall.*Y_max + Y_avg;


%% Write settings to .mat file (TODO)
if saveSettings == true
    write2struct;
    save(['Results/',dataID(1:end-4),'_settings.mat'],'-struct','settings');
end
%% Plot Results
tall      = [1:size(X,1)]*ts;
tlong     = T(1)+([1:(N_loop)*N_query])*ts;
t_predict = T;
i_predict = [(resamp*Z):1:length(X)];

addpath('Data/InverseDynamics')
load('TFlex1D-2real.mat')
Y_new    = Y_mean;
Y_new(1:376,:) = [];
sigma_s  = noise_est; 
sigma_s(1:376,:) = [];

%Hyperparams
if param_update == true
    figure(555),clf(555)
    hold on
    for ii = 1:Q
        hyperparams = squeeze(HYP(ii,:,:))';
        subplot(1,Q,ii);
        plot(t_predict',hyperparams,'LineWidth',1.5);
        hold on
        fm = 4/5;
        mean_hyp = mean(hyperparams(round(length(hyperparams)*fm):end,:))';
        plot(t_predict([1,end]),[mean_hyp,mean_hyp]','--k');
        hold off
        xlabel('[s]');
        legend('$l_1$ $(\theta)$','$l_2$ $(\dot{\theta})$','$l_3$ $(\ddot{\theta})$','$\tau_{t-1}$','$\sigma_s$','Interpreter','Latex');
    end
    hold off
end

% Plot N_query-step ahead predictions & actual values
figure(558),clf(558)
hold on
for ii = 1:P
    scatter(tall,Y(:,ii)','MarkerEdgeColor','none','MarkerFaceColor','b','MarkerFaceAlpha',.05)
    plot(tall,Y_new(:,:)','r','LineWidth',2.5);
    
    plot(tlong,YMUVall(ii,:),'.-k','LineWidth',2);
    plot(tall,Y_new' + sigma_s','k')
    plot(tall,Y_new' - sigma_s','k')
    %     plot(tlong,YMUVall(ii,:)+sqrt(YS2Sall(ii,:)),'k');
    %     plot(tlong,YMUVall(ii,:)-sqrt(YS2Sall(ii,:)),'k');
end
hold off
xlabel('t [s]')
ylabel('I [A]')
legend('Measured','without Noise','$t+N_{query}$ pred.','$\sigma_s$','Interpreter','Latex','FontSize',12)

%% Error measure
disp(' ');
disp(['t+',num2str(N_query),' predictions:']);
NMSE = errorMeasure(Y(Iall,:)',YMUVall,'method','NMSE','show',true);
MAE = errorMeasure(Y(Iall,:)',YMUVall,'method','MAE','show',true);
MSE = errorMeasure(Y(Iall,:)',YMUVall,'method','MSE','show',true);
RMSE = errorMeasure(Y(Iall,:)',YMUVall,'method','RMSE','show',true);

disp(' ');
disp('Comp. time [s]')
disp(['total:     ',num2str(t_total)])
disp(['Per iter.: ',num2str(t_iter)])

%% Other
%plot(X_int,mean_sigma_s)
%title('Rotational displacement vs hyperparameter $\sigma_s$','Interpreter','Latex','FontSize',20)
%ylabel('$\sigma_s$','Interpreter','Latex','FontSize',20)
%xlabel('$\theta$ [deg]','Interpreter','Latex','FontSize',20)
%set(gcf,'Color','White')