{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns, CPP, ForeignFunctionInterface,
    ScopedTypeVariables #-}

#if MIN_VERSION_base(4,10,0)
-- Disable deprecation warnings for now until we remove the use of getGCStats
-- and applyGCStats for good
{-# OPTIONS_GHC -Wno-deprecations #-}
#endif

-- |
-- Module      : Gauge.Measurement
-- Copyright   : (c) 2009-2014 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Benchmark measurement code.

module Gauge.Measurement
    (
      initializeTime
    , getTime
    , getCPUTime
    , getCycles
    , getGCStatistics
    , GCStatistics(..)
    , secs
    , measure
    , runBenchmark
    , runBenchmarkable
    , runBenchmarkable_
    , measured
    , applyGCStatistics
    , threshold
      -- * Deprecated
    , getGCStats
    , applyGCStats
    ) where

import Gauge.Types (Benchmarkable(..), Measured(..))
import Control.Applicative ((<*))
import Control.DeepSeq (NFData(rnf))
import Control.Exception (finally,evaluate)
import Data.Data (Data, Typeable)
import Data.Int (Int64)
import Data.List (unfoldr)
import Data.Word (Word64)
import Foreign.C (CLong(..))
import Foreign.Ptr (Ptr)
import GHC.Generics (Generic)
import GHC.Stats (GCStats(..))
#if MIN_VERSION_base(4,10,0)
import GHC.Stats (RTSStats(..), GCDetails(..))
#endif
import System.Mem (performGC)
import Text.Printf (printf)
import qualified Control.Exception as Exc
import qualified Data.Vector as V
import qualified GHC.Stats as Stats

-- | Statistics about memory usage and the garbage collector. Apart from
-- 'gcStatsCurrentBytesUsed' and 'gcStatsCurrentBytesSlop' all are cumulative values since
-- the program started.
--
-- 'GCStatistics' is cargo-culted from the 'GCStats' data type that "GHC.Stats"
-- has. Since 'GCStats' was marked as deprecated and will be removed in GHC 8.4,
-- we use 'GCStatistics' to provide a backwards-compatible view of GC statistics.
data GCStatistics = GCStatistics
    { -- | Total number of bytes allocated
    gcStatsBytesAllocated :: !Int64
    -- | Number of garbage collections performed (any generation, major and
    -- minor)
    , gcStatsNumGcs :: !Int64
    -- | Maximum number of live bytes seen so far
    , gcStatsMaxBytesUsed :: !Int64
    -- | Number of byte usage samples taken, or equivalently
    -- the number of major GCs performed.
    , gcStatsNumByteUsageSamples :: !Int64
    -- | Sum of all byte usage samples, can be used with
    -- 'gcStatsNumByteUsageSamples' to calculate averages with
    -- arbitrary weighting (if you are sampling this record multiple
    -- times).
    , gcStatsCumulativeBytesUsed :: !Int64
    -- | Number of bytes copied during GC
    , gcStatsBytesCopied :: !Int64
    -- | Number of live bytes at the end of the last major GC
    , gcStatsCurrentBytesUsed :: !Int64
    -- | Current number of bytes lost to slop
    , gcStatsCurrentBytesSlop :: !Int64
    -- | Maximum number of bytes lost to slop at any one time so far
    , gcStatsMaxBytesSlop :: !Int64
    -- | Maximum number of megabytes allocated
    , gcStatsPeakMegabytesAllocated :: !Int64
    -- | CPU time spent running mutator threads.  This does not include
    -- any profiling overhead or initialization.
    , gcStatsMutatorCpuSeconds :: !Double

    -- | Wall clock time spent running mutator threads.  This does not
    -- include initialization.
    , gcStatsMutatorWallSeconds :: !Double
    -- | CPU time spent running GC
    , gcStatsGcCpuSeconds :: !Double
    -- | Wall clock time spent running GC
    , gcStatsGcWallSeconds :: !Double
    -- | Total CPU time elapsed since program start
    , gcStatsCpuSeconds :: !Double
    -- | Total wall clock time elapsed since start
    , gcStatsWallSeconds :: !Double
    } deriving (Eq, Read, Show, Typeable, Data, Generic)

-- | Try to get GC statistics, bearing in mind that the GHC runtime
-- will throw an exception if statistics collection was not enabled
-- using \"@+RTS -T@\".
{-# DEPRECATED getGCStats
      ["GCStats has been deprecated in GHC 8.2. As a consequence,",
       "getGCStats has also been deprecated in favor of getGCStatistics.",
       "getGCStats will be removed in the next major gauge release."] #-}
getGCStats :: IO (Maybe GCStats)
getGCStats =
  (Just `fmap` Stats.getGCStats) `Exc.catch` \(_::Exc.SomeException) ->
  return Nothing

-- | Try to get GC statistics, bearing in mind that the GHC runtime
-- will throw an exception if statistics collection was not enabled
-- using \"@+RTS -T@\".
getGCStatistics :: IO (Maybe GCStatistics)
#if MIN_VERSION_base(4,10,0)
-- Use RTSStats/GCDetails to gather GC stats
getGCStatistics = do
  stats <- Stats.getRTSStats
  let gcdetails :: Stats.GCDetails
      gcdetails = gc stats

      nsToSecs :: Int64 -> Double
      nsToSecs ns = fromIntegral ns * 1.0E-9

  return $ Just GCStatistics {
      gcStatsBytesAllocated         = fromIntegral $ gcdetails_allocated_bytes gcdetails
    , gcStatsNumGcs                 = fromIntegral $ gcs stats
    , gcStatsMaxBytesUsed           = fromIntegral $ max_live_bytes stats
    , gcStatsNumByteUsageSamples    = fromIntegral $ major_gcs stats
    , gcStatsCumulativeBytesUsed    = fromIntegral $ cumulative_live_bytes stats
    , gcStatsBytesCopied            = fromIntegral $ gcdetails_copied_bytes gcdetails
    , gcStatsCurrentBytesUsed       = fromIntegral $ gcdetails_live_bytes gcdetails
    , gcStatsCurrentBytesSlop       = fromIntegral $ gcdetails_slop_bytes gcdetails
    , gcStatsMaxBytesSlop           = fromIntegral $ max_slop_bytes stats
    , gcStatsPeakMegabytesAllocated = fromIntegral (max_mem_in_use_bytes stats) `quot` (1024*1024)
    , gcStatsMutatorCpuSeconds      = nsToSecs $ mutator_cpu_ns stats
    , gcStatsMutatorWallSeconds     = nsToSecs $ mutator_elapsed_ns stats
    , gcStatsGcCpuSeconds           = nsToSecs $ gcdetails_cpu_ns gcdetails
    , gcStatsGcWallSeconds          = nsToSecs $ gcdetails_elapsed_ns gcdetails
    , gcStatsCpuSeconds             = nsToSecs $ cpu_ns stats
    , gcStatsWallSeconds            = nsToSecs $ elapsed_ns stats
    }
 `Exc.catch`
  \(_::Exc.SomeException) -> return Nothing
#else
-- Use the old GCStats type to gather GC stats
getGCStatistics = do
  stats <- Stats.getGCStats
  return $ Just GCStatistics {
      gcStatsBytesAllocated         = bytesAllocated stats
    , gcStatsNumGcs                 = numGcs stats
    , gcStatsMaxBytesUsed           = maxBytesUsed stats
    , gcStatsNumByteUsageSamples    = numByteUsageSamples stats
    , gcStatsCumulativeBytesUsed    = cumulativeBytesUsed stats
    , gcStatsBytesCopied            = bytesCopied stats
    , gcStatsCurrentBytesUsed       = currentBytesUsed stats
    , gcStatsCurrentBytesSlop       = currentBytesSlop stats
    , gcStatsMaxBytesSlop           = maxBytesSlop stats
    , gcStatsPeakMegabytesAllocated = peakMegabytesAllocated stats
    , gcStatsMutatorCpuSeconds      = mutatorCpuSeconds stats
    , gcStatsMutatorWallSeconds     = mutatorWallSeconds stats
    , gcStatsGcCpuSeconds           = gcCpuSeconds stats
    , gcStatsGcWallSeconds          = gcWallSeconds stats
    , gcStatsCpuSeconds             = cpuSeconds stats
    , gcStatsWallSeconds            = wallSeconds stats
    }
 `Exc.catch`
  \(_::Exc.SomeException) -> return Nothing
#endif

data RUsage = RUsage
    { ruUtime  :: Int64
    , ruStime  :: Int64
    , ruMaxrss :: Int64
    , ruMinflt :: Int64
    , ruMajflt :: Int64
    , ruNvcsw  :: Int64
    , ruNivcsw :: Int64
    }

-- | Measure the execution of a benchmark a given number of times.
measure :: Benchmarkable        -- ^ Operation to benchmark.
        -> Int64                -- ^ Number of iterations.
        -> IO (Measured, Double)
measure bm iters = runBenchmarkable bm iters addResults $ \act -> do
  startStats <- getGCStatistics
  startRUsage <- getRUsage
  startTime <- getTime
  startCpuTime <- getCPUTime
  startCycles <- getCycles
  act
  endTime <- getTime
  endCpuTime <- getCPUTime
  endCycles <- getCycles
  endRUsage <- getRUsage
  endStats <- getGCStatistics

  let diffRUsage f = f endRUsage - f startRUsage
  let !m = applyGCStatistics endStats startStats $ measured {
             measTime    = max 0 (endTime - startTime)
           , measCpuTime = max 0 (endCpuTime - startCpuTime)
           , measCycles  = max 0 (fromIntegral (endCycles - startCycles))
           , measUtime   = max 0 (diffRUsage ruUtime)
           , measStime   = max 0 (diffRUsage ruStime)
           , measMaxrss  = ruMaxrss endRUsage
           , measMinflt  = max 0 (diffRUsage ruMinflt)
           , measMajflt  = max 0 (diffRUsage ruMajflt)
           , measNvcsw   = max 0 (diffRUsage ruNvcsw)
           , measNivcsw  = max 0 (diffRUsage ruNivcsw)
           , measIters   = iters
           }
  return (m, endTime)
  where
    addResults :: (Measured, Double) -> (Measured, Double) -> (Measured, Double)
    addResults (!m1, !d1) (!m2, !d2) = (m3, d1 + d2)
      where
        add f = f m1 + f m2

        m3 = Measured
            { measTime               = add measTime
            , measCpuTime            = add measCpuTime
            , measCycles             = add measCycles
            , measIters              = add measIters

            , measUtime              = add measUtime
            , measStime              = add measStime
            , measMaxrss             = max (measMaxrss m1) (measMaxrss m2)
            , measMinflt             = add measMinflt
            , measMajflt             = add measMajflt
            , measNvcsw              = add measNvcsw
            , measNivcsw             = add measNivcsw

            , measAllocated          = add measAllocated
            , measNumGcs             = add measNumGcs
            , measBytesCopied        = add measBytesCopied
            , measMutatorWallSeconds = add measMutatorWallSeconds
            , measMutatorCpuSeconds  = add measMutatorCpuSeconds
            , measGcWallSeconds      = add measGcWallSeconds
            , measGcCpuSeconds       = add measGcCpuSeconds
            }
{-# INLINE measure #-}

-- | The amount of time a benchmark must run for in order for us to
-- have some trust in the raw measurement.
--
-- We set this threshold so that we can generate enough data to later
-- perform meaningful statistical analyses.
--
-- The threshold is 30 milliseconds. One use of 'runBenchmark' must
-- accumulate more than 300 milliseconds of total measurements above
-- this threshold before it will finish.
threshold :: Double
threshold = 0.03
{-# INLINE threshold #-}

runBenchmarkable :: Benchmarkable
                 -> Int64
                 -> (a -> a -> a)
                 -> (IO () -> IO a)
                 -> IO a
runBenchmarkable Benchmarkable{..} i comb f
    | perRun = work >>= go (i - 1)
    | otherwise = work
  where
    go 0 result = return result
    go !n !result = work >>= go (n - 1) . comb result

    count | perRun = 1
          | otherwise = i

    work = do
        env <- allocEnv count
        let clean = cleanEnv count env
            run = runRepeatedly env count

        clean `seq` run `seq` evaluate $ rnf env

        performGC
        f run `finally` clean <* performGC
    {-# INLINE work #-}
{-# INLINE runBenchmarkable #-}

runBenchmarkable_ :: Benchmarkable -> Int64 -> IO ()
runBenchmarkable_ bm i = runBenchmarkable bm i (\() () -> ()) id
{-# INLINE runBenchmarkable_ #-}

-- | Run a single benchmark, and return measurements collected while
-- executing it, along with the amount of time the measurement process
-- took.
runBenchmark :: Benchmarkable
             -> Double
             -- ^ Lower bound on how long the benchmarking process
             -- should take.  In practice, this time limit may be
             -- exceeded in order to generate enough data to perform
             -- meaningful statistical analyses.
             -> IO (V.Vector Measured, Double)
runBenchmark bm timeLimit = do
  runBenchmarkable_ bm 1
  start <- performGC >> getTime
  let loop [] !_ !_ _ = error "unpossible!"
      loop (iters:niters) prev count acc = do
        (m, endTime) <- measure bm iters
        let overThresh = max 0 (measTime m - threshold) + prev
        -- We try to honour the time limit, but we also have more
        -- important constraints:
        --
        -- We must generate enough data that bootstrapping won't
        -- simply crash.
        --
        -- We need to generate enough measurements that have long
        -- spans of execution to outweigh the (rather high) cost of
        -- measurement.
        if endTime - start >= timeLimit &&
           overThresh > threshold * 10 &&
           count >= (4 :: Int)
          then do
            let !v = V.reverse (V.fromList acc)
            return (v, endTime - start)
          else loop niters overThresh (count+1) (m:acc)
  loop (squish (unfoldr series 1)) 0 0 []

-- Our series starts its growth very slowly when we begin at 1, so we
-- eliminate repeated values.
squish :: (Eq a) => [a] -> [a]
squish ys = foldr go [] ys
  where go x xs = x : dropWhile (==x) xs

series :: Double -> Maybe (Int64, Double)
series k = Just (truncate l, l)
  where l = k * 1.05

-- | An empty structure.
measured :: Measured
measured = Measured {
      measTime               = 0
    , measCpuTime            = 0
    , measCycles             = 0
    , measIters              = 0

    , measUtime              = 0
    , measStime              = 0
    , measMaxrss             = 0
    , measMinflt             = 0
    , measMajflt             = 0
    , measNvcsw              = 0
    , measNivcsw             = 0

    , measAllocated          = minBound
    , measNumGcs             = minBound
    , measBytesCopied        = minBound
    , measMutatorWallSeconds = bad
    , measMutatorCpuSeconds  = bad
    , measGcWallSeconds      = bad
    , measGcCpuSeconds       = bad
    } where bad = -1/0

-- | Apply the difference between two sets of GC statistics to a
-- measurement.
{-# DEPRECATED applyGCStats
      ["GCStats has been deprecated in GHC 8.2. As a consequence,",
       "applyGCStats has also been deprecated in favor of applyGCStatistics.",
       "applyGCStats will be removed in the next major gauge release."] #-}
applyGCStats :: Maybe GCStats
             -- ^ Statistics gathered at the __end__ of a run.
             -> Maybe GCStats
             -- ^ Statistics gathered at the __beginning__ of a run.
             -> Measured
             -- ^ Value to \"modify\".
             -> Measured
applyGCStats (Just end) (Just start) m = m {
    measAllocated          = diff bytesAllocated
  , measNumGcs             = diff numGcs
  , measBytesCopied        = diff bytesCopied
  , measMutatorWallSeconds = diff mutatorWallSeconds
  , measMutatorCpuSeconds  = diff mutatorCpuSeconds
  , measGcWallSeconds      = diff gcWallSeconds
  , measGcCpuSeconds       = diff gcCpuSeconds
  } where diff f = f end - f start
applyGCStats _ _ m = m

-- | Apply the difference between two sets of GC statistics to a
-- measurement.
applyGCStatistics :: Maybe GCStatistics
                  -- ^ Statistics gathered at the __end__ of a run.
                  -> Maybe GCStatistics
                  -- ^ Statistics gathered at the __beginning__ of a run.
                  -> Measured
                  -- ^ Value to \"modify\".
                  -> Measured
applyGCStatistics (Just end) (Just start) m = m {
    measAllocated          = diff gcStatsBytesAllocated
  , measNumGcs             = diff gcStatsNumGcs
  , measBytesCopied        = diff gcStatsBytesCopied
  , measMutatorWallSeconds = diff gcStatsMutatorWallSeconds
  , measMutatorCpuSeconds  = diff gcStatsMutatorCpuSeconds
  , measGcWallSeconds      = diff gcStatsGcWallSeconds
  , measGcCpuSeconds       = diff gcStatsGcCpuSeconds
  } where diff f = f end - f start
applyGCStatistics _ _ m = m

-- | Convert a number of seconds to a string.  The string will consist
-- of four decimal places, followed by a short description of the time
-- units.
secs :: Double -> String
secs k
    | k < 0      = '-' : secs (-k)
    | k >= 1     = k        `with` "s"
    | k >= 1e-3  = (k*1e3)  `with` "ms"
#ifdef mingw32_HOST_OS
    | k >= 1e-6  = (k*1e6)  `with` "us"
#else
    | k >= 1e-6  = (k*1e6)  `with` "μs"
#endif
    | k >= 1e-9  = (k*1e9)  `with` "ns"
    | k >= 1e-12 = (k*1e12) `with` "ps"
    | k >= 1e-15 = (k*1e15) `with` "fs"
    | k >= 1e-18 = (k*1e18) `with` "as"
    | otherwise  = printf "%g s" k
     where with (t :: Double) (u :: String)
               | t >= 1e9  = printf "%.4g %s" t u
               | t >= 1e3  = printf "%.0f %s" t u
               | t >= 1e2  = printf "%.1f %s" t u
               | t >= 1e1  = printf "%.2f %s" t u
               | otherwise = printf "%.3f %s" t u

-- | Set up time measurement.
foreign import ccall unsafe "gauge_inittime" initializeTime :: IO ()

-- | Read the CPU cycle counter.
foreign import ccall unsafe "gauge_rdtsc" getCycles :: IO Word64

-- | Return the current wallclock time, in seconds since some
-- arbitrary time.
--
-- You /must/ call 'initializeTime' once before calling this function!
foreign import ccall unsafe "gauge_gettime" getTime :: IO Double

-- | Return the amount of elapsed CPU time, combining user and kernel
-- (system) time into a single measure.
foreign import ccall unsafe "gauge_getcputime" getCPUTime :: IO Double

-- rusage accessor functions
-- XXX All fields of rusage may not be available on MinGW
foreign import ccall unsafe "gauge_getrusage" c_getRUsage :: IO (Ptr RUsage)

foreign import ccall unsafe "gauge_getrusage_utime" c_getRUutime
    :: Ptr RUsage -> IO CLong
foreign import ccall unsafe "gauge_getrusage_stime" c_getRUstime
    :: Ptr RUsage -> IO CLong
foreign import ccall unsafe "gauge_getrusage_maxrss" c_getRUmaxrss
    :: Ptr RUsage -> IO CLong
foreign import ccall unsafe "gauge_getrusage_minflt" c_getRUminflt
    :: Ptr RUsage -> IO CLong
foreign import ccall unsafe "gauge_getrusage_majflt" c_getRUmajflt
    :: Ptr RUsage -> IO CLong
foreign import ccall unsafe "gauge_getrusage_nvcsw" c_getRUnvcsw
    :: Ptr RUsage -> IO CLong
foreign import ccall unsafe "gauge_getrusage_nivcsw" c_getRUnivcsw
    :: Ptr RUsage -> IO CLong

getRUsage :: IO RUsage
getRUsage = do
    ru <- c_getRUsage
    -- ru points to static memory, copy it over
    utime  <- c_getRUutime ru
    stime  <- c_getRUstime ru
    maxrss <- c_getRUmaxrss ru
    minflt <- c_getRUminflt ru
    majflt <- c_getRUmajflt ru
    nvcsw  <- c_getRUnvcsw ru
    nivcsw <- c_getRUnivcsw ru

    return RUsage
        { ruUtime  = (fromInteger . toInteger) utime
        , ruStime  = (fromInteger . toInteger) stime
        , ruMaxrss = (fromInteger . toInteger) maxrss
        , ruMinflt = (fromInteger . toInteger) minflt
        , ruMajflt = (fromInteger . toInteger) majflt
        , ruNvcsw  = (fromInteger . toInteger) nvcsw
        , ruNivcsw = (fromInteger . toInteger) nivcsw
        }
