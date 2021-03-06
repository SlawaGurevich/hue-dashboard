
{-# LANGUAGE OverloadedStrings, TemplateHaskell, FlexibleContexts, RankNTypes, LambdaCase #-}

module WebUIHelpers where

import Data.Monoid
import Data.Maybe
import Data.Hashable
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Concurrent.STM
import Graphics.UI.Threepenny.Core
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

import Util
import Trace
import HueJSON
import PersistConfig
import AppDefs (AppEnv)

-- Some utility functions split out from the WebUI / WebUITileBuilding modules

-- We build our page in a monad stack that provides the application environment and a
-- place to store all the event handlers and HTML elements that comprise it

data Page = Page { _pgTiles     :: ![H.Html]  -- Functions to generate all the tiles in the page
                 , _pgUIActions :: ![UI ()]   -- Functions to register all event handlers etc.
                                              --   once the page has been build
                 }

makeLenses ''Page

type PageBuilder = StateT Page (ReaderT AppEnv IO)

addPageTile :: MonadState Page m => H.Html -> m ()
addPageTile tile = pgTiles %= (tile :)

addPageUIAction :: MonadState Page m => UI () -> m ()
addPageUIAction action = pgUIActions %= (action :)

-- Opacities used for enabled and disabled elements
enabledOpacity, disabledOpacity :: Float
enabledOpacity  = 1.0
disabledOpacity = 0.3

-- Amount of brightness changed when any brightness widget is used
brightnessChange :: Int
brightnessChange = 25 -- Relative to 255

-- Build a string for the id field in a light specific DOM object. Do this in one
-- place as we need to locate them later when we want to update

buildLightID :: LightID -> String -> String
buildLightID lightID elemName = "light-" <> fromLightID lightID <> "-" <> elemName

buildGroupID :: GroupName -> String -> String
buildGroupID groupName elemName =
    "light-" <>
    -- We use the hash of the group name, just in case the user
    -- used characters not valid for element IDs
    (show . hash $ fromGroupName groupName) <>
    "-" <> elemName

-- Throw an exception if we can't find the element. This is mostly an artifact from older
-- versions of threepenny which never returned Nothing and just broke on the client with a
-- JS error, hanging everything and forcing a reload
--
-- TODO: Now that invalid elements are returned properly as Nothing, we should probably
--       think about a less 'exceptional' method of dealing with these
--
getElementByIdSafe :: Window -> String -> UI Element
getElementByIdSafe window elementID =
    getElementById window elementID >>= \case
        Nothing -> traceAndThrow $ "getElementByIdSafe: Invalid element ID: " <> elementID
        Just e  -> return e

-- Register event handlers directly on an element ID string. Why do we need this? Earlier
-- versions of threepenny required a client server roundtrip to add DOM elements. To avoid
-- this overhead, we build the DOM as HTML server side and submit it with a single
-- runFunction call. The DOM building has since been fixed, but we still use the HTML
-- generation (for various reasons). Unfortunately, registering event handlers requires a
-- threepenny Element and getting one without the native DOM building combinators requires
-- a call to getElementById, which does a roundtrip. So each event handler does a full
-- client server roundtrip, very slow. These wrapper functions here register an event
-- handler without the roundtrip / wait when used in combination with the new batching
-- mode for runFunction calls (setCallBufferMode BufferRun). See the following bug for a
-- full discussion and background:
--
-- https://github.com/HeinrichApfelmus/threepenny-gui/issues/131

onElementIDClick :: String -> UI void -> UI ()
onElementIDClick elementID handler = do
    window   <- askWindow
    exported <- ffiExport $ runUI window handler >> return ()
    runFunction $ ffi "$(%1).on('click', %2)" ("#" ++ elementID) exported

onElementIDMouseDown :: String -> (Int -> Int -> UI void) -> UI ()
onElementIDMouseDown elementID handler = do
    window   <- askWindow
    exported <- ffiExport (\mx my -> runUI window (handler mx my) >> return ())
    runFunction $ ffi
        ( "$(%1).on('mousedown', function(e) " ++
          "{ var offs = $(this).offset(); %2(e.pageX - offs.left, e.pageY - offs.top); })"
        )
        ("#" ++ elementID)
        exported

-- TODO: Those any* functions duplicate functionality already have in App.fetchBridgeState

anyLightsOn :: Lights -> Bool
anyLightsOn lights = any (^. _2 . lgtState . lsOn) $ HM.toList lights

anyLightsInGroup :: GroupName -> LightGroups -> Lights -> (Light -> Bool) -> Bool
anyLightsInGroup groupName groups lights condition =
    case HM.lookup groupName groups of
        Nothing          -> False
        Just groupLights ->
            or . map condition . catMaybes . map (flip HM.lookup lights) . HS.toList $ groupLights

-- Reload the page (TODO: Maybe we can do something more granular, just repopulate a div?)
reloadPage :: UI ()
reloadPage = runFunction $ ffi "window.location.reload(false);"

-- Apply a lens getter to the user data for the passed user ID
queryUserData :: TVar PersistConfig -> CookieUserID -> Getter UserData a -> STM a
queryUserData tvPC userID g = getUserData tvPC userID <&> (^. g)
getUserData :: TVar PersistConfig -> CookieUserID -> STM UserData
getUserData tvPC userID = readTVar tvPC <&> (^. pcUserData . at userID . non defaultUserData)

-- Captions for the show / hide group button
grpShownCaption, grpHiddenCaption :: String
grpShownCaption  = "Hide ◄"
grpHiddenCaption = "Show ►"

trucateEllipsis :: Int -> String -> String
trucateEllipsis maxLength str
    | length str > maxLength = take maxLength str <> "…"
    | otherwise              = str

-- TODO: Make the delete button small and the edit button large
addEditAndDeleteButton :: String -> String -> String -> String -> H.Html
addEditAndDeleteButton editDeleteDivID
                       editBtnOnClick
                       deleteConfirmDivID
                       deleteConfirmBtnID = do
   H.div H.! A.id (H.toValue deleteConfirmDivID)
         H.! A.class_ "btn-group btn-group-sm"
         H.! A.style "display: none;" $ do
     H.button H.! A.type_ "button"
              H.! A.class_ "btn btn-scene btn-sm"
              H.! A.onclick ( H.toValue $
                                "this.parentNode.style.display = 'none'; getElementById('"
                                <> editDeleteDivID <> "').style.display = 'block';"
                            ) $
                H.span H.! A.class_ "glyphicon glyphicon-chevron-left edit-back-btn" $ return ()
     H.button H.! A.type_ "button"
              H.! A.id (H.toValue deleteConfirmBtnID)
              H.! A.class_ "btn btn-danger btn-sm delete-confirm-btn"
              $ "Confirm"
   H.div H.! A.id (H.toValue editDeleteDivID)
         H.! A.class_ "btn-group btn-group-sm" $ do
     H.button H.! A.type_ "button"
              H.! A.class_ "btn btn-scene btn-sm"
              H.! A.onclick (H.toValue editBtnOnClick) $
                H.span H.! A.class_ "glyphicon glyphicon-th-list edit-back-btn" $ return ()
     H.button H.! A.type_ "button"
              H.! A.class_ "btn btn-danger btn-sm delete-confirm-btn"
              H.! A.onclick ( H.toValue $
                                "this.parentNode.style.display = 'none'; getElementById('"
                                <> deleteConfirmDivID <> "').style.display = 'block';"
                            )
              $ "Delete"

