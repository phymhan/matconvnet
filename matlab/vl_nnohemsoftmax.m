function y = vl_nnohemsoftmax(x, c, varargin)
%VL_NNOHEMSOFTMAX

if ~isempty(varargin) && ~ischar(varargin{1}) % passed in dzdy
    dzdy = varargin{1};
    varargin(1) = [];
else
    dzdy = [];
end

opts.instanceWeights = [];
opts.classFrequencies = [];
opts.classWeights = [];
opts.minKept = 0;
opts.maxKept = Inf;
opts.topK = 2;
opts.margin = -1;
opts.threshold = 0.6;
opts.softmax = [];
opts = vl_argparse(opts, varargin, 'nonrecursive');

inputSize = [size(x,1) size(x,2) size(x,3) size(x,4)];
minKept = opts.minKept * inputSize(4);
maxKept = opts.maxKept * inputSize(4);
if ~isempty(opts.classFrequencies)
    assert(opts.minKept > 0);
    assert(numel(opts.classFrequencies) == inputSize(3));
    opts.classFrequencies = opts.classFrequencies / sum(opts.classFrequencies);
end

c = gather(c);
c = double(c); % fix
if numel(c) == inputSize(4)
    c = reshape(c, [1 1 1 inputSize(4)]);
    c = repmat(c, inputSize(1:2));
end

hasIgnoreLabel = any(c(:) == 0);

% -------------------------------------------------------------------------
% Spatial weighting
% -------------------------------------------------------------------------

% work around a bug in MATLAB, where native cast() would slow progressively
if isa(x, 'gpuArray')
    switch classUnderlying(x)
        case 'single', cast = @(z) single(z);
        case 'double', cast = @(z) double(z);
    end
else
    switch class(x)
        case 'single', cast = @(z) single(z);
        case 'double', cast = @(z) double(z);
    end
end

labelSize = [size(c,1) size(c,2) size(c,3) size(c,4)];
assert(isequal(labelSize(1:2), inputSize(1:2)));
assert(labelSize(4) == inputSize(4));
instanceWeights = [];
% there must be one categorical label per prediction vector
assert(labelSize(3) == 1);

if hasIgnoreLabel
    % null labels denote instances that should be skipped
    instanceWeights = cast(c(:,:,1,:) ~= 0);
    c = c + (c == 0); % set null label to 1
end
if ~isempty(opts.instanceWeights)
    % important: this code needs to broadcast opts.instanceWeights to
    % an array of the same size as c
    if isempty(instanceWeights)
        instanceWeights = bsxfun(@times, onesLike(c), opts.instanceWeights);
    else
        instanceWeights = bsxfun(@times, instanceWeights, opts.instanceWeights);
    end
end
if ~isempty(opts.classWeights)
    assert(numel(opts.classWeights) == inputSize(3));
    if isempty(instanceWeights)
        instanceWeights = opts.classWeights(c);
    else
        instanceWeights = bsxfun(@times, instanceWeights, opts.classWeights(c));
    end
end

% -------------------------------------------------------------------------
% Do the work
% -------------------------------------------------------------------------

% from category labels to indexes
numPixelsPerImage = prod(inputSize(1:2));
numPixels = numPixelsPerImage * inputSize(4);
imageVolume = numPixelsPerImage * inputSize(3);

n = reshape(0:numPixels-1, labelSize);
offset = 1 + mod(n, numPixelsPerImage) + ...
    imageVolume * fix(n / numPixelsPerImage);
ci = offset + numPixelsPerImage * max(c - 1, 0);

if nargin <= 2 || isempty(dzdy)
    % forward pass, compute total softmax loss
    Xmax = max(x, [], 3);
    ex = exp(bsxfun(@minus, x, Xmax));
    t = Xmax + log(sum(ex, 3)) - x(ci);
    
    if ~isempty(instanceWeights)
        y = instanceWeights(:)' * t(:);
    else
        y = sum(t(:));
    end
    y = gather(y);
else
    % backward pass, only backprop hard examples
    if ~isempty(instanceWeights)
        dzdy = dzdy * instanceWeights;
    end
    if hasIgnoreLabel
        validFlag = c(:,:,1,:) ~= 0;
    else
        validFlag = true(size(c));
    end
    numValid = nnz(validFlag);
    Xmax = max(x, [], 3);
    ex = exp(bsxfun(@minus, x, Xmax));
    ex = bsxfun(@rdivide, ex, sum(ex, 3));
    if minKept < numValid
        pred = ex(ci(validFlag));
        if isempty(opts.classFrequencies)
            validFlag = sample_by_threshold(pred, validFlag, minKept, maxKept, opts);
        else
            label = c(validFlag);
            validFlagClass = sample_by_category(pred, label, validFlag, minKept, maxKept, opts);
            if nnz(validFlagClass) < minKept
                validFlagThresh = xor(validFlagClass, validFlag);
                predThresh = ex(ci(validFlagThresh));
                validFlagThresh = sample_by_threshold(predThresh, validFlagThresh, ...
                    minKept-nnz(validFlagClass), Inf, opts);
                validFlag = validFlagThresh | validFlagClass;
            else
                validFlag = validFlagClass;
            end
        end
    end
    y = bsxfun(@times, ex, validFlag);
    y(ci(validFlag)) = y(ci(validFlag)) - 1;
    % loss is devided by number of valid pixels
    y = bsxfun(@times, dzdy, y) ./ nnz(validFlag);
end

% -------------------------------------------------------------------------
function validFlag = sample_by_category(pred, label, validFlag, minKept, maxKept, opts)
% -------------------------------------------------------------------------
validInds = find(validFlag);
threshold = opts.threshold;
if minKept > 0 || maxKept < Inf
    predSorted = sort(pred, 1, 'ascend');
    if minKept > 0 && predSorted(min(numel(pred), minKept)) > opts.threshold
        threshold = predSorted(min(numel(pred), minKept));
    elseif maxKept < Inf && predSorted(min(numel(pred), maxKept)) < opts.threshold
        threshold = predSorted(min(numel(pred), maxKept));
    end
end
keptFlag = pred <= threshold;
numSamples = round(nnz(keptFlag) * opts.classFrequencies);
sampleInds = [];
for c_ = 1:numel(numSamples)
    flag_ = label == c_;
    if nnz(flag_) > numSamples(c_)
        [~, inds_] = sort(pred(flag_), 1, 'ascend');
        valid_ = validInds(flag_);
        inds_ = valid_(inds_(1:numSamples(c_)));
    else
        inds_ = validInds(flag_);
    end
    sampleInds = cat(1, sampleInds, inds_);
end
validFlag = false(size(validFlag));
validFlag(sampleInds) = true;

% -------------------------------------------------------------------------
function validFlag = sample_by_threshold(pred, validFlag, minKept, maxKept, opts)
% -------------------------------------------------------------------------
% If threshold <= 0, will just sample minKept points
validInds = find(validFlag);
threshold = opts.threshold;
if minKept > 0 || maxKept < Inf
    predSorted = sort(pred, 1, 'ascend');
    if minKept > 0 && predSorted(min(numel(pred), minKept)) > opts.threshold
        threshold = predSorted(min(numel(pred), minKept));
    elseif maxKept < Inf && predSorted(min(numel(pred), maxKept)) < opts.threshold
        threshold = predSorted(min(numel(pred), maxKept));
    end
end
keptFlag = pred <= threshold;
pred = pred(keptFlag);
validInds = validInds(keptFlag);
marginThreshold = opts.margin;
if opts.margin > 0
    topK = sort(ex, 3, 'descend');
    topK = topK(:,:,opts.topK,:);
    topK = topK(validInds);
    margin = pred - topK;
    if minKept > 0 || maxKept < Inf
        marginSorted = sort(margin, 1, 'ascend');
        if minKept > 0 && marginSorted(min(numel(margin), minKept)) > opts.margin
            marginThreshold = marginSorted(min(numel(margin), minKept));
        elseif maxKept < Inf && marginSorted(min(numel(margin), maxKept)) < opts.margin
            marginThreshold = marginSorted(min(numel(margin), maxKept));
        end
    end
    keptFlag = margin <= marginThreshold;
    validInds = validInds(keptFlag);
end
validFlag = false(size(validFlag));
validFlag(validInds) = true;

% -------------------------------------------------------------------------
function y = onesLike(x)
% -------------------------------------------------------------------------
if isa(x, 'gpuArray')
    y = gpuArray.ones(size(x), classUnderlying(x));
else
    y = ones(size(x), 'like', x);
end
