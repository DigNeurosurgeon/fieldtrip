function [stat] = ft_spike_xcorr(cfg,spike)

% FT_SPIKE_XCORR computes the cross-correlation histogram and shift predictor.
%
% Use as
%   [stat] = ft_spike_xcorr(cfg,data)
%
% The input SPIKE should be organised as the spike or the raw datatype, obtained from
% FT_SPIKE_MAKETRIALS or FT_PREPROCESSING (in that case, conversion is done
% within the function). A mex file is located in /contrib/spike/private
% which will be automatically mexed.
%
% Configurations options for xcorr general:
%   cfg.maxlag           = number in seconds, indicating the maximum lag for the
%                          cross-correlation function in sec (default = 0.1 sec).
%   cfg.biased           = 'yes' or 'no' (default). If 'no', we scale the
%                          cross-correlogram by M/(M-abs(lags)), where M = 2*N -1 with N
%                          the length of the data segment. 
%   cfg.method           = 'xcorr' or 'shiftpredictor'. If 'shiftpredictor'
%                           we do not compute the normal cross-correlation
%                           but shuffle the subsequent trials.
%                           If two channels are independent, then the shift
%                           predictor should give the same correlogram as the raw
%                           correlogram calculated from the same trials.
%                           Typically, the shift predictor is subtracted from the
%                           correlogram.
%   cfg.outputunit       = - 'proportion' (value in each bin indicates proportion of occurence)
%                          - 'center' (values are scaled to center value which is set to 1)
%                          - 'raw' (default) unnormalized crosscorrelogram.
%   cfg.binsize          = [binsize] in sec (default = 0.001 sec).
%   cfg.channelcmb       = Mx2 cell-array with selection of channel pairs (default = {'all' 'all'}),
%                          see FT_CHANNELCOMBINATION for details
%   cfg.latency          = [begin end] in seconds, 'max' (default), 'min', 'prestim'(t<=0), or
%                          'poststim' (t>=0).%
%   cfg.vartriallen      = 'yes' (default) or 'no'.
%                          If 'yes' - accept variable trial lengths and use all available trials
%                          and the samples in every trial.
%                          If 'no'  - only select those trials that fully cover the window as
%                          specified by cfg.latency and discard those trials that do not.
%                          if cfg.method = 'yes', then cfg.vartriallen
%                          should be 'no' (otherwise, fewer coincidences
%                          will occur because of non-overlapping windows)
%   cfg.trials           = numeric selection of trials (default = 'all')
%   cfg.keeptrials       = 'yes' or 'no' (default)
%
% A peak at a negative lag for stat.xcorr(chan1,chan2,:) means that chan1 is
% leading chan2. Thus, a negative lag represents a spike in the second
% dimension of stat.xcorr before the channel in the third dimension of
% stat.stat.
%
% Variable trial length is controlled by the option cfg.vartriallen. If
% cfg.vartriallen = 'yes', all trials are selected that have a minimum
% overlap with the latency window of cfg.maxlag. However, the shift
% predictor calculation demands that following trials have the same amount
% of data, otherwise, it does not control for rate non-stationarities. If
% cfg.vartriallen = 'yes', all trials should fall in the latency window,
% otherwise we do not compute the shift predictor.
%
% Output:
%    stat.xcorr            = nchans-by-nchans-by-(2*nlags+1) cross correlation histogram
%   or 
%    stat.shiftpredictor   = nchans-by-nchans-by-(2*nlags+1) shift predictor.
%  both with dimord 'chan_chan_time'
%    stat.lags             = (2*nlags + 1) vector with lags in seconds.
%
%    stat.trial            = ntrials-by-nchans-by-nchans-by-(2*nlags + 1) with single
%                            trials and dimord 'rpt_chan_chan_time';
%    stat.label            = corresponding labels to channels in stat.xcorr
%    stat.cfg              = configurations used in this function.

% Copyright (C) 2010-2012, Martin Vinck
%
% $Id$

revision = '$Id$';

% do the general setup of the function
ft_defaults
ft_preamble help
ft_preamble callinfo
ft_preamble trackconfig

% check input spike structure
spike = ft_checkdata(spike,'datatype', 'spike', 'feedback', 'yes');

% get the default options
cfg.trials         = ft_getopt(cfg,'trials', 'all');
cfg.latency        = ft_getopt(cfg,'latency','maxperiod');
cfg.keeptrials     = ft_getopt(cfg,'keeptrials', 'yes');
cfg.method         = ft_getopt(cfg,'method', 'xcorr');
cfg.channelcmb     = ft_getopt(cfg,'channelcmb', 'all');
cfg.vartriallen    = ft_getopt(cfg,'vartriallen', 'yes');
cfg.biased         = ft_getopt(cfg,'biased', 'no');
cfg.maxlag         = ft_getopt(cfg,'maxlag', 0.01);
cfg.binsize        = ft_getopt(cfg,'binsize', 0.001);
cfg.outputunit     = ft_getopt(cfg,'outputunit', 'proportion');

% ensure that the options are valid
cfg = ft_checkopt(cfg,'latency', {'char', 'ascendingdoublebivector'});
cfg = ft_checkopt(cfg,'trials', {'char', 'doublevector', 'logical'}); 
cfg = ft_checkopt(cfg,'keeptrials', 'char', {'yes', 'no'});
cfg = ft_checkopt(cfg,'method', 'char', {'xcorr', 'shiftpredictor'});
cfg = ft_checkopt(cfg,'channelcmb', {'char', 'cell'});
cfg = ft_checkopt(cfg,'vartriallen', 'char', {'no', 'yes'});
cfg = ft_checkopt(cfg,'biased', 'char', {'yes', 'no'});
cfg = ft_checkopt(cfg,'maxlag', 'doublescalar');
cfg = ft_checkopt(cfg,'binsize', 'doublescalar');
cfg = ft_checkopt(cfg,'outputunit', 'char', {'proportion', 'center', 'raw'});

cfg = ft_checkconfig(cfg,'allowed', {'latency', 'trials', 'keeptrials', 'method', 'channelcmb', 'vartriallen', 'biased', 'maxlag', 'binsize', 'outputunit'});

doShiftPredictor  = strcmp(cfg.method,'shiftpredictor'); % shift predictor
doBiased          = strcmp(cfg.biased,'yes'); % debiasing

% determine the corresponding indices of the requested channel combinations
cfg.channelcmb = ft_channelcombination(cfg.channelcmb, spike.label,true);
cmbindx        = zeros(size(cfg.channelcmb));
for k=1:size(cfg.channelcmb,1)
  cmbindx(k,1) = strmatch(cfg.channelcmb(k,1), spike.label, 'exact');
  cmbindx(k,2) = strmatch(cfg.channelcmb(k,2), spike.label, 'exact');
end
nCmbs 	   = size(cmbindx,1);
chansel    = unique(cmbindx(:)); % get the unique channels
nChans     = length(chansel);
if isempty(chansel), error('No channel was selected'); end

% get the number of trials or change SPIKE according to cfg.trials
nTrials = size(spike.trialtime,1);
if  strcmp(cfg.trials,'all')
  cfg.trials = 1:nTrials;
elseif islogical(cfg.trials)
  cfg.trials = find(cfg.trials);
end
cfg.trials = sort(cfg.trials(:));
if max(cfg.trials)>nTrials, error('maximum trial number in cfg.trials should not exceed length of DATA.trial'); end
if isempty(cfg.trials), errors('No trials were selected in cfg.trials'); end
nTrials = length(cfg.trials);

% get the latencies
begTrialLatency = spike.trialtime(cfg.trials,1);
endTrialLatency = spike.trialtime(cfg.trials,2);
trialDur = endTrialLatency - begTrialLatency;

% select the latencies
if strcmp(cfg.latency,'minperiod')
  cfg.latency = [max(begTrialLatency) min(endTrialLatency)];
elseif strcmp(cfg.latency,'maxperiod')
  cfg.latency = [min(begTrialLatency) max(endTrialLatency)];
elseif strcmp(cfg.latency,'prestim')
  cfg.latency = [min(begTrialLatency) 0];
elseif strcmp(cfg.latency,'poststim')
  cfg.latency = [0 max(endTrialLatency)];
end

% check whether the time window fits with the data
if (cfg.latency(1) < min(begTrialLatency)), cfg.latency(1) = min(begTrialLatency);
  warning('Correcting begin latency of averaging window');
end
if (cfg.latency(2) > max(endTrialLatency)), cfg.latency(2) = max(endTrialLatency);
  warning('Correcting begin latency of averaging window');
end

% get the maximum number of lags in samples
fsample = (1/cfg.binsize);
if cfg.maxlag>(cfg.latency(2)-cfg.latency(1))
  warning('Correcting cfg.maxlag since it exceeds latency period');
  cfg.maxlag = (cfg.latency(2) - cfg.latency(1));
end
nLags        = round(cfg.maxlag*fsample);
lags         = (-nLags:nLags)/fsample; % create the lag axis

% check which trials will be used based on the latency
fullDur       = trialDur>=(cfg.maxlag); % only trials which are larger than maximum lag
overlaps      = endTrialLatency>(cfg.latency(1)+cfg.maxlag) & begTrialLatency<(cfg.latency(2)-cfg.maxlag);
hasWindow     = ones(nTrials,1);
if strcmp(cfg.vartriallen,'no') % only select trials that fully cover our latency window
  startsLater    = single(begTrialLatency>=single(cfg.latency(1)));
  endsEarlier    = single(endTrialLatency<=single(cfg.latency(2)));
  hasWindow      = ~(startsLater | endsEarlier); % check this in all other funcs
end
trialSel           = fullDur(:) & overlaps(:) & hasWindow(:);
cfg.trials         = cfg.trials(trialSel);
if isempty(cfg.trials), warning('No trials were selected'); end
if length(cfg.trials)<2&&doShiftPredictor
  error('Shift predictor can only be calculated with more than 1 selected trial.');
end

% if we allow variable trial lengths
if strcmp(cfg.vartriallen,'yes') && doShiftPredictor && nTrials~=length(cfg.trials)
  error('cfg.vartriallen = "yes" and shift predictor method are only possible when all trials contain the full window period');
end
nTrials   = length(cfg.trials); % only now reset nTrials

% preallocate the sum and the single trials and the shift predictor
keepTrials   = strcmp(cfg.keeptrials,'yes');
s     = zeros(nChans,nChans,2*nLags + 1); 
singleTrials = zeros(nTrials,nChans,nChans,2*nLags+1);    
if strcmp(cfg.method,'shiftpredictor'), singleTrials(1,:,:,:) = NaN; end

for iTrial = 1:nTrials
  origTrial = cfg.trials(iTrial);

  for iCmb = 1:nCmbs
    % take only the times that are in this trial and latency window
    indx  = cmbindx(iCmb,:);
    inTrial1 = spike.trial{indx(1)}==origTrial;
    inTrial2 = spike.trial{indx(2)}==origTrial;
    inWindow1 = spike.time{indx(1)}>=cfg.latency(1) &  spike.time{indx(1)}<=cfg.latency(2);
    inWindow2 = spike.time{indx(2)}>=cfg.latency(1) &  spike.time{indx(2)}<=cfg.latency(2);    
    ts1 = sort(spike.time{indx(1)}(inTrial1(:) & inWindow1(:)));
    ts2 = sort(spike.time{indx(2)}(inTrial2(:) & inWindow2(:)));
    
    switch cfg.method
      case 'xcorr'
        % compute the xcorr if both are non-empty
        if ~isempty(ts1) && ~isempty(ts2)
          if indx(1)<=indx(2)
            [x]   = spike_crossx(ts1(:),ts2(:),cfg.binsize,nLags*2+1);
          else
            [x]   = spike_crossx(ts2(:),ts1(:),cfg.binsize,nLags*2+1);
          end

          % sum the xcorr
          s(indx(1),indx(2),:) = s(indx(1),indx(2),:) + shiftdim(x(:),-2);
          s(indx(2),indx(1),:) = s(indx(2),indx(1),:) + shiftdim(flipud(x(:)),-2);

          % store individual trials if requested
          if keepTrials
            singleTrials(iTrial,indx(1),indx(2),:) = shiftdim(x(:),-3);
            singleTrials(iTrial,indx(2),indx(1),:) = shiftdim(flipud(x(:)),-3);
          end
        end
      case 'shiftpredictor'
        if iTrial>1
          % symmetric, get x21 to x12 and x22 to x11
          inTrial1_old = spike.trial{indx(1)}==cfg.trials(iTrial-1);
          ts1_old      = sort(spike.time{indx(1)}(inTrial1_old(:) & inWindow1(:)));
          inTrial2_old = spike.trial{indx(2)}==cfg.trials(iTrial-1);
          ts2_old      = sort(spike.time{indx(2)}(inTrial2_old(:) & inWindow2(:)));

          % compute both combinations
          for k = 1:2

            % take chan from this and previous channel
            if k==1
              A = ts1;
              B = ts2_old;
            else
              A = ts1_old;
              B = ts2;
            end
            if ~isempty(A) && ~isempty(B),
              if indx(1)<=indx(2)            
                [x]   = spike_crossx(A(:),B(:),cfg.binsize,nLags*2+1);
              else
                [x]   = spike_crossx(A(:),B(:),cfg.binsize,nLags*2+1);
              end
              % compute the sum
              s(indx(1),indx(2),:) =  s(indx(1),indx(2),:) + shiftdim(x(:),-2);
              s(indx(2),indx(1),:) =  s(indx(2),indx(1),:) + shiftdim(flipud(x(:)),-2);
              if keepTrials
                 singleTrials(iTrial,indx(1),indx(2),:) = shiftdim(x(:)/2,-3);
                 singleTrials(iTrial,indx(2),indx(1),:) = shiftdim(flipud(x(:))/2,-3);
              end              
            end
          end
        end
    end % symmetric shift predictor loop
  end % combinations
end % trial loop

% multiply the shift sum by a factor so it has the same scale as raw 
dofShiftPred = 2*(nTrials-1);
if doShiftPredictor, s = s*nTrials/dofShiftPred; end
switch cfg.outputunit
  case 'proportion'
    sm = repmat(nansum(s,3),[1 1 nLags*2 + 1]);
    s = s./sm;        
    if keepTrials
      singleTrials       = singleTrials./repmat(shiftdim(sm,-1),[nTrials 1 1 1]);
    end            
  case 'center'
      center   = repmat(s(:,:,nLags+1),[1 1 nLags*2 + 1]);
      s        = s./center;
      if keepTrials
        singleTrials       = singleTrials./repmat(shiftdim(center,-1),[nTrials 1 1 1]);
      end            
end

% return the results
stat.(cfg.method)      = s;
stat.time              = lags;
stat.dimord            = 'chan_chan_time'; 
if keepTrials
  stat.trial   = singleTrials;
  stat.dimord  = 'trial_chan_chan_time';
end
stat.label       = spike.label(chansel);

% do the general cleanup and bookkeeping at the end of the function
ft_postamble trackconfig
ft_postamble callinfo
ft_postamble previous spike
ft_postamble history Xcorr

