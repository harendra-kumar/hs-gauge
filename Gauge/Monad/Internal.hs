{-# LANGUAGE GeneralizedNewtypeDeriving, MultiParamTypeClasses #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

-- |
-- Module      : Gauge.Monad.Internal
-- Copyright   : (c) 2009 Neil Brown
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- The environment in which most criterion code executes.
module Gauge.Monad.Internal
    (
      Criterion(..)
    , Crit(..)
    ) where

-- Temporary: to support pre-AMP GHC 7.8.4:
import Control.Applicative

import Control.Monad.Catch (MonadThrow, MonadCatch, MonadMask)
import Control.Monad.Reader (MonadReader(..), ReaderT)
import Control.Monad.Trans (MonadIO)
import Gauge.Types (Config)
import Data.IORef (IORef)
import System.Random.MWC (GenIO)
import Prelude

data Crit = Crit {
    config   :: !Config
  , gen      :: !(IORef (Maybe GenIO))
  , overhead :: !(IORef (Maybe Double))
  }

-- | The monad in which most criterion code executes.
newtype Criterion a = Criterion {
      runCriterion :: ReaderT Crit IO a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch, MonadMask)

instance MonadReader Config Criterion where
    ask     = config `fmap` Criterion ask
    local f = Criterion . local fconfig . runCriterion
      where fconfig c = c { config = f (config c) }
