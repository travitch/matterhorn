{-# LANGUAGE MultiWayIf #-}
module Events where

import           Brick
import           Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import Data.Monoid ((<>))
import qualified Graphics.Vty as Vty
import           Lens.Micro.Platform

import           Prelude

import           Network.Mattermost.Lenses
import           Network.Mattermost.WebSocket.Types

import           Connection
import           State
import           State.Common
import           Types

import           Events.ShowHelp
import           Events.Main
import           Events.JoinChannel
import           Events.ChannelScroll
import           Events.ChannelSelect
import           Events.LeaveChannelConfirm
import           Events.UrlSelect

onEvent :: ChatState -> BrickEvent Name MHEvent -> EventM Name (Next ChatState)
onEvent st (AppEvent e) = onAppEvent st e
onEvent st (VtyEvent (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl])) = do
    Just vty <- getVtyHandle
    liftIO $ Vty.refresh vty
    continue st
onEvent st (VtyEvent e) = onVtyEvent st e
onEvent st _ = continue st

onAppEvent :: ChatState -> MHEvent -> EventM Name (Next ChatState)
onAppEvent st RefreshWebsocketEvent = do
  liftIO $ connectWebsockets st
  continue st
onAppEvent st WebsocketDisconnect =
  continue (st & csConnectionStatus .~ Disconnected)
onAppEvent st WebsocketConnect =
  continue =<< refreshLoadedChannels (st & csConnectionStatus .~ Connected)
onAppEvent st (WSEvent we) =
  handleWSEvent st we
onAppEvent st (RespEvent f) =
  continue =<< f st
onAppEvent st (AsyncErrEvent e) = do
  msg <- newClientMessage Error $
    "An unexpected error has occurred! The exception encountered was:\n  " <>
    T.pack (show e) <>
    "\nPlease report this error at https://github.com/aisamanra/matterhorn/issues"
  continue =<< addClientMessage msg st

onVtyEvent :: ChatState -> Vty.Event -> EventM Name (Next ChatState)
onVtyEvent st e = do
    case st^.csMode of
        Main                -> onEventMain st e
        ShowHelp            -> onEventShowHelp st e
        ChannelSelect       -> onEventChannelSelect st e
        UrlSelect           -> onEventUrlSelect st e
        LeaveChannelConfirm -> onEventLeaveChannelConfirm st e
        JoinChannel         -> onEventJoinChannel st e
        ChannelScroll       -> onEventChannelScroll st e

handleWSEvent :: ChatState -> WebsocketEvent -> EventM Name (Next ChatState)
handleWSEvent st we =
  case weEvent we of
    WMPosted -> case wepPost (weData we) of
      Just p  -> addMessage p st >>= continue
      Nothing -> continue st
    WMPostEdited -> case wepPost (weData we) of
      Just p  -> editMessage p st >>= continue
      Nothing -> continue st
    WMPostDeleted -> case wepPost (weData we) of
      Just p  -> deleteMessage p st >>= continue
      Nothing -> continue st
    WMStatusChange -> case wepStatus (weData we) of
      Just status -> updateStatus (weUserId we) status st >>= continue
      Nothing -> continue st
    WMChannelViewed -> case wepChannelId (weData we) of
      Just cId -> setLastViewedFor st cId >>= continue
      Nothing -> continue st
    WMUserAdded -> case weChannelId we of
      Just cId -> if weUserId we == st^.csMe.userIdL
                  then handleChannelInvite cId st >>= continue
                  else continue st
      Nothing -> continue st
    WMNewUser -> -- XXX
      continue st
    WMUserRemoved -> -- XXX
      continue st
    WMChannelDeleted -> -- XXX
      continue st
    WMDirectAdded -> -- XXX
      continue st
    WMLeaveTeam -> -- XXX: How do we deal with this one?
      continue st
    -- An 'ephemeral message' is just MatterMost's version
    -- of our 'client message'. This can be a little bit
    -- wacky, e.g. if the user types '/shortcuts' in the
    -- browser, we'll get an ephemeral message even in
    -- MatterHorn with the browser shortcuts, but it's
    -- probably a good idea to handle these messages anyway.
    WMEphemeralMessage -> case wepPost (weData we) of
      Just p  -> do
        msg <- newClientMessage Informative (p^.postMessageL)
        continue =<< addClientMessage msg st
      Nothing -> continue st
    -- Right now, we don't use any server preferences in
    -- our client, but that might change
    WMPreferenceChanged -> continue st
    -- This happens whenever a user connects to the server
    -- I think all the information we need (about being
    -- online or away or what-have-you) gets represented
    -- in StatusChanged messages, so we can ignore it.
    WMHello -> continue st
    -- right now we don't show typing notifications. maybe
    -- we should? i dunno.
    WMTyping -> continue st
