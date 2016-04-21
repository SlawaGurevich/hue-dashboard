
{-# LANGUAGE TemplateHaskell #-}

module AppDefs ( AppState(..)
               , asPC
               , asBC
               , AppT
               , AppIO
               ) where

import Control.Lens
import Control.Monad.State

import PersistConfig (PersistConfig)
import HueJSON (BridgeConfig)

-- Some definitions for the App module which we split out here

-- Application state
data AppState = AppState
    { _asPC :: !PersistConfig
    , _asBC :: !BridgeConfig
    }

makeLenses ''AppState

-- Our main application monad
type AppT m = StateT AppState m
type AppIO = AppT IO

