-- ModelLogreg.lua
-- weighted logistic regression

-- NOTE: This module is a port of code form ModelLogregNnBatch. However, only a
-- portion of the code was ported, namely the procedures around Bottou's method
-- for a full epoch. 

if false then
   m = ModelLogreg(X, y, s, nClasses)  -- s is a vector of saliences (importances)
   optimalTheta, fitInfo = m:fit(fittingOptions)  -- fittingOptions includes any regularizer
   predictions, predictionInfo = m:predict(newX, optimalTheta)
end

require 'isTensor'
require 'keyWithMinimumValue'
require 'Model'
require 'ObjectivefunctionLogregNnbatch'
require 'printTableValue'
require 'torch'
require 'vectorToString'

-------------------------------------------------------------------------------
-- CONSTRUCTION
-------------------------------------------------------------------------------

local ModelLogreg, parent = torch.class('ModelLogreg', 'Model')

-- ARGS
-- X        : 2D Tensor, each row a vector of features
-- y        : 1D Tensor of integers >= 1, class numbers
-- s        : 1D Tensor of saliences (weights)
-- nClasses : number of classes (max value in y)
function ModelLogreg:__init(X, y, s, nClasses, errorIfSupplied)
   assert(errorIfSupplied == nil, 'lambda is not supplied as part of call to method fit')

   parent.__init(self)

   assert(isTensor(X), 'X is not a torch.Tensor')
   assert(X:nDimension() == 2, 'X is not a 2D Tensor')
   self.nSamples = X:size(1)
   self.nFeatures = X:size(2)

   assert(isTensor(y), 'y is not a torch.Tensor')
   assert(y:nDimension() == 1, 'y is not a 1D Tensor')
   assert(y:size(1) == self.nSamples, 'y has incorrect size')

   assert(isTensor(s), 's is not a torch.Tensor')
   assert(s:nDimension() == 1, 's is not a 1D Tensor')
   assert(s:size(1) == self.nSamples, 's has incorrect size')

   assert(type(nClasses) == 'number', 'nClasses is not a number')
   assert(nClasses >= 2, 'number of classes is not at least 2')

   self.X = X
   self.y = y
   self.s = s
   self.nClasses = nClasses
end


-------------------------------------------------------------------------------
-- PUBLIC METHODS
-------------------------------------------------------------------------------

-- return optimalTheta and perhaps statistics and convergence info
-- ARGS
-- fittingOptions : table with these fields
--                  .method          : string in {'bottou', 'cg', ...}
--                  .sampling        : string in {'epoch', ...}
--                  .methodOptions   : table, some fields depend on method value
--                                     if method == 'bottou' the fields are these:
--                                     .callBackEndOfEpoch(lossBeforeStep, currentTheta, stepSize) : optional function
--                                     .initialStepSize                : number > 0
--                                     .nEpochsBeforeAdjustingStepSize : integer > 0
--                                     .nEpochsToAdjustStepSize        : integer > 0
--                                     .nextStepSizes                  ; function(currentSize) --> seq of new sizes
--                                     .printLoss : optional boolean default true
--                                                  whether to print each loss value
--                                     if method == 'cg' the fields are these:
--                                     .maxEval : number, max number of function evaluations
--                                     .maxIter : number, max number of iterations
--                  .samplingOptions : table, fields depend on sampling value
--                                     if sampling == 'epoch' the table has no fields
--                  .convergence     : table, possibly with no elements
--                                     if method == 'bottou' then the table contains at leat one of these fields
--                                     .maxEpochs      : number
--                                     .toleranceLoss  : number
--                                     .toleranceTheta : number
--                  .regularizer     : table with these optional fields
--                                    .L1 : optional number default 0, strength of L1 regularizer
--                                    .L2 : optional number default 0, strength of L2 regularizer
-- RETURNS
-- optimalTheta   : 1D Tensor of flat parameters
-- fitInfo        : table, dependent on method and sampling
--                  if method == 'bottou' and sampling == 'epoch', the fields are these:
--                  .convergedReason         : string
--                  .finalLoss               : number, loss before the last step taken
--                  .nEpochsUntilConvergence : number
--                  .optimalTheta            : 1D Tensor
--                  .evaluations             : sequence with each evalution, each element is another sequence
--                                             {'step', stepsize, loss-before-step}
--                                             {'explore', stepsize, loss-before-step}
--                                             The number of evaluations of the loss function is #evaluations
--                 .nCalls                  : table returned from Objectivefunction
--                                            number of times each Objectivefunction method was called
--                 if method == 'cg' and sampling == 'epoch' the fields are these:
--                 .functionEvals : table of function values f[#f] is value at optimalTheta
--                 .nFunctionEvals : number 
--
function ModelLogreg:runFit(fittingOptions)
   assert(fittingOptions ~= nil, 'missing arg fittingOptions')
   assert(type(fittingOptions) == 'table', 'fittingOptions not a table')

   self:_validate(fittingOptions)

   local method = fittingOptions.method
   local sampling = fittingOptions.sampling
   if method == 'bottou' and sampling == 'epoch' then
      local objectiveFunction, optimalTheta, fitInfo = self:_algoBottouEpoch(fittingOptions)
      self.objectiveFunction = objectiveFunction
      fitInfo.nCalls = objectiveFunction:getNCalls()
      return optimalTheta, fitInfo
   elseif method == 'cg' and sampling == 'epoch' then
      local objectiveFunction, optimalTheta, fitInfo = self:_algoCgEpoch(fittingOptions)
      self.objectiveFunction = objectiveFunction
      fitInfo.nCalls = objectiveFunction:getNCalls()
      return optimalTheta, fitInfo
   else
      error(string.format('invalid sampling scheme %s for method %s', sampling, method))
   end
end

-- return predictions and perhaps some other info
-- ARGS
-- newX  : 2D Tensor, each row is an observation
-- theta : 1D Tensor of parameters (often the optimalTheta returned by method fit()
-- RETURNS
-- predictions : 2D Tensor of probabilities
-- predictInfo : table
--               .mostLikelyClasses : 1D Tensor of integers, the most likely class numbers
function ModelLogreg:runPredict(newX, theta)
   local vp = makeVp(0, 'ModelLogreg:runrunPredict')
   vp(1, 'newX', newX, 'theta', theta)
   assert(newX ~= nil, 'newX is nil')
   assert(newX:nDimension() == 2, 'newX is not a 2D Tensor')
   
   assert(theta ~= nil, 'theta is nil')
   assert(theta:nDimension() == 1, 'theta is not a 1D Tensor')

   vp(1, 'self.objectivefunction', self.objectivefunction)
   local probs = self.objectiveFunction:predictions(newX, theta)
   vp(1, 'probs', probs)

   local nSamples = newX:size(1)
   local mostLikelyClasses = torch.Tensor(nSamples)
   for sampleIndex = 1, nSamples do
      mostLikelyClasses[sampleIndex] = argmax(probs[sampleIndex])
      vp(2, 'sampleIndex', sampleIndex, 
            'probs[]', probs[sampleIndex], 
            'mostLikelyClasses[]', mostLikelyClasses[sampleIndex])
   end

   vp(1, 'probs', probs, 'mostLikelyClasses', mostLikelyClasses)
   return probs,  {mostLikelyClasses = mostLikelyClasses}
end

-------------------------------------------------------------------------------
-- PRIVATE METHODS
-------------------------------------------------------------------------------

-- adjust the step size by testing several choices and return the best
-- "best" means the stepsize that reduces the current loss the most
-- ARGS
-- feval           : function(theta) --> loss, gradient
-- fittingOptions  : table
-- currentStepSize : number > 0
-- theta           : 1D Tensor
-- printLoss       : boolean
-- evaluations     : table for recording history
-- RETURNS
-- bestStepSize    : number
-- nextTheta       : 1D Tensor
-- lossBeforeStep  : number, the loss before the last step taken
function ModelLogreg:_adjustStepSizeAndStep(feval, methodOptions, currentStepSize, theta, printLoss, evaluations)
   local vp = makeVp(0, '_adjustStepSizeAndStep')
   vp(1, 'currentStepSize', currentStepSize)
   vp(2, 'theta', vectorToString(theta))
   local possibleNextStepSizes = methodOptions.nextStepSizes(currentStepSize)
   vp(3, 'possibleNextStepSizes', possibleNextStepSizes)
   local nSteps = methodOptions.nEpochsToAdjustStepSize
   vp(2, 'nSteps', nSteps)

   -- take nSteps using each possible step size
   local lossesAfterSteps = {}
   local lossesBeforeLastStep = {}
   local nextThetas = {}
   for _, stepSize in ipairs(possibleNextStepSizes) do
      local nextTheta, lossAfterSteps, lossBeforeLastStep = 
         self:_lossAfterNSteps(feval, stepSize, theta, nSteps)
      table.insert(evaluations, {'adjust', stepSize, lossAfterSteps})
      lossesAfterSteps[stepSize] = lossAfterSteps
      lossesBeforeLastStep[stepSize] = lossBeforeLastStep
      nextThetas[stepSize] = nextTheta
      vp(2, 'stepSize', stepSize, 'lossAfterSteps', lossAfterSteps)
      if printLoss then
         print(string.format('stepsize %f leads to loss of %f', stepSize, lossAfterSteps))
      end
   end

   local bestStepSize = keyWithMinimumValue(lossesAfterSteps)
   local nextTheta = nextThetas[bestStepSize]
   local lossBeforeStep = lossesBeforeLastStep[bestStepSize]
   vp(1, 'bestStepSize', bestStepSize)
   vp(1, 'nextTheta', vectorToString(nextTheta))
   vp(1, 'lossBeforeStep', lossBeforeStep)
   return bestStepSize, nextTheta, lossBeforeStep
end

-- fit using Conjugate gradient method on full epochs
-- RETURNS:
-- objectiveFunction
-- optimalTheta
-- fitInfo
function ModelLogreg:_algoCgEpoch(fittingOptions)
   local vp, verboseLevel = makeVp(0, '_algoCgEpoch')
   local vp2 = verboseLevel >= 2

   local of = ObjectivefunctionLogregNnbatch(self.X, self.y, self.s, self.nClasses, fittingOptions.regularizer.L2)
   local function feval(flatParameters)
      return of:lossGradient(flatParameters)
   end
   
   local initialTheta = of:initialTheta()

   local state = {
      maxEval = fittingOptions.methodOptions.maxEval,
      maxIter = fittingOptions.methodOptions.maxIter,
   }

   local optimalTheta, functionEvals, nFunctionEvals = optim.cg(feval, initialTheta, state)

   local fitInfo = {
      functionEvals = functionEvals,
      nFunctionEvals = nFunctionEvals,
      --convergedReason = ifelse(#functionEvals == maxEval + 1, 'maxIter', 'maxEval'),
   }
   self.fitInfo = fitInfo -- save a copy
   
   return of, optimalTheta, fitInfo

end

-- fit using Bottou's stepsize adjustment on full epochs
-- RETURNS:
-- objectiveFunction
-- optimalTheta
-- fitInfo
function ModelLogreg:_algoBottouEpoch(fittingOptions)
   local vp, verboseLevel, myName = makeVp(0, '_algoBottouEpoch')
   local vp2 = verboseLevel >= 2

   -- short hand
   local methodOptions = fittingOptions.methodOptions
   local callBackEndOfEpoch = methodOptions.callBackEndOfEpoch
   local printLoss = methodOptions.printLoss
   assert(printLoss == false)
   local stepSize = methodOptions.initialStepSize  -- some folks call this variable eta
   local nEpochsToAdjustStepSize = methodOptions.nEpochsToAdjustStepSize

   local convergence = fittingOptions.convergence

   -- setup the objective function feval
   local of = ObjectivefunctionLogregNnbatch(self.X, self.y, self.s, self.nClasses, fittingOptions.regularizer.L2)
   local function feval(flatParameters)
      return of:lossGradient(flatParameters)
   end

   -- initialize loop
   local previousLoss = nil
   local lossBeforeStep = nil
   local lossIncreasedOnLastStep = false
   local previousTheta = of:initialTheta()
   local nEpochsCompleted = 0
   local evaluations = {}  -- history of evaluations

   repeat -- until convergence
      if vp2 then
         vp(2, '----------------- loop restarts')
         vp(2, 'nEpochsCompleted', nEpochsCompleted, 'stepSize', stepSize)
         vp(2, 'previousLoss', previousLoss, 'previousTheta', vectorToString(previousTheta))
         vp(2, 'lossIncreasedOnLastStep', tostring(lossIncreasedOnLastStep))
      end
      if self:_timeToAdjustStepSize(nEpochsCompleted, methodOptions) or 
         lossIncreasedOnLastStep then
         -- adjust stepsize and take a step with the adjusted size
         if vp2 then vp(2, 'adjusting step size and stepping') end
         stepSize, nextTheta, lossBeforeStep = 
            self:_adjustStepSizeAndStep(feval, methodOptions, stepSize, previousTheta, printLoss, evaluations)
         nEpochsCompleted = nEpochsCompleted + nEpochsToAdjustStepSize
      else
         -- take a step with the current stepsize
         if vp2 then vp(2, 'stepping with current step size') end
         nextTheta, lossBeforeStep = self:_step(feval, stepSize, previousTheta)
         table.insert(evaluations, {'step', stepSize, lossBeforeStep})
         nEpochsCompleted = nEpochsCompleted + 1
      end

      vp(2, 'lossBeforeStep', lossBeforeStep, 'nextTheta', vectorToString(nextTheta))
      if printLoss then
         print(string.format(myName .. ' nEpochsCompleted %d stepSize %f lossBeforeStep %f',
                             nEpochsCompleted, stepSize, lossBeforeStep))
      end
      
      if callBackEndOfEpoch then
         callBackEndOfEpoch(lossBeforeStep, nextTheta, stepSize)
      end
      

      local hasConverged, convergedReason, relevantLimit = self:_converged(convergence, 
                                                                           nEpochsCompleted, 
                                                                           nextTheta, previousTheta, 
                                                                           lossBeforeStep, previousLoss)
      vp(2, 'hasConverged', hasConverged, 'convergedReason', convergedReason)

      if hasConverged then
         local fitInfo = {
            convergedReason = convergedReason,
            finalLoss = lossBeforeStep,
            nEpochsUntilConvergence = nEpochsCompleted,
            optimalTheta = nextTheta,
            evaluations = evaluations,
         }
         self.fitInfo = fitInfo  -- save a copy
         if printLoss then
            local function p(fieldName)
               print('converged fitInfo.' .. fieldName .. ' = ' .. tostring(fitInfo[fieldName]))
            end
            p('convergedReason')
            p('finalLoss')
            p('nEpochsUntilConvergence')
         end
         return of, nextTheta, fitInfo
      end
      
      -- Determine if loss is increasing, so that we can search for a smaller stepsize
      if previousLoss ~= nil then
         lossIncreasedOnLastStep = lossBeforeStep > previousLoss
         if lossIncreasedOnLastStep and printLoss then
            print(string.format('loss increased from %f to %f on epoch %d',
                                previousLoss, lossBeforeStep, nEpochsCompleted))
         end
      end
      
      previousLoss = lossBeforeStep
      previousTheta = nextTheta
   until false
   error('cannot get here')
end

-- determine if we have converged
-- RETURNS
-- hasConverged  : boolean
-- howConverged  : string, if hasConverged == true; reason for convergence
function ModelLogreg:_converged(convergence, 
                                nEpochsCompleted, 
                                nextTheta, previousTheta, 
                                nextLoss, previousLoss)
   local vp = makeVp(0, '_converged') 
   vp(2, 'nEpochsComplete', nEpochsCompleted)
   
   local maxEpochs = convergence.maxEpochs
   if maxEpochs ~= nil then
      if nEpochsCompleted >= maxEpochs then
         return true, 'maxEpochs'
      end
   end

   local toleranceLoss = convergence.toleranceLoss
   if toleranceLoss ~= nil then
      if previousLoss ~= nil then 
         if math.abs(nextLoss - previousLoss) < toleranceLoss then
            return true, 'toleranceLoss'
         end
      end
   end

   local toleranceTheta = convergence.toleranceTheta
   if toleranceTheta ~= nil then 
      if previousTheta ~= nil then
         if torch.norm(nextTheta - previousTheta) < toleranceTheta then
            return true, 'toleranceTheta'
         end
      end
   end

   vp(1, 'did not converge')
   return false, 'did not converge'
end

function ModelLogreg:_lossAfterNSteps(feval, stepSize, startingTheta, nSteps)
   local nextTheta = startingTheta
   local loss = nil
   for stepNumber = 1, nSteps do
      nextTheta, lossBeforeLastStep = self:_step(feval, stepSize, nextTheta)
   end

   local lossAfterSteps = feval(nextTheta)
   return nextTheta, lossAfterSteps, lossBeforeLastStep
end

function ModelLogreg:_setDefaultsBottou(methodOptions)
   if methodOptions.printLoss == nil then
      methodOptions.printLoss = true
   end
end

-- take a step in the direction of the gradient implied by theta
-- ARGS
-- feval       : function(theta) --> loss, gradient
-- stepSize    : number
-- theta       : 1D Tensor
-- RETURNS
-- nextTheta   : 1D Tensor, theta after the step
-- loss        : number, loss at the theta before the step
function ModelLogreg:_step(feval, stepSize, theta)
   local vp = makeVp(0, '_step')
   vp(1, 'stepSize', stepSize, 'theta', vectorToString(theta))
   local loss, gradient =feval(theta)  -- loss before step
   vp(2, 'gradient', vectorToString(gradient))
   local nextTheta = theta - gradient * stepSize
   vp(1, 'loss before step', loss, 'nextTheta', vectorToString(nextTheta))
   return nextTheta, loss
end

-- determine if the step size should be adjusted
-- ARGS
-- nEpochsCompleted : number of epochs already completed, in [0, infinity)
-- methodOptions    : table
-- RETURNS
-- adjustP : boolean, true if nEpochsCompleted >= nEpochsBeforeAdjustingStepSize
function ModelLogreg:_timeToAdjustStepSize(nEpochsCompleted, methodOptions)
   return (nEpochsCompleted % methodOptions.nEpochsBeforeAdjustingStepSize) == 0
end

function ModelLogreg:_hasOnlyFields(table, expectedFields)
   -- make set of all fields in the table
   local actualFieldsSet = {}
   for k, v in pairs(table) do
      actualFieldsSet[k] = true
   end
   
   -- convert fields arg into a set
   local expectedFieldsSet = {}
   for _, v in ipairs(expectedFields) do
      expectedFieldsSet[v] = true
   end

   local function contains(set, item)
      return set[item] == true
   end

   -- Is A a subset  of B?
   -- RETURNS
   -- boolean : result
   -- item    : option object in A but not in B
   local function isSubset(A, B)  -- a is a subset of b
      for item in pairs(A) do
         if not B[item] then
            return false, item
         end
      end
      return true
   end
   
   -- check that each set contains the other
   local subset, extraItem = isSubset(actualFieldsSet, expectedFieldsSet)
   if not subset then
      error('extra field ' .. extraItem)
   end

   local subset, extraItem = isSubset(expectedFieldsSet, actualFieldsSet)
   if not subset then
      error('missing field ' .. extraItem)
   end
end

function ModelLogreg:_validate(fittingOptions)
   self:_validateMethod(fittingOptions.method)
   self:_validateSampling(fittingOptions.sampling)
   self:_validateMethodOptions(fittingOptions.method, fittingOptions.methodOptions)
   self:_validateSamplingOptions(fittingOptions.sampling, fittingOptions.samplingOptions)
   self:_validateConvergence(fittingOptions.method, fittingOptions.convergence)
   self:_validateRegularizer(fittingOptions.regularizer)
end

function ModelLogreg:_validateConvergence(method, convergence)
   assert(convergence ~= nil, 'convergence table not supplied')

   if method ~= 'bottou' then
      return  -- no convergence options are needed unless the method is bottou
   end

   -- check options when method == 'bottou'
   if convergence.maxEpochs ~= nil then
      validateAttributes(convergence.maxEpochs, 'number', 'integer', 'positive')
   end

   if convergence.toleranceLoss ~= nil then
      validateAttributes(convergence.toleranceLoss, 'number', 'positive')
   end

   if convergence.toleranceTheta ~= nil then
      validateAttributes(convergence.toleranceTheta, 'number', 'positive')
   end

   assert(convergence.maxEpochs ~= nil or
          convergence.toleranceLoss ~= nil or
          convergence.toleranceTheta ~= nil,
          'at least one convergence options must be specified')
end


function ModelLogreg:_validateMethod(method)
   assert(method ~= nil, 'fittingOptions.method missing')
   assert(type(method) == 'string', '.method not a string')
   if method == 'bottou' or method == 'cg' then
      return
   else
      error(string.format('method %s is invalid', method))
   end
end

function ModelLogreg:_validateMethodOptions(method, methodOptions)
   assert(methodOptions ~= nil, 'fittingOptions.methodOptions missing')
   if method == 'bottou' then
      self:_setDefaultsBottou(methodOptions)  -- mutate methodOptions
      self:_validateMethodOptionsBottou(methodOptions)
   elseif method == 'cg' then
      self:_validateMethodOptionsCg(methodOptions)
   else
      error('cannot happend; method = ' .. method)
   end
end

function ModelLogreg:_validateMethodOptionsBottou(methodOptions)
   assert(type(methodOptions.printLoss) == 'boolean', 'fittingOptions.methodOptions.printLoss not boolean')
   self:_hasOnlyFields(methodOptions, 
                       {'printLoss', 
                        'initialStepSize', 
                        'nEpochsBeforeAdjustingStepSize', 
                        'nEpochsToAdjustStepSize', 
                        'nextStepSizes'})

   validateAttributes(methodOptions.initialStepSize, 'number', 'positive')
   validateAttributes(methodOptions.nEpochsBeforeAdjustingStepSize, 'number', 'integer', 'positive')
   validateAttributes(methodOptions.nEpochsToAdjustStepSize, 'number', 'integer', 'positive')
   assert(type(methodOptions.nextStepSizes) == 'function', 
          'methodOptions.nextStepSizes is not a function')

   
   if methodOptions.callBackEndOfEpoch ~= nil then
      assert(type(methodOptions.callBackEndOfEpoch == 'function',
                  'callBackEndOfEpoch not a function of (lossBeforeStep, nextTheta)'))
   end
end

function ModelLogreg:_validateMethodOptionsCg(methodOptions)
   self:_hasOnlyFields(methodOptions, 
                       {'maxEval',
                        'maxIter'})

   validateAttributes(methodOptions.maxEval, 'number', 'nonnegative')
   validateAttributes(methodOptions.maxIter, 'number', 'nonnegative')
end

function ModelLogreg:_validateRegularizer(regularizer)
   assert(regularizer ~= nil, 'regularizer table not supplied')

   if regularizer.L1 == nil then
      regularizer.L1 = 0
   end

   local L1 = regularizer.L1
   assert(type(L1) == 'number', 'L1 must be a number')
   assert(L1 == 0, 'for now, L1 regularizers are not implemented')

   if regularizer.L2 == nil then
      regularizer.L2 = 0
   end

   local L2 = regularizer.L2
   assert(type(L2) == 'number', 'L2 must be a number')
   assert(L2 >= 0, 'L2 must be non negative')
end 

function ModelLogreg:_validateSampling(sampling)
   assert(sampling ~= nil, 'fittingOptions.sampling missing')
   assert(type(sampling) == 'string', '.sampling not a string')
   assert(sampling == 'epoch', 'sampling not "epoch"')
end

function ModelLogreg:_validateSamplingOptions(sampling, samplingOptions)
   assert(samplingOptions ~= nil, 'fittingOptions.samplingOptions missing')
   if sampling == 'epoch' then
      self:_validateSamplingOptionsEpoch(samplingOptions)
   else
      error('impossible')
   end
end

function ModelLogreg:_validateSamplingOptionsEpoch(samplingOptions)
   for k, v in pairs(samplingOptions) do
      error('samplingOptions may have no fields when sampling == "epoch"')
   end
end
   
